import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import '../../../shared/theme/theme_extensions.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:conduit/l10n/app_localizations.dart';
import '../../../core/widgets/error_boundary.dart';
import '../../../shared/widgets/conduit_loading.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';

import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../auth/providers/unified_auth_providers.dart';
import '../../../core/services/api_service.dart';
import '../../../core/models/user.dart' as models;
import '../../../core/utils/user_display_name.dart';
import '../../../core/utils/user_avatar_utils.dart';
import '../../../shared/widgets/user_avatar.dart';
import '../widgets/profile_setting_tile.dart';

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

    return ErrorBoundary(child: _buildScaffold(context, body: body));
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
        _buildProfileHeader(context, userData, api),
        const SizedBox(height: Spacing.xl),
        _buildAccountSection(context, ref),
        const SizedBox(height: Spacing.xl),
        _buildSupportSection(context),
      ],
    );
  }

  double _topContentPadding(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    if (PlatformInfo.isIOS26OrHigher()) {
      return mediaQuery.padding.top + kTextTabBarHeight + Spacing.lg;
    }
    return Spacing.lg;
  }

  Widget _buildSupportSection(BuildContext context) {
    final theme = context.conduitTheme;
    final textTheme = theme.bodySmall?.copyWith(
      color: theme.sidebarForeground.withValues(alpha: 0.75),
    );

    final supportTiles = [
      _buildSupportOption(
        context,
        icon: UiUtils.platformIcon(
          ios: CupertinoIcons.gift,
          android: Icons.coffee,
        ),
        title: AppLocalizations.of(context)!.buyMeACoffeeTitle,
        subtitle: AppLocalizations.of(context)!.buyMeACoffeeSubtitle,
        url: _buyMeACoffeeUrl,
        color: theme.warning,
      ),
      _buildSupportOption(
        context,
        icon: UiUtils.platformIcon(
          ios: CupertinoIcons.heart,
          android: Icons.favorite_border,
        ),
        title: AppLocalizations.of(context)!.githubSponsorsTitle,
        subtitle: AppLocalizations.of(context)!.githubSponsorsSubtitle,
        url: _githubSponsorsUrl,
        color: theme.success,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppLocalizations.of(context)!.supportConduit,
          style: theme.headingSmall?.copyWith(color: theme.sidebarForeground),
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          AppLocalizations.of(context)!.supportConduitSubtitle,
          style: textTheme,
        ),
        const SizedBox(height: Spacing.sm),
        for (var i = 0; i < supportTiles.length; i++) ...[
          supportTiles[i],
          if (i != supportTiles.length - 1) const SizedBox(height: Spacing.md),
        ],
      ],
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
    return ProfileSettingTile(
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
    try {
      final launched = await launchUrlString(
        url,
        mode: LaunchMode.externalApplication,
      );

      if (!launched && context.mounted) {
        UiUtils.showMessage(
          context,
          AppLocalizations.of(context)!.errorMessage,
        );
      }
    } catch (_) {
      if (!context.mounted) return;
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

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => context.pushNamed(RouteNames.accountSettings),
      child: Container(
        padding: const EdgeInsets.all(Spacing.md),
        decoration: BoxDecoration(
          color: theme.sidebarAccent.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(AppBorderRadius.large),
          border: Border.all(
            color: theme.sidebarBorder.withValues(alpha: 0.6),
            width: BorderWidth.thin,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            UserAvatar(size: 56, imageUrl: avatarUrl, fallbackText: initial),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    style: theme.headingMedium?.copyWith(
                      color: theme.sidebarForeground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Row(
                    children: [
                      Icon(
                        UiUtils.platformIcon(
                          ios: CupertinoIcons.envelope,
                          android: Icons.mail_outline,
                        ),
                        size: IconSize.small,
                        color: theme.sidebarForeground.withValues(alpha: 0.75),
                      ),
                      const SizedBox(width: Spacing.xs),
                      Flexible(
                        child: Text(
                          email,
                          style: theme.bodySmall?.copyWith(
                            color: theme.sidebarForeground.withValues(
                              alpha: 0.75,
                            ),
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Icon(
              UiUtils.platformIcon(
                ios: CupertinoIcons.chevron_right,
                android: Icons.chevron_right,
              ),
              color: theme.iconSecondary,
              size: IconSize.small,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccountSection(BuildContext context, WidgetRef ref) {
    final items = [
      _buildAccountOption(
        context,
        icon: UiUtils.platformIcon(
          ios: CupertinoIcons.person_crop_circle_badge_checkmark,
          android: Icons.auto_awesome,
        ),
        title: AppLocalizations.of(context)!.personalization,
        subtitle: AppLocalizations.of(context)!.personalizationSubtitle,
        onTap: () {
          context.pushNamed(RouteNames.personalization);
        },
      ),
      _buildAccountOption(
        context,
        icon: UiUtils.platformIcon(
          ios: CupertinoIcons.waveform,
          android: Icons.graphic_eq,
        ),
        title: AppLocalizations.of(context)!.audioSettingsTitle,
        subtitle: AppLocalizations.of(context)!.audioSettingsSubtitle,
        onTap: () {
          context.pushNamed(RouteNames.audioSettings);
        },
      ),
      _buildAccountOption(
        context,
        icon: UiUtils.platformIcon(
          ios: CupertinoIcons.slider_horizontal_3,
          android: Icons.tune,
        ),
        title: AppLocalizations.of(context)!.appAndChat,
        subtitle: AppLocalizations.of(context)!.appAndChatSubtitle,
        onTap: () {
          context.pushNamed(RouteNames.appCustomization);
        },
      ),
      _buildAboutTile(context),
      _buildAccountOption(
        context,
        icon: UiUtils.platformIcon(
          ios: CupertinoIcons.square_arrow_left,
          android: Icons.logout,
        ),
        title: AppLocalizations.of(context)!.signOut,
        subtitle: AppLocalizations.of(context)!.endYourSession,
        onTap: () => _signOut(context, ref),
        showChevron: false,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          items[i],
          if (i != items.length - 1) const SizedBox(height: Spacing.md),
        ],
      ],
    );
  }

  Widget _buildAccountOption(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool showChevron = true,
  }) {
    final theme = context.conduitTheme;
    final color = theme.buttonPrimary;
    return ProfileSettingTile(
      onTap: onTap,
      leading: _buildIconBadge(context, icon, color: color),
      title: title,
      subtitle: subtitle,
      trailing: showChevron
          ? Icon(
              UiUtils.platformIcon(
                ios: CupertinoIcons.chevron_right,
                android: Icons.chevron_right,
              ),
              color: theme.iconSecondary,
              size: IconSize.small,
            )
          : null,
    );
  }

  Widget _buildIconBadge(
    BuildContext context,
    IconData icon, {
    required Color color,
  }) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppBorderRadius.small),
        border: Border.all(
          color: color.withValues(alpha: 0.2),
          width: BorderWidth.thin,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: color, size: IconSize.medium),
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
      subtitle: AppLocalizations.of(context)!.aboutAppSubtitle,
      onTap: () => context.pushNamed(RouteNames.about),
    );
  }

  void _signOut(BuildContext context, WidgetRef ref) async {
    final confirm = await ThemedDialogs.confirm(
      context,
      title: AppLocalizations.of(context)!.signOut,
      message: AppLocalizations.of(context)!.endYourSession,
      confirmText: AppLocalizations.of(context)!.signOut,
      isDestructive: true,
    );

    if (confirm) {
      await ref.read(authActionsProvider).logout();
    }
  }
}
