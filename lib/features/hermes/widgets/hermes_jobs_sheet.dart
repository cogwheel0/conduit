import 'dart:async';
import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/utils/utf16_sanitizer.dart';
import '../models/hermes_job.dart';
import '../providers/hermes_providers.dart';
import '../utils/hermes_schedule_format.dart';

const _nativeJobTogglePrefix = 'hermes-job-toggle:';
const _nativeJobsSheetId = 'hermes-scheduled-agents';
const _manageJobsActionId = 'hermes-jobs-manage';

enum _HermesJobsSheetAction { manage }

/// Opens the compact scheduled-agents surface. iOS uses the native sheet
/// bridge; other platforms use the matching Flutter bottom sheet.
Future<void> showHermesJobsSheet(BuildContext context) async {
  if (Platform.isIOS) {
    try {
      final usedNative = await _showNativeHermesJobsSheet(context);
      if (usedNative) return;
    } catch (error) {
      DebugLogger.error(
        'native-jobs-sheet-failed',
        scope: 'hermes/jobs-sheet',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (!context.mounted) return;
    }
  }

  if (!context.mounted) return;
  final theme = context.conduitTheme;
  final action = await showModalBottomSheet<_HermesJobsSheetAction>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: theme.surfaceBackground,
    constraints: BoxConstraints(
      maxWidth: MediaQuery.sizeOf(context).width,
      maxHeight: MediaQuery.sizeOf(context).height * 0.78,
    ),
    builder: (_) => const HermesJobsSheet(),
  );
  if (action == _HermesJobsSheetAction.manage && context.mounted) {
    context.pushNamed(RouteNames.hermesJobs);
  }
}

Future<bool> _showNativeHermesJobsSheet(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final writable =
      container.read(hermesCapabilitiesProvider).asData?.value.jobsAdmin ??
      true;

  List<HermesJob> jobs;
  Object? loadError;
  try {
    jobs = await container.read(hermesJobsProvider.future);
  } catch (error) {
    jobs = const [];
    loadError = error;
  }
  if (!context.mounted) return true;

  final subscription = NativeSheetBridge.instance.events.listen((event) {
    if (event case NativeSheetControlChanged(
      :final id,
      :final value,
    ) when id.startsWith(_nativeJobTogglePrefix) && value is bool) {
      final encodedId = id.substring(_nativeJobTogglePrefix.length);
      unawaited(
        _toggleNativeJob(
          container,
          Uri.decodeComponent(encodedId),
          value,
          writable: writable,
        ),
      );
    }
  });

  try {
    final result = await NativeSheetBridge.instance.presentSheet(
      root: NativeSheetDetailConfig(
        id: _nativeJobsSheetId,
        title: 'Scheduled agents',
        subtitle: loadError == null
            ? 'Review when each agent runs and pause schedules without leaving the sidebar.'
            : 'Scheduled agents could not be loaded.',
        maxHeightFraction: 0.78,
        items: _nativeJobItems(jobs, writable: writable, loadError: loadError),
      ),
      rethrowErrors: true,
    );
    if (result?.actionId == _manageJobsActionId && context.mounted) {
      context.pushNamed(RouteNames.hermesJobs);
    }
  } finally {
    await subscription.cancel();
  }
  return true;
}

Future<void> _toggleNativeJob(
  ProviderContainer container,
  String jobId,
  bool enabled, {
  required bool writable,
}) async {
  if (!writable) return;
  try {
    await container
        .read(hermesJobsProvider.notifier)
        .setEnabled(jobId, enabled);
  } catch (_) {
    _logHermesJobToggleFailure(enabled: enabled);
    final jobs = container.read(hermesJobsProvider).asData?.value;
    if (jobs != null) {
      try {
        await NativeSheetBridge.instance.applyDetailPatch(
          detailId: _nativeJobsSheetId,
          title: 'Scheduled agents',
          items: _nativeJobItems(jobs, writable: writable),
        );
      } catch (_) {
        DebugLogger.error('toggle-rollback-failed', scope: 'hermes/jobs-sheet');
      }
    }
  }
}

List<NativeSheetItemConfig> _nativeJobItems(
  List<HermesJob> jobs, {
  required bool writable,
  Object? loadError,
}) {
  return [
    if (loadError != null)
      const NativeSheetItemConfig(
        id: 'hermes-jobs-error',
        title: 'Could not load scheduled agents',
        subtitle: 'Check the Hermes connection and try again.',
        sfSymbol: 'exclamationmark.triangle',
        kind: NativeSheetItemKind.info,
      )
    else if (jobs.isEmpty)
      const NativeSheetItemConfig(
        id: 'hermes-jobs-empty',
        title: 'No scheduled agents yet',
        subtitle: 'Create one from Manage scheduled agents.',
        sfSymbol: 'calendar.badge.plus',
        kind: NativeSheetItemKind.info,
      )
    else
      for (final job in jobs)
        NativeSheetItemConfig(
          id: '$_nativeJobTogglePrefix${Uri.encodeComponent(job.id)}',
          title: sanitizeUtf16(job.displayName),
          subtitle: sanitizeUtf16(_nativeJobSubtitle(job)),
          sfSymbol: job.enabled ? 'clock.badge.checkmark' : 'pause.circle',
          kind: writable
              ? NativeSheetItemKind.toggle
              : NativeSheetItemKind.info,
          value: writable ? job.enabled : null,
        ),
    const NativeSheetItemConfig(
      id: _manageJobsActionId,
      title: 'Manage scheduled agents',
      subtitle: 'Create, edit, run now, or delete schedules.',
      sfSymbol: 'slider.horizontal.3',
    ),
  ];
}

String _nativeJobSubtitle(HermesJob job) {
  final prompt = job.prompt.trim().replaceAll(RegExp(r'\s+'), ' ');
  final preview = prompt.length <= 110
      ? prompt
      : '${prompt.substring(0, 110)}…';
  final cadence = describeHermesCronSchedule(job.schedule);
  final timing = hermesJobTimingDetail(job);
  final status = job.enabled ? cadence : '$cadence · Paused';
  final rawSchedule = job.schedule.trim();
  return [
    status,
    timing,
    if (job.lastStatus?.trim().isNotEmpty ?? false)
      'Last status: ${job.lastStatus!.trim()}',
    if (preview.isNotEmpty) preview,
    if (hermesScheduleNeedsRawDisplay(job.schedule)) 'Cron $rawSchedule',
  ].join('\n');
}

void _logHermesJobToggleFailure({required bool enabled}) {
  // A provider error can contain its request URL (and therefore the opaque
  // job id), so neither the caught object nor the raw id belongs in logs.
  DebugLogger.error(
    'toggle-failed',
    scope: 'hermes/jobs-sheet',
    data: {'enabled': enabled},
  );
}

class HermesJobsSheet extends ConsumerWidget {
  const HermesJobsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobsAsync = ref.watch(hermesJobsProvider);
    final writable =
        ref.watch(hermesCapabilitiesProvider).asData?.value.jobsAdmin ?? true;
    final theme = context.conduitTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.xs,
            Spacing.sm,
            Spacing.md,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Scheduled agents',
                      style: AppTypography.titleMediumStyle.copyWith(
                        color: theme.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: Spacing.xxs),
                    Text(
                      'Pause schedules or review what runs next.',
                      style: AppTypography.captionStyle.copyWith(
                        color: theme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.of(context).pop(_HermesJobsSheetAction.manage),
                child: const Text('Manage'),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: theme.cardBorder),
        Expanded(
          child: jobsAsync.when(
            skipLoadingOnRefresh: true,
            data: (jobs) {
              if (jobs.isEmpty) return const _JobsEmptyState();
              return ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
                itemCount: jobs.length,
                separatorBuilder: (_, _) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
                  child: Divider(height: 1, color: theme.cardBorder),
                ),
                itemBuilder: (_, index) => _HermesJobSheetRow(
                  key: ValueKey<String>('hermes-job-sheet-${jobs[index].id}'),
                  job: jobs[index],
                  writable: writable,
                ),
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(Spacing.xl),
                child: Text(
                  'Could not load scheduled agents.\nCheck the Hermes connection and try again.',
                  textAlign: TextAlign.center,
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: theme.error,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _HermesJobSheetRow extends ConsumerStatefulWidget {
  const _HermesJobSheetRow({
    super.key,
    required this.job,
    required this.writable,
  });

  final HermesJob job;
  final bool writable;

  @override
  ConsumerState<_HermesJobSheetRow> createState() => _HermesJobSheetRowState();
}

class _HermesJobSheetRowState extends ConsumerState<_HermesJobSheetRow> {
  bool _toggling = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final job = widget.job;
    final locale = Localizations.localeOf(context).toString();
    final cadence = describeHermesCronSchedule(job.schedule);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: Spacing.xxs),
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: (job.enabled ? theme.success : theme.textSecondary)
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppBorderRadius.button),
              ),
              child: Icon(
                job.enabled ? Icons.schedule_rounded : Icons.pause_rounded,
                size: IconSize.listItem,
                color: job.enabled ? theme.success : theme.iconSecondary,
              ),
            ),
          ),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  job.displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.standard.copyWith(
                    color: theme.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: Spacing.xxs),
                Text(
                  job.enabled ? cadence : '$cadence · Paused',
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: job.enabled
                        ? theme.textPrimary
                        : theme.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: Spacing.xxs),
                Text(
                  hermesJobTimingDetail(job, locale: locale),
                  style: AppTypography.captionStyle.copyWith(
                    color: theme.textSecondary,
                  ),
                ),
                if (job.lastStatus?.trim().isNotEmpty ?? false) ...[
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    'Last status: ${job.lastStatus!.trim()}',
                    style: AppTypography.captionStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                ],
                if (job.prompt.trim().isNotEmpty) ...[
                  const SizedBox(height: Spacing.xs),
                  Text(
                    job.prompt.trim().replaceAll(RegExp(r'\s+'), ' '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.captionStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                ],
                if (hermesScheduleNeedsRawDisplay(job.schedule)) ...[
                  const SizedBox(height: Spacing.xs),
                  Text(
                    job.schedule,
                    style: AppTypography.codeStyle.copyWith(
                      color: theme.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: Spacing.sm),
          if (_toggling)
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
              onChanged: widget.writable ? _setEnabled : null,
            ),
        ],
      ),
    );
  }

  Future<void> _setEnabled(bool enabled) async {
    if (_toggling) return;
    setState(() => _toggling = true);
    try {
      await ref
          .read(hermesJobsProvider.notifier)
          .setEnabled(widget.job.id, enabled);
    } catch (_) {
      _logHermesJobToggleFailure(enabled: enabled);
      if (mounted) {
        UiUtils.showMessage(
          context,
          enabled
              ? 'Could not resume scheduled job.'
              : 'Could not pause scheduled job.',
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _toggling = false);
    }
  }
}

class _JobsEmptyState extends StatelessWidget {
  const _JobsEmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.event_repeat_rounded,
              size: 36,
              color: theme.iconSecondary,
            ),
            const SizedBox(height: Spacing.md),
            Text(
              'No scheduled agents yet',
              style: AppTypography.standard.copyWith(
                color: theme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              'Use Manage to create a prompt that runs on a schedule.',
              textAlign: TextAlign.center,
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
