import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/persistence/persistence_keys.dart';
import '../../../core/persistence/preferences_store.dart';
import '../../../core/platform/conduit_platform_apis.g.dart';
import '../../../core/providers/backend_mode_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../direct_connections/providers/direct_connection_providers.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/utility_components.dart';

/// First-run screen letting a fresh install choose its chat backend.
class BackendChooserPage extends ConsumerWidget {
  const BackendChooserPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final appleOnDeviceStatus = PlatformInfo.isIOS
        ? ref.watch(appleOnDeviceStatusProvider)
        : null;
    final applePccStatus = PlatformInfo.isIOS
        ? ref.watch(applePccStatusProvider)
        : null;
    final appleRows = <Widget>[
      if (_isAppleModelAvailable(appleOnDeviceStatus))
        UtilitySelectionRow(
          leading: const _AppleModelIcon(),
          title: l10n.backendChooserAppleOnDeviceTitle,
          subtitle: l10n.backendChooserAppleOnDeviceSubtitle,
          selected: false,
          showSelectionIndicator: false,
          trailing: _chooserChevron(context),
          onTap: () => _selectAppleModel(
            context,
            ref,
            l10n,
            PlatformAppleModel.onDevice,
          ),
        ),
      if (_isAppleModelAvailable(applePccStatus))
        UtilitySelectionRow(
          leading: const _AppleModelIcon(cloud: true),
          title: l10n.backendChooserApplePccTitle,
          subtitle: l10n.backendChooserApplePccSubtitle,
          selected: false,
          showSelectionIndicator: false,
          trailing: _chooserChevron(context),
          onTap: () => _selectAppleModel(
            context,
            ref,
            l10n,
            PlatformAppleModel.privateCloudCompute,
          ),
        ),
    ];

    return UtilityPageScaffold.auth(
      title: l10n.backendChooserWelcome,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
            child: Text(
              l10n.backendChooserPrompt,
              style: AppTypography.bodyMediumStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
          ),
          const SizedBox(height: Spacing.lg),
          InsetGroupedList(
            title: l10n.backendChooserSelfHostedSectionTitle,
            dividerIndent: _providerDividerIndent,
            children: [
              UtilitySelectionRow(
                leading: const _ProviderLogo(
                  assetName: 'assets/icons/open_webui.png',
                  kind: _ProviderLogoKind.openWebUI,
                ),
                title: l10n.backendChooserOpenWebUITitle,
                subtitle: l10n.backendChooserOpenWebUISubtitle,
                selected: false,
                showSelectionIndicator: false,
                trailing: _chooserChevron(context),
                onTap: () => context.go(Routes.serverConnection),
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
                onTap: () => context.go(Routes.hermesSettings, extra: true),
              ),
            ],
          ),
          if (appleRows.isNotEmpty) ...[
            const SizedBox(height: Spacing.lg),
            InsetGroupedList(
              title: l10n.backendChooserAppleSectionTitle,
              dividerIndent: _providerDividerIndent,
              children: appleRows,
            ),
          ],
          const SizedBox(height: Spacing.lg),
          InsetGroupedList(
            title: l10n.backendChooserModelApisSectionTitle,
            children: [
              UtilitySelectionRow(
                leading: const _DirectConnectionIcon(),
                title: l10n.backendChooserDirectTitle,
                subtitle: l10n.backendChooserDirectSubtitle,
                selected: false,
                showSelectionIndicator: false,
                trailing: _chooserChevron(context),
                onTap: () => context.goNamed(
                  RouteNames.directConnections,
                  queryParameters: const {'onboarding': 'true'},
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

bool _isAppleModelAvailable(AsyncValue<PlatformPccStatus>? status) =>
    kDebugMode ||
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

    if (PreferencesStore.getString(PreferenceKeys.directHistoryPolicy) ==
        null) {
      await ref
          .read(directHistoryPolicyProvider.notifier)
          .setPolicy(DirectHistoryPolicy.localOnly);
    }
    if (onDevice) {
      await ref.read(appleOnDeviceEnabledProvider.notifier).setEnabled(true);
    } else {
      await ref.read(applePccEnabledProvider.notifier).setEnabled(true);
    }
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

Widget _chooserChevron(BuildContext context) => Icon(
  context.usesCupertinoChrome
      ? CupertinoIcons.chevron_forward
      : Icons.chevron_right,
  color: context.conduitTheme.iconSecondary,
  size: IconSize.small,
);

enum _ProviderLogoKind { openWebUI, hermes }

/// Matches the 40x40 icon-badge footprint used by `SettingsIconBadge` and the
/// Cupertino leading slot in `UtilitySelectionRow`; a larger box gets squeezed
/// into 40 there, which crops the edges off a full-bleed logo.
const double _providerLogoSize = 40;
const double _providerDividerIndent =
    Spacing.md + _providerLogoSize + Spacing.sm + Spacing.xs;

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
          width: _providerLogoSize,
          height: _providerLogoSize,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          excludeFromSemantics: true,
        ),
      );
    }

    return Container(
      width: _providerLogoSize,
      height: _providerLogoSize,
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
      width: _providerLogoSize,
      height: _providerLogoSize,
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

class _AppleModelIcon extends StatelessWidget {
  const _AppleModelIcon({this.cloud = false});

  final bool cloud;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Container(
      width: _providerLogoSize,
      height: _providerLogoSize,
      decoration: BoxDecoration(
        color: theme.buttonPrimary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
      ),
      child: Icon(
        cloud
            ? (context.usesCupertinoChrome
                  ? CupertinoIcons.cloud_fill
                  : Icons.cloud_rounded)
            : (context.usesCupertinoChrome
                  ? CupertinoIcons.device_phone_portrait
                  : Icons.smartphone_rounded),
        color: theme.buttonPrimary,
        size: IconSize.medium,
      ),
    );
  }
}
