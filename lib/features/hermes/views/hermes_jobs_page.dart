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
import '../widgets/hermes_schedule_editor.dart';
import '../widgets/hermes_schedule_details.dart';
import '../widgets/hermes_mobile_shell.dart' show startHermesMobileConversation;
import '../providers/hermes_mobile_navigation.dart';
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
      title: l10n.mobileSchedules,
      children: [
        if (ref.watch(hermesMobileLayoutProvider))
          Align(
            alignment: Alignment.centerRight,
            child: HermesScheduleCreateAction(writable: writable),
          )
        else
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
                  HermesScheduleCard(
                    key: ValueKey<String>(job.id),
                    job: job,
                    writable: writable,
                    management: true,
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
    if (ref.read(hermesMobileLayoutProvider)) {
      await showHermesScheduleEditor(context);
      return;
    }
    final result = await showHermesJobEditor(context);
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
          ),
      failureMessage: l10n.hermesJobCreateFailed,
      successMessage: l10n.hermesJobCreated,
    );
    if (mounted) setState(() => _creating = false);
  }
}

enum _ScheduleCreate { direct, ask }

class HermesScheduleCreateAction extends ConsumerWidget {
  const HermesScheduleCreateAction({
    super.key,
    required this.writable,
    this.onAsk,
    this.askLabel,
  });
  final bool writable;
  final VoidCallback? onAsk;
  final String? askLabel;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = _l10n(context);
    return CompactPopupMenu<_ScheduleCreate>(
      tooltip: l10n.create,
      icon: const Icon(Icons.add_rounded),
      choices: [
        CompactMenuChoice(
          _ScheduleCreate.direct,
          l10n.scheduleNew,
          icon: Icons.calendar_today_outlined,
          enabled: writable,
        ),
        CompactMenuChoice(
          _ScheduleCreate.ask,
          askLabel ?? l10n.scheduleAsk,
          icon: Icons.chat_bubble_outline_rounded,
        ),
      ],
      onSelected: (choice) {
        if (choice == _ScheduleCreate.direct) {
          showHermesScheduleEditor(context);
        } else if (onAsk != null) {
          onAsk!();
        } else {
          startHermesMobileConversation(ref, prefill: l10n.scheduleAskPrompt);
        }
      },
    );
  }
}

enum _JobMutation { toggle, run, edit, delete }

class HermesScheduleCard extends ConsumerStatefulWidget {
  const HermesScheduleCard({
    super.key,
    required this.job,
    this.writable = true,
    this.management = false,
    this.grouped = false,
  });

  final HermesJob job;
  final bool writable;
  final bool management;
  final bool grouped;

  @override
  ConsumerState<HermesScheduleCard> createState() => HermesScheduleCardState();
}

class HermesScheduleCardState extends ConsumerState<HermesScheduleCard> {
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

    if (ref.watch(hermesMobileLayoutProvider)) return _buildMobileCard();

    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: theme.groupedSurface,
        borderRadius: BorderRadius.circular(
          context.usesCupertinoChrome
              ? AppBorderRadius.md
              : AppBorderRadius.card,
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

  Widget _buildMobileCard() {
    final l10n = _l10n(context);
    final failed = hermesScheduleHasError(job);
    return CompactContentRow(
      surface: !widget.grouped,
      title: Text(
        job.displayName,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: AppTypography.standard.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (failed)
            Text(
              l10n.mobileScheduleFailed,
              style: TextStyle(color: context.conduitTheme.error),
            ),
          if (job.enabled && job.nextRun == null)
            Text(hermesScheduleSummary(job.schedule)),
          Text(
            job.enabled
                ? hermesJobTimingDetail(
                    job,
                    locale: Localizations.localeOf(context).toString(),
                  )
                : l10n.hermesJobPaused,
          ),
        ],
      ),
      trailing: Icon(
        failed ? Icons.error_outline_rounded : Icons.chevron_right_rounded,
        color: failed ? context.conduitTheme.error : null,
      ),
      onTap: () => showHermesScheduleDetail(context, job, writable: writable),
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
    if (ref.read(hermesMobileLayoutProvider)) {
      await showHermesScheduleEditor(context, job: job);
      return;
    }
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

/// Owns its modal context/ref independently of a refreshing schedule list.
class HermesScheduleDetails extends ConsumerWidget {
  const HermesScheduleDetails({
    super.key,
    required this.job,
    this.error = false,
    this.onRepair,
  });
  final HermesJob job;
  final bool error;
  final VoidCallback? onRepair;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = _l10n(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            job.displayName,
            style: AppTypography.standard.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Text(
            error ? l10n.mobileScheduleError : l10n.mobileScheduleDetails,
            style: AppTypography.bodySmallStyle.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          if (job.lastError?.isNotEmpty == true) SelectableText(job.lastError!),
          if (job.lastDeliveryError?.isNotEmpty == true) ...[
            const SizedBox(height: 12),
            Text(l10n.mobileDeliveryFailed),
            SelectableText(job.lastDeliveryError!),
          ],
          if (error &&
              job.lastError?.isNotEmpty != true &&
              job.lastDeliveryError?.isNotEmpty != true)
            Text('${l10n.hermesJobLastLabel}: ${job.lastStatus ?? 'error'}'),
          if (!error) ...[
            Text('${l10n.mobileSchedules}: ${job.schedule}'),
            Text(
              '${l10n.hermesJobStateLabel}: ${job.state ?? (job.enabled ? 'active' : 'paused')}',
            ),
            Text(
              '${l10n.hermesJobDeliveryLabel}: ${job.deliveryTarget ?? 'local'}',
            ),
            if (job.lastRun != null)
              Text(
                '${l10n.hermesJobLastLabel}: ${_formatJobTime(context, job.lastRun!)}',
              ),
            if (job.nextRun != null)
              Text(
                '${l10n.hermesJobNextLabel}: ${_formatJobTime(context, job.nextRun!)}',
              ),
            const SizedBox(height: 12),
            SelectableText(job.prompt),
          ],
          if (error) ...[
            const SizedBox(height: 20),
            ConduitButton(
              key: ValueKey('hermes-job-fix-${job.id}'),
              text: l10n.mobileAskHermesFix,
              icon: Icons.chat_bubble_outline_rounded,
              onPressed: () {
                if (onRepair != null) {
                  onRepair!();
                  return;
                }
                Navigator.of(context).pop();
                startHermesMobileConversation(
                  ref,
                  prefill: hermesScheduleRepairPrompt(job),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  String _formatJobTime(BuildContext context, DateTime value) {
    final local = value.toLocal();
    final material = MaterialLocalizations.of(context);
    return '${material.formatMediumDate(local)} '
        '${material.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
  }
}

/// A user-reviewable draft: opening the repair chat never dispatches it.
String hermesScheduleRepairPrompt(HermesJob job, {String? profile}) =>
    'Help me diagnose and fix this scheduled task. Explain the cause and propose a fix before changing its schedule or configuration.\n'
    'Task: ${job.displayName}\nJob ID: ${job.id}\nSchedule: ${job.schedule}\n'
    '${profile == null ? "" : "Bot profile: $profile\n"}'
    'Last status: ${job.lastStatus ?? "unknown"}\n'
    'Error reported by Hermes:\n${job.lastError ?? "No execution error details were provided."}\n'
    '${job.lastDeliveryError == null ? "" : "Delivery error:\n${job.lastDeliveryError}\n"}';
