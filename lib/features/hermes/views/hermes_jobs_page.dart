import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../profile/widgets/settings_page_scaffold.dart';
import '../models/hermes_job.dart';
import '../providers/hermes_providers.dart';
import '../widgets/hermes_job_editor.dart';

/// "Scheduled Agents" — cron-driven Hermes jobs (`/api/jobs`): create, edit,
/// pause/resume, run-now, delete.
class HermesJobsPage extends ConsumerWidget {
  const HermesJobsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          onPressed: writable ? () => _createJob(context, ref) : null,
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
                  _JobCard(job: job, writable: writable),
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
                style: AppTypography.bodySmallStyle.copyWith(color: theme.error),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _createJob(BuildContext context, WidgetRef ref) async {
    final result = await showHermesJobEditor(context);
    if (result == null) return;
    await ref
        .read(hermesJobsProvider.notifier)
        .create(prompt: result.prompt, schedule: result.schedule);
  }
}

class _JobCard extends ConsumerWidget {
  const _JobCard({required this.job, this.writable = true});

  final HermesJob job;
  final bool writable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.conduitTheme;
    final controller = ref.read(hermesJobsProvider.notifier);

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
              AdaptiveSwitch(
                value: job.enabled,
                onChanged: writable
                    ? (value) => controller.setEnabled(job.id, value)
                    : null,
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Row(
            children: [
              Icon(Icons.schedule, size: 14, color: theme.textSecondary),
              const SizedBox(width: Spacing.xs),
              Text(
                job.schedule.isEmpty ? '—' : job.schedule,
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.textSecondary,
                  fontFeatures: const [],
                ),
              ),
              if (!job.enabled) ...[
                const SizedBox(width: Spacing.sm),
                Text(
                  'Paused',
                  style: AppTypography.captionStyle.copyWith(color: theme.error),
                ),
              ],
            ],
          ),
          const SizedBox(height: Spacing.sm),
          if (writable)
            Row(
              children: [
                ConduitButton(
                  text: 'Run now',
                  isSecondary: true,
                  isCompact: true,
                  onPressed: () => controller.runNow(job.id),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.edit_outlined, color: theme.iconSecondary),
                  onPressed: () => _editJob(context, ref),
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline, color: theme.error),
                  onPressed: () => _deleteJob(context, ref),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _editJob(BuildContext context, WidgetRef ref) async {
    final result = await showHermesJobEditor(
      context,
      initialPrompt: job.prompt,
      initialSchedule: job.schedule,
    );
    if (result == null) return;
    await ref
        .read(hermesJobsProvider.notifier)
        .edit(job.id, prompt: result.prompt, schedule: result.schedule);
  }

  Future<void> _deleteJob(BuildContext context, WidgetRef ref) async {
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: 'Delete job',
      message: 'Delete this scheduled job? This cannot be undone.',
      confirmText: 'Delete',
      isDestructive: true,
    );
    if (confirmed) await ref.read(hermesJobsProvider.notifier).delete(job.id);
  }
}
