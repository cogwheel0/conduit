import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../l10n/app_localizations_en.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/utility_components.dart';

import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/utils/hermes_schedule_format.dart';

import '../widgets/hermes_job_editor.dart';
import '../widgets/hermes_session_tile.dart' show openHermesSession;

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? AppLocalizationsEn();

/// "Scheduled Agents" — cron-driven Hermes jobs (`/api/jobs`): create, edit,
/// pause/resume, run-now, delete.
@visibleForTesting
Future<bool> runHermesJobMutation(
  BuildContext context, {
  required Future<void> Function() action,
  required String failureMessage,
  String? successMessage,
}) async {
  try {
    await action();
    if (context.mounted && successMessage != null) {
      UiUtils.showMessage(context, successMessage);
    }
    return true;
  } catch (_) {
    if (context.mounted) {
      UiUtils.showMessage(context, failureMessage, isError: true);
    }
    return false;
  }
}

class HermesJobsPage extends ConsumerStatefulWidget {
  const HermesJobsPage({super.key});

  @override
  ConsumerState<HermesJobsPage> createState() => _HermesJobsPageState();
}

/// How often the page re-reads the job list while a run is in flight or
/// being stopped: a cancel lands at the run's next cancel check, about a
/// second after it is asked for.
const Duration _kLiveRunPollInterval = Duration(seconds: 2);

class _HermesJobsPageState extends ConsumerState<HermesJobsPage> {
  bool _creating = false;

  /// Jobs with a Stop in progress, to the execution each Stop targeted
  /// (empty until Hermes names it).
  final Map<String, String> _stopping = {};

  /// Jobs whose Run now request is still waiting: Hermes answers it only once
  /// the run ends, so the run counts as live meanwhile.
  final Set<String> _runPending = {};

  bool _stopUnsupported = false;
  Timer? _pollTimer;

  /// Jobs whose run was in flight in the previous list.
  Set<String> _liveJobIds = const {};

  bool get _desktop =>
      ref.read(hermesConfigProvider).mode == HermesBackendMode.desktopGateway;

  @override
  void initState() {
    super.initState();
    ref.listenManual<AsyncValue<List<HermesJob>>>(
      hermesJobsProvider,
      (_, next) => _onJobs(next.asData?.value),
      fireImmediately: true,
    );
    // A Stop left behind by a connection switch can no longer be settled.
    ref.listenManual(hermesApiServiceProvider, (previous, next) {
      if (identical(previous, next) || !mounted) return;
      setState(() {
        _stopping.clear();
        _runPending.clear();
        _stopUnsupported = false;
      });
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _onJobs(List<HermesJob>? jobs) {
    if (jobs == null) return;
    final live = {
      for (final job in jobs)
        if (job.runInFlight) job.id,
    };
    // A run that ended (or was stopped) now has its final title, such as the
    // reason it was cancelled, in the run history.
    for (final jobId in _liveJobIds.difference(live)) {
      ref.invalidate(hermesJobRunsProvider(jobId));
    }
    _liveJobIds = live;
    _settleStops(jobs);
    _syncPolling(jobs);
  }

  void _settleStops(List<HermesJob> jobs) {
    if (_stopping.isEmpty || !mounted) return;
    final l10n = _l10n(context);
    final settled = <String, HermesJobStopOutcome>{};
    for (final MapEntry(key: jobId, value: executionId) in _stopping.entries) {
      final job = jobs.where((candidate) => candidate.id == jobId).firstOrNull;
      final outcome = hermesJobStopOutcome(job, executionId);
      if (outcome != HermesJobStopOutcome.pending) settled[jobId] = outcome;
    }
    if (settled.isEmpty) return;
    setState(() => settled.keys.forEach(_stopping.remove));
    for (final outcome in settled.values) {
      UiUtils.showMessage(
        context,
        outcome == HermesJobStopOutcome.cancelled
            ? l10n.hermesJobStopped
            : l10n.hermesJobFinishedBeforeStop,
      );
    }
  }

  /// Polls while there is a run to watch, so Stop appears for a run started
  /// elsewhere and "Stopping…" settles without a manual refresh.
  void _syncPolling([List<HermesJob>? jobs]) {
    final current = jobs ?? ref.read(hermesJobsProvider).asData?.value;
    final active =
        mounted &&
        _desktop &&
        (_stopping.isNotEmpty ||
            _runPending.isNotEmpty ||
            (current?.any((job) => job.runInFlight) ?? false));
    if (!active) {
      _pollTimer?.cancel();
      _pollTimer = null;
    } else {
      _pollTimer ??= Timer.periodic(_kLiveRunPollInterval, (_) => _poll());
    }
  }

  void _poll() {
    if (!mounted) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    // Covered by the editor or a run's chat: nothing on screen to update.
    if (ModalRoute.of(context)?.isCurrent == false) return;
    unawaited(ref.read(hermesJobsProvider.notifier).refreshQuietly());
  }

  void _setRunPending(String jobId, bool pending) {
    if (!mounted) return;
    setState(() {
      if (pending) {
        _runPending.add(jobId);
      } else {
        _runPending.remove(jobId);
      }
    });
    _syncPolling();
  }

  Future<void> _stop(HermesJob job) async {
    if (_stopping.containsKey(job.id)) return;
    final l10n = _l10n(context);
    final notifier = ref.read(hermesJobsProvider.notifier);
    setState(() => _stopping[job.id] = '');
    _syncPolling();
    try {
      final result = await notifier.stopRun(job.id);
      if (!mounted) return;
      if (!result.cancelled) {
        setState(() => _stopping.remove(job.id));
        UiUtils.showMessage(context, l10n.hermesJobNothingToStop);
        return;
      }
      if (_stopping.containsKey(job.id)) {
        _stopping[job.id] = result.executionId ?? '';
      }
      await notifier.refreshQuietly();
    } on HermesJobStopUnsupportedException {
      if (!mounted) return;
      setState(() {
        _stopping.remove(job.id);
        _stopUnsupported = true;
      });
      UiUtils.showMessage(
        context,
        l10n.hermesJobStopUnsupported,
        isError: true,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _stopping.remove(job.id));
      UiUtils.showMessage(context, l10n.hermesJobStopFailed, isError: true);
    } finally {
      _syncPolling();
    }
  }

  @override
  Widget build(BuildContext context) {
    final jobsAsync = ref.watch(hermesJobsProvider);
    final writable =
        ref.watch(hermesCapabilitiesProvider).asData?.value.jobsAdmin ?? true;
    final desktop =
        ref.watch(hermesConfigProvider.select((config) => config.mode)) ==
        HermesBackendMode.desktopGateway;
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context) ?? AppLocalizationsEn();

    return UtilityPageScaffold.settings(
      title: l10n.hermesScheduledAgentsTitle,
      children: [
        ConduitButton(
          text: l10n.hermesJobNew,
          icon: Icons.add,
          isFullWidth: true,
          isLoading: _creating,
          onPressed: writable && !_creating ? _createJob : null,
        ),
        if (!writable) ...[
          const SizedBox(height: Spacing.sm),
          Text(
            l10n.hermesJobAdminDisabled,
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textSecondary,
            ),
          ),
        ],
        const SizedBox(height: Spacing.lg),
        jobsAsync.when(
          data: (jobs) {
            if (jobs.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: Spacing.xl),
                child: Center(
                  child: Text(
                    '${l10n.hermesNoSchedulesYet}\n${l10n.hermesJobEmptyMessage}',
                    textAlign: TextAlign.center,
                    style: AppTypography.bodySmallStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                ),
              );
            }
            return Column(
              children: [
                for (final job in jobs) ...[
                  _JobCard(
                    key: ValueKey<String>(job.id),
                    job: job,
                    writable: writable,
                    canStop: desktop && writable && !_stopUnsupported,
                    stopping: _stopping.containsKey(job.id),
                    runPending: _runPending.contains(job.id),
                    onStop: () => _stop(job),
                    onRunPendingChanged: (pending) =>
                        _setRunPending(job.id, pending),
                  ),
                  const SizedBox(height: Spacing.sm),
                ],
              ],
            );
          },
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: Spacing.xl),
            child: Center(child: AdaptiveProgressIndicator()),
          ),
          error: (error, _) => Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.xl),
            child: Center(
              child: Text(
                l10n.hermesJobLoadFailed,
                textAlign: TextAlign.center,
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.error,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _createJob() async {
    final l10n = AppLocalizations.of(context) ?? AppLocalizationsEn();
    final result = await showHermesJobEditor(context, scheduling: _desktop);
    if (result == null || !mounted || _creating) return;
    if (ref.read(hermesApiServiceProvider) == null) {
      UiUtils.showMessage(context, l10n.hermesJobCreateFailed, isError: true);
      return;
    }
    setState(() => _creating = true);
    await runHermesJobMutation(
      context,
      action: () => ref
          .read(hermesJobsProvider.notifier)
          .create(
            name: result.name,
            prompt: result.prompt,
            schedule: result.schedule,
            catchUp: result.catchUp ?? HermesJobCatchUp.hermesDefault,
          ),
      failureMessage: l10n.hermesJobCreateFailed,
      successMessage: l10n.hermesJobCreated,
    );
    if (mounted) setState(() => _creating = false);
  }
}

enum _JobMutation { toggle, run, edit, delete }

class _JobCard extends ConsumerStatefulWidget {
  const _JobCard({
    super.key,
    required this.job,
    this.writable = true,
    this.canStop = false,
    this.stopping = false,
    this.runPending = false,
    this.onStop,
    this.onRunPendingChanged,
  });

  final HermesJob job;
  final bool writable;

  /// Whether this connection can stop a running job.
  final bool canStop;

  /// Whether a Stop of this job's run is in progress.
  final bool stopping;

  /// Whether this job's Run now request is still waiting.
  final bool runPending;
  final VoidCallback? onStop;
  final ValueChanged<bool>? onRunPendingChanged;

  @override
  ConsumerState<_JobCard> createState() => _JobCardState();
}

class _JobCardState extends ConsumerState<_JobCard> {
  _JobMutation? _mutation;
  bool _historyExpanded = false;

  /// Set when Stop is pressed while this card's Run now is waiting, so the
  /// trigger's late answer does not announce a started run.
  bool _stopRequestedDuringRun = false;

  HermesJob get job => widget.job;
  bool get writable => widget.writable;
  bool get _busy => _mutation != null;

  /// A run is in flight, or this card's Run now is still waiting for one.
  bool get _runLive => job.runInFlight || widget.runPending;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context) ?? AppLocalizationsEn();
    final desktop =
        ref.watch(hermesConfigProvider.select((config) => config.mode)) ==
        HermesBackendMode.desktopGateway;
    final cancelReason = _runLive ? null : job.lastCancelReason;

    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: theme.groupedSurface,
        borderRadius: BorderRadius.circular(
          context.usesCupertinoChrome ? AppBorderRadius.md : AppBorderRadius.card,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ExcludeSemantics(
                  excluding: !_busy,
                  child: Text(
                    job.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.standard.copyWith(
                      color: theme.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.all(Spacing.sm),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: AdaptiveProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                AdaptiveSwitch(
                  value: job.enabled,
                  semanticLabel: job.displayName,
                  onChanged: writable ? _setEnabled : null,
                ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.schedule,
                  size: 14,
                  color: theme.textSecondary,
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      describeHermesCronSchedule(job.schedule),
                      style: AppTypography.bodySmallStyle.copyWith(
                        color: theme.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (hermesScheduleNeedsRawDisplay(job.schedule))
                      Text(
                        job.schedule,
                        style: AppTypography.codeStyle.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              if (!job.enabled) ...[
                const SizedBox(width: Spacing.sm),
                Text(
                  l10n.hermesJobPaused,
                  style: AppTypography.captionStyle.copyWith(
                    color: theme.error,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: Spacing.sm),
          if (desktop) ...[
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.xxs,
              children: [
                Text(
                  '${l10n.hermesJobStateLabel}: ${job.state ?? (job.enabled ? 'active' : 'paused')}',
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: theme.textSecondary,
                  ),
                ),
                Text(
                  '${l10n.hermesJobDeliveryLabel}: ${job.deliveryTarget ?? 'local'}',
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: theme.textSecondary,
                  ),
                ),
                if (job.lastRun != null)
                  Text(
                    '${l10n.hermesJobLastLabel}: ${_formatJobTime(context, job.lastRun!)}',
                    style: AppTypography.bodySmallStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                if (job.nextRun != null)
                  Text(
                    '${l10n.hermesJobNextLabel}: ${_formatJobTime(context, job.nextRun!)}',
                    style: AppTypography.bodySmallStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
              ],
            ),
            if (_runLive)
              Text(
                widget.stopping
                    ? l10n.hermesJobStopping
                    : l10n.hermesJobRunning,
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.success,
                  fontWeight: FontWeight.w600,
                ),
              )
            else if (cancelReason != null)
              Text(
                cancelReason.isEmpty
                    ? l10n.hermesJobLastCancelledNoReason
                    : l10n.hermesJobLastCancelled(cancelReason),
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.textSecondary,
                ),
              )
            else if (job.lastStatus?.isNotEmpty == true)
              Text(
                job.lastStatus!,
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.textSecondary,
                ),
              ),
            if (job.lastError?.isNotEmpty == true)
              Text(
                job.lastError!,
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.error,
                ),
              ),
            if (job.lastDeliveryError?.isNotEmpty == true)
              Text(
                'Delivery: ${job.lastDeliveryError}',
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.error,
                ),
              ),
            const SizedBox(height: Spacing.xs),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () =>
                    setState(() => _historyExpanded = !_historyExpanded),
                icon: Icon(
                  _historyExpanded ? Icons.expand_less : Icons.history,
                  size: 18,
                ),
                label: Text(l10n.hermesJobRunHistory),
              ),
            ),
            if (_historyExpanded) _buildRunHistory(theme),
            const SizedBox(height: Spacing.xs),
          ],
          if (writable)
            Row(
              children: [
                ConduitButton(
                  key: ValueKey<String>('hermes-job-run-${job.id}'),
                  text: l10n.hermesJobRunNow,
                  isSecondary: true,
                  isCompact: true,
                  isLoading: _mutation == _JobMutation.run,
                  onPressed: _busy || job.runInFlight ? null : _runNow,
                ),
                // Not gated on [_busy]: this card's own Run now holds it
                // for as long as the run lasts.
                if (widget.canStop && (_runLive || widget.stopping)) ...[
                  const SizedBox(width: Spacing.sm),
                  ConduitButton(
                    key: ValueKey<String>('hermes-job-stop-${job.id}'),
                    text: widget.stopping
                        ? l10n.hermesJobStopping
                        : l10n.hermesJobStop,
                    isSecondary: true,
                    isDestructive: true,
                    isCompact: true,
                    isLoading: widget.stopping,
                    onPressed: widget.stopping ? null : _stop,
                  ),
                ],
                const Spacer(),
                ConduitIconButton(
                  icon: Icons.edit_outlined,
                  iconColor: theme.iconSecondary,
                  tooltip: l10n.hermesJobEdit,
                  onPressed: _busy ? null : _editJob,
                  isCompact: true,
                ),
                ConduitIconButton(
                  icon: Icons.delete_outline,
                  iconColor: theme.error,
                  tooltip: l10n.hermesJobDelete,
                  onPressed: _busy ? null : _deleteJob,
                  isCompact: true,
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildRunHistory(ConduitThemeExtension theme) {
    final runs = ref.watch(hermesJobRunsProvider(job.id));
    return runs.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(Spacing.sm),
        child: Center(child: AdaptiveProgressIndicator()),
      ),
      error: (_, _) => Text(
        'Could not load run history.',
        style: AppTypography.bodySmallStyle.copyWith(color: theme.error),
      ),
      data: (items) {
        if (items.isEmpty) {
          return Text(
            'No runs yet.',
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textSecondary,
            ),
          );
        }
        return Column(
          children: [
            for (final run in items)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.chat_bubble_outline, size: 18),
                title: Text(run.title, maxLines: 1),
                subtitle: run.updatedAt == null
                    ? null
                    : Text(_formatJobTime(context, run.updatedAt!)),
                onTap: () => openHermesSession(context, ref, run),
              ),
          ],
        );
      },
    );
  }

  String _formatJobTime(BuildContext context, DateTime value) {
    final local = value.toLocal();
    final material = MaterialLocalizations.of(context);
    return '${material.formatMediumDate(local)} '
        '${material.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
  }

  Future<bool> _runMutation({
    required _JobMutation mutation,
    required Future<void> Function() action,
    required String failureMessage,
    String? successMessage,
  }) async {
    if (_busy) return false;
    if (ref.read(hermesApiServiceProvider) == null) {
      UiUtils.showMessage(context, failureMessage, isError: true);
      return false;
    }
    setState(() => _mutation = mutation);
    final succeeded = await runHermesJobMutation(
      context,
      action: action,
      failureMessage: failureMessage,
      successMessage: successMessage,
    );
    if (mounted) setState(() => _mutation = null);
    return succeeded;
  }

  Future<void> _setEnabled(bool enabled) => _runMutation(
    mutation: _JobMutation.toggle,
    action: () =>
        ref.read(hermesJobsProvider.notifier).setEnabled(job.id, enabled),
    failureMessage: enabled
        ? _l10n(context).hermesJobResumeFailed
        : _l10n(context).hermesJobPauseFailed,
    successMessage: enabled
        ? _l10n(context).hermesJobResumed
        : _l10n(context).hermesJobPausedSuccess,
  );

  Future<void> _runNow() async {
    if (_busy) return;
    final l10n = _l10n(context);
    final onRunPendingChanged = widget.onRunPendingChanged;
    _stopRequestedDuringRun = false;
    onRunPendingChanged?.call(true);
    try {
      final started = await _runMutation(
        mutation: _JobMutation.run,
        action: () => ref.read(hermesJobsProvider.notifier).runNow(job.id),
        failureMessage: l10n.hermesJobRunFailed,
      );
      if (started && mounted && !_stopRequestedDuringRun) {
        UiUtils.showMessage(context, l10n.hermesJobStarted);
      }
    } finally {
      onRunPendingChanged?.call(false);
    }
  }

  void _stop() {
    if (_mutation == _JobMutation.run) _stopRequestedDuringRun = true;
    widget.onStop?.call();
  }

  Future<void> _editJob() async {
    final result = await showHermesJobEditor(
      context,
      initialName: job.name ?? job.displayName,
      initialPrompt: job.prompt,
      initialSchedule: job.schedule,
      initialCatchUp: job.catchUpChoice,
      scheduling:
          ref.read(hermesConfigProvider).mode ==
          HermesBackendMode.desktopGateway,
    );
    if (result == null || !mounted) return;
    await _runMutation(
      mutation: _JobMutation.edit,
      action: () => ref
          .read(hermesJobsProvider.notifier)
          .edit(
            job.id,
            name: result.name,
            prompt: result.prompt,
            schedule: result.schedule,
            catchUp: result.catchUp,
          ),
      failureMessage: _l10n(context).hermesJobUpdateFailed,
      successMessage: _l10n(context).hermesJobUpdated,
    );
  }

  Future<void> _deleteJob() async {
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: _l10n(context).hermesJobDeleteTitle,
      message: _l10n(context).hermesJobDeleteMessage,
      confirmText: _l10n(context).delete,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    await _runMutation(
      mutation: _JobMutation.delete,
      action: () => ref.read(hermesJobsProvider.notifier).delete(job.id),
      failureMessage: _l10n(context).hermesJobDeleteFailed,
      successMessage: _l10n(context).hermesJobDeleted,
    );
  }
}
