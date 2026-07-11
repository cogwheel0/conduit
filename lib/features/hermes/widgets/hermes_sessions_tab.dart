import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/platform_scroll_physics.dart';
import '../../../shared/widgets/conduit_loading.dart';
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../models/hermes_session.dart';
import '../providers/hermes_providers.dart';
import 'hermes_jobs_sheet.dart';
import 'hermes_session_tile.dart';

/// Sidebar tab listing the user's Hermes server-side conversations, with one
/// compact entry point for scheduled agents when the server exposes jobs.
class HermesSessionsTab extends ConsumerWidget {
  const HermesSessionsTab({super.key, this.showBottomNavigationBar = true});

  final bool showBottomNavigationBar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final caps = ref.watch(hermesCapabilitiesProvider).asData?.value;
    final showJobs = caps?.jobs ?? true;
    final sessionsAsync = ref.watch(hermesSessionsProvider);

    // The sidebar tab host has no Material ancestor; provide a transparent one
    // so InkWell / IconButton / CustomizationTile work inside this tab.
    // Top/bottom insets + the refresh edge offset mirror the Chats tab so the
    // content clears the native sidebar chrome and bottom tab bar.
    return Material(
      type: MaterialType.transparency,
      child: ConduitRefreshIndicator(
        edgeOffset: sidebarRefreshIndicatorEdgeOffset(context),
        onRefresh: () async {
          if (showJobs) ref.invalidate(hermesJobsProvider);
          ref.invalidate(hermesSessionsProvider);
          await ref.read(hermesSessionsProvider.future);
        },
        child: CustomScrollView(
          physics: platformAlwaysScrollablePhysics(context),
          slivers: [
            SliverToBoxAdapter(
              child: SizedBox(height: sidebarTabContentTopPadding(context)),
            ),
            if (showJobs)
              const SliverToBoxAdapter(child: _ScheduledAgentsTile()),
            ..._sessionSlivers(context, sessionsAsync),
            SliverToBoxAdapter(
              child: SizedBox(
                height: sidebarTabContentBottomPadding(
                  context,
                  includeNativeBottomBar: showBottomNavigationBar,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _sessionSlivers(
    BuildContext context,
    AsyncValue<List<HermesSessionSummary>> sessionsAsync,
  ) {
    final theme = context.conduitTheme;
    return sessionsAsync.when(
      data: (sessions) {
        if (sessions.isEmpty) {
          return [
            SliverToBoxAdapter(
              child: _message(
                theme,
                Icons.smart_toy_outlined,
                'No Hermes conversations yet.\nStart a new chat with the '
                'Hermes Agent and it will appear here.',
                theme.textSecondary,
              ),
            ),
          ];
        }
        return [
          SliverToBoxAdapter(
            child: _SectionHeader(
              title: 'Conversations',
              count: sessions.length,
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.sm,
              vertical: Spacing.xs,
            ),
            sliver: SliverList.builder(
              itemCount: sessions.length,
              itemBuilder: (context, index) =>
                  HermesSessionTile(session: sessions[index]),
            ),
          ),
        ];
      },
      loading: () => const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 64),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ],
      error: (_, _) => [
        SliverToBoxAdapter(
          child: _message(
            theme,
            Icons.error_outline,
            'Could not load Hermes conversations.\nCheck the connection in '
            'Settings → Hermes Agent.',
            theme.error,
          ),
        ),
      ],
    );
  }

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
    final subtitle = switch ((count, activeCount, jobsAsync)) {
      (null, _, AsyncLoading()) => 'Loading schedules…',
      (null, _, AsyncError()) => 'Schedules unavailable',
      (0, _, _) => 'No schedules yet',
      (final int total, final int active, _) =>
        '$active active · $total ${total == 1 ? 'schedule' : 'schedules'}',
      _ => 'Review schedules',
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
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: theme.buttonPrimary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppBorderRadius.button),
                ),
                child: Icon(
                  Icons.event_repeat_rounded,
                  size: IconSize.listItem,
                  color: theme.buttonPrimary,
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Scheduled agents',
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
                      style: AppTypography.captionStyle.copyWith(
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
                    color: theme.buttonPrimary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(AppBorderRadius.pill),
                  ),
                  child: Text(
                    '$count',
                    style: AppTypography.labelMediumStyle.copyWith(
                      color: theme.buttonPrimary,
                      fontWeight: FontWeight.w700,
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
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.count});

  final String title;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final titleStyle = AppTypography.labelStyle.copyWith(
      color: theme.textSecondary,
      fontWeight: FontWeight.w700,
    );

    return Padding(
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
  }
}
