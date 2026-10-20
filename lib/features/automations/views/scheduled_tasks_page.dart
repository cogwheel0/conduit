import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/automations/automation_schedule.dart';
import 'package:conduit_core/features/automations/models/automation.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/services/settings_service.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/advanced_required_state.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../profile/widgets/adaptive_segmented_selector.dart';
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
        children: [AdvancedRequiredState(feature: l10n.scheduledTasksTitle)],
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
  static const _searchDebounce = Duration(milliseconds: 300);

  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';

  // What the user last asked for, shown at once while the server answers.
  AutomationStatusFilter? _pendingStatus;
  String? _pendingQuery;
  int _refreshGeneration = 0;
  bool _refreshing = false;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    // Reopening shows the server's current list. A first open has no list yet,
    // and reading the provider below is what loads it, so only a provider that
    // already existed is refreshed.
    final reopened = ref.exists(automationsProvider);
    _query = ref.read(automationsProvider).asData?.value.query ?? '';
    _search.text = _query;
    if (reopened) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || ref.read(automationsProvider).isLoading) return;
        _refresh();
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// The account is captured here, on the action, before anything is awaited.
  Future<void> _refresh({String? query, AutomationStatusFilter? status}) async {
    final notifier = ref.read(automationsProvider.notifier);
    final owner = notifier.captureOwner();
    if (owner == null) return;
    final generation = ++_refreshGeneration;
    setState(() {
      _refreshing = true;
      if (status != null) _pendingStatus = status;
      if (query != null) _pendingQuery = query.trim();
    });
    try {
      await notifier.refresh(owner: owner, query: query, status: status);
    } finally {
      // Only the newest request settles what is shown; an older one that
      // finishes later must not clear a filter the user picked since.
      if (mounted && generation == _refreshGeneration) {
        setState(() {
          _refreshing = false;
          _pendingStatus = null;
          _pendingQuery = null;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    final notifier = ref.read(automationsProvider.notifier);
    final owner = notifier.captureOwner();
    if (owner == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      await notifier.loadMore(owner: owner);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _onSearchChanged(String value) {
    setState(() => _query = value);
    _debounce?.cancel();
    _debounce = Timer(_searchDebounce, () {
      if (mounted) _refresh(query: value);
    });
  }

  void _onSearchSubmitted(String value) {
    _debounce?.cancel();
    _refresh(query: value);
  }

  void _clearSearch() {
    _debounce?.cancel();
    _search.clear();
    setState(() => _query = '');
    _refresh(query: '');
  }

  /// Leaves a search or filter that matched nothing for the whole list.
  void _showAll() {
    _debounce?.cancel();
    _search.clear();
    setState(() => _query = '');
    _refresh(query: '', status: AutomationStatusFilter.all);
  }

  void _open(String id) => context.pushNamed(
    RouteNames.scheduledTaskDetail,
    pathParameters: {'id': id},
  );

  void _add() => context.pushNamed(RouteNames.scheduledTaskNew);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final state = ref.watch(automationsProvider);
    final data = state.asData?.value;
    final status = _pendingStatus ?? data?.status ?? AutomationStatusFilter.all;
    // The rows on screen belong to a different search or filter than the one
    // the user just chose, so they are not shown as its answer.
    final awaitingFilter =
        _refreshing &&
        data != null &&
        ((_pendingStatus != null && _pendingStatus != data.status) ||
            (_pendingQuery != null && _pendingQuery != data.query));
    final filtered =
        data != null &&
        (data.query.isNotEmpty || data.status != AutomationStatusFilter.all);
    final emptyAccount = data != null && data.items.isEmpty && !filtered;

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
        _searchField(l10n),
        const SizedBox(height: Spacing.sm),
        KeyedSubtree(
          key: const Key('scheduled-tasks-filter'),
          child: SizedBox(
            width: double.infinity,
            child: AdaptiveSegmentedSelector<AutomationStatusFilter>(
              value: status,
              showIcons: false,
              onChanged: (filter) => _refresh(status: filter),
              options: [
                for (final filter in AutomationStatusFilter.values)
                  (
                    value: filter,
                    label: switch (filter) {
                      AutomationStatusFilter.all =>
                        l10n.scheduledTasksFilterAll,
                      AutomationStatusFilter.active =>
                        l10n.scheduledTasksFilterActive,
                      AutomationStatusFilter.paused =>
                        l10n.scheduledTasksFilterPaused,
                    },
                    cupertinoIcon: CupertinoIcons.circle,
                    materialIcon: Icons.circle_outlined,
                    enabled: true,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Spacing.lg),
        InsetGroupedList(
          useNativeSurface: PlatformInfo.isIOS,
          children: [
            if ((data == null && state.isLoading) || awaitingFilter)
              const Padding(
                key: Key('scheduled-tasks-loading'),
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
            else if (emptyAccount)
              UtilityRow(
                key: const Key('scheduled-tasks-empty'),
                title: l10n.scheduledTasksEmpty,
                subtitle: l10n.scheduledTasksEmptyHint,
                trailing: Icon(
                  UiUtils.platformIcon(
                    ios: CupertinoIcons.add_circled,
                    android: Icons.add_circle_outline,
                  ),
                  color: theme.buttonPrimary,
                  size: IconSize.medium,
                ),
                onTap: _add,
              )
            else if (data.items.isEmpty) ...[
              UtilityRow(
                key: const Key('scheduled-tasks-no-match'),
                title: l10n.scheduledTasksEmptyFiltered,
              ),
              UtilityRow(
                key: const Key('scheduled-tasks-show-all'),
                title: l10n.scheduledTasksShowAll,
                foregroundColor: theme.buttonPrimary,
                onTap: _showAll,
              ),
            ] else
              for (final task in data.items)
                _TaskRow(task: task, onTap: () => _open(task.id)),
            if (data != null && data.hasMore && !awaitingFilter)
              UtilityRow(
                key: const Key('scheduled-tasks-load-more'),
                title: l10n.scheduledTasksLoadMore,
                foregroundColor: theme.buttonPrimary,
                enabled: !_loadingMore,
                status: _loadingMore ? const _RowSpinner() : null,
                onTap: _loadingMore ? null : _loadMore,
              ),
            if ((data?.stale ?? false) && !awaitingFilter)
              UtilityRow(
                key: const Key('scheduled-tasks-stale'),
                title: l10n.scheduledTasksStale,
                subtitle: l10n.retry,
                status: _refreshing ? const _RowSpinner() : null,
                onTap: _refreshing ? null : _refresh,
              ),
          ],
        ),
        if (!emptyAccount) ...[
          const SizedBox(height: Spacing.lg),
          InsetGroupedList(
            useNativeSurface: PlatformInfo.isIOS,
            children: [
              UtilityRow(
                key: const Key('scheduled-tasks-add'),
                title: l10n.scheduledTasksAdd,
                foregroundColor: theme.buttonPrimary,
                leading: Icon(
                  UiUtils.platformIcon(
                    ios: CupertinoIcons.add_circled,
                    android: Icons.add_circle_outline,
                  ),
                  color: theme.buttonPrimary,
                ),
                onTap: _add,
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _searchField(AppLocalizations l10n) {
    if (PlatformInfo.isIOS) {
      return CupertinoSearchTextField(
        key: const Key('scheduled-tasks-search'),
        controller: _search,
        placeholder: l10n.scheduledTasksSearchHint,
        onChanged: _onSearchChanged,
        onSubmitted: _onSearchSubmitted,
        onSuffixTap: _clearSearch,
      );
    }
    return ConduitGlassSearchField(
      key: const Key('scheduled-tasks-search'),
      controller: _search,
      hintText: l10n.scheduledTasksSearchHint,
      query: _query,
      onChanged: _onSearchChanged,
      onClear: _clearSearch,
    );
  }
}

class _RowSpinner extends StatelessWidget {
  const _RowSpinner();

  @override
  Widget build(BuildContext context) =>
      const ConduitLoadingIndicator(size: IconSize.small, isCompact: true);
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
    final lastRunFailed = task.lastRun?.succeeded == false;
    final schedule = AutomationSchedule.parse(task.rrule);
    final subtitle = [
      // A rule the controls cannot describe is named, not printed: the raw
      // text is too long for a list and means little at a glance.
      if (schedule is RawAutomationSchedule)
        l10n.scheduledTaskScheduleCustom
      else
        scheduleSummary(context, l10n, schedule),
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
      status: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            status,
            style: theme.bodySmall?.copyWith(color: theme.textSecondary),
          ),
          if (lastRunFailed)
            Text(
              l10n.scheduledTaskLastRunFailed,
              key: Key('scheduled-task-row-failed-${task.id}'),
              textAlign: TextAlign.end,
              style: theme.bodySmall?.copyWith(color: theme.error),
            ),
        ],
      ),
      semanticLabel: [
        task.name,
        status,
        if (lastRunFailed) l10n.scheduledTaskLastRunFailed,
        subtitle,
      ].join('. '),
      showChevron: true,
      onTap: onTap,
    );
  }
}
