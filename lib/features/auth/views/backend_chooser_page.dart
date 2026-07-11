import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/navigation_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';

/// First-run screen letting a fresh install choose its backend: a self-hosted
/// Open WebUI, direct model APIs, or a Hermes Agent.
class BackendChooserPage extends ConsumerWidget {
  const BackendChooserPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
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
                    l10n.backendChooserWelcome,
                    textAlign: TextAlign.center,
                    style: AppTypography.headlineLargeStyle.copyWith(
                      color: theme.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: Spacing.sm),
                  Text(
                    l10n.backendChooserPrompt,
                    textAlign: TextAlign.center,
                    style: AppTypography.bodyMediumStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: Spacing.xxl),
                  _ChooserCard(
                    leading: const _ProviderLogo(
                      assetName: 'assets/icons/open_webui.png',
                      kind: _ProviderLogoKind.openWebUI,
                    ),
                    title: l10n.backendChooserOpenWebUITitle,
                    subtitle: l10n.backendChooserOpenWebUISubtitle,
                    onTap: () => context.go(Routes.serverConnection),
                  ),
                  const SizedBox(height: Spacing.md),
                  _ChooserCard(
                    leading: const _DirectConnectionIcon(),
                    title: l10n.backendChooserDirectTitle,
                    subtitle: l10n.backendChooserDirectSubtitle,
                    onTap: () => context.go(
                      '${Routes.directConnections}?onboarding=true',
                    ),
                  ),
                  const SizedBox(height: Spacing.md),
                  _ChooserCard(
                    leading: const _ProviderLogo(
                      assetName: 'assets/icons/hermes_agent.png',
                      kind: _ProviderLogoKind.hermes,
                    ),
                    title: l10n.backendChooserHermesTitle,
                    subtitle: l10n.backendChooserHermesSubtitle,
                    onTap: () => context.go(Routes.hermesSettings, extra: true),
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
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final platform = Theme.of(context).platform;
    final usesCupertinoChrome =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;

    return Semantics(
      label: '$title. $subtitle',
      button: true,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
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
                leading,
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
                Icon(
                  usesCupertinoChrome
                      ? CupertinoIcons.chevron_forward
                      : Icons.chevron_right,
                  color: theme.iconSecondary,
                  size: IconSize.small,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _ProviderLogoKind { openWebUI, hermes }

class _ProviderLogo extends StatelessWidget {
  const _ProviderLogo({required this.assetName, required this.kind});

  final String assetName;
  final _ProviderLogoKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    if (kind == _ProviderLogoKind.openWebUI) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
        child: Image.asset(
          assetName,
          width: TouchTarget.minimum,
          height: TouchTarget.minimum,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          excludeFromSemantics: true,
        ),
      );
    }

    return Container(
      width: TouchTarget.minimum,
      height: TouchTarget.minimum,
      padding: const EdgeInsets.all(Spacing.xs),
      decoration: BoxDecoration(
        color: theme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
      ),
      child: Image.asset(
        assetName,
        fit: BoxFit.contain,
        color: theme.textPrimary,
        colorBlendMode: BlendMode.srcIn,
        filterQuality: FilterQuality.medium,
        excludeFromSemantics: true,
      ),
    );
  }
}

class _DirectConnectionIcon extends StatelessWidget {
  const _DirectConnectionIcon();

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final platform = Theme.of(context).platform;
    final usesCupertinoChrome =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;

    return Container(
      width: TouchTarget.minimum,
      height: TouchTarget.minimum,
      decoration: BoxDecoration(
        color: theme.buttonPrimary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
      ),
      child: Icon(
        usesCupertinoChrome ? CupertinoIcons.link : Icons.api_rounded,
        color: theme.buttonPrimary,
        size: IconSize.medium,
      ),
    );
  }
}
