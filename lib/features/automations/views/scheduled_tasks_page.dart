import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/features/automations/automation_schedule.dart';
import 'package:conduit_core/features/automations/models/automation.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/services/settings_service.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/utility_components.dart';
import 'scheduled_task_format.dart';

/// Wraps a scheduled tasks screen with the rule every entry point shares: the
/// Advanced disclosure is on and the server and account allow tasks.
///
/// Advanced only reveals these screens. Turning it off hides the entry and
/// leaves every task on the server running.
class ScheduledTasksGate extends ConsumerWidget {
  const ScheduledTasksGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final advanced = ref.watch(
      appSettingsProvider.select(
        (settings) => settings.advancedFeaturesEnabled,
      ),
    );
    if (!advanced) {
      return UtilityPageScaffold.settings(
        key: const Key('scheduled-tasks-needs-advanced'),
        title: l10n.scheduledTasksTitle,
        children: [Text(l10n.scheduledTasksNeedsAdvanced)],
      );
    }
    if (!ref.watch(automationsAvailableProvider)) {
      return UtilityPageScaffold.settings(
        key: const Key('scheduled-tasks-unavailable'),
        title: l10n.scheduledTasksTitle,
        children: [Text(l10n.scheduledTasksUnavailable)],
      );
    }
    return child;
  }
}

/// The account's Open WebUI scheduled tasks. The server runs them on its own
/// schedule, so nothing here depends on this phone being online.
class ScheduledTasksPage extends StatelessWidget {
  const ScheduledTasksPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const ScheduledTasksGate(child: _ScheduledTasksList());
}

class _ScheduledTasksList extends ConsumerStatefulWidget {
  const _ScheduledTasksList();

  @override
  ConsumerState<_ScheduledTasksList> createState() =>
      _ScheduledTasksListState();
}

class _ScheduledTasksListState extends ConsumerState<_ScheduledTasksList> {
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Reopening shows the server's current list. A first open has no list yet,
    // and reading the provider below is what loads it, so only a provider that
    // already existed is refreshed.
    final reopened = ref.exists(automationsProvider);
    _search.text = ref.read(automationsProvider).asData?.value.query ?? '';
    if (reopened) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || ref.read(automationsProvider).isLoading) return;
        _refresh();
      });
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// The account is captured here, on the action, before anything is awaited.
  Future<void> _refresh({String? query, AutomationStatusFilter? status}) async {
    final notifier = ref.read(automationsProvider.notifier);
    final owner = notifier.captureOwner();
    if (owner == null) return;
    await notifier.refresh(owner: owner, query: query, status: status);
  }

  Future<void> _loadMore() async {
    final notifier = ref.read(automationsProvider.notifier);
    final owner = notifier.captureOwner();
    if (owner == null) return;
    await notifier.loadMore(owner: owner);
  }

  void _open(String id) => context.pushNamed(
    RouteNames.scheduledTaskDetail,
    pathParameters: {'id': id},
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final state = ref.watch(automationsProvider);
    final data = state.asData?.value;
    final status = data?.status ?? AutomationStatusFilter.all;

    return UtilityPageScaffold.settings(
      title: l10n.scheduledTasksTitle,
      children: [
        Text(
          l10n.scheduledTasksDescription,
          style: AppTypography.bodySmallStyle.copyWith(
            color: theme.textSecondary,
          ),
        ),
        const SizedBox(height: Spacing.md),
        ConduitInput(
          key: const Key('scheduled-tasks-search'),
          controller: _search,
          hint: l10n.scheduledTasksSearchHint,
          semanticLabel: l10n.scheduledTasksSearchHint,
          textInputAction: TextInputAction.search,
          onSubmitted: (value) => _refresh(query: value),
        ),
        const SizedBox(height: Spacing.sm),
        Row(
          children: [
            for (final filter in AutomationStatusFilter.values) ...[
              ConduitChip(
                key: Key('scheduled-tasks-filter-${filter.name}'),
                label: switch (filter) {
                  AutomationStatusFilter.all => l10n.scheduledTasksFilterAll,
                  AutomationStatusFilter.active =>
                    l10n.scheduledTasksFilterActive,
                  AutomationStatusFilter.paused =>
                    l10n.scheduledTasksFilterPaused,
                },
                isSelected: status == filter,
                onTap: () => _refresh(status: filter),
              ),
              const SizedBox(width: Spacing.sm),
            ],
          ],
        ),
        const SizedBox(height: Spacing.lg),
        InsetGroupedList(
          children: [
            if (data == null && state.isLoading)
              const Padding(
                padding: EdgeInsets.all(Spacing.md),
                child: Center(child: ConduitLoadingIndicator(isCompact: true)),
              )
            else if (data == null)
              UtilityRow(
                key: const Key('scheduled-tasks-retry'),
                title: l10n.scheduledTasksLoadFailed,
                subtitle: l10n.retry,
                onTap: _refresh,
              )
            else if (data.items.isEmpty)
              UtilityRow(
                title: data.query.isEmpty && data.status.query == null
                    ? l10n.scheduledTasksEmpty
                    : l10n.scheduledTasksEmptyFiltered,
                enabled: false,
              )
            else
              for (final task in data.items)
                _TaskRow(task: task, onTap: () => _open(task.id)),
            if (data != null && data.hasMore)
              UtilityRow(
                key: const Key('scheduled-tasks-load-more'),
                title: l10n.scheduledTasksLoadMore,
                onTap: _loadMore,
              ),
            if (data?.stale ?? false)
              UtilityRow(
                key: const Key('scheduled-tasks-stale'),
                title: l10n.scheduledTasksStale,
                subtitle: l10n.retry,
                onTap: _refresh,
              ),
            UtilityRow(
              key: const Key('scheduled-tasks-add'),
              title: l10n.scheduledTasksAdd,
              leading: Icon(
                UiUtils.platformIcon(
                  ios: CupertinoIcons.add_circled,
                  android: Icons.add_circle_outline,
                ),
              ),
              onTap: () => context.pushNamed(RouteNames.scheduledTaskNew),
            ),
          ],
        ),
      ],
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task, required this.onTap});

  final Automation task;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final next = formatServerTime(context, task.nextRunNs);
    final status = task.isActive
        ? l10n.scheduledTaskStatusActive
        : l10n.scheduledTaskStatusPaused;
    final subtitle = [
      scheduleSummary(context, l10n, AutomationSchedule.parse(task.rrule)),
      if (task.isActive)
        next == null
            ? l10n.scheduledTaskNoNextRun
            : l10n.scheduledTaskNextRun(next),
    ].join(' · ');
    return UtilityRow(
      key: Key('scheduled-task-row-${task.id}'),
      title: task.name,
      subtitle: subtitle,
      subtitleMaxLines: 2,
      status: Text(
        status,
        style: theme.bodySmall?.copyWith(color: theme.textSecondary),
      ),
      semanticLabel: '${task.name}. $status. $subtitle',
      showChevron: true,
      onTap: onTap,
    );
  }
}
