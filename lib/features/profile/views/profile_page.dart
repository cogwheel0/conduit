import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../shared/theme/theme_extensions.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:conduit/l10n/app_localizations.dart';
import '../../../core/widgets/error_boundary.dart';
import '../../../shared/widgets/conduit_loading.dart';

import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../chat/providers/chat_providers.dart' show restoreDefaultModel;
import '../../auth/providers/unified_auth_providers.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/models/model.dart';
import '../../../core/services/api_service.dart';
import '../../../core/models/user.dart' as models;
import 'dart:async';
import '../../../core/utils/user_display_name.dart';
import '../../../core/utils/user_avatar_utils.dart';
import '../../../core/utils/model_icon_utils.dart';
import '../../../shared/widgets/user_avatar.dart';
import '../../../shared/widgets/model_avatar.dart';
import '../widgets/default_model_sheet.dart';
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

  Scaffold _buildScaffold(BuildContext context, {required Widget body}) {
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: context.conduitTheme.surfaceBackground,
      extendBodyBehindAppBar: true,
      appBar: FloatingAppBar(
        leading: canPop ? const FloatingAppBarBackButton() : null,
        title: FloatingAppBarTitle(text: l10n.you),
      ),
      body: body,
    );
  }

  Widget _buildCenteredState(BuildContext context, Widget child) {
    final topPadding =
        MediaQuery.of(context).padding.top + kTextTabBarHeight + 24;
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
    // Calculate top padding to account for app bar + safe area
    final topPadding =
        MediaQuery.of(context).padding.top + kTextTabBarHeight + 24;

    return ListView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: EdgeInsets.fromLTRB(
        Spacing.pagePadding,
        topPadding,
        Spacing.pagePadding,
        Spacing.pagePadding + MediaQuery.of(context).padding.bottom,
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

  Widget _buildSupportSection(BuildContext context) {
    final theme = context.conduitTheme;
    final textTheme =
        theme.bodySmall?.copyWith(
          color: theme.sidebarForeground.withValues(alpha: 0.75),
        ) ??
        AppTypography.bodySmallStyle.copyWith(
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
    } on PlatformException catch (_) {
      if (!context.mounted) return;
      UiUtils.showMessage(context, AppLocalizations.of(context)!.errorMessage);
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
    final displayName = deriveUserDisplayName(user);
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

    final email = extractEmail(user) ?? 'No email';
    final theme = context.conduitTheme;

    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: theme.sidebarAccent.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppBorderRadius.large),
        border: Border.all(
          color: theme.sidebarBorder.withValues(alpha: 0.6),
          width: BorderWidth.thin,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
                          color: theme.sidebarForeground.withValues(
                            alpha: 0.75,
                          ),
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
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAccountSection(BuildContext context, WidgetRef ref) {
    final items = [
      _buildDefaultModelTile(context, ref),
      _buildAccountOption(
        context,
        icon: UiUtils.platformIcon(
          ios: CupertinoIcons.slider_horizontal_3,
          android: Icons.tune,
        ),
        title: AppLocalizations.of(context)!.appCustomization,
        subtitle: AppLocalizations.of(context)!.appCustomizationSubtitle,
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

  Widget _buildDefaultModelTile(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final modelsAsync = ref.watch(modelsProvider);
    final api = ref.watch(apiServiceProvider);

    return modelsAsync.when(
      data: (models) {
        final currentModel = models.firstWhere(
          (m) => m.id == settings.defaultModel,
          orElse: () => models.isNotEmpty
              ? models.first
              : Model(
                  id: 'none',
                  name: AppLocalizations.of(context)!.noModelsAvailable,
                ),
        );

        final selectedModelExplicit = settings.defaultModel != null;
        final modelIconUrl = selectedModelExplicit
            ? resolveModelIconUrlForModel(api, currentModel)
            : null;
        final modelLabel = selectedModelExplicit
            ? currentModel.name
            : AppLocalizations.of(context)!.autoSelect;

        final theme = context.conduitTheme;

        Widget leading;
        if (selectedModelExplicit) {
          leading = Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: theme.sidebarAccent.withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(AppBorderRadius.small),
              border: Border.all(
                color: theme.cardBorder,
                width: BorderWidth.thin,
              ),
            ),
            alignment: Alignment.center,
            child: ModelAvatar(
              size: 28,
              imageUrl: modelIconUrl,
              label: currentModel.name,
            ),
          );
        } else {
          leading = _buildIconBadge(
            context,
            UiUtils.platformIcon(
              ios: CupertinoIcons.wand_stars,
              android: Icons.auto_awesome,
            ),
            color: theme.buttonPrimary,
          );
        }

        return ProfileSettingTile(
          leading: leading,
          title: AppLocalizations.of(context)!.defaultModel,
          subtitle: modelLabel,
          onTap: () => _showModelSelector(context, ref, models),
        );
      },
      loading: () => ProfileSettingTile(
        leading: _buildIconBadge(
          context,
          UiUtils.platformIcon(
            ios: CupertinoIcons.cube_box,
            android: Icons.psychology,
          ),
          color: context.conduitTheme.buttonPrimary,
        ),
        title: AppLocalizations.of(context)!.defaultModel,
        subtitle: AppLocalizations.of(context)!.loadingModels,
        showChevron: false,
        trailing: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(
              context.conduitTheme.buttonPrimary,
            ),
          ),
        ),
      ),
      error: (error, stack) => ProfileSettingTile(
        leading: _buildIconBadge(
          context,
          UiUtils.platformIcon(
            ios: CupertinoIcons.exclamationmark_triangle,
            android: Icons.error_outline,
          ),
          color: Colors.red,
        ),
        title: AppLocalizations.of(context)!.defaultModel,
        subtitle: AppLocalizations.of(context)!.failedToLoadModels,
        showChevron: false,
        onTap: () => ref.invalidate(modelsProvider),
        trailing: IconButton(
          onPressed: () => ref.invalidate(modelsProvider),
          tooltip: AppLocalizations.of(context)!.retry,
          icon: Icon(
            UiUtils.platformIcon(
              ios: CupertinoIcons.refresh,
              android: Icons.refresh,
            ),
            color: Colors.red,
            size: IconSize.small,
          ),
        ),
      ),
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
      onTap: () => _showAboutDialog(context),
    );
  }

  Future<void> _showAboutDialog(BuildContext context) async {
    try {
      final info = await PackageInfo.fromPlatform();
      // Update dialog with dynamic version each time
      // GitHub repo URL source of truth
      const githubUrl = 'https://github.com/cogwheel0/conduit';

      if (!context.mounted) return;
      final l10n = AppLocalizations.of(context)!;
      await ThemedDialogs.show(
        context,
        title: l10n.aboutConduit,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.versionLabel(info.version, info.buildNumber)),
            const SizedBox(height: Spacing.md),
            InkWell(
              onTap: () => launchUrlString(
                githubUrl,
                mode: LaunchMode.externalApplication,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    UiUtils.platformIcon(
                      ios: CupertinoIcons.link,
                      android: Icons.link,
                    ),
                    size: IconSize.small,
                    color: context.conduitTheme.buttonPrimary,
                  ),
                  const SizedBox(width: Spacing.xs),
                  Text(
                    l10n.githubRepository,
                    style: AppTypography.bodyMediumStyle.copyWith(
                      color: context.conduitTheme.buttonPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.closeButtonSemantic),
          ),
        ],
      );
    } catch (e) {
      if (!context.mounted) return;
      UiUtils.showMessage(
        context,
        AppLocalizations.of(context)!.unableToLoadAppInfo,
      );
    }
  }

  Future<void> _showModelSelector(
    BuildContext context,
    WidgetRef ref,
    List<Model> models,
  ) async {
    final result = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DefaultModelBottomSheet(
        models: models,
        currentDefaultModelId: ref.read(appSettingsProvider).defaultModel,
      ),
    );

    // result is non-null only when Save button is pressed
    // null means the sheet was dismissed without saving
    if (result != null) {
      // Handle special case: 'auto-select' should be stored as null
      final modelIdToSave = result == 'auto-select' ? null : result;
      await ref
          .read(appSettingsProvider.notifier)
          .setDefaultModel(modelIdToSave);

      // Immediately apply the new default model selection
      await restoreDefaultModel(ref);
    }
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
