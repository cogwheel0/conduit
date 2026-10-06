import 'dart:async';

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

/// One scheduled task: its definition as the server holds it, controls that
/// call the server, and its run history.
///
/// The history is separate from the definition. Asking for a run only asks;
/// the server records the outcome when the run finishes, so a run request is
/// reported as requested and the result is read from History.
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
  bool _runsLoading = false;
  bool _runsFailed = false;
  bool _hasMoreRuns = false;
  bool _busy = false;
  String? _notice;
  String? _error;
  Timer? _historyRefresh;

  Automations get _notifier => ref.read(automationsProvider.notifier);

  @override
  void initState() {
    super.initState();
    _owner = _notifier.captureOwner();
    _load();
  }

  @override
  void dispose() {
    _historyRefresh?.cancel();
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
    try {
      final page = await _notifier.runs(
        widget.taskId,
        skip: reset ? 0 : _runs.length,
        owner: owner,
      );
      _requireOwner(owner);
      setState(() {
        final known = reset ? <String>{} : {for (final run in _runs) run.id};
        _runs = [
          if (!reset) ..._runs,
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

  Future<void> _act(
    Future<void> Function(AutomationsOwner owner) action, {
    required String fallback,
  }) async {
    final owner = _owner;
    final l10n = AppLocalizations.of(context)!;
    if (owner == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(owner);
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _error = scheduledTaskErrorText(l10n, error, fallback: fallback),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setActive(bool active) {
    final fallback = AppLocalizations.of(context)!.scheduledTaskChangeFailed;
    return _act((owner) async {
      final task = await _notifier.setActive(
        widget.taskId,
        active,
        owner: owner,
      );
      // The change was made for the previous account and stays made; it is
      // not shown as this account's task.
      _requireOwner(owner);
      setState(() => _task = task);
    }, fallback: fallback);
  }

  /// Asks the server to run the task once. The reply only means the request
  /// was accepted; the outcome shows in History when the server records it.
  Future<void> _run() {
    final l10n = AppLocalizations.of(context)!;
    return _act((owner) async {
      final accepted = await _notifier.run(widget.taskId, owner: owner);
      _requireOwner(owner);
      setState(() {
        _task = accepted;
        _notice = l10n.scheduledTaskRunRequested;
      });
      _historyRefresh?.cancel();
      _historyRefresh = Timer(const Duration(seconds: 2), () {
        if (mounted && _notifier.isCurrentOwner(owner)) {
          _loadRuns(reset: true);
        }
      });
    }, fallback: l10n.scheduledTaskRunRequestFailed);
  }

  Future<void> _delete() async {
    final task = _task;
    if (task == null || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    final route = ModalRoute.of(context);
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.scheduledTaskDelete,
      message: l10n.scheduledTaskDeleteConfirm(task.name),
      confirmText: l10n.scheduledTaskDelete,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    await _act((owner) async {
      await _notifier.remove(widget.taskId, owner: owner);
      _requireOwner(owner);
      // Leave this page, not one opened over it while the request ran.
      if (mounted && (route?.isCurrent ?? true)) context.pop();
    }, fallback: l10n.errorMessage);
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
      children: [
        ..._definition(context, l10n, task),
        const SizedBox(height: Spacing.lg),
        ..._actions(l10n),
        const SizedBox(height: Spacing.lg),
        ..._history(context, l10n),
      ],
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
    final next = task.isActive ? task.nextRunsNs : null;
    final lastRun = formatServerTime(
      context,
      task.lastRun?.createdAtNs ?? task.lastRunAtNs,
    );
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
    return [
      InsetGroupedList(
        children: [
          UtilityRow(
            title: l10n.scheduledTaskActiveLabel,
            subtitle: task.isActive
                ? l10n.scheduledTaskStatusActive
                : l10n.scheduledTaskStatusPaused,
            trailing: AdaptiveSwitch(
              key: const Key('scheduled-task-active-switch'),
              value: task.isActive,
              semanticLabel: l10n.scheduledTaskActiveLabel,
              onChanged: _busy ? null : _setActive,
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
            title: l10n.scheduledTaskModelLabel,
            subtitle: task.modelId,
          ),
          UtilityRow(
            title: l10n.scheduledTaskDestinationLabel,
            subtitle: destination,
          ),
          UtilityRow(
            key: const Key('scheduled-task-last-run'),
            title: lastRun == null
                ? l10n.scheduledTaskNeverRun
                : l10n.scheduledTaskLastRun(lastRun),
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

  List<Widget> _actions(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return [
      if (_notice case final notice?)
        Padding(
          padding: const EdgeInsets.only(bottom: Spacing.sm),
          child: Text(
            notice,
            key: const Key('scheduled-task-run-notice'),
            style: theme.bodySmall?.copyWith(color: theme.textSecondary),
          ),
        ),
      if (_error case final message?)
        Padding(
          padding: const EdgeInsets.only(bottom: Spacing.sm),
          child: Text(
            message,
            key: const Key('scheduled-task-error'),
            style: theme.bodySmall?.copyWith(color: theme.error),
          ),
        ),
      ConduitButton(
        key: const Key('scheduled-task-run'),
        text: l10n.scheduledTaskRunNow,
        isFullWidth: true,
        onPressed: _busy ? null : _run,
      ),
      const SizedBox(height: Spacing.sm),
      ConduitButton(
        key: const Key('scheduled-task-edit'),
        text: l10n.edit,
        isSecondary: true,
        isFullWidth: true,
        onPressed: _busy ? null : _edit,
      ),
      const SizedBox(height: Spacing.sm),
      ConduitButton(
        key: const Key('scheduled-task-delete'),
        text: l10n.scheduledTaskDelete,
        isDestructive: true,
        isFullWidth: true,
        onPressed: _busy ? null : _delete,
      ),
    ];
  }

  List<Widget> _history(BuildContext context, AppLocalizations l10n) {
    return [
      InsetGroupedList(
        title: l10n.scheduledTaskHistoryTitle,
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
            UtilityRow(title: l10n.scheduledTaskHistoryEmpty, enabled: false)
          else
            for (final run in _runs) _runRow(context, l10n, run),
          if (_hasMoreRuns)
            UtilityRow(
              key: const Key('scheduled-task-history-more'),
              title: l10n.scheduledTasksLoadMore,
              onTap: _runsLoading ? null : () => _loadRuns(reset: false),
            ),
        ],
      ),
    ];
  }

  Widget _runRow(
    BuildContext context,
    AppLocalizations l10n,
    AutomationRun run,
  ) {
    final theme = context.conduitTheme;
    final time = formatServerTime(context, run.createdAtNs) ?? '';
    final hasChannel = run.resultChannelId != null;
    final canOpen = hasChannel || run.resultChatId != null;
    final status = run.succeeded
        ? l10n.scheduledTaskRunSucceeded
        : l10n.scheduledTaskRunFailedStatus;
    return UtilityRow(
      key: Key('scheduled-task-run-${run.id}'),
      title: '$status · $time',
      subtitle: run.error,
      subtitleMaxLines: 3,
      status: canOpen
          ? Text(
              hasChannel
                  ? l10n.scheduledTaskViewChannel
                  : l10n.scheduledTaskViewChat,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            )
          : null,
      showChevron: canOpen,
      onTap: canOpen ? () => _openResult(run) : null,
    );
  }
}
