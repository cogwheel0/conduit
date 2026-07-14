import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../profile/widgets/settings_page_scaffold.dart';
import '../models/hermes_job.dart';
import '../providers/hermes_providers.dart';
import '../utils/hermes_schedule_format.dart';
import '../widgets/hermes_job_editor.dart';

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

    return SettingsPageScaffold(
      title: 'Scheduled Agents',
      children: [
        ConduitButton(
          text: 'New scheduled job',
          icon: Icons.add,
          isFullWidth: true,
          isLoading: _creating,
          onPressed: writable && !_creating ? _createJob : null,
        ),
        if (!writable) ...[
          const SizedBox(height: Spacing.sm),
          Text(
            'This server has job administration disabled — jobs are read-only.',
            style: AppTypography.captionStyle.copyWith(
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
                    'No scheduled jobs yet.\nCreate one to have the agent run a '
                    'prompt on a schedule.',
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
                'Could not load scheduled jobs.\nCheck the connection in '
                'Settings → Hermes Agent.',
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
    final result = await showHermesJobEditor(context);
    if (result == null || !mounted || _creating) return;
    if (ref.read(hermesApiServiceProvider) == null) {
      UiUtils.showMessage(
        context,
        'Could not create scheduled job.',
        isError: true,
      );
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
          ),
      failureMessage: 'Could not create scheduled job.',
      successMessage: 'Scheduled job created.',
    );
    if (mounted) setState(() => _creating = false);
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

  HermesJob get job => widget.job;
  bool get writable => widget.writable;
  bool get _busy => _mutation != null;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: theme.surfaceBackground,
        borderRadius: BorderRadius.circular(AppBorderRadius.card),
        border: Border.all(color: theme.cardBorder),
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
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
              if (!job.enabled) ...[
                const SizedBox(width: Spacing.sm),
                Text(
                  'Paused',
                  style: AppTypography.captionStyle.copyWith(
                    color: theme.error,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: Spacing.sm),
          if (writable)
            Row(
              children: [
                ConduitButton(
                  key: ValueKey<String>('hermes-job-run-${job.id}'),
                  text: 'Run now',
                  isSecondary: true,
                  isCompact: true,
                  isLoading: _mutation == _JobMutation.run,
                  onPressed: _busy ? null : _runNow,
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.edit_outlined, color: theme.iconSecondary),
                  tooltip: 'Edit scheduled job',
                  onPressed: _busy ? null : _editJob,
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline, color: theme.error),
                  tooltip: 'Delete scheduled job',
                  onPressed: _busy ? null : _deleteJob,
                ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _runMutation({
    required _JobMutation mutation,
    required Future<void> Function() action,
    required String failureMessage,
    String? successMessage,
  }) async {
    if (_busy) return;
    if (ref.read(hermesApiServiceProvider) == null) {
      UiUtils.showMessage(context, failureMessage, isError: true);
      return;
    }
    setState(() => _mutation = mutation);
    await runHermesJobMutation(
      context,
      action: action,
      failureMessage: failureMessage,
      successMessage: successMessage,
    );
    if (mounted) setState(() => _mutation = null);
  }

  Future<void> _setEnabled(bool enabled) => _runMutation(
    mutation: _JobMutation.toggle,
    action: () =>
        ref.read(hermesJobsProvider.notifier).setEnabled(job.id, enabled),
    failureMessage: enabled
        ? 'Could not resume scheduled job.'
        : 'Could not pause scheduled job.',
    successMessage: enabled
        ? 'Scheduled job resumed.'
        : 'Scheduled job paused.',
  );

  Future<void> _runNow() => _runMutation(
    mutation: _JobMutation.run,
    action: () => ref.read(hermesJobsProvider.notifier).runNow(job.id),
    failureMessage: 'Could not run scheduled job.',
    successMessage: 'Scheduled job started.',
  );

  Future<void> _editJob() async {
    final result = await showHermesJobEditor(
      context,
      initialName: job.name ?? job.displayName,
      initialPrompt: job.prompt,
      initialSchedule: job.schedule,
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
          ),
      failureMessage: 'Could not update scheduled job.',
      successMessage: 'Scheduled job updated.',
    );
  }

  Future<void> _deleteJob() async {
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: 'Delete job',
      message: 'Delete this scheduled job? This cannot be undone.',
      confirmText: 'Delete',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    await _runMutation(
      mutation: _JobMutation.delete,
      action: () => ref.read(hermesJobsProvider.notifier).delete(job.id),
      failureMessage: 'Could not delete scheduled job.',
      successMessage: 'Scheduled job deleted.',
    );
  }
}
