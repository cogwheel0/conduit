import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';

import 'package:conduit_core/features/direct_connections/services/apple_pcc_host.dart';

import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';

import '../../../shared/services/navigation_service.dart';

import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../direct_connections/providers/apple_pcc_providers.dart';
import '../widgets/auth_grouped_form.dart';

/// First-run screen letting a fresh install choose its chat backend.
///
/// It opens on the app's identity -- its icon, name and what it is for --
/// then lists the backends in inset-grouped sections.
class BackendChooserPage extends ConsumerWidget {
  const BackendChooserPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final cupertino = context.usesCupertinoChrome;
    final appleOnDeviceStatus = PlatformInfo.isIOS
        ? ref.watch(appleOnDeviceStatusProvider)
        : null;
    final applePccStatus = PlatformInfo.isIOS
        ? ref.watch(applePccStatusProvider)
        : null;

    final sections = <_BackendSection>[
      _BackendSection(
        title: l10n.backendChooserSelfHostedSectionTitle,
        options: [
          _BackendOption(
            tile: const AuthIconTile(
              assetName: 'assets/icons/open_webui_tab.png',
              assetSize: 22,
            ),
            title: l10n.backendChooserOpenWebUITitle,
            subtitle: l10n.backendChooserOpenWebUISubtitle,
            onTap: () => context.go(Routes.serverConnection),
          ),
          if (ref.watch(libreChatBackendEnabledProvider))
            _BackendOption(
              key: const Key('backend-chooser-librechat'),
              tile: AuthIconTile(
                icon: cupertino
                    ? CupertinoIcons.chat_bubble_2
                    : Icons.forum_outlined,
              ),
              title: l10n.libreChatTitle,
              subtitle: l10n.libreChatChooserSubtitle,
              badge: l10n.libreChatBetaLabel,
              onTap: () => context.go(Routes.libreChatSignIn),
            ),
          _BackendOption(
            tile: const AuthIconTile(
              assetName: 'assets/icons/hermes_agent.png',
              assetSize: 26,
            ),
            title: l10n.backendChooserHermesTitle,
            subtitle: l10n.backendChooserHermesSubtitle,
            onTap: () => context.go(Routes.hermesSettings, extra: true),
          ),
        ],
      ),
      _BackendSection(
        title: l10n.backendChooserAppleSectionTitle,
        options: [
          if (_isAppleModelAvailable(appleOnDeviceStatus))
            _BackendOption(
              tile: AuthIconTile(
                icon: cupertino
                    ? CupertinoIcons.device_phone_portrait
                    : Icons.smartphone_rounded,
              ),
              title: l10n.backendChooserAppleOnDeviceTitle,
              subtitle: l10n.backendChooserAppleOnDeviceSubtitle,
              onTap: () => _selectAppleModel(
                context,
                ref,
                l10n,
                PlatformAppleModel.onDevice,
              ),
            ),
          if (_isAppleModelAvailable(applePccStatus))
            _BackendOption(
              tile: AuthIconTile(
                icon: cupertino ? CupertinoIcons.cloud : Icons.cloud_outlined,
              ),
              title: l10n.backendChooserApplePccTitle,
              subtitle: l10n.backendChooserApplePccSubtitle,
              onTap: () => _selectAppleModel(
                context,
                ref,
                l10n,
                PlatformAppleModel.privateCloudCompute,
              ),
            ),
        ],
      ),
      _BackendSection(
        title: l10n.backendChooserModelApisSectionTitle,
        footer: l10n.backendChooserFooter,
        options: [
          _BackendOption(
            tile: AuthIconTile(
              icon: cupertino ? CupertinoIcons.link : Icons.api_rounded,
            ),
            title: l10n.backendChooserDirectTitle,
            subtitle: l10n.backendChooserDirectSubtitle,
            onTap: () => context.goNamed(
              RouteNames.directConnections,
              queryParameters: const {'onboarding': 'true'},
            ),
          ),
        ],
      ),
    ].where((section) => section.options.isNotEmpty).toList(growable: false);

    return UtilityPageScaffold.auth(
      title: l10n.onboardingWelcomeTitle,
      largeTitleHeader: const _WelcomeHero(),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < sections.length; index++) ...[
            if (index > 0) const SizedBox(height: Spacing.lg + Spacing.xs),
            if (cupertino)
              _buildCupertinoSection(sections[index])
            else
              _buildMaterialSection(context, sections[index]),
          ],
        ],
      ),
    );
  }

  Widget _buildCupertinoSection(_BackendSection section) {
    return AuthGroupedSection(
      header: section.title,
      footer: section.footer,
      separatorInset: _providerDividerIndent,
      children: [
        for (final option in section.options)
          AuthGroupedRow(
            key: option.key,
            leading: option.tile,
            title: option.title,
            subtitle: option.subtitle,
            // The badge is read with the title, not as a node of its own.
            trailing: option.badge == null
                ? null
                : ExcludeSemantics(child: _BetaBadge(label: option.badge!)),
            semanticLabel: option.badge == null
                ? null
                : '${option.title}, ${option.badge}. ${option.subtitle}',
            showChevron: true,
            onTap: option.onTap,
          ),
      ],
    );
  }

  Widget _buildMaterialSection(BuildContext context, _BackendSection section) {
    return InsetGroupedList(
      title: section.title,
      footer: section.footer,
      dividerIndent: _providerDividerIndent,
      children: [
        for (final option in section.options)
          UtilitySelectionRow(
            key: option.key,
            leading: option.tile,
            title: option.title,
            subtitle: option.subtitle,
            selected: false,
            showSelectionIndicator: false,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (option.badge case final badge?) ...[
                  _BetaBadge(label: badge),
                  const SizedBox(width: Spacing.xs),
                ],
                Icon(
                  Icons.chevron_right,
                  color: context.conduitTheme.textTertiary,
                  size: IconSize.small,
                ),
              ],
            ),
            onTap: option.onTap,
          ),
      ],
    );
  }
}

class _BackendSection {
  const _BackendSection({
    required this.title,
    required this.options,
    this.footer,
  });

  final String title;
  final String? footer;
  final List<_BackendOption> options;
}

class _BackendOption {
  const _BackendOption({
    this.key,
    required this.tile,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.badge,
  });

  final Key? key;
  final Widget tile;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// A short tag after the title's row, such as "Beta".
  final String? badge;
}

/// Marks an option that is still in beta: a small capsule in the row's
/// secondary ink on a faint fill, like the tile beside it, so it reads as a
/// label and not a button.
class _BetaBadge extends StatelessWidget {
  const _BetaBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 2),
      decoration: ShapeDecoration(
        color: theme.textPrimary.withValues(alpha: theme.isDark ? 0.12 : 0.06),
        shape: const StadiumBorder(),
      ),
      child: Text(
        label,
        style: AppTypography.labelSmallStyle.copyWith(
          color: theme.textSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// The app's icon, name and purpose, centred above the choices.
class _WelcomeHero extends StatelessWidget {
  const _WelcomeHero();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.md, bottom: Spacing.xl),
      child: Column(
        children: [
          // The full-bleed icon clipped to the home screen's continuous
          // corners, so the mark matches the icon people tapped to get here.
          ClipRSuperellipse(
            borderRadius: BorderRadius.circular(
              _heroIconSize * _homeScreenIconCornerRatio,
            ),
            child: Image.asset(
              'assets/icons/app_icon_square.png',
              key: const ValueKey<String>('welcome-app-icon'),
              width: _heroIconSize,
              height: _heroIconSize,
              filterQuality: FilterQuality.medium,
              excludeFromSemantics: true,
            ),
          ),
          const SizedBox(height: Spacing.md),
          Semantics(
            header: true,
            child: Text(
              l10n.onboardingWelcomeTitle,
              textAlign: TextAlign.center,
              style: AppTypography.displayLargeStyle.copyWith(
                color: theme.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            l10n.onboardingWelcomeSubtitle,
            textAlign: TextAlign.center,
            style: AppTypography.bodyLargeStyle.copyWith(
              color: theme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

const double _heroIconSize = 64;

/// Corner radius of a home screen icon as a share of its side.
const double _homeScreenIconCornerRatio = 0.2237;

@visibleForTesting
bool debugShowAllAppleBackends = kDebugMode;

bool _isAppleModelAvailable(AsyncValue<PlatformPccStatus>? status) =>
    debugShowAllAppleBackends ||
    (status?.hasValue == true &&
        status!.requireValue.availability ==
            PlatformPccAvailability.available &&
        !status.requireValue.quotaLimitReached);

Future<void> _selectAppleModel(
  BuildContext context,
  WidgetRef ref,
  AppLocalizations l10n,
  PlatformAppleModel model,
) async {
  final onDevice = model == PlatformAppleModel.onDevice;
  final unavailable = onDevice
      ? l10n.appleOnDeviceUnavailable
      : l10n.applePccUnavailable;
  try {
    final status = await ref.refresh(
      onDevice
          ? appleOnDeviceStatusProvider.future
          : applePccStatusProvider.future,
    );
    if (!context.mounted) return;
    if (status.availability != PlatformPccAvailability.available ||
        status.quotaLimitReached) {
      AdaptiveSnackBar.show(
        context,
        message: status.message ?? unavailable,
        type: AdaptiveSnackBarType.warning,
      );
      return;
    }

    if (onDevice) {
      await ref.read(appleOnDeviceEnabledProvider.notifier).setEnabled(true);
    } else {
      await ref.read(applePccEnabledProvider.notifier).setEnabled(true);
    }
    if (!context.mounted) return;
    if (PreferencesStore.getString(PreferenceKeys.directHistoryPolicy) ==
        null) {
      await ref
          .read(directHistoryPolicyProvider.notifier)
          .setPolicy(DirectHistoryPolicy.localOnly);
    }
    if (!context.mounted) return;
    await ref
        .read(preferredBackendProvider.notifier)
        .set(PreferredBackend.direct);
    if (context.mounted) context.go(Routes.chat);
  } catch (_) {
    if (!context.mounted) return;
    AdaptiveSnackBar.show(
      context,
      message: unavailable,
      type: AdaptiveSnackBarType.error,
    );
  }
}

/// Where row separators start: after the 40pt tile and its gap, in line
/// with the row text.
const double _providerDividerIndent =
    authGroupedInset + 40 + Spacing.sm + Spacing.xs;
