import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/navigation_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';

/// First-run screen letting a fresh install choose its backend: a self-hosted
/// Open WebUI server, or a Hermes Agent (used exclusively, no Open WebUI).
class BackendChooserPage extends ConsumerWidget {
  const BackendChooserPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.conduitTheme;
    final safePadding = MediaQuery.of(context).padding;

    return AdaptiveRouteShell(
      backgroundColor: theme.surfaceBackground,
      body: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: EdgeInsets.only(
                left: Spacing.pagePadding,
                right: Spacing.pagePadding,
                top: safePadding.top + Spacing.xxl,
                bottom: Spacing.xxl,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Welcome to Conduit',
                    textAlign: TextAlign.center,
                    style: AppTypography.headlineLargeStyle.copyWith(
                      color: theme.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: Spacing.sm),
                  Text(
                    'Choose how you want to connect.',
                    textAlign: TextAlign.center,
                    style: AppTypography.bodyMediumStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: Spacing.xxl),
                  _ChooserCard(
                    icon: Icons.dns_outlined,
                    title: 'Connect to Open WebUI',
                    subtitle:
                        'Use your self-hosted Open WebUI server with full chat, '
                        'notes, and more.',
                    onTap: () => context.go(Routes.serverConnection),
                  ),
                  const SizedBox(height: Spacing.md),
                  _ChooserCard(
                    icon: Icons.smart_toy_outlined,
                    title: 'Use a Hermes Agent',
                    subtitle:
                        'Connect directly to a self-hosted Hermes agent — no '
                        'Open WebUI server needed.',
                    onTap: () =>
                        context.go(Routes.hermesSettings, extra: true),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChooserCard extends StatelessWidget {
  const _ChooserCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppBorderRadius.card),
        child: Container(
          padding: const EdgeInsets.all(Spacing.lg),
          decoration: BoxDecoration(
            color: theme.cardBackground,
            borderRadius: BorderRadius.circular(AppBorderRadius.card),
            border: Border.all(color: theme.cardBorder),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: theme.buttonPrimary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppBorderRadius.md),
                ),
                child: Icon(icon, color: theme.buttonPrimary),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppTypography.standard.copyWith(
                        color: theme.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: Spacing.xxs),
                    Text(
                      subtitle,
                      style: AppTypography.bodySmallStyle.copyWith(
                        color: theme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: theme.iconSecondary),
            ],
          ),
        ),
      ),
    );
  }
}
