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
import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/models/push_target.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';

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

class _HermesJobsPageState extends ConsumerState<HermesJobsPage> {
  bool _creating = false;

  @override
  Widget build(BuildContext context) {
    final jobsAsync = ref.watch(hermesJobsProvider);
    final writable =
        ref.watch(hermesCapabilitiesProvider).asData?.value.jobsAdmin ?? true;
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
                  ),
                  const SizedBox(height: Spacing.sm),
                ],
              ],
            );
          },
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: Spacing.xl),
            child: Center(child: CircularProgressIndicator()),
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
    final connectionId = _pushConnectionId(ref);
    final hint = _notifyUnavailableHint(ref, l10n, connectionId);
    // A new job notifies by default where push reaches this connection.
    final result = await showHermesJobEditor(
      context,
      initialNotify: connectionId == null ? null : true,
      notifyUnavailableHint: hint,
    );
    if (result == null || !mounted || _creating) return;
    if (ref.read(hermesApiServiceProvider) == null) {
      UiUtils.showMessage(context, l10n.hermesJobCreateFailed, isError: true);
      return;
    }
    setState(() => _creating = true);
    final wantsNotify = connectionId != null && result.notify == true;
    HermesJob? job;
    final created = await runHermesJobMutation(
      context,
      action: () async {
        job = await ref
            .read(hermesJobsProvider.notifier)
            .create(
              name: result.name,
              prompt: result.prompt,
              schedule: result.schedule,
            );
      },
      failureMessage: l10n.hermesJobCreateFailed,
      successMessage: wantsNotify ? null : l10n.hermesJobCreated,
    );
    // Reported apart from the creation, which has happened: a failure here
    // must not read as one to try again, which would make the job twice.
    if (created && wantsNotify) {
      final notified =
          job != null &&
          await _trySetJobNotify(ref, connectionId, job!, notify: true);
      if (mounted) {
        UiUtils.showMessage(
          context,
          notified ? l10n.hermesJobCreated : l10n.hermesJobCreatedNotifyFailed,
          isError: !notified,
        );
      }
    }
    if (mounted) setState(() => _creating = false);
  }
}

/// Why "Notify me" can't be changed for the connection push reaches, or
/// null when it can: the Scheduled tasks kind is off on this device, so the
/// job's pushes would not be shown, and the plugin is not even told to send
/// them.
String? _notifyUnavailableHint(
  WidgetRef ref,
  AppLocalizations l10n,
  String? connectionId,
) {
  if (connectionId == null) return null;
  final scheduled = ref.read(appSettingsProvider).notificationScheduledEnabled;
  return scheduled ? null : l10n.hermesJobNotifyNeedsScheduled;
}

/// The connection in use when push works for it, so a job's "Notify me"
/// can reach this device; null otherwise.
String? _pushConnectionId(WidgetRef ref) {
  final connectionId = ref.read(hermesActiveConnectionIdProvider);
  final push = ref.read(pushStateIfUsedProvider);
  if (connectionId == null || push == null || !push.enabled) return null;
  final target = push.targets[PushTarget.hermesScope(connectionId)];
  return target?.status == PushStatus.on && !target!.optedOut
      ? connectionId
      : null;
}

/// Turns [job]'s "Notify me" on or off. Answers whether that worked; a
/// failure is logged here and reported by the caller, apart from the change
/// to the job itself.
Future<bool> _trySetJobNotify(
  WidgetRef ref,
  String connectionId,
  HermesJob job, {
  required bool notify,
}) async {
  try {
    await ref
        .read(pushCoordinatorProvider.notifier)
        .setHermesJobNotify(
          connectionId: connectionId,
          jobId: job.id,
          notify: notify,
        );
    return true;
  } catch (error, stackTrace) {
    DebugLogger.error(
      'hermes-job-notify-failed',
      scope: 'hermes/jobs',
      error: error,
      stackTrace: stackTrace,
    );
    return false;
  } finally {
    ref.invalidate(hermesJobsProvider);
  }
}

enum _JobMutation { toggle, run, edit, delete }

class _JobCard extends ConsumerStatefulWidget {
  const _JobCard({super.key, required this.job, this.writable = true});

  final HermesJob job;
  final bool writable;

  @override
  ConsumerState<_JobCard> createState() => _JobCardState();
}

class _JobCardState extends ConsumerState<_JobCard> {
  _JobMutation? _mutation;
  bool _historyExpanded = false;

  HermesJob get job => widget.job;
  bool get writable => widget.writable;
  bool get _busy => _mutation != null;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context) ?? AppLocalizationsEn();
    final desktop =
        ref.watch(hermesConfigProvider.select((config) => config.mode)) ==
        HermesBackendMode.desktopGateway;

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
              if (_busy)
                const Padding(
                  padding: EdgeInsets.all(Spacing.sm),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                AdaptiveSwitch(
                  value: job.enabled,
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
            if (job.lastStatus?.isNotEmpty == true)
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
                  onPressed: _busy ? null : _runNow,
                ),
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
        child: Center(child: CircularProgressIndicator()),
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

  /// Runs [action] as [mutation]. Answers whether it succeeded.
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

  Future<void> _runNow() => _runMutation(
    mutation: _JobMutation.run,
    action: () => ref.read(hermesJobsProvider.notifier).runNow(job.id),
    failureMessage: _l10n(context).hermesJobRunFailed,
    successMessage: _l10n(context).hermesJobStarted,
  );

  Future<void> _editJob() async {
    final l10n = _l10n(context);
    // A job whose delivery targets could not be read offers no switch: it
    // would write them back without the unread ones.
    final connectionId = job.deliveryKnown ? _pushConnectionId(ref) : null;
    final notifies = PushCoordinator.hermesJobNotifies(job.deliveryTarget);
    final result = await showHermesJobEditor(
      context,
      initialName: job.name ?? job.displayName,
      initialPrompt: job.prompt,
      initialSchedule: job.schedule,
      initialNotify: connectionId == null ? null : notifies,
      notifyUnavailableHint: _notifyUnavailableHint(ref, l10n, connectionId),
    );
    if (result == null || !mounted) return;
    final notify = result.notify;
    final changesNotify =
        connectionId != null && notify != null && notify != notifies;
    final saved = await _runMutation(
      mutation: _JobMutation.edit,
      action: () => ref
          .read(hermesJobsProvider.notifier)
          .edit(
            job.id,
            name: result.name,
            prompt: result.prompt,
            schedule: result.schedule,
          ),
      failureMessage: l10n.hermesJobUpdateFailed,
      successMessage: changesNotify ? null : l10n.hermesJobUpdated,
    );
    // Reported apart from the edit, which has been saved.
    if (saved && changesNotify) {
      final changed = await _trySetJobNotify(
        ref,
        connectionId,
        job,
        notify: notify,
      );
      if (mounted) {
        UiUtils.showMessage(
          context,
          changed ? l10n.hermesJobUpdated : l10n.hermesJobUpdatedNotifyFailed,
          isError: !changed,
        );
      }
    }
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
