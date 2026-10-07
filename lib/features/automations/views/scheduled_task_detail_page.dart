import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/automations/automation_schedule.dart';
import 'package:conduit_core/features/automations/models/automation.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/features/channels/providers/channel_providers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';

import '../../../core/services/haptic_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/services/navigation_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../navigation/providers/conversation_selection_provider.dart';
import 'scheduled_task_format.dart';
import 'scheduled_tasks_page.dart';

/// How often history is read while waiting for a run the user asked for.
@visibleForTesting
const scheduledTaskRunPollInterval = Duration(seconds: 5);

/// How many history reads a Run now waits before it stops watching, about two
/// minutes at [scheduledTaskRunPollInterval].
@visibleForTesting
const scheduledTaskRunPollLimit = 24;

/// Where a Run now the user pressed on this screen stands.
enum _RunPhase {
  idle,

  /// The run request is on its way to the server.
  requesting,

  /// The server accepted the request; history is read until the run shows.
  waiting,
  finished,
  failed,

  /// The run did not show in history in time. It may still finish.
  timedOut,
}

/// One scheduled task: its definition as the server holds it, controls that
/// call the server, and its run history.
///
/// The history is separate from the definition. Asking for a run only asks;
/// the server records the outcome when the run finishes, so after Run now the
/// screen reads History until a run newer than the request appears.
class ScheduledTaskDetailPage extends StatelessWidget {
  const ScheduledTaskDetailPage({super.key, required this.taskId});

  final String taskId;

  @override
  Widget build(BuildContext context) =>
      ScheduledTasksGate(child: _TaskDetail(taskId: taskId));
}

class _TaskDetail extends ConsumerStatefulWidget {
  const _TaskDetail({required this.taskId});

  final String taskId;

  @override
  ConsumerState<_TaskDetail> createState() => _TaskDetailState();
}

class _TaskDetailState extends ConsumerState<_TaskDetail> {
  /// The account this screen was opened for, captured before anything is
  /// awaited. Every request and every navigation is for this account only.
  late final AutomationsOwner? _owner;
  Automation? _task;
  Object? _loadError;
  List<AutomationRun> _runs = const [];

  /// Counts the History reads Run now merged into [_runs], so a page read
  /// that started earlier adds to them instead of replacing them.
  int _runsMerges = 0;
  bool _runsLoading = false;
  bool _runsFailed = false;
  bool _hasMoreRuns = false;

  /// The state the switch was moved to, shown until the server answers.
  bool? _pendingActive;
  bool _deleting = false;

  _RunPhase _runPhase = _RunPhase.idle;

  /// Why the last Run now was refused, shown next to the control.
  String? _runError;
  Timer? _runPoll;

  /// The run Run now found in History, newer than anything this screen knew
  /// when it was asked for, until the task is read again.
  AutomationRun? _requestedRun;
  int _runPolls = 0;
  bool _runPollInFlight = false;

  Automations get _notifier => ref.read(automationsProvider.notifier);

  bool get _runBusy =>
      _runPhase == _RunPhase.requesting || _runPhase == _RunPhase.waiting;

  @override
  void initState() {
    super.initState();
    _owner = _notifier.captureOwner();
    _load();
  }

  @override
  void dispose() {
    _runPoll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final owner = _owner;
    if (owner == null) {
      setState(() => _loadError = AutomationsOwnerChangedException());
      return;
    }
    try {
      final task = await _notifier.fetch(widget.taskId, owner: owner);
      _requireOwner(owner);
      setState(() {
        _task = task;
        _requestedRun = null;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadError = error);
      return;
    }
    await _loadRuns(reset: true);
  }

  /// Throws unless this screen is still showing and [owner] is still the
  /// signed-in account. Whatever finished for another account must not change
  /// what this screen shows or where it goes.
  void _requireOwner(AutomationsOwner owner) {
    if (!mounted || !_notifier.isCurrentOwner(owner)) {
      throw AutomationsOwnerChangedException();
    }
  }

  Future<void> _loadRuns({required bool reset}) async {
    final owner = _owner;
    if (owner == null || _runsLoading) return;
    setState(() {
      _runsLoading = true;
      _runsFailed = false;
    });
    final merges = _runsMerges;
    try {
      final page = await _notifier.runs(
        widget.taskId,
        skip: reset ? 0 : _runs.length,
        owner: owner,
      );
      _requireOwner(owner);
      setState(() {
        // A Run now read that landed while this one was on its way holds
        // newer runs than this page, so they are kept ahead of it.
        final keep = !reset || merges != _runsMerges;
        final known = keep ? {for (final run in _runs) run.id} : <String>{};
        _runs = [
          if (keep) ..._runs,
          for (final run in page)
            if (known.add(run.id)) run,
        ];
        // A page shorter than the page size is the last one.
        _hasMoreRuns = page.length >= automationRunsPageSize;
      });
    } catch (_) {
      if (mounted) setState(() => _runsFailed = true);
    } finally {
      if (mounted) setState(() => _runsLoading = false);
    }
  }

  void _showError(String message) {
    UiUtils.showMessage(context, message, isError: true);
  }

  /// Moves the switch at once and asks the server. A refusal puts the switch
  /// back and says why.
  Future<void> _setActive(bool active) async {
    final owner = _owner;
    final l10n = AppLocalizations.of(context)!;
    if (owner == null || _pendingActive != null) return;
    setState(() => _pendingActive = active);
    try {
      final task = await _notifier.setActive(
        widget.taskId,
        active,
        owner: owner,
      );
      // The change was made for the previous account and stays made; it is
      // not shown as this account's task.
      _requireOwner(owner);
      setState(() {
        _task = task;
        _pendingActive = null;
      });
      // Android's switch already clicked when it moved.
      if (PlatformInfo.isIOS) unawaited(ConduitHaptics.success());
    } catch (error) {
      if (!mounted) return;
      setState(() => _pendingActive = null);
      _showError(
        scheduledTaskErrorText(
          l10n,
          error,
          fallback: l10n.scheduledTaskChangeFailed,
        ),
      );
    }
  }

  /// Asks the server to run the task once, then reads History until a run
  /// newer than the request shows, for up to [scheduledTaskRunPollLimit]
  /// reads. The request's reply only means the server accepted it.
  Future<void> _run() async {
    final owner = _owner;
    final l10n = AppLocalizations.of(context)!;
    if (owner == null || _runBusy) return;
    // What History held before the request. A run is the requested one only
    // if it is not one of these and is not older than the newest of them,
    // the task's own last run time included when History is not loaded.
    final before = <AutomationRun>[..._runs, ?_task?.lastRun, ?_requestedRun];
    final knownIds = {for (final run in before) run.id};
    int? newestBefore = _task?.lastRunAtNs;
    for (final run in before) {
      final at = run.createdAtNs;
      if (at != null && (newestBefore == null || at > newestBefore)) {
        newestBefore = at;
      }
    }
    _runPoll?.cancel();
    setState(() {
      _runPhase = _RunPhase.requesting;
      _runError = null;
    });
    try {
      final accepted = await _notifier.run(widget.taskId, owner: owner);
      _requireOwner(owner);
      setState(() {
        _task = accepted;
        _runPhase = _RunPhase.waiting;
      });
      _runPolls = 0;
      _runPoll = Timer.periodic(
        scheduledTaskRunPollInterval,
        (_) => _pollRun(owner, knownIds, newestBefore),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _runPhase = _RunPhase.idle;
        _runError = scheduledTaskErrorText(
          l10n,
          error,
          fallback: l10n.scheduledTaskRunRequestFailed,
        );
      });
    }
  }

  void _stopRunPolling() {
    _runPoll?.cancel();
    _runPoll = null;
  }

  /// One History read while a run is awaited. It stops for good once this
  /// screen is gone or belongs to an account that is no longer signed in.
  Future<void> _pollRun(
    AutomationsOwner owner,
    Set<String> knownIds,
    int? newestBefore,
  ) async {
    if (!mounted || !_notifier.isCurrentOwner(owner)) {
      _stopRunPolling();
      if (mounted) {
        setState(() {
          _runPhase = _RunPhase.idle;
          _runError = AppLocalizations.of(context)!.scheduledTasksAccountChanged;
        });
      }
      return;
    }
    if (_runPollInFlight) return;
    _runPollInFlight = true;
    _runPolls++;
    try {
      final page = await _notifier.runs(widget.taskId, owner: owner);
      _requireOwner(owner);
      if (_runPhase != _RunPhase.waiting) return;
      // A run without a time can only be told apart from older ones when
      // nothing ran before.
      final requested = page.where((run) {
        if (knownIds.contains(run.id)) return false;
        final at = run.createdAtNs;
        return newestBefore == null || (at != null && at >= newestBefore);
      }).firstOrNull;
      setState(() {
        _runsMerges++;
        final known = <String>{};
        _runs = [
          for (final run in page)
            if (known.add(run.id)) run,
          for (final run in _runs)
            if (known.add(run.id)) run,
        ];
        if (_runsFailed || _runs.length == page.length) {
          _hasMoreRuns = page.length >= automationRunsPageSize;
        }
        _runsFailed = false;
        if (requested != null) {
          _requestedRun = requested;
          _runPhase = requested.succeeded
              ? _RunPhase.finished
              : _RunPhase.failed;
        }
      });
      if (requested != null) _stopRunPolling();
    } on AutomationsOwnerChangedException {
      _stopRunPolling();
      if (mounted) {
        setState(() {
          _runPhase = _RunPhase.idle;
          _runError = AppLocalizations.of(context)!.scheduledTasksAccountChanged;
        });
      }
    } catch (_) {
      // A failed read is tried again on the next tick.
    } finally {
      _runPollInFlight = false;
      if (mounted &&
          _runPhase == _RunPhase.waiting &&
          _runPolls >= scheduledTaskRunPollLimit) {
        _stopRunPolling();
        setState(() => _runPhase = _RunPhase.timedOut);
      }
    }
  }

  Future<void> _delete() async {
    final task = _task;
    if (task == null || _deleting) return;
    final owner = _owner;
    final l10n = AppLocalizations.of(context)!;
    final route = ModalRoute.of(context);
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.scheduledTaskDeleteTitle,
      message: l10n.scheduledTaskDeleteConfirm(task.name),
      confirmText: l10n.delete,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _deleting = true);
    try {
      if (owner == null) throw AutomationsOwnerChangedException();
      await _notifier.remove(widget.taskId, owner: owner);
      _requireOwner(owner);
      _stopRunPolling();
      // Leave this page, not one opened over it while the request ran.
      if (mounted && (route?.isCurrent ?? true)) context.pop();
    } catch (error) {
      if (mounted) {
        _showError(
          scheduledTaskErrorText(l10n, error, fallback: l10n.errorMessage),
        );
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _edit() async {
    await context.pushNamed<Object?>(
      RouteNames.scheduledTaskEdit,
      pathParameters: {'id': widget.taskId},
    );
    // Reopening shows what the server holds now.
    if (mounted) await _load();
  }

  /// Opens what a run produced, for the account this screen was opened for.
  /// A screen that outlived an account switch refuses rather than navigating
  /// the next account to a chat id that is not theirs.
  Future<void> _openResult(AutomationRun run) async {
    final owner = _owner;
    final l10n = AppLocalizations.of(context)!;
    if (owner == null || !_notifier.isCurrentOwner(owner)) {
      UiUtils.showMessage(
        context,
        l10n.scheduledTasksAccountChanged,
        isError: true,
      );
      return;
    }
    final channelId = run.resultChannelId;
    if (channelId != null) {
      // Channels live in the shell that is already mounted under this page.
      // Pushing into it again reserves its page key twice.
      context.goNamed(RouteNames.channel, pathParameters: {'id': channelId});
      return;
    }
    final chatId = run.resultChatId;
    if (chatId == null) return;

    final originRoute = NavigationService.currentRoute;
    final originRevision = NavigationService.currentRouteRevision;
    final when =
        dateTimeFromEpochNanoseconds(run.createdAtNs) ?? DateTime.now();
    final result = await ref
        .read(conversationSelectionProvider.notifier)
        .select(
          Conversation(
            id: chatId,
            title: _task?.name ?? '',
            createdAt: when,
            updatedAt: when,
          ),
        );
    if (!mounted ||
        !_notifier.isCurrentOwner(owner) ||
        NavigationService.currentRoute != originRoute ||
        NavigationService.currentRouteRevision != originRevision) {
      return;
    }
    switch (result.disposition) {
      case ConversationSelectionDisposition.committed:
        context.go(Routes.chat);
      case ConversationSelectionDisposition.canceled:
        break;
      case ConversationSelectionDisposition.failed:
        UiUtils.showMessage(
          context,
          l10n.scheduledTaskOpenResultFailed,
          isError: true,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final task = _task;
    if (task == null) {
      return UtilityPageScaffold.settings(
        title: l10n.scheduledTasksTitle,
        children: [
          if (_loadError case final error?) ...[
            Text(
              scheduledTaskErrorText(
                l10n,
                error,
                fallback: l10n.scheduledTasksLoadFailed,
              ),
              key: const Key('scheduled-task-load-error'),
            ),
            const SizedBox(height: Spacing.md),
            ConduitButton(
              key: const Key('scheduled-task-retry'),
              text: l10n.retry,
              onPressed: _load,
            ),
          ] else
            const Center(child: ConduitLoadingIndicator(isCompact: true)),
        ],
      );
    }
    return UtilityPageScaffold.settings(
      title: task.name,
      trailing: _editButton(l10n),
      children: [
        ..._definition(context, l10n, task),
        const SizedBox(height: Spacing.lg),
        ..._runControls(context, l10n),
        const SizedBox(height: Spacing.lg),
        ..._history(context, l10n),
        const SizedBox(height: Spacing.lg),
        InsetGroupedList(
          useNativeSurface: PlatformInfo.isIOS,
          children: [
            UtilityRow(
              key: const Key('scheduled-task-delete'),
              title: l10n.scheduledTaskDelete,
              destructive: true,
              enabled: !_deleting,
              status: _deleting ? const _Spinner() : null,
              onTap: _deleting ? null : _delete,
            ),
          ],
        ),
      ],
    );
  }

  Widget _editButton(AppLocalizations l10n) {
    final onPressed = _deleting ? null : _edit;
    if (PlatformInfo.isIOS) {
      return CupertinoButton(
        key: const Key('scheduled-task-edit'),
        padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
        minimumSize: const Size(0, TouchTarget.minimum),
        onPressed: onPressed,
        child: Text(l10n.edit),
      );
    }
    return TextButton(
      key: const Key('scheduled-task-edit'),
      onPressed: onPressed,
      child: Text(l10n.edit),
    );
  }

  List<Widget> _definition(
    BuildContext context,
    AppLocalizations l10n,
    Automation task,
  ) {
    final theme = context.conduitTheme;
    final channels = ref.watch(channelsListProvider).asData?.value;
    final folders = ref.watch(foldersProvider).asData?.value;
    final models = ref.watch(modelsProvider).asData?.value;
    final next = task.isActive ? task.nextRunsNs : null;
    final (run: lastRun, at: lastRunAtNs) = _latestRun(task);
    final lastRunAt = formatServerTime(context, lastRunAtNs);
    final destination = task.target.isChannel
        ? [
            l10n.scheduledTaskDestinationChannel,
            ?channels
                ?.where((c) => c.id == task.target.channelId)
                .map((c) => '#${c.name}')
                .firstOrNull,
          ].join(' · ')
        : [
            l10n.scheduledTaskDestinationChat,
            ?folders
                ?.where((f) => f.id == task.folderId)
                .map((f) => f.name)
                .firstOrNull,
          ].join(' · ');
    final modelName =
        models?.where((m) => m.id == task.modelId).firstOrNull?.name ??
        task.modelId;
    final lastRunTitle = lastRunAt != null
        ? l10n.scheduledTaskLastRun(lastRunAt)
        : lastRun != null
        ? _runStatus(l10n, lastRun)
        : l10n.scheduledTaskNeverRun;
    final pending = _pendingActive;
    return [
      InsetGroupedList(
        useNativeSurface: PlatformInfo.isIOS,
        children: [
          UtilityRow(
            title: l10n.scheduledTaskActiveLabel,
            status: pending == null ? null : const _Spinner(),
            trailing: AdaptiveSwitch(
              key: const Key('scheduled-task-active-switch'),
              value: pending ?? task.isActive,
              semanticLabel: l10n.scheduledTaskActiveLabel,
              onChanged: pending != null || _deleting ? null : _setActive,
            ),
            preserveTrailingSemantics: true,
          ),
          UtilityRow(
            title: l10n.scheduledTaskScheduleLabel,
            subtitle: scheduleSummary(
              context,
              l10n,
              AutomationSchedule.parse(task.rrule),
            ),
            subtitleMaxLines: 3,
          ),
          UtilityRow(
            key: const Key('scheduled-task-model-row'),
            title: l10n.scheduledTaskModelLabel,
            subtitle: modelName,
          ),
          UtilityRow(
            title: l10n.scheduledTaskDestinationLabel,
            subtitle: destination,
          ),
          UtilityRow(
            key: const Key('scheduled-task-last-run'),
            leading: lastRun == null
                ? null
                : _RunOutcomeIcon(succeeded: lastRun.succeeded),
            title: lastRunTitle,
            semanticLabel: lastRun == null
                ? lastRunTitle
                : '$lastRunTitle. ${_runStatus(l10n, lastRun)}',
          ),
        ],
      ),
      const SizedBox(height: Spacing.md),
      Text(
        l10n.scheduledTaskNextRunsLabel,
        style: theme.label?.copyWith(color: theme.textSecondary),
      ),
      const SizedBox(height: Spacing.xs),
      if (next == null || next.isEmpty)
        Text(
          key: const Key('scheduled-task-no-next-runs'),
          task.isActive
              ? l10n.scheduledTaskNoNextRun
              : l10n.scheduledTaskStatusPaused,
          style: theme.bodySmall?.copyWith(color: theme.textSecondary),
        )
      else
        for (final run in next)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.xxs),
            child: Text(
              formatServerTime(context, run) ?? '',
              key: Key('scheduled-task-next-run-$run'),
              style: theme.bodyMedium?.copyWith(color: theme.textPrimary),
            ),
          ),
      const SizedBox(height: Spacing.md),
      Text(
        l10n.scheduledTaskPromptSection,
        style: theme.label?.copyWith(color: theme.textSecondary),
      ),
      const SizedBox(height: Spacing.xs),
      Text(
        task.prompt,
        key: const Key('scheduled-task-prompt-text'),
        style: theme.bodyMedium?.copyWith(color: theme.textPrimary),
      ),
      if (task.terminal != null) ...[
        const SizedBox(height: Spacing.md),
        Text(
          l10n.scheduledTaskTerminalKept,
          style: theme.bodySmall?.copyWith(color: theme.textSecondary),
        ),
      ],
    ];
  }

  /// The newest run this screen knows of, and when it ran: the task's own
  /// last run, unless Run now or History has shown a newer one since the task
  /// was read. The Last run row then agrees with History and the run notice.
  ({AutomationRun? run, int? at}) _latestRun(Automation task) {
    var run = task.lastRun;
    var at = run?.createdAtNs ?? task.lastRunAtNs;
    final requested = _requestedRun;
    if (requested != null && requested.id != run?.id) {
      // Found as newer than everything known when it was asked for.
      final requestedAt = requested.createdAtNs;
      if (requestedAt == null || at == null || requestedAt >= at) {
        run = requested;
        at = requestedAt;
      }
    }
    for (final candidate in _runs) {
      final candidateAt = candidate.createdAtNs;
      if (candidateAt == null) continue;
      // An untimed run cannot be ordered, so a timed one replaces it only
      // when there was none.
      if (at == null ? run == null : candidateAt > at) {
        run = candidate;
        at = candidateAt;
      }
    }
    return (run: run, at: at);
  }

  List<Widget> _runControls(BuildContext context, AppLocalizations l10n) {
    final notice = switch (_runPhase) {
      _RunPhase.idle || _RunPhase.requesting => null,
      _RunPhase.waiting => (
        message: l10n.scheduledTaskRunning,
        tone: UtilityStatusTone.info,
      ),
      _RunPhase.finished => (
        message: l10n.scheduledTaskRunFinished,
        tone: UtilityStatusTone.success,
      ),
      _RunPhase.failed => (
        message: l10n.scheduledTaskRunFailedNotice,
        tone: UtilityStatusTone.error,
      ),
      _RunPhase.timedOut => (
        message: l10n.scheduledTaskRunRequested,
        tone: UtilityStatusTone.neutral,
      ),
    };
    return [
      InsetGroupedList(
        useNativeSurface: PlatformInfo.isIOS,
        children: [
          UtilityRow(
            key: const Key('scheduled-task-run'),
            title: l10n.scheduledTaskRunNow,
            titleFontWeight: PlatformInfo.isIOS ? FontWeight.w400 : null,
            foregroundColor: context.conduitTheme.buttonPrimary,
            enabled: !_runBusy && !_deleting,
            status: _runPhase == _RunPhase.requesting ? const _Spinner() : null,
            onTap: _runBusy || _deleting ? null : _run,
          ),
        ],
      ),
      if (notice != null) ...[
        const SizedBox(height: Spacing.sm),
        UtilityStatusBanner(
          key: const Key('scheduled-task-run-notice'),
          message: notice.message,
          tone: notice.tone,
          progress: _runPhase == _RunPhase.waiting,
        ),
      ],
      if (_runError case final message?) ...[
        const SizedBox(height: Spacing.sm),
        UtilityStatusBanner(
          key: const Key('scheduled-task-error'),
          message: message,
          tone: UtilityStatusTone.error,
        ),
      ],
    ];
  }

  List<Widget> _history(BuildContext context, AppLocalizations l10n) {
    return [
      InsetGroupedList(
        title: l10n.scheduledTaskHistoryTitle,
        useNativeSurface: PlatformInfo.isIOS,
        children: [
          if (_runs.isEmpty && _runsLoading)
            const Padding(
              padding: EdgeInsets.all(Spacing.md),
              child: Center(child: ConduitLoadingIndicator(isCompact: true)),
            )
          else if (_runs.isEmpty && _runsFailed)
            UtilityRow(
              key: const Key('scheduled-task-history-retry'),
              title: l10n.scheduledTaskHistoryLoadFailed,
              subtitle: l10n.retry,
              onTap: () => _loadRuns(reset: true),
            )
          else if (_runs.isEmpty)
            UtilityRow(
              key: const Key('scheduled-task-history-empty'),
              title: l10n.scheduledTaskHistoryEmpty,
            )
          else
            for (final run in _runs) _runRow(context, l10n, run),
          if (_hasMoreRuns && _runs.isNotEmpty)
            UtilityRow(
              key: const Key('scheduled-task-history-more'),
              title: l10n.scheduledTasksLoadMore,
              foregroundColor: context.conduitTheme.buttonPrimary,
              enabled: !_runsLoading,
              status: _runsLoading ? const _Spinner() : null,
              onTap: _runsLoading ? null : () => _loadRuns(reset: false),
            ),
        ],
      ),
    ];
  }

  String _runStatus(AppLocalizations l10n, AutomationRun run) => run.succeeded
      ? l10n.scheduledTaskRunSucceeded
      : l10n.scheduledTaskRunFailedStatus;

  Widget _runRow(
    BuildContext context,
    AppLocalizations l10n,
    AutomationRun run,
  ) {
    final theme = context.conduitTheme;
    final time = formatServerTime(context, run.createdAtNs) ?? '';
    final hasChannel = run.resultChannelId != null;
    final canOpen = hasChannel || run.resultChatId != null;
    final open = hasChannel
        ? l10n.scheduledTaskViewChannel
        : l10n.scheduledTaskViewChat;
    return UtilityRow(
      key: Key('scheduled-task-run-${run.id}'),
      leading: _RunOutcomeIcon(succeeded: run.succeeded),
      title: time.isEmpty ? _runStatus(l10n, run) : time,
      subtitle: run.error,
      subtitleMaxLines: 3,
      status: canOpen
          ? Text(
              open,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            )
          : null,
      semanticLabel: [
        _runStatus(l10n, run),
        if (time.isNotEmpty) time,
        ?run.error,
        if (canOpen) open,
      ].join('. '),
      showChevron: canOpen,
      onTap: canOpen ? () => _openResult(run) : null,
    );
  }
}

/// A run's outcome at a glance. The row's label says it in words.
class _RunOutcomeIcon extends StatelessWidget {
  const _RunOutcomeIcon({required this.succeeded});

  final bool succeeded;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Icon(
      succeeded
          ? UiUtils.platformIcon(
              ios: CupertinoIcons.checkmark_circle_fill,
              android: Icons.check_circle,
            )
          : UiUtils.platformIcon(
              ios: CupertinoIcons.exclamationmark_circle_fill,
              android: Icons.error,
            ),
      key: ValueKey<String>(succeeded ? 'run-succeeded' : 'run-failed'),
      color: succeeded ? theme.success : theme.error,
      size: IconSize.medium,
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) =>
      const ConduitLoadingIndicator(size: IconSize.small, isCompact: true);
}
