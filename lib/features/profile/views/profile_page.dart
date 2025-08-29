import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../shared/theme/theme_extensions.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:conduit/l10n/app_localizations.dart';
import '../../../core/widgets/error_boundary.dart';
import '../../../shared/widgets/improved_loading_states.dart';

import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/sheet_handle.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../core/providers/app_providers.dart';
import '../../auth/providers/unified_auth_providers.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/models/model.dart';
import 'dart:async';
import 'dart:io';
import '../../chat/views/chat_page_helpers.dart';

/// Profile page (You tab) showing user info and main actions
/// Enhanced with production-grade design tokens for better cohesion
class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);

    return ErrorBoundary(
      child: user.when(
        data: (userData) => Scaffold(
          backgroundColor: context.conduitTheme.surfaceBackground,
          appBar: AppBar(
            backgroundColor: context.conduitTheme.surfaceBackground,
            elevation: Elevation.none,
            automaticallyImplyLeading: false,
            leading: IconButton(
              icon: Icon(
                UiUtils.platformIcon(
                  ios: CupertinoIcons.back,
                  android: Icons.arrow_back,
                ),
                color: context.conduitTheme.textPrimary,
              ),
              onPressed: () => Navigator.of(context).maybePop(),
              tooltip: AppLocalizations.of(context)!.back,
            ),
            toolbarHeight: kToolbarHeight,
            titleSpacing: 0.0,
            title: Text(
              AppLocalizations.of(context)!.you,
              style: AppTypography.headlineSmallStyle.copyWith(
                color: context.conduitTheme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            centerTitle: true,
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(Spacing.pagePadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Profile Header - Enhanced with better spacing and animations
                _buildProfileHeader(userData)
                    .animate()
                    .fadeIn(duration: AnimationDuration.pageTransition)
                    .slideY(
                      begin: 0.1,
                      end: 0,
                      curve: AnimationCurves.pageTransition,
                    ),
                const SizedBox(height: Spacing.sectionGap),

                // Account Section - Enhanced with improved spacing
                _buildAccountSection(context, ref)
                    .animate()
                    .fadeIn(
                      delay: AnimationDelay.short,
                      duration: AnimationDuration.pageTransition,
                    )
                    .slideY(
                      begin: 0.1,
                      end: 0,
                      curve: AnimationCurves.pageTransition,
                    ),
              ],
            ),
          ),
        ),
        loading: () => Scaffold(
          backgroundColor: context.conduitTheme.surfaceBackground,
          appBar: AppBar(
            backgroundColor: context.conduitTheme.surfaceBackground,
            elevation: Elevation.none,
            automaticallyImplyLeading: false,
            leading: IconButton(
              icon: Icon(
                UiUtils.platformIcon(
                  ios: CupertinoIcons.back,
                  android: Icons.arrow_back,
                ),
                color: context.conduitTheme.textPrimary,
              ),
              onPressed: () => Navigator.of(context).maybePop(),
              tooltip: AppLocalizations.of(context)!.back,
            ),
            title: Text(
              AppLocalizations.of(context)!.you,
              style: AppTypography.headlineSmallStyle.copyWith(
                color: context.conduitTheme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            centerTitle: true,
          ),
          body: Center(
            child: ImprovedLoadingState(
              message: AppLocalizations.of(context)!.loadingProfile,
            ),
          ),
        ),
        error: (error, stack) => Scaffold(
          backgroundColor: context.conduitTheme.surfaceBackground,
          appBar: AppBar(
            backgroundColor: context.conduitTheme.surfaceBackground,
            elevation: Elevation.none,
            automaticallyImplyLeading: false,
            leading: IconButton(
              icon: Icon(
                UiUtils.platformIcon(
                  ios: CupertinoIcons.back,
                  android: Icons.arrow_back,
                ),
                color: context.conduitTheme.textPrimary,
              ),
              onPressed: () => Navigator.of(context).maybePop(),
              tooltip: AppLocalizations.of(context)!.back,
            ),
            title: Text(
              AppLocalizations.of(context)!.you,
              style: AppTypography.headlineSmallStyle.copyWith(
                color: context.conduitTheme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            centerTitle: true,
          ),
          body: Center(
            child: ImprovedEmptyState(
              title: AppLocalizations.of(context)!.unableToLoadProfile,
              subtitle: AppLocalizations.of(context)!.pleaseCheckConnection,
              icon: UiUtils.platformIcon(
                ios: CupertinoIcons.exclamationmark_triangle,
                android: Icons.error_outline,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProfileHeader(dynamic user) {
    return Builder(
      builder: (context) => ConduitCard(
        padding: const EdgeInsets.all(Spacing.cardPadding),
        child: Row(
          children: [
            // Enhanced avatar with better sizing and shadows
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppBorderRadius.avatar),
                boxShadow: ConduitShadows.card,
              ),
              child: ConduitAvatar(
                size: IconSize.avatar,
                text: user?.name?.substring(0, 1) ?? 'U',
              ),
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user?.name ?? 'User',
                    style: context.conduitTheme.headingMedium?.copyWith(
                      color: context.conduitTheme.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: Spacing.sm),
                  Text(
                    user?.email ?? 'No email',
                    style: context.conduitTheme.bodyMedium?.copyWith(
                      color: context.conduitTheme.textSecondary,
                    ),
                  ),
                  // Status badge removed per design update
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccountSection(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppLocalizations.of(context)!.account,
          style: context.conduitTheme.headingSmall?.copyWith(
            color: context.conduitTheme.textPrimary,
          ),
        ),
        const SizedBox(height: Spacing.md),
        ConduitCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              _buildDefaultModelTile(context, ref),
              Divider(color: context.conduitTheme.dividerColor, height: 1),
              _buildThemeToggleTile(context, ref),
              Divider(color: context.conduitTheme.dividerColor, height: 1),
              _buildLanguageTile(context, ref),
              Divider(color: context.conduitTheme.dividerColor, height: 1),
              _buildTTSLanguageTile(context, ref),
              Divider(color: context.conduitTheme.dividerColor, height: 1),
              _buildAboutTile(context),
              Divider(color: context.conduitTheme.dividerColor, height: 1),
              _buildAccountOption(
                icon: UiUtils.platformIcon(
                  ios: CupertinoIcons.square_arrow_left,
                  android: Icons.logout,
                ),
                title: AppLocalizations.of(context)!.signOut,
                subtitle: AppLocalizations.of(context)!.endYourSession,
                onTap: () => _signOut(context, ref),
                isDestructive: true,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAccountOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    return Builder(
      builder: (context) => ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Spacing.listItemPadding,
          vertical: Spacing.sm,
        ),
        leading: Container(
          padding: const EdgeInsets.all(Spacing.sm),
          decoration: BoxDecoration(
            color: isDestructive
                ? context.conduitTheme.error.withValues(alpha: Alpha.highlight)
                : context.conduitTheme.buttonPrimary.withValues(
                    alpha: Alpha.highlight,
                  ),
            borderRadius: BorderRadius.circular(AppBorderRadius.small),
          ),
          child: Icon(
            icon,
            color: isDestructive
                ? context.conduitTheme.error
                : context.conduitTheme.buttonPrimary,
            size: IconSize.medium,
          ),
        ),
        title: Text(
          title,
          style: context.conduitTheme.bodyLarge?.copyWith(
            color: isDestructive
                ? context.conduitTheme.error
                : context.conduitTheme.textPrimary,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: context.conduitTheme.bodySmall?.copyWith(
            color: context.conduitTheme.textSecondary,
          ),
        ),
        trailing: Icon(
          UiUtils.platformIcon(
            ios: CupertinoIcons.chevron_right,
            android: Icons.chevron_right,
          ),
          color: context.conduitTheme.iconSecondary,
          size: IconSize.small,
        ),
        onTap: onTap,
      ),
    );
  }

  Widget _buildDefaultModelTile(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final modelsAsync = ref.watch(modelsProvider);

    return modelsAsync.when(
      data: (models) {
        final currentModel = models.firstWhere(
          (m) => m.id == settings.defaultModel,
          orElse: () => models.isNotEmpty
              ? models.first
              : Model(id: 'none', name: AppLocalizations.of(context)!.noModelsAvailable),
        );

        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: Spacing.listItemPadding,
            vertical: Spacing.sm,
          ),
          leading: Container(
            padding: const EdgeInsets.all(Spacing.sm),
            decoration: BoxDecoration(
              color: context.conduitTheme.buttonPrimary.withValues(
                alpha: Alpha.highlight,
              ),
              borderRadius: BorderRadius.circular(AppBorderRadius.small),
            ),
            child: Icon(
              UiUtils.platformIcon(
                ios: CupertinoIcons.cube_box,
                android: Icons.psychology,
              ),
              color: context.conduitTheme.buttonPrimary,
              size: IconSize.medium,
            ),
          ),
          title: Text(
            AppLocalizations.of(context)!.defaultModel,
            style: context.conduitTheme.bodyLarge?.copyWith(
              color: context.conduitTheme.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
          subtitle: Text(
            settings.defaultModel != null
                ? currentModel.name
                : AppLocalizations.of(context)!.autoSelect,
            style: context.conduitTheme.bodySmall?.copyWith(
              color: context.conduitTheme.textSecondary,
            ),
          ),
          trailing: Icon(
            UiUtils.platformIcon(
              ios: CupertinoIcons.chevron_right,
              android: Icons.chevron_right,
            ),
            color: context.conduitTheme.iconSecondary,
            size: IconSize.small,
          ),
          onTap: () => _showModelSelector(context, ref, models),
        );
      },
      loading: () => ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Spacing.listItemPadding,
          vertical: Spacing.sm,
        ),
        leading: Container(
          padding: const EdgeInsets.all(Spacing.sm),
          decoration: BoxDecoration(
            color: context.conduitTheme.buttonPrimary.withValues(
              alpha: Alpha.highlight,
            ),
            borderRadius: BorderRadius.circular(AppBorderRadius.small),
          ),
          child: Icon(
            UiUtils.platformIcon(
              ios: CupertinoIcons.cube_box,
              android: Icons.psychology,
            ),
            color: context.conduitTheme.buttonPrimary,
            size: IconSize.medium,
          ),
        ),
        title: Text(
          AppLocalizations.of(context)!.defaultModel,
          style: context.conduitTheme.bodyLarge?.copyWith(
            color: context.conduitTheme.textPrimary,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          AppLocalizations.of(context)!.loadingModels,
          style: context.conduitTheme.bodySmall?.copyWith(
            color: context.conduitTheme.textSecondary,
          ),
        ),
      ),
      error: (error, stack) => ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Spacing.listItemPadding,
          vertical: Spacing.sm,
        ),
        leading: Container(
          padding: const EdgeInsets.all(Spacing.sm),
          decoration: BoxDecoration(
            color: context.conduitTheme.error.withValues(
              alpha: Alpha.highlight,
            ),
            borderRadius: BorderRadius.circular(AppBorderRadius.small),
          ),
          child: Icon(
            UiUtils.platformIcon(
              ios: CupertinoIcons.exclamationmark_triangle,
              android: Icons.error_outline,
            ),
            color: context.conduitTheme.error,
            size: IconSize.medium,
          ),
        ),
        title: Text(
          AppLocalizations.of(context)!.defaultModel,
          style: context.conduitTheme.bodyLarge?.copyWith(
            color: context.conduitTheme.textPrimary,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          AppLocalizations.of(context)!.failedToLoadModels,
          style: context.conduitTheme.bodySmall?.copyWith(
            color: context.conduitTheme.error,
          ),
        ),
      ),
    );
  }

  Widget _buildLanguageTile(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeProvider);
    final currentCode = locale?.languageCode ?? 'system';
    final label = () {
      switch (currentCode) {
        case 'en':
          return 'English';
        case 'de':
          return 'Deutsch';
        case 'fr':
          return 'Français';
        case 'it':
          return 'Italiano';
        default:
          return 'System';
      }
    }();

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Spacing.listItemPadding,
        vertical: Spacing.sm,
      ),
      leading: Container(
        padding: const EdgeInsets.all(Spacing.sm),
        decoration: BoxDecoration(
          color: context.conduitTheme.buttonPrimary.withValues(
            alpha: Alpha.highlight,
          ),
          borderRadius: BorderRadius.circular(AppBorderRadius.small),
        ),
        child: Icon(
          UiUtils.platformIcon(
            ios: CupertinoIcons.globe,
            android: Icons.language,
          ),
          color: context.conduitTheme.buttonPrimary,
          size: IconSize.medium,
        ),
      ),
      title: Text(
        AppLocalizations.of(context)!.appLanguage,
        style: context.conduitTheme.bodyLarge?.copyWith(
          color: context.conduitTheme.textPrimary,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        label,
        style: context.conduitTheme.bodySmall?.copyWith(
          color: context.conduitTheme.textSecondary,
        ),
      ),
      trailing: Icon(
        UiUtils.platformIcon(
          ios: CupertinoIcons.chevron_right,
          android: Icons.chevron_right,
        ),
        color: context.conduitTheme.iconSecondary,
        size: IconSize.small,
      ),
      onTap: () async {
        final selected = await _showLanguageSelector(context, currentCode);
        if (selected != null) {
          if (selected == 'system') {
            await ref.read(localeProvider.notifier).setLocale(null);
          } else {
            await ref.read(localeProvider.notifier).setLocale(Locale(selected));
          }
        }
      },
    );
  }

  Widget _buildTTSLanguageTile(BuildContext context, WidgetRef ref) {
    final currentTTSLanguage = ref.watch(ttsLanguageProvider);

    final label = () {
      switch (currentTTSLanguage) {
        case 'en-US':
          return AppLocalizations.of(context)!.english;
        case 'es-ES':
          return AppLocalizations.of(context)!.espanol;
        case 'de-DE':
          return AppLocalizations.of(context)!.deutsch;
        case 'fr-FR':
          return AppLocalizations.of(context)!.francais;
        case 'it-IT':
          return AppLocalizations.of(context)!.italiano;
        default:
          return 'System';
      }
    }();

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Spacing.listItemPadding,
        vertical: Spacing.sm,
      ),
      leading: Container(
        padding: const EdgeInsets.all(Spacing.sm),
        decoration: BoxDecoration(
          color: context.conduitTheme.buttonPrimary.withValues(
            alpha: Alpha.highlight,
          ),
          borderRadius: BorderRadius.circular(AppBorderRadius.small),
        ),
        child: Icon(
          UiUtils.platformIcon(
            ios: CupertinoIcons.speaker_2_fill,
            android: Icons.record_voice_over,
          ),
          color: context.conduitTheme.buttonPrimary,
          size: IconSize.medium,
        ),
      ),
      title: Text(
        AppLocalizations.of(context)!.ttsLanguage,
        style: context.conduitTheme.bodyLarge?.copyWith(
          color: context.conduitTheme.textPrimary,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        label,
        style: context.conduitTheme.bodySmall?.copyWith(
          color: context.conduitTheme.textSecondary,
        ),
      ),
      trailing: Icon(
        UiUtils.platformIcon(
          ios: CupertinoIcons.chevron_right,
          android: Icons.chevron_right,
        ),
        color: context.conduitTheme.iconSecondary,
        size: IconSize.small,
      ),
      onTap: () async {
        final selected = await _showTTSLanguageSelector(
          context,
          currentTTSLanguage ?? 'system',
        );
        if (selected != null) {
          if (selected == 'system') {
            await ref.read(ttsLanguageProvider.notifier).setTTSLanguage(null);
          } else {
            await ref
                .read(ttsLanguageProvider.notifier)
                .setTTSLanguage(selected);
          }
        }
      },
    );
  }

  Future<String?> _showTTSLanguageSelector(
    BuildContext context,
    String current,
  ) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: context.conduitTheme.surfaceBackground,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppBorderRadius.modal),
          ),
          boxShadow: ConduitShadows.modal,
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: Spacing.sm),
              const SheetHandle(),
              const SizedBox(height: Spacing.md),
              Text(
                AppLocalizations.of(context)!.ttsLanguage,
                style: context.conduitTheme.headingSmall?.copyWith(
                  color: context.conduitTheme.textPrimary,
                ),
              ),
              const SizedBox(height: Spacing.md),
              ListTile(
                title: Text('System'),
                trailing: current == 'system' ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, 'system'),
              ),
              ListTile(
                title: Text(AppLocalizations.of(context)!.english),
                trailing: current == 'en-US' ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, 'en-US'),
              ),
              ListTile(
                title: Text(AppLocalizations.of(context)!.espanol),
                trailing: current == 'es-ES' ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, 'es-ES'),
              ),
              ListTile(
                title: Text(AppLocalizations.of(context)!.deutsch),
                trailing: current == 'de-DE' ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, 'de-DE'),
              ),
              ListTile(
                title: Text(AppLocalizations.of(context)!.francais),
                trailing: current == 'fr-FR' ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, 'fr-FR'),
              ),
              ListTile(
                title: Text(AppLocalizations.of(context)!.italiano),
                trailing: current == 'it-IT' ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, 'it-IT'),
              ),
              const SizedBox(height: Spacing.sm),
            ],
          ),
        ),
      ),
    );
  }

  Future<String?> _showLanguageSelector(BuildContext context, String current) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: context.conduitTheme.surfaceBackground,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppBorderRadius.modal),
          ),
          boxShadow: ConduitShadows.modal,
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: Spacing.sm),
              ListTile(
                title: Text(AppLocalizations.of(context)!.system),
                trailing: current == 'system' ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, 'system'),
              ),
              ListTile(
                title: Text(AppLocalizations.of(context)!.english),
                trailing: current == 'en' ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, 'en'),
              ),
              ListTile(
                title: Text(AppLocalizations.of(context)!.deutsch),
                trailing: current == 'de' ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, 'de'),
              ),
              ListTile(
                title: Text(AppLocalizations.of(context)!.francais),
                trailing: current == 'fr' ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, 'fr'),
              ),
              ListTile(
                title: Text(AppLocalizations.of(context)!.italiano),
                trailing: current == 'it' ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, 'it'),
              ),
              const SizedBox(height: Spacing.sm),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThemeToggleTile(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final platformBrightness = MediaQuery.platformBrightnessOf(context);
    final bool isDarkEffective =
        themeMode == ThemeMode.dark ||
        (themeMode == ThemeMode.system &&
            platformBrightness == Brightness.dark);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Spacing.listItemPadding,
        vertical: Spacing.sm,
      ),
      leading: Container(
        padding: const EdgeInsets.all(Spacing.sm),
        decoration: BoxDecoration(
          color: context.conduitTheme.buttonPrimary.withValues(
            alpha: Alpha.highlight,
          ),
          borderRadius: BorderRadius.circular(AppBorderRadius.small),
        ),
        child: Icon(
          UiUtils.platformIcon(
            ios: CupertinoIcons.moon_stars,
            android: Icons.dark_mode,
          ),
          color: context.conduitTheme.buttonPrimary,
          size: IconSize.medium,
        ),
      ),
      title: Text(
        AppLocalizations.of(context)!.darkMode,
        style: context.conduitTheme.bodyLarge?.copyWith(
          color: context.conduitTheme.textPrimary,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        themeMode == ThemeMode.system
            ? AppLocalizations.of(context)!.followingSystem(
                platformBrightness == Brightness.dark
                    ? AppLocalizations.of(context)!.themeDark
                    : AppLocalizations.of(context)!.themeLight,
              )
            : (isDarkEffective
                  ? AppLocalizations.of(context)!.currentlyUsingDarkTheme
                  : AppLocalizations.of(context)!.currentlyUsingLightTheme),
        style: context.conduitTheme.bodySmall?.copyWith(
          color: context.conduitTheme.textSecondary,
        ),
      ),
      trailing: Switch.adaptive(
        value: isDarkEffective,
        onChanged: (value) {
          ref
              .read(themeModeProvider.notifier)
              .setTheme(value ? ThemeMode.dark : ThemeMode.light);
        },
      ),
      onTap: () {
        final newValue = !isDarkEffective;
        ref
            .read(themeModeProvider.notifier)
            .setTheme(newValue ? ThemeMode.dark : ThemeMode.light);
      },
    );
  }

  Widget _buildAboutTile(BuildContext context) {
    return _buildAccountOption(
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
      await showDialog<void>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            backgroundColor: ctx.conduitTheme.surfaceBackground,
            title: Text(
              AppLocalizations.of(ctx)!.aboutConduit,
              style: ctx.conduitTheme.headingSmall?.copyWith(
                color: ctx.conduitTheme.textPrimary,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocalizations.of(ctx)!.versionLabel(info.version, info.buildNumber),
                  style: ctx.conduitTheme.bodyMedium?.copyWith(
                    color: ctx.conduitTheme.textSecondary,
                  ),
                ),
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
                        color: ctx.conduitTheme.buttonPrimary,
                      ),
                      const SizedBox(width: Spacing.xs),
                      Text(
                        AppLocalizations.of(ctx)!.githubRepository,
                        style: ctx.conduitTheme.bodyMedium?.copyWith(
                          color: ctx.conduitTheme.buttonPrimary,
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
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(AppLocalizations.of(ctx)!.closeButtonSemantic),
              ),
            ],
          );
        },
      );
    } catch (e) {
      if (!context.mounted) return;
      UiUtils.showMessage(context, AppLocalizations.of(context)!.unableToLoadAppInfo);
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
      builder: (ctx) => _DefaultModelBottomSheet(
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
    }
  }

  void _signOut(BuildContext context, WidgetRef ref) async {
    final confirm = await UiUtils.showConfirmationDialog(
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

class _DefaultModelBottomSheet extends ConsumerStatefulWidget {
  final List<Model> models;
  final String? currentDefaultModelId;

  const _DefaultModelBottomSheet({
    required this.models,
    required this.currentDefaultModelId,
  });

  @override
  ConsumerState<_DefaultModelBottomSheet> createState() =>
      _DefaultModelBottomSheetState();
}

class _DefaultModelBottomSheetState
    extends ConsumerState<_DefaultModelBottomSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<Model> _filteredModels = [];
  Timer? _searchDebounce;
  String? _selectedModelId;

  Widget _capabilityChip({required IconData icon, required String label}) {
    return Container(
      margin: const EdgeInsets.only(right: Spacing.xs),
      padding: const EdgeInsets.symmetric(horizontal: Spacing.xs, vertical: 2),
      decoration: BoxDecoration(
        color: context.conduitTheme.buttonPrimary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppBorderRadius.chip),
        border: Border.all(
          color: context.conduitTheme.buttonPrimary.withValues(alpha: 0.3),
          width: BorderWidth.thin,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: context.conduitTheme.buttonPrimary),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: AppTypography.labelSmall,
              color: context.conduitTheme.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    // If no default model is set (null), default to auto-select
    _selectedModelId = widget.currentDefaultModelId ?? 'auto-select';
    // Add auto-select as first item
    _filteredModels = [
      const Model(id: 'auto-select', name: 'Auto-select'),
      ...widget.models,
    ];
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _filterModels(String query) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 160), () {
      setState(() {
        _searchQuery = query.toLowerCase();
        List<Model> allModels = [
          const Model(id: 'auto-select', name: 'Auto-select'),
          ...widget.models,
        ];

        if (_searchQuery.isNotEmpty) {
          _filteredModels = allModels.where((model) {
            return model.name.toLowerCase().contains(_searchQuery) ||
                model.id.toLowerCase().contains(_searchQuery);
          }).toList();
        } else {
          _filteredModels = allModels;
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      maxChildSize: 0.92,
      minChildSize: 0.45,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: context.conduitTheme.surfaceBackground,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppBorderRadius.bottomSheet),
            ),
            border: Border.all(
              color: context.conduitTheme.dividerColor,
              width: BorderWidth.regular,
            ),
            boxShadow: ConduitShadows.modal,
          ),
          child: SafeArea(
            top: false,
            bottom: true,
            child: Padding(
              padding: const EdgeInsets.all(Spacing.bottomSheetPadding),
              child: Column(
                children: [
                  // Handle bar (standardized)
                  const SheetHandle(),

                  // Header removed (no icon/title or save button)
                  const SizedBox(height: Spacing.md),

                  // Search field
                  Padding(
                    padding: const EdgeInsets.only(bottom: Spacing.md),
                    child: TextField(
                      controller: _searchController,
                      style: TextStyle(color: context.conduitTheme.textPrimary),
                      decoration: InputDecoration(
                        hintText: AppLocalizations.of(context)!.searchModels,
                        hintStyle: TextStyle(
                          color: context.conduitTheme.inputPlaceholder,
                        ),
                        prefixIcon: Icon(
                          Platform.isIOS ? CupertinoIcons.search : Icons.search,
                          color: context.conduitTheme.iconSecondary,
                        ),
                        filled: true,
                        fillColor: context.conduitTheme.inputBackground,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(
                            AppBorderRadius.md,
                          ),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(
                            AppBorderRadius.md,
                          ),
                          borderSide: BorderSide(
                            color: context.conduitTheme.inputBorder,
                            width: 1,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(
                            AppBorderRadius.md,
                          ),
                          borderSide: BorderSide(
                            color: context.conduitTheme.buttonPrimary,
                            width: 1,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: Spacing.md,
                          vertical: Spacing.md,
                        ),
                      ),
                      onChanged: _filterModels,
                    ),
                  ),

                  // Section header (cohesive with Chats Drawer)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Spacing.sm),
                    child: Row(
                      children: [
                        Text(
                          AppLocalizations.of(context)!.availableModels,
                          style: AppTypography.bodySmallStyle.copyWith(
                            fontWeight: FontWeight.w600,
                            color: context.conduitTheme.textSecondary,
                            letterSpacing: 0.2,
                          ),
                        ),
                        const SizedBox(width: Spacing.xs),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: context.conduitTheme.surfaceBackground
                                .withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(
                              AppBorderRadius.xs,
                            ),
                            border: Border.all(
                              color: context.conduitTheme.dividerColor,
                              width: BorderWidth.thin,
                            ),
                          ),
                          child: Text(
                            '${_filteredModels.length}',
                            style: AppTypography.bodySmallStyle.copyWith(
                              color: context.conduitTheme.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: Spacing.sm),

                  // Models list
                  Expanded(
                    child: Scrollbar(
                      controller: scrollController,
                      child: _filteredModels.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Platform.isIOS
                                        ? CupertinoIcons.search_circle
                                        : Icons.search_off,
                                    size: 48,
                                    color: context.conduitTheme.iconSecondary,
                                  ),
                                  const SizedBox(height: Spacing.md),
                                  Text(
                                    AppLocalizations.of(context)!.noResults,
                                    style: TextStyle(
                                      color: context.conduitTheme.textSecondary,
                                      fontSize: AppTypography.bodyLarge,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              padding: EdgeInsets.zero,
                              itemCount: _filteredModels.length,
                              itemBuilder: (context, index) {
                                final model = _filteredModels[index];
                                final isAutoSelect = model.id == 'auto-select';
                                final isSelected = isAutoSelect
                                    ? _selectedModelId == null ||
                                          _selectedModelId == 'auto-select'
                                    : _selectedModelId == model.id;

                                return _buildModelListTile(
                                  model: model,
                                  isSelected: isSelected,
                                  isAutoSelect: isAutoSelect,
                                  onTap: () {
                                    HapticFeedback.lightImpact();
                                    final selectedId = isAutoSelect
                                        ? 'auto-select'
                                        : model.id;
                                    // Return selection immediately; caller handles persisting
                                    Navigator.pop(context, selectedId);
                                  },
                                );
                              },
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  bool _modelSupportsReasoning(Model model) {
    final params = model.supportedParameters ?? const [];
    return params.any((p) => p.toLowerCase().contains('reasoning'));
  }

  Widget _buildModelListTile({
    required Model model,
    required bool isSelected,
    required bool isAutoSelect,
    required VoidCallback onTap,
  }) {
    return PressableScale(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppBorderRadius.md),
      child: Container(
        margin: const EdgeInsets.only(bottom: Spacing.md),
        decoration: BoxDecoration(
          gradient: isSelected
              ? LinearGradient(
                  colors: [
                    context.conduitTheme.buttonPrimary.withValues(alpha: 0.2),
                    context.conduitTheme.buttonPrimary.withValues(alpha: 0.1),
                  ],
                )
              : null,
          color: isSelected
              ? null
              : context.conduitTheme.surfaceBackground.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(AppBorderRadius.md),
          border: Border.all(
            color: isSelected
                ? context.conduitTheme.buttonPrimary.withValues(alpha: 0.5)
                : context.conduitTheme.dividerColor,
            width: BorderWidth.regular,
          ),
          boxShadow: isSelected ? ConduitShadows.card : null,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.sm,
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: context.conduitTheme.buttonPrimary.withValues(
                    alpha: 0.15,
                  ),
                  borderRadius: BorderRadius.circular(AppBorderRadius.md),
                ),
                child: Icon(
                  isAutoSelect
                      ? (Platform.isIOS
                            ? CupertinoIcons.wand_stars
                            : Icons.auto_awesome)
                      : (Platform.isIOS
                            ? CupertinoIcons.cube
                            : Icons.psychology),
                  color: context.conduitTheme.buttonPrimary,
                  size: 16,
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isAutoSelect
                          ? AppLocalizations.of(context)!.autoSelect
                          : model.name,
                      style: TextStyle(
                        color: context.conduitTheme.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: AppTypography.bodyMedium,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (isAutoSelect) ...[
                      const SizedBox(height: Spacing.xs),
                      Text(
                        'Let the app choose the best model',
                        style: TextStyle(
                          fontSize: AppTypography.bodySmall,
                          color: context.conduitTheme.textSecondary,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: Spacing.xs),
                      Row(
                        children: [
                          if (model.isMultimodal)
                            _capabilityChip(
                              icon: Platform.isIOS
                                  ? CupertinoIcons.photo
                                  : Icons.image,
                              label: 'Multimodal',
                            ),
                          if (_modelSupportsReasoning(model))
                            _capabilityChip(
                              icon: Platform.isIOS
                                  ? CupertinoIcons.lightbulb
                                  : Icons.psychology_alt,
                              label: 'Reasoning',
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: Spacing.md),
              AnimatedOpacity(
                opacity: isSelected ? 1 : 0.6,
                duration: AnimationDuration.fast,
                child: Container(
                  padding: const EdgeInsets.all(Spacing.xxs),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? context.conduitTheme.buttonPrimary
                        : context.conduitTheme.surfaceBackground,
                    borderRadius: BorderRadius.circular(AppBorderRadius.md),
                    border: Border.all(
                      color: isSelected
                          ? context.conduitTheme.buttonPrimary.withValues(
                              alpha: 0.6,
                            )
                          : context.conduitTheme.dividerColor,
                    ),
                  ),
                  child: Icon(
                    isSelected
                        ? (Platform.isIOS
                              ? CupertinoIcons.check_mark
                              : Icons.check)
                        : (Platform.isIOS ? CupertinoIcons.add : Icons.add),
                    color: isSelected
                        ? context.conduitTheme.textInverse
                        : context.conduitTheme.iconSecondary,
                    size: 14,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ).animate().fadeIn(duration: AnimationDuration.microInteraction);
  }
}
