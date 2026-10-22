import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/utils/hermes_schedule_format.dart';

import '../../../l10n/app_localizations.dart';
import '../../../l10n/app_localizations_en.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/utils/ui_utils.dart';
import '../views/hermes_jobs_page.dart'
    show HermesScheduleDetails, hermesScheduleRepairPrompt;
import 'hermes_schedule_editor.dart';
import 'hermes_mobile_shell.dart' show startHermesMobileConversation;
import 'hermes_session_tile.dart' show openHermesSessionWithReader;

AppLocalizations _labels(BuildContext context) =>
    AppLocalizations.of(context) ?? AppLocalizationsEn();

bool hermesScheduleHasError(HermesJob job) =>
    job.lastError?.isNotEmpty == true ||
    job.lastDeliveryError?.isNotEmpty == true ||
    const {
      'error',
      'fail',
      'failed',
      'failure',
    }.contains(job.lastStatus?.toLowerCase());

enum _ScheduleAction { edit, toggle, history, error, delete }

void _closeScheduleSheets(ModalRoute<dynamic>? detailRoute) {
  final navigator = detailRoute?.navigator;
  if (navigator == null) return;
  navigator.popUntil((route) => identical(route, detailRoute));
  navigator.pop();
}

Future<void> showHermesScheduleDetail(
  BuildContext context,
  HermesJob job, {
  bool writable = true,
}) => showHermesScheduleSheet<void>(
  context,
  HermesScheduleDetail(
    job: job,
    writable: writable,
    sourceRoute: ModalRoute.of(context),
  ),
  heightFraction: .56,
);

class HermesScheduleDetail extends ConsumerStatefulWidget {
  const HermesScheduleDetail({
    super.key,
    required this.job,
    required this.sourceRoute,
    this.writable = true,
  });
  final HermesJob job;
  final bool writable;
  final ModalRoute<dynamic>? sourceRoute;
  @override
  ConsumerState<HermesScheduleDetail> createState() =>
      _HermesScheduleDetailState();
}

class _HermesScheduleDetailState extends ConsumerState<HermesScheduleDetail> {
  late final _service = ref.read(hermesApiServiceProvider);
  bool _busy = false;
  bool get _current => identical(ref.read(hermesApiServiceProvider), _service);
  Future<void> _mutate(
    Future<void> Function() action,
    String failure, {
    String? success,
    bool close = false,
  }) async {
    if (_busy || !_current || _service == null) return;
    HermesScheduleDismissScope.allow(context, false);
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted || !_current) return;
      if (success != null) UiUtils.showMessage(context, success);
      if (close) {
        HermesScheduleDismissScope.allow(context, true);
        Navigator.of(context).pop();
      }
    } catch (_) {
      if (mounted) UiUtils.showMessage(context, failure, isError: true);
    } finally {
      if (mounted) {
        HermesScheduleDismissScope.allow(context, true);
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _action(_ScheduleAction action, HermesJob job) async {
    final l10n = _labels(context);
    final detailRoute = ModalRoute.of(context);
    switch (action) {
      case _ScheduleAction.edit:
        await showHermesScheduleEditor(context, job: job);
      case _ScheduleAction.toggle:
        await _mutate(
          () => ref
              .read(hermesJobsProvider.notifier)
              .setEnabled(job.id, !job.enabled),
          job.enabled ? l10n.hermesJobPauseFailed : l10n.hermesJobResumeFailed,
        );
      case _ScheduleAction.history:
        await showHermesScheduleSheet<void>(
          context,
          HermesScheduleRunHistory(
            job: job,
            sourceRoute: widget.sourceRoute,
            detailRoute: detailRoute,
            service: _service,
          ),
        );
      case _ScheduleAction.error:
        await showHermesScheduleSheet<void>(
          context,
          HermesScheduleDetails(
            job: job,
            error: true,
            onRepair: () {
              if (!mounted || !_current) return;
              final profile = ref.read(hermesScheduleProfileProvider);
              final sourceRoute = widget.sourceRoute;
              final sourceContext = sourceRoute?.subtreeContext;
              final preparation = startHermesMobileConversation(
                ref,
                prefill: hermesScheduleRepairPrompt(job, profile: profile),
              );
              _closeScheduleSheets(detailRoute);
              unawaited(
                preparation.then((_) {
                  if (profile != null &&
                      sourceContext?.mounted == true &&
                      sourceRoute?.isCurrent == true) {
                    Navigator.of(sourceContext!).pop();
                  }
                }),
              );
            },
          ),
        );
      case _ScheduleAction.delete:
        final confirmed = await ThemedDialogs.confirm(
          context,
          title: l10n.hermesJobDeleteTitle,
          message: l10n.hermesJobDeleteMessage,
          confirmText: l10n.delete,
          isDestructive: true,
        );
        if (confirmed && mounted && _current) {
          await _mutate(
            () => ref.read(hermesJobsProvider.notifier).delete(job.id),
            l10n.hermesJobDeleteFailed,
            close: true,
          );
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _labels(context);
    final rows = ref.watch(hermesJobsProvider).asData?.value;
    final job =
        rows?.where((item) => item.id == widget.job.id).firstOrNull ??
        widget.job;
    final writable =
        _current &&
        widget.writable &&
        (ref.watch(hermesCapabilitiesProvider).asData?.value.jobsAdmin ?? true);
    final hasError = hermesScheduleHasError(job);
    return PopScope(
      canPop: !_busy,
      child: HermesScheduleSheetFrame(
        title: job.displayName,
        actions: [
          CompactPopupMenu<_ScheduleAction>(
            tooltip: l10n.scheduleActions,
            icon: const Icon(Icons.more_horiz_rounded),
            choices: [
              CompactMenuChoice(
                _ScheduleAction.edit,
                l10n.scheduleEdit,
                icon: Icons.edit_outlined,
                enabled: writable && !_busy,
              ),
              CompactMenuChoice(
                _ScheduleAction.toggle,
                job.enabled ? l10n.schedulePause : l10n.scheduleResume,
                icon: job.enabled
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                enabled: writable && !_busy,
              ),
              CompactMenuChoice(
                _ScheduleAction.history,
                l10n.hermesJobRunHistory,
                icon: Icons.history_rounded,
                enabled: _current && !_busy,
              ),
              if (hasError)
                CompactMenuChoice(
                  _ScheduleAction.error,
                  l10n.mobileScheduleError,
                  icon: Icons.error_outline_rounded,
                  enabled: _current && !_busy,
                ),
              CompactMenuChoice(
                _ScheduleAction.delete,
                l10n.delete,
                icon: Icons.delete_outline_rounded,
                enabled: writable && !_busy,
              ),
            ],
            onSelected: (action) => _action(action, job),
          ),
        ],
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          children: [
            Text(
              hermesScheduleSummary(job.schedule),
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 8),
            Text(
              !job.enabled
                  ? l10n.hermesJobPaused
                  : job.nextRun == null
                  ? 'Next run not reported'
                  : '${l10n.scheduleNextLocal}: ${_date(context, job.nextRun!)}',
              style: TextStyle(color: context.conduitTheme.textSecondary),
            ),
            const SizedBox(height: 24),
            Text(
              l10n.scheduleWhat,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            if (job.script?.isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: CompactContentRow(
                  surface: true,
                  title: Text(l10n.scheduleScript),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => showHermesScheduleSkillDetail(
                    context,
                    l10n.scheduleScript,
                    job.script,
                  ),
                ),
              ),
            if (job.script == null &&
                job.skills.isEmpty &&
                job.prompt.trim().isEmpty)
              Text(l10n.scheduleNoWork),
            for (final skill in job.skills)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: CompactContentRow(
                  surface: true,
                  title: Text(skill),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () async {
                    final rows = await ref
                        .read(hermesInstalledSkillsProvider.future)
                        .catchError((_) => <Map<String, dynamic>>[]);
                    if (!context.mounted || !_current) return;
                    final description = rows
                        .where((row) => row['name'] == skill)
                        .firstOrNull?['description']
                        ?.toString();
                    await showHermesScheduleSkillDetail(
                      context,
                      skill,
                      description,
                    );
                  },
                ),
              ),
            if (job.prompt.trim().isNotEmpty)
              CompactContentRow(
                surface: true,
                title: Text(l10n.scheduleInstructions),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => showHermesScheduleSheet<void>(
                  context,
                  HermesScheduleSheetFrame(
                    title: l10n.scheduleInstructions,
                    body: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: SelectableText(job.prompt),
                    ),
                  ),
                ),
              ),
            if (hasError)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: CompactContentRow(
                  key: ValueKey('hermes-job-error-${job.id}'),
                  title: Text(
                    l10n.mobileScheduleFailed,
                    style: TextStyle(color: context.conduitTheme.error),
                  ),
                  leading: Icon(
                    Icons.error_outline_rounded,
                    color: context.conduitTheme.error,
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    if (_current && !_busy) _action(_ScheduleAction.error, job);
                  },
                ),
              ),
            if (!_current)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(l10n.hermesJobAdminDisabled),
              ),
          ],
        ),
        footer: ConduitButton(
          key: ValueKey('hermes-job-run-${job.id}'),
          text: l10n.hermesJobRunNow,
          icon: Icons.play_arrow_rounded,
          isLoading: _busy,
          isFullWidth: true,
          onPressed: writable && !_busy
              ? () => _mutate(
                  () => ref.read(hermesJobsProvider.notifier).runNow(job.id),
                  l10n.hermesJobRunFailed,
                  success: l10n.hermesJobStarted,
                )
              : null,
        ),
      ),
    );
  }
}

String _date(BuildContext context, DateTime value) {
  final local = value.toLocal();
  final material = MaterialLocalizations.of(context);
  return '${material.formatMediumDate(local)} ${material.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
}

class HermesScheduleRunHistory extends ConsumerWidget {
  const HermesScheduleRunHistory({
    super.key,
    required this.job,
    required this.sourceRoute,
    required this.detailRoute,
    required this.service,
  });
  final HermesJob job;
  final ModalRoute<dynamic>? sourceRoute;
  final ModalRoute<dynamic>? detailRoute;
  final Object? service;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = _labels(context);
    return HermesScheduleSheetFrame(
      title: l10n.hermesJobRunHistory,
      body: ref
          .watch(hermesJobRunsProvider(job.id))
          .when(
            loading: () => const Center(child: AdaptiveProgressIndicator()),
            error: (_, _) => Center(
              child: ConduitButton(
                text: l10n.retry,
                onPressed: () => ref.invalidate(hermesJobRunsProvider(job.id)),
              ),
            ),
            data: (items) => ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: [
                if (items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(l10n.scheduleNoRuns),
                  ),
                for (final run in items)
                  CompactContentRow(
                    title: Text(
                      run.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: run.updatedAt == null
                        ? null
                        : Text(_date(context, run.updatedAt!)),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () async {
                      // Close the root sheets before asking the existing conversation owner
                      // to perform its history-to-chat transition. The provider result is
                      // scoped by this job; an unrelated session is never substituted.
                      final container = ProviderScope.containerOf(
                        context,
                        listen: false,
                      );
                      if (!identical(
                            container.read(hermesApiServiceProvider),
                            service,
                          ) ||
                          sourceRoute?.subtreeContext?.mounted != true) {
                        return;
                      }
                      final destination = sourceRoute;
                      final sourceContext = destination?.subtreeContext;
                      if (destination == null || sourceContext == null) return;
                      _closeScheduleSheets(detailRoute);
                      final profile = container.read(
                        hermesScheduleProfileProvider,
                      );
                      var opened = false;
                      await openHermesSessionWithReader(
                        sourceContext,
                        container.read,
                        run,
                        onOpened: () => opened = true,
                      );
                      if (opened &&
                          profile != null &&
                          sourceContext.mounted &&
                          destination.isCurrent) {
                        Navigator.of(sourceContext).pop();
                      }
                    },
                  ),
              ],
            ),
          ),
    );
  }
}
