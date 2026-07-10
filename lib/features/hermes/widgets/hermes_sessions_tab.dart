import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/navigation_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/platform_scroll_physics.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_loading.dart';
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../models/hermes_job.dart';
import '../models/hermes_session.dart';
import '../providers/hermes_providers.dart';
import 'hermes_session_tile.dart';

/// Sidebar tab listing the user's Hermes server-side conversations — the
/// Hermes-backend analogue of the Chats tab — with a collapsible "Scheduled
/// Agents" section on top (when the server exposes jobs).
class HermesSessionsTab extends ConsumerWidget {
  const HermesSessionsTab({super.key});

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
            if (showJobs) const SliverToBoxAdapter(child: _JobsSection()),
            ..._sessionSlivers(context, sessionsAsync),
            SliverToBoxAdapter(
              child: SizedBox(height: sidebarTabContentBottomPadding(context)),
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

/// Collapsible "Scheduled Agents" section showing jobs inline, mirroring the
/// chats drawer's folders section.
class _JobsSection extends ConsumerWidget {
  const _JobsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded = ref.watch(hermesJobsSectionExpandedProvider);
    final jobsAsync = ref.watch(hermesJobsProvider);
    final count = jobsAsync.asData?.value.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: 'Scheduled Agents',
          count: count,
          expanded: expanded,
          onToggle: () =>
              ref.read(hermesJobsSectionExpandedProvider.notifier).toggle(),
          onManage: () => context.pushNamed(RouteNames.hermesJobs),
        ),
        if (expanded)
          jobsAsync.when(
            data: (jobs) {
              if (jobs.isEmpty) {
                return _hint(context, 'No scheduled jobs.');
              }
              return Column(
                children: [for (final job in jobs) _JobRow(job: job)],
              );
            },
            loading: () => _hint(context, 'Loading…'),
            error: (_, _) => _hint(context, 'Unavailable.'),
          ),
      ],
    );
  }

  Widget _hint(BuildContext context, String text) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.md,
        Spacing.xs,
        Spacing.md,
        Spacing.sm,
      ),
      child: Text(
        text,
        style: AppTypography.bodySmallStyle.copyWith(
          color: theme.textSecondary,
        ),
      ),
    );
  }
}

/// Compact inline job row (monitoring + quick run-now). Full edit lives on the
/// dedicated jobs page.
class _JobRow extends ConsumerStatefulWidget {
  const _JobRow({required this.job});

  final HermesJob job;

  @override
  ConsumerState<_JobRow> createState() => _JobRowState();
}

class _JobRowState extends ConsumerState<_JobRow> {
  bool _running = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final writable =
        ref.watch(hermesCapabilitiesProvider).asData?.value.jobsAdmin ?? true;
    final job = widget.job;

    return InkWell(
      onTap: _running ? null : () => context.pushNamed(RouteNames.hermesJobs),
      borderRadius: BorderRadius.circular(AppBorderRadius.card),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.sm,
        ),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: job.enabled ? theme.success : theme.textSecondary,
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    job.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyMediumStyle.copyWith(
                      color: theme.textPrimary,
                    ),
                  ),
                  Text(
                    job.enabled ? job.schedule : '${job.schedule} · paused',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.captionStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (writable)
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: _running
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        Icons.play_arrow_rounded,
                        size: 20,
                        color: theme.iconSecondary,
                      ),
                tooltip: 'Run now',
                onPressed: _running ? null : _runNow,
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _runNow() async {
    if (_running) return;
    if (ref.read(hermesApiServiceProvider) == null) {
      UiUtils.showMessage(
        context,
        'Could not run scheduled job.',
        isError: true,
      );
      return;
    }
    setState(() => _running = true);
    try {
      await ref.read(hermesJobsProvider.notifier).runNow(widget.job.id);
      if (mounted) UiUtils.showMessage(context, 'Scheduled job started.');
    } catch (_) {
      if (mounted) {
        UiUtils.showMessage(
          context,
          'Could not run scheduled job.',
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }
}

/// Section header with optional disclosure chevron, count badge, and a
/// trailing "manage" affordance.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    this.count,
    this.expanded,
    this.onToggle,
    this.onManage,
  });

  final String title;
  final int? count;
  final bool? expanded;
  final VoidCallback? onToggle;
  final VoidCallback? onManage;

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
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onToggle,
              child: Row(
                children: [
                  if (expanded != null) ...[
                    Icon(
                      expanded!
                          ? Icons.expand_more
                          : Icons.chevron_right_rounded,
                      color: theme.iconSecondary,
                      size: IconSize.listItem,
                    ),
                    const SizedBox(width: Spacing.xxs),
                  ],
                  Text(title, style: titleStyle),
                  if (count != null) ...[
                    const SizedBox(width: Spacing.sm),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: theme.buttonPrimary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(
                          AppBorderRadius.pill,
                        ),
                      ),
                      child: Text(
                        '$count',
                        style: AppTypography.labelMediumStyle.copyWith(
                          color: theme.buttonPrimary.withValues(alpha: 0.9),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (onManage != null)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onManage,
              child: Padding(
                padding: const EdgeInsets.all(Spacing.xs),
                child: Text(
                  'Manage',
                  style: AppTypography.captionStyle.copyWith(
                    color: theme.buttonPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
