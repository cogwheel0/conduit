import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/navigation_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';
import '../../../shared/widgets/utility_components.dart';

/// First-run screen letting a fresh install choose its backend: a self-hosted
/// Open WebUI, direct model APIs, or a Hermes Agent.
class BackendChooserPage extends ConsumerWidget {
  const BackendChooserPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final safePadding = MediaQuery.viewPaddingOf(context);

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
                bottom: safePadding.bottom + Spacing.xl,
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
                  InsetGroupedSection(
                    title: '',
                    padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
                    child: Column(
                      children: [
                        UtilitySelectionRow(
                          leading: const _ProviderLogo(
                            assetName: 'assets/icons/open_webui.png',
                            kind: _ProviderLogoKind.openWebUI,
                          ),
                          title: l10n.backendChooserOpenWebUITitle,
                          subtitle: l10n.backendChooserOpenWebUISubtitle,
                          selected: false,
                          showDivider: true,
                          showSelectionIndicator: false,
                          trailing: _chooserChevron(context),
                          onTap: () => context.go(Routes.serverConnection),
                        ),
                        UtilitySelectionRow(
                          leading: const _DirectConnectionIcon(),
                          title: l10n.backendChooserDirectTitle,
                          subtitle: l10n.backendChooserDirectSubtitle,
                          selected: false,
                          showDivider: true,
                          showSelectionIndicator: false,
                          trailing: _chooserChevron(context),
                          onTap: () => context.goNamed(
                            RouteNames.directConnections,
                            queryParameters: const {'onboarding': 'true'},
                          ),
                        ),
                        UtilitySelectionRow(
                          leading: const _ProviderLogo(
                            assetName: 'assets/icons/hermes_agent.png',
                            kind: _ProviderLogoKind.hermes,
                          ),
                          title: l10n.backendChooserHermesTitle,
                          subtitle: l10n.backendChooserHermesSubtitle,
                          selected: false,
                          showSelectionIndicator: false,
                          trailing: _chooserChevron(context),
                          onTap: () =>
                              context.go(Routes.hermesSettings, extra: true),
                        ),
                      ],
                    ),
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

Widget _chooserChevron(BuildContext context) => Icon(
  context.usesCupertinoChrome
      ? CupertinoIcons.chevron_forward
      : Icons.chevron_right,
  color: context.conduitTheme.iconSecondary,
  size: IconSize.small,
);

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

    return Container(
      width: TouchTarget.minimum,
      height: TouchTarget.minimum,
      decoration: BoxDecoration(
        color: theme.buttonPrimary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
      ),
      child: Icon(
        context.usesCupertinoChrome ? CupertinoIcons.link : Icons.api_rounded,
        color: theme.buttonPrimary,
        size: IconSize.medium,
      ),
    );
  }
}
