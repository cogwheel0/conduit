import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/haptic_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/platform_scroll_physics.dart';
import '../../../shared/widgets/conduit_loading.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import '../../navigation/providers/sidebar_tab_scroll_registry.dart';

import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';

import '../../navigation/widgets/chats_drawer.dart'
    show sidebarSectionDisclosureIcon;

import 'package:conduit_core/features/navigation/providers/drawer_section_notifiers.dart';

import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_room_providers.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';

import 'hermes_bot_tile.dart';
import 'hermes_connection_switcher.dart';
import 'hermes_jobs_sheet.dart';
import 'hermes_rooms_section.dart';
import 'hermes_session_tile.dart';

/// Sidebar tab listing the user's Hermes server-side conversations, with one
/// compact entry point for scheduled agents when the server exposes jobs.
class HermesSessionsTab extends ConsumerStatefulWidget {
  const HermesSessionsTab({super.key, this.showBottomNavigationBar = true});

  final bool showBottomNavigationBar;

  @override
  ConsumerState<HermesSessionsTab> createState() => _HermesSessionsTabState();
}

class _HermesSessionsTabState extends ConsumerState<HermesSessionsTab>
    with SidebarTabScrollRegistration<HermesSessionsTab> {
  final ScrollController _scrollController = ScrollController();

  /// Whether the archived chats are listed below their row.
  bool _showArchived = false;

  @override
  SidebarTabId get sidebarTabId => SidebarTabId.hermes;

  @override
  ScrollController get sidebarScrollController => _scrollController;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final caps = ref.watch(hermesCapabilitiesProvider).asData?.value;
    final showJobs = caps?.jobs ?? true;
    final sessionsAsync = ref.watch(hermesSessionsProvider);

    // The sidebar tab host has no Material ancestor; provide a transparent one
    // so InkWell / IconButton / CustomizationTile work inside this tab.
    // Top/bottom insets + the refresh edge offset mirror the Chats tab so the
    // content clears the native sidebar chrome and bottom tab bar.
    final scroll = CustomScrollView(
      controller: _scrollController,
      primary: false,
      physics: platformAlwaysScrollablePhysics(context),
      slivers: [
        SliverToBoxAdapter(
          child: SizedBox(height: sidebarTabContentTopPadding(context)),
        ),
        // Names the active connection; switches when several are saved.
        const SliverToBoxAdapter(child: HermesConnectionSwitcherTile()),
        ..._botSlivers(context, ref.watch(hermesBotsProvider).asData?.value),
        const HermesRoomsSection(),
        if (showJobs) const SliverToBoxAdapter(child: _ScheduledAgentsTile()),
        ..._sessionSlivers(context, sessionsAsync),
        SliverToBoxAdapter(
          child: SizedBox(
            height: sidebarTabContentBottomPadding(
              context,
              includeNativeBottomBar: widget.showBottomNavigationBar,
            ),
          ),
        ),
      ],
    );
    final refreshable = ConduitRefreshIndicator(
      edgeOffset: sidebarRefreshIndicatorEdgeOffset(context),
      onRefresh: () async {
        ConduitHaptics.lightImpact();
        if (showJobs) ref.invalidate(hermesJobsProvider);
        ref.invalidate(hermesBotsProvider);
        ref.invalidate(hermesArchivedSessionsProvider);
        // A capabilities read that failed hid Rooms; this one retries it.
        ref.invalidate(hermesRoomCapabilitiesProvider);
        ref.invalidate(hermesRoomsProvider);
        ref.invalidate(hermesSessionsProvider);
        await ref.read(hermesSessionsProvider.future);
      },
      child: scroll,
    );
    final primary = PrimaryScrollController(
      controller: _scrollController,
      child: refreshable,
    );
    return Material(
      type: MaterialType.transparency,
      child: SidebarTabScrollbar(
        builder: (child) => context.usesCupertinoChrome
            ? CupertinoScrollbar(controller: _scrollController, child: child)
            : Scrollbar(controller: _scrollController, child: child),
        child: primary,
      ),
    );
  }

  /// The Bot Mode roster, above everything else. Absent entirely on gateways
  /// without Bot Mode, which report no bots.
  List<Widget> _botSlivers(BuildContext context, List<HermesBot>? bots) {
    if (bots == null || bots.isEmpty) return const [];
    final expanded = ref.watch(hermesShowBotsProvider);
    return [
      SliverToBoxAdapter(
        child: _SectionHeader(
          title: AppLocalizations.of(context)!.hermesBotsTitle,
          count: bots.length,
          expanded: expanded,
          onToggle: () {
            ConduitHaptics.selectionClick();
            ref.read(hermesShowBotsProvider.notifier).toggle();
          },
        ),
      ),
      if (expanded)
        SliverPadding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
          sliver: SliverList.builder(
            itemCount: bots.length,
            itemBuilder: (context, index) => HermesBotTile(bot: bots[index]),
          ),
        ),
    ];
  }

  List<Widget> _sessionSlivers(
    BuildContext context,
    AsyncValue<List<HermesSessionSummary>> sessionsAsync,
  ) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final archivedAsync = ref.watch(hermesArchivedSessionsProvider);
    // A failed refresh keeps the chats it last listed, and says it failed.
    final archived = archivedAsync.value ?? const [];
    // The archived list has its own loading and failure: neither reads as
    // having no archived chats.
    final archivedFailed = archivedAsync.hasError;
    final archivedLoading = archivedAsync.isLoading && !archivedAsync.hasValue;
    return sessionsAsync.when(
      data: (sessions) {
        if (sessions.isEmpty && archived.isEmpty && !archivedFailed) {
          if (archivedLoading) return _loadingSlivers;
          return [
            SliverToBoxAdapter(
              child: _message(
                theme,
                Icons.smart_toy_outlined,
                l10n.hermesNoConversationsMessage,
                theme.textSecondary,
              ),
            ),
          ];
        }
        final pinned = [
          for (final session in sessions)
            if (session.pinned) session,
        ];
        final recent = [
          for (final session in sessions)
            if (!session.pinned) session,
        ];
        return [
          if (pinned.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: _SectionHeader(title: l10n.pinned, count: pinned.length),
            ),
            _sessionList(pinned),
          ],
          if (recent.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: _SectionHeader(
                title: l10n.hermesConversationsTitle,
                count: recent.length,
              ),
            ),
            _sessionList(recent),
          ],
          if (archived.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: _SectionHeader(
                key: const ValueKey<String>('hermes-archived-sessions'),
                title: l10n.archived,
                count: archived.length,
                expanded: _showArchived,
                onToggle: () {
                  ConduitHaptics.selectionClick();
                  setState(() => _showArchived = !_showArchived);
                },
              ),
            ),
            if (_showArchived) _sessionList(archived),
          ],
          if (archivedFailed) ...[
            if (archived.isEmpty)
              SliverToBoxAdapter(child: _SectionHeader(title: l10n.archived)),
            SliverToBoxAdapter(
              child: _ArchivedLoadError(
                onRetry: () => ref.invalidate(hermesArchivedSessionsProvider),
              ),
            ),
          ],
        ];
      },
      loading: () => _loadingSlivers,
      error: (_, _) => [
        SliverToBoxAdapter(
          child: _message(
            theme,
            Icons.error_outline,
            l10n.hermesConversationsLoadError,
            theme.error,
          ),
        ),
      ],
    );
  }

  static const List<Widget> _loadingSlivers = [
    SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.only(top: 64),
        child: Center(child: AdaptiveProgressIndicator()),
      ),
    ),
  ];

  Widget _sessionList(List<HermesSessionSummary> sessions) => SliverPadding(
    // The shared conversation tile supplies the 4.0.3 Hermes 8pt row
    // gutter. Keep list padding vertical to avoid doubling that inset
    // only in this tab.
    padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
    sliver: SliverList.builder(
      itemCount: sessions.length,
      itemBuilder: (context, index) =>
          HermesSessionTile(session: sessions[index]),
    ),
  );

  Widget _message(
    ConduitThemeExtension theme,
    IconData icon,
    String text,
    Color color,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 80, left: 24, right: 24),
      child: Column(
        children: [
          Icon(icon, size: 40, color: color),
          const SizedBox(height: Spacing.md),
          Text(
            text,
            textAlign: TextAlign.center,
            style: AppTypography.bodySmallStyle.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

class _ScheduledAgentsTile extends ConsumerWidget {
  const _ScheduledAgentsTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobsAsync = ref.watch(hermesJobsProvider);
    final jobs = jobsAsync.value;
    final count = jobs?.length;
    final activeCount = jobs?.where((job) => job.enabled).length;
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final subtitle = switch ((count, activeCount, jobsAsync)) {
      (null, _, AsyncLoading()) => l10n.hermesSchedulesLoading,
      (null, _, AsyncError()) => l10n.hermesSchedulesUnavailable,
      (0, _, _) => l10n.hermesNoSchedulesYet,
      (final int total, final int active, _) => l10n.hermesSchedulesSummary(
        active,
        total,
      ),
      _ => l10n.hermesReviewSchedules,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.sm,
        Spacing.md,
        Spacing.sm,
        Spacing.xs,
      ),
      child: InkWell(
        key: const ValueKey<String>('hermes-scheduled-agents-tile'),
        onTap: () => showHermesJobsSheet(context),
        borderRadius: BorderRadius.circular(AppBorderRadius.card),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.sm,
          ),
          decoration: BoxDecoration(
            color: theme.surfaceBackground,
            borderRadius: BorderRadius.circular(AppBorderRadius.card),
            border: Border.all(color: theme.cardBorder),
          ),
          child: Row(
            children: [
              SizedBox(
                width: IconSize.xl,
                height: IconSize.xl,
                child: Icon(
                  Icons.event_repeat_rounded,
                  size: IconSize.medium,
                  color: theme.textPrimary,
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.hermesScheduledAgentsTitle,
                      style: AppTypography.bodyMediumStyle.copyWith(
                        color: theme.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: Spacing.xxs),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.bodySmallStyle.copyWith(
                        color: theme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (count != null && count > 0) ...[
                const SizedBox(width: Spacing.sm),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.sm,
                    vertical: Spacing.xxs,
                  ),
                  decoration: BoxDecoration(
                    color: theme.surfaceContainer,
                    borderRadius: BorderRadius.circular(AppBorderRadius.pill),
                  ),
                  child: Text(
                    '$count',
                    style: AppTypography.labelMediumStyle.copyWith(
                      color: theme.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: Spacing.xs),
              Icon(
                Icons.chevron_right_rounded,
                size: IconSize.listItem,
                color: theme.iconSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Section header with an optional count badge.
/// The archived row when its list failed to load: says so, with a retry.
class _ArchivedLoadError extends StatelessWidget {
  const _ArchivedLoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      key: const ValueKey<String>('hermes-archived-sessions-error'),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.hermesArchivedLoadError,
              style: AppTypography.bodySmallStyle.copyWith(color: theme.error),
            ),
          ),
          const SizedBox(width: Spacing.sm),
          AdaptiveButton(
            onPressed: onRetry,
            label: l10n.retry,
            style: AdaptiveButtonStyle.tinted,
            size: AdaptiveButtonSize.small,
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    super.key,
    required this.title,
    this.count,
    this.expanded,
    this.onToggle,
  });

  final String title;
  final int? count;

  /// Disclosure state; null renders a plain, non-collapsible header.
  final bool? expanded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final titleStyle = AppTypography.labelStyle.copyWith(
      color: theme.textSecondary,
      fontWeight: FontWeight.w700,
    );

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.md,
        Spacing.md,
        Spacing.sm,
        Spacing.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                if (expanded != null) ...[
                  Icon(
                    sidebarSectionDisclosureIcon(expanded!),
                    color: theme.iconSecondary,
                    size: IconSize.listItem,
                  ),
                  const SizedBox(width: Spacing.xxs),
                ],
                Text(title, style: titleStyle),
                if (count != null) ...[
                  const SizedBox(width: Spacing.sm),
                  Text(
                    '$count',
                    style: AppTypography.labelMediumStyle.copyWith(
                      color: theme.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    if (onToggle == null) return header;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggle,
      child: header,
    );
  }
}
