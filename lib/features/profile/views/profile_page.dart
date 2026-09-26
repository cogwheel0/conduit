import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';

import 'package:material_ui/material_ui.dart';

import '../../../shared/theme/theme_extensions.dart';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:conduit/l10n/app_localizations.dart';

import '../../../shared/widgets/conduit_loading.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';

import '../../../shared/utils/ui_utils.dart';
import '../../../shared/utils/external_link_launcher.dart';
import '../../../shared/widgets/sign_out_options_dialog.dart';

import 'package:conduit_core/providers/app_providers.dart';

import 'package:conduit_core/providers/backend_mode_providers.dart';

import '../../../shared/services/navigation_service.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';

import '../../workspace/providers/workspace_capabilities_provider.dart';

import 'package:conduit_core/services/api_service.dart';

import 'package:conduit_core/models/user.dart' as models;
import 'package:conduit_core/utils/user_display_name.dart';

import 'package:conduit_core/utils/user_avatar_utils.dart';

import '../../../shared/widgets/user_avatar.dart';
import '../../../shared/widgets/utility_components.dart';

/// Profile page (You tab) showing user info and main actions
/// Enhanced with production-grade design tokens for better cohesion
class ProfilePage extends ConsumerWidget {
  static const _githubSponsorsUrl = 'https://github.com/sponsors/cogwheel0';
  static const _buyMeACoffeeUrl = 'https://www.buymeacoffee.com/cogwheel0';

  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authUser = ref.watch(currentUserProvider2);
    final asyncUser = ref.watch(currentUserProvider);
    final user = asyncUser.maybeWhen(
      data: (value) => value ?? authUser,
      orElse: () => authUser,
    );
    final isAuthLoading = ref.watch(isAuthLoadingProvider2);
    final api = ref.watch(apiServiceProvider);

    Widget body;
    if (isAuthLoading && user == null) {
      body = _buildCenteredState(
        context,
        ImprovedLoadingState(
          message: AppLocalizations.of(context)!.loadingProfile,
        ),
      );
    } else {
      body = _buildProfileBody(context, ref, user, api);
    }

    return _buildScaffold(context, body: body);
  }

  Widget _buildScaffold(BuildContext context, {required Widget body}) {
    final l10n = AppLocalizations.of(context)!;

    return AdaptiveRouteShell(
      backgroundColor: context.conduitTheme.surfaceBackground,
      appBar: AdaptiveAppBar(title: l10n.you),
      body: body,
    );
  }

  Widget _buildCenteredState(BuildContext context, Widget child) {
    final topPadding = _topContentPadding(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Spacing.pagePadding,
        topPadding,
        Spacing.pagePadding,
        Spacing.pagePadding + MediaQuery.of(context).padding.bottom,
      ),
      child: Center(child: child),
    );
  }

  Widget _buildProfileBody(
    BuildContext context,
    WidgetRef ref,
    dynamic userData,
    ApiService? api,
  ) {
    final mediaQuery = MediaQuery.of(context);
    final topPadding = _topContentPadding(context);
    final directPrimary =
        ref.watch(preferredBackendProvider) == PreferredBackend.direct;
    final hasOpenWebUiAccount = userData != null && api != null;
    final items = _buildSettingsItems(
      context,
      ref,
      directPrimary: directPrimary,
      hasOpenWebUiAccount: hasOpenWebUiAccount,
    );
    return ListView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: EdgeInsets.fromLTRB(
        Spacing.pagePadding,
        topPadding,
        Spacing.pagePadding,
        Spacing.pagePadding + mediaQuery.padding.bottom,
      ),
      children: [
        if (hasOpenWebUiAccount) ...[
          _buildProfileHeader(context, userData, api),
          const SizedBox(height: Spacing.lg),
        ],
        ...items,
        const SizedBox(height: Spacing.xl),
        _buildDonationSection(context),
        if (hasOpenWebUiAccount) const SizedBox(height: Spacing.xl),
        if (hasOpenWebUiAccount)
          InsetGroupedList(children: [_buildSignOutOption(context, ref)]),
      ],
    );
  }

  double _topContentPadding(BuildContext context) {
    return Spacing.lg;
  }

  Widget _buildDonationSection(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final donationOptions = [
      _buildSupportOption(
        context,
        icon: UiUtils.platformIcon(
          ios: CupertinoIcons.gift,
          android: Icons.coffee,
        ),
        title: l10n.buyMeACoffeeTitle,
        subtitle: l10n.buyMeACoffeeSubtitle,
        url: _buyMeACoffeeUrl,
        color: theme.warning,
      ),
      _buildSupportOption(
        context,
        icon: UiUtils.platformIcon(
          ios: CupertinoIcons.heart,
          android: Icons.favorite_border,
        ),
        title: l10n.githubSponsorsTitle,
        subtitle: l10n.githubSponsorsSubtitle,
        url: _githubSponsorsUrl,
        color: theme.success,
      ),
    ];

    return InsetGroupedList(
      key: const Key('settings-donations'),
      title: l10n.supportConduit,
      description: l10n.supportConduitSubtitle,
      children: donationOptions,
    );
  }

  Widget _buildSupportOption(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required String url,
    required Color color,
  }) {
    final theme = context.conduitTheme;
    return UtilityRow(
      onTap: () => _openExternalLink(context, url),
      leading: _buildIconBadge(context, icon, color: color),
      title: title,
      subtitle: subtitle,
      trailing: Icon(
        UiUtils.platformIcon(
          ios: CupertinoIcons.arrow_up_right,
          android: Icons.open_in_new,
        ),
        color: theme.iconSecondary,
        size: IconSize.small,
      ),
    );
  }

  Future<void> _openExternalLink(BuildContext context, String url) async {
    final launched = await launchExternalLink(url, scope: 'profile/support');
    if (!launched && context.mounted) {
      UiUtils.showMessage(context, AppLocalizations.of(context)!.errorMessage);
    }
  }

  Widget _buildProfileHeader(
    BuildContext context,
    dynamic user,
    ApiService? api,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final displayName = deriveUserDisplayName(
      user,
      fallback: l10n.userFallbackName,
    );
    final characters = displayName.characters;
    final initial = characters.isNotEmpty
        ? characters.first.toUpperCase()
        : 'U';
    final avatarUrl = resolveUserAvatarUrlForUser(api, user);

    String? extractEmail(dynamic source) {
      if (source is models.User) {
        return source.email;
      }
      if (source is Map) {
        final value = source['email'];
        if (value is String && value.trim().isNotEmpty) {
          return value.trim();
        }
        final nested = source['user'];
        if (nested is Map) {
          final nestedValue = nested['email'];
          if (nestedValue is String && nestedValue.trim().isNotEmpty) {
            return nestedValue.trim();
          }
        }
      }
      return null;
    }

    final email = extractEmail(user) ?? l10n.noEmailLabel;
    final theme = context.conduitTheme;
    // Identity header: centered avatar, name, and account line,
    // with an explicit pill that opens the account editor.
    return Column(
      children: [
        UserAvatar(size: 80, imageUrl: avatarUrl, fallbackText: initial),
        const SizedBox(height: Spacing.sm + Spacing.xxs),
        Text(
          displayName,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTypography.headlineSmallStyle.copyWith(
            color: theme.textPrimary,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: Spacing.xxs),
        Text(
          email,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTypography.bodyMediumStyle.copyWith(
            color: theme.textSecondary,
          ),
        ),
        const SizedBox(height: Spacing.md),
        AdaptiveButton(
          key: const Key('settings-edit-profile'),
          onPressed: () => context.pushNamed(RouteNames.accountSettings),
          label: l10n.edit,
          style: AdaptiveButtonStyle.bordered,
          size: AdaptiveButtonSize.small,
        ),
      ],
    );
  }

  List<Widget> _buildSettingsItems(
    BuildContext context,
    WidgetRef ref, {
    required bool directPrimary,
    required bool hasOpenWebUiAccount,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final canManageWorkspace = canManageAnyWorkspaceSection(ref);

    // Single-line settings rows, so each title and its
    // icon carry the meaning without a descriptive subtitle.
    final appItems = <Widget>[
      _buildAccountOption(
        context,
        icon: UiUtils.platformIcon(
          ios: CupertinoIcons.paintbrush,
          android: Icons.palette_outlined,
        ),
        title: l10n.settingsAppearance,
        onTap: () => context.pushNamed(RouteNames.appearanceSettings),
      ),
      _buildAccountOption(
        context,
        icon: UiUtils.platformIcon(
          ios: CupertinoIcons.bubble_left_bubble_right,
          android: Icons.chat_bubble_outline,
        ),
        title: l10n.chatSettings,
        onTap: () => context.pushNamed(RouteNames.chatSettings),
      ),
      _buildAccountOption(
        context,
        icon: UiUtils.platformIcon(
          ios: CupertinoIcons.waveform,
          android: Icons.graphic_eq,
        ),
        title: l10n.audioSettingsTitle,
        onTap: () => context.pushNamed(RouteNames.audioSettings),
      ),
      if (hasOpenWebUiAccount)
        _buildAccountOption(
          context,
          icon: UiUtils.platformIcon(
            ios: CupertinoIcons.bell,
            android: Icons.notifications_outlined,
          ),
          title: l10n.notificationsTitle,
          onTap: () => context.pushNamed(RouteNames.notificationSettings),
        ),
      if (hasOpenWebUiAccount || directPrimary)
        _buildAccountOption(
          context,
          icon: UiUtils.platformIcon(
            ios: CupertinoIcons.person_crop_circle_badge_checkmark,
            android: Icons.auto_awesome,
          ),
          title: l10n.personalization,
          onTap: () => context.pushNamed(RouteNames.personalization),
        ),
    ];
    final connectionItems = <Widget>[
      _buildAccountOption(
        context,
        iconAsset: 'assets/icons/hermes_agent.png',
        title: l10n.hermesAgentSettingsTitle,
        onTap: () => context.pushNamed(RouteNames.hermesSettings),
      ),
      if (canManageWorkspace)
        _buildAccountOption(
          context,
          key: const Key('workspace-entry'),
          icon: UiUtils.platformIcon(
            ios: CupertinoIcons.square_grid_2x2,
            android: Icons.dashboard_customize_outlined,
          ),
          title: l10n.workspaceTitle,
          onTap: () => context.pushNamed(RouteNames.workspace),
        ),
      if (hasOpenWebUiAccount)
        _buildAccountOption(
          context,
          key: const Key('data-connection-entry'),
          icon: UiUtils.platformIcon(
            ios: CupertinoIcons.antenna_radiowaves_left_right,
            android: Icons.hub_outlined,
          ),
          title: l10n.settingsDataAndConnection,
          onTap: () => context.pushNamed(RouteNames.dataConnectionSettings),
        ),
      _buildAccountOption(
        context,
        icon: UiUtils.platformIcon(
          ios: CupertinoIcons.link,
          android: Icons.hub_outlined,
        ),
        title: l10n.directConnectionsTitle,
        onTap: () => context.pushNamed(RouteNames.directConnections),
      ),
      if (!hasOpenWebUiAccount)
        _buildAccountOption(
          context,
          icon: UiUtils.platformIcon(
            ios: CupertinoIcons.add_circled,
            android: Icons.add_circle_outline,
          ),
          title: l10n.connectOpenWebUITitle,
          onTap: () => context.goNamed(RouteNames.serverConnection),
        ),
    ];
    return [
      InsetGroupedList(children: appItems),
      const SizedBox(height: Spacing.lg),
      InsetGroupedList(children: connectionItems),
      const SizedBox(height: Spacing.lg),
      InsetGroupedList(children: [_buildAboutTile(context)]),
    ];
  }

  Widget _buildSignOutOption(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return _buildAccountOption(
      context,
      key: const Key('settings-sign-out'),
      icon: UiUtils.platformIcon(
        ios: CupertinoIcons.square_arrow_left,
        android: Icons.logout,
      ),
      title: l10n.signOut,
      onTap: () => _signOut(context, ref),
      showChevron: false,
      destructive: true,
    );
  }

  Widget _buildAccountOption(
    BuildContext context, {
    Key? key,
    IconData? icon,
    String? iconAsset,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
    bool showChevron = true,
    bool destructive = false,
  }) {
    assert(
      (icon == null) != (iconAsset == null),
      'Provide exactly one of icon or iconAsset.',
    );
    final theme = context.conduitTheme;
    final color = theme.buttonPrimary;
    return UtilityRow(
      key: key,
      onTap: onTap,
      leading: iconAsset != null
          ? _buildAssetIconBadge(context, iconAsset, color: color)
          : _buildIconBadge(context, icon!, color: color),
      title: title,
      subtitle: subtitle,
      showChevron: showChevron,
      destructive: destructive,
    );
  }

  // Plain monochrome glyphs instead of tinted
  // badges; the fixed box keeps every row's title on the same leading edge.
  Widget _buildIconBadge(
    BuildContext context,
    IconData icon, {
    required Color color,
  }) {
    return SizedBox(
      width: IconSize.xl,
      height: IconSize.xl,
      child: Icon(icon, color: color, size: IconSize.medium),
    );
  }

  Widget _buildAssetIconBadge(
    BuildContext context,
    String asset, {
    required Color color,
  }) {
    return SizedBox(
      width: IconSize.xl,
      height: IconSize.xl,
      child: Center(
        child: Image.asset(
          asset,
          key: const Key('hermes-settings-logo'),
          width: IconSize.medium + 2,
          height: IconSize.medium + 2,
          color: color,
          colorBlendMode: BlendMode.srcIn,
          filterQuality: FilterQuality.high,
        ),
      ),
    );
  }

  // Theme and language controls moved to AppCustomizationPage.

  Widget _buildAboutTile(BuildContext context) {
    return _buildAccountOption(
      context,
      icon: UiUtils.platformIcon(
        ios: CupertinoIcons.info,
        android: Icons.info_outline,
      ),
      title: AppLocalizations.of(context)!.aboutApp,
      onTap: () => context.pushNamed(RouteNames.about),
    );
  }

  void _signOut(BuildContext context, WidgetRef ref) async {
    final keepServerDetails = await showSignOutOptionsDialog(context);

    if (!context.mounted || keepServerDetails == null) return;
    try {
      await ref
          .read(signOutCoordinatorProvider)
          .signOut(keepServerDetails: keepServerDetails);
    } catch (_) {
      if (!context.mounted) return;
      UiUtils.showMessage(context, AppLocalizations.of(context)!.errorMessage);
    }
  }
}
