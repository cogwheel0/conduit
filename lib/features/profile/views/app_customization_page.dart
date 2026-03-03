import 'dart:async';
import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/socket_health.dart';
import '../../../core/services/socket_service.dart';
import '../../../core/services/settings_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/theme/tweakcn_themes.dart';
import '../../tools/providers/tools_providers.dart';
import '../../../core/models/tool.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../core/providers/app_providers.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/providers/text_to_speech_provider.dart';
import '../../chat/services/voice_input_service.dart';

const _sectionGap = SizedBox(height: Spacing.lg);

class AppCustomizationPage extends ConsumerWidget {
  const AppCustomizationPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final themeMode = ref.watch(appThemeModeProvider);
    final platformBrightness = MediaQuery.platformBrightnessOf(context);
    final l10n = AppLocalizations.of(context)!;
    final themeDescription = () {
      if (themeMode == ThemeMode.system) {
        final systemThemeLabel = platformBrightness == Brightness.dark
            ? l10n.themeDark
            : l10n.themeLight;
        return l10n.followingSystem(systemThemeLabel);
      }
      if (themeMode == ThemeMode.dark) {
        return l10n.currentlyUsingDarkTheme;
      }
      return l10n.currentlyUsingLightTheme;
    }();
    final locale = ref.watch(appLocaleProvider);
    final currentLanguageCode = locale?.toLanguageTag() ?? 'system';
    final languageLabel = _resolveLanguageLabel(context, currentLanguageCode);
    final activeTheme = ref.watch(appThemePaletteProvider);
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    final topPadding = MediaQuery.of(context).padding.top + kToolbarHeight + 24;

    return Scaffold(
      backgroundColor: context.conduitTheme.surfaceBackground,
      extendBodyBehindAppBar: true,
      appBar: FloatingAppBar(
        leading: canPop ? const FloatingAppBarBackButton() : null,
        title: FloatingAppBarTitle(text: l10n.appCustomization),
      ),
      body: ListView(
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
          _buildThemesDropdownSection(
            context,
            ref,
            themeMode,
            themeDescription,
            activeTheme,
            settings,
          ),
          _sectionGap,
          _buildLanguageSection(
            context,
            ref,
            currentLanguageCode,
            languageLabel,
          ),
          _sectionGap,
          _buildSttSection(context, ref, settings),
          _sectionGap,
          _buildTtsDropdownSection(context, ref, settings),
          _sectionGap,
          _buildChatSection(context, ref, settings),
          _sectionGap,
          _buildSocketHealthSection(context, ref),
        ],
      ),
    );
  }

  Widget _buildThemesDropdownSection(
    BuildContext context,
    WidgetRef ref,
    ThemeMode themeMode,
    String themeDescription,
    TweakcnThemeDefinition activeTheme,
    AppSettings settings,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: AppLocalizations.of(context)!.display),
        const SizedBox(height: Spacing.sm),
        _ExpandableCard(
          title: AppLocalizations.of(context)!.darkMode,
          subtitle: themeDescription,
          icon: UiUtils.platformIcon(
            ios: CupertinoIcons.moon_stars,
            android: Icons.dark_mode,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ThemeModeSegmentedControl(
                value: themeMode,
                onChanged: (mode) {
                  ref.read(appThemeModeProvider.notifier).setTheme(mode);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.md),
        _buildPaletteSelector(context, ref, activeTheme),
        const SizedBox(height: Spacing.md),
        _buildQuickPillsSection(context, ref, settings),
      ],
    );
  }

  Widget _buildLanguageSection(
    BuildContext context,
    WidgetRef ref,
    String currentLanguageTag,
    String languageLabel,
  ) {
    final theme = context.conduitTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: AppLocalizations.of(context)!.appLanguage),
        const SizedBox(height: Spacing.sm),
        _CustomizationTile(
          leading: _buildIconBadge(
            context,
            UiUtils.platformIcon(
              ios: CupertinoIcons.globe,
              android: Icons.language,
            ),
            color: theme.buttonPrimary,
          ),
          title: AppLocalizations.of(context)!.appLanguage,
          subtitle: languageLabel,
          onTap: () async {
            final selected = await _showLanguageSelector(
              context,
              currentLanguageTag,
            );
            if (selected == null) return;
            if (selected == 'system') {
              await ref.read(appLocaleProvider.notifier).setLocale(null);
            } else {
              final parsed = _parseLocaleTag(selected);
              await ref
                  .read(appLocaleProvider.notifier)
                  .setLocale(parsed ?? Locale(selected));
            }
          },
        ),
      ],
    );
  }

  Widget _buildPaletteSelector(
    BuildContext context,
    WidgetRef ref,
    TweakcnThemeDefinition activeTheme,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;

    return _CustomizationTile(
      leading: _buildIconBadge(
        context,
        UiUtils.platformIcon(
          ios: CupertinoIcons.square_fill_on_square_fill,
          android: Icons.palette,
        ),
        color: theme.buttonPrimary,
      ),
      title: l10n.themePalette,
      subtitle: activeTheme.label(l10n),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final color in activeTheme.preview.take(3))
            _PaletteColorDot(color: color),
        ],
      ),
      onTap: () => _showPaletteSelectorSheet(context, ref, activeTheme.id),
    );
  }

  Widget _buildQuickPillsSection(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) {
    // Allow unlimited selections on all platforms
    final maxPills = 999;

    final selectedRaw = ref.watch(
      appSettingsProvider.select((s) => s.quickPills),
    );
    final toolsAsync = ref.watch(toolsListProvider);
    final tools = toolsAsync.maybeWhen(
      data: (value) => value,
      orElse: () => const <Tool>[],
    );

    // Get filters from the selected model
    final selectedModel = ref.watch(selectedModelProvider);
    final filters = selectedModel?.filters ?? const [];

    // Include filter IDs in allowed set (prefixed with 'filter:' to avoid collisions)
    final allowed = <String>{
      'web',
      'image',
      ...tools.map((t) => t.id),
      ...filters.map((f) => 'filter:${f.id}'),
    };

    final selected = selectedRaw
        .where((id) => allowed.contains(id))
        .take(maxPills)
        .toList();
    if (selected.length != selectedRaw.length) {
      Future.microtask(
        () => ref.read(appSettingsProvider.notifier).setQuickPills(selected),
      );
    }

    final selectedCount = selected.length;

    Future<void> toggle(String id) async {
      final next = List<String>.from(selected);
      if (next.contains(id)) {
        next.remove(id);
      } else {
        if (next.length >= maxPills) return;
        next.add(id);
      }
      await ref.read(appSettingsProvider.notifier).setQuickPills(next);
    }

    final l10n = AppLocalizations.of(context)!;
    final selectedCountText = l10n.quickActionsSelectedCount(selectedCount);
    final options = <({String id, String label, IconData icon})>[
      (
        id: 'web',
        label: l10n.web,
        icon: Platform.isIOS ? CupertinoIcons.search : Icons.search,
      ),
      (
        id: 'image',
        label: l10n.imageGen,
        icon: Platform.isIOS ? CupertinoIcons.photo : Icons.image,
      ),
      for (final tool in tools)
        (id: tool.id, label: tool.name, icon: Icons.extension),
      for (final filter in filters)
        (
          id: 'filter:${filter.id}',
          label: filter.name,
          icon: Platform.isIOS ? CupertinoIcons.sparkles : Icons.auto_awesome,
        ),
    ];

    return _ExpandableCard(
      title: l10n.quickActionsDescription,
      subtitle: selectedCountText,
      icon: UiUtils.platformIcon(
        ios: CupertinoIcons.bolt,
        android: Icons.flash_on,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConduitCard(
            padding: EdgeInsets.zero,
            child: Theme(
              data: Theme.of(context).copyWith(
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Column(
                children: [
                  for (var i = 0; i < options.length; i++) ...[
                    AdaptiveListTile(
                      leading: Icon(options[i].icon, size: IconSize.small),
                      title: Text(
                        options[i].label,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      trailing: Checkbox.adaptive(
                        value: selected.contains(options[i].id),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged:
                            (selectedCount < maxPills ||
                                selected.contains(options[i].id))
                            ? (_) => toggle(options[i].id)
                            : null,
                      ),
                      onTap:
                          (selectedCount < maxPills ||
                              selected.contains(options[i].id))
                          ? () => toggle(options[i].id)
                          : null,
                    ),
                    if (i != options.length - 1)
                      Divider(
                        height: 1,
                        color: Theme.of(
                          context,
                        ).dividerColor.withValues(alpha: 0.2),
                      ),
                  ],
                ],
              ),
            ),
          ),
          if (selected.isNotEmpty) ...[
            const SizedBox(height: Spacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: AdaptiveButton.child(
                onPressed: () => ref
                    .read(appSettingsProvider.notifier)
                    .setQuickPills(const []),
                style: AdaptiveButtonStyle.plain,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Platform.isIOS ? CupertinoIcons.xmark : Icons.close,
                      size: IconSize.small,
                    ),
                    const SizedBox(width: Spacing.xs),
                    Text(l10n.clear),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildChatSection(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final transportAvailability = ref.watch(socketTransportOptionsProvider);
    var activeTransportMode = settings.socketTransportMode;
    if (!transportAvailability.allowPolling &&
        activeTransportMode == 'polling') {
      activeTransportMode = 'ws';
    } else if (!transportAvailability.allowWebsocketOnly &&
        activeTransportMode == 'ws') {
      activeTransportMode = 'polling';
    }
    final transportLabel = activeTransportMode == 'polling'
        ? l10n.transportModePolling
        : l10n.transportModeWs;
    final assistantTriggerLabel = _androidAssistantTriggerLabel(
      l10n,
      settings.androidAssistantTrigger,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: l10n.chatSettings),
        const SizedBox(height: Spacing.sm),
        _CustomizationTile(
          leading: _buildIconBadge(
            context,
            UiUtils.platformIcon(
              ios: CupertinoIcons.arrow_2_circlepath,
              android: Icons.sync,
            ),
            color: theme.buttonPrimary,
          ),
          title: l10n.transportMode,
          subtitle: transportLabel,
          trailing:
              transportAvailability.allowPolling &&
                  transportAvailability.allowWebsocketOnly
              ? _buildValueBadge(context, transportLabel)
              : null,
          onTap:
              transportAvailability.allowPolling &&
                  transportAvailability.allowWebsocketOnly
              ? () => _showTransportModeSheet(
                  context,
                  ref,
                  settings,
                  allowPolling: transportAvailability.allowPolling,
                  allowWebsocketOnly: transportAvailability.allowWebsocketOnly,
                )
              : null,
          showChevron:
              transportAvailability.allowPolling &&
              transportAvailability.allowWebsocketOnly,
        ),
        const SizedBox(height: Spacing.sm),
        _CustomizationTile(
          leading: _buildIconBadge(
            context,
            Platform.isIOS ? CupertinoIcons.paperplane : Icons.keyboard_return,
            color: theme.buttonPrimary,
          ),
          title: l10n.sendOnEnter,
          subtitle: l10n.sendOnEnterDescription,
          trailing: AdaptiveSwitch(
            value: settings.sendOnEnter,
            onChanged: (value) =>
                ref.read(appSettingsProvider.notifier).setSendOnEnter(value),
          ),
          showChevron: false,
          onTap: () => ref
              .read(appSettingsProvider.notifier)
              .setSendOnEnter(!settings.sendOnEnter),
        ),
        if (Platform.isAndroid) ...[
          const SizedBox(height: Spacing.sm),
          _CustomizationTile(
            leading: _buildIconBadge(
              context,
              Icons.assistant,
              color: theme.buttonPrimary,
            ),
            title: l10n.androidAssistantTitle,
            subtitle: assistantTriggerLabel,
            onTap: () =>
                _showAndroidAssistantTriggerSheet(context, ref, settings),
          ),
        ],
      ],
    );
  }

  Widget _buildSocketHealthSection(BuildContext context, WidgetRef ref) {
    final socketService = ref.watch(socketServiceProvider);

    if (socketService == null) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: 'Connection Health'),
        const SizedBox(height: Spacing.sm),
        _SocketHealthCard(socketService: socketService),
      ],
    );
  }

  String _androidAssistantTriggerLabel(
    AppLocalizations l10n,
    AndroidAssistantTrigger trigger,
  ) {
    switch (trigger) {
      case AndroidAssistantTrigger.overlay:
        return l10n.androidAssistantOverlayOption;
      case AndroidAssistantTrigger.newChat:
        return l10n.androidAssistantNewChatOption;
      case AndroidAssistantTrigger.voiceCall:
        return l10n.androidAssistantVoiceCallOption;
    }
  }

  Future<void> _showAndroidAssistantTriggerSheet(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) async {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final options = <({AndroidAssistantTrigger value, String label})>[
      (
        value: AndroidAssistantTrigger.overlay,
        label: l10n.androidAssistantOverlayOption,
      ),
      (
        value: AndroidAssistantTrigger.newChat,
        label: l10n.androidAssistantNewChatOption,
      ),
      (
        value: AndroidAssistantTrigger.voiceCall,
        label: l10n.androidAssistantVoiceCallOption,
      ),
    ];

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.sidebarBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.modal),
        ),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.lg,
                  vertical: Spacing.md,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.androidAssistantTitle,
                            style:
                                theme.headingSmall?.copyWith(
                                  color: theme.sidebarForeground,
                                ) ??
                                TextStyle(
                                  color: theme.sidebarForeground,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          const SizedBox(height: Spacing.xs),
                          Text(
                            l10n.androidAssistantDescription,
                            style:
                                theme.bodySmall?.copyWith(
                                  color: theme.sidebarForeground.withValues(
                                    alpha: 0.7,
                                  ),
                                ) ??
                                TextStyle(
                                  color: theme.sidebarForeground.withValues(
                                    alpha: 0.7,
                                  ),
                                ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        Platform.isIOS ? CupertinoIcons.xmark : Icons.close,
                        color: theme.iconPrimary,
                      ),
                      onPressed: () => Navigator.of(sheetContext).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              for (var i = 0; i < options.length; i++) ...[
                () {
                  final option = options[i];
                  final selected =
                      settings.androidAssistantTrigger == option.value;
                  return AdaptiveListTile(
                    leading: Icon(
                      selected
                          ? (Platform.isIOS
                                ? CupertinoIcons.checkmark_circle_fill
                                : Icons.check_circle)
                          : (Platform.isIOS
                                ? CupertinoIcons.circle
                                : Icons.circle_outlined),
                      color: selected
                          ? theme.buttonPrimary
                          : theme.iconSecondary,
                    ),
                    title: Text(
                      option.label,
                      style: theme.bodyMedium?.copyWith(
                        color: theme.sidebarForeground,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                    onTap: () {
                      if (!selected) {
                        ref
                            .read(appSettingsProvider.notifier)
                            .setAndroidAssistantTrigger(option.value);
                      }
                      Navigator.of(sheetContext).pop();
                    },
                  );
                }(),
                if (i != options.length - 1) const Divider(height: 1),
              ],
              const SizedBox(height: Spacing.lg),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSttSection(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final localSupport = ref.watch(localVoiceRecognitionAvailableProvider);
    final bool localAvailable = localSupport.maybeWhen(
      data: (value) => value,
      orElse: () => false,
    );
    final bool localLoading = localSupport.isLoading;
    final bool serverAvailable = ref.watch(
      serverVoiceRecognitionAvailableProvider,
    );
    final notifier = ref.read(appSettingsProvider.notifier);
    final description = _sttPreferenceDescription(l10n, settings.sttPreference);

    final warnings = <String>[];
    if (settings.sttPreference == SttPreference.deviceOnly &&
        !localAvailable &&
        !localLoading) {
      warnings.add(l10n.sttDeviceUnavailableWarning);
    }
    if (settings.sttPreference == SttPreference.serverOnly &&
        !serverAvailable) {
      warnings.add(l10n.sttServerUnavailableWarning);
    }

    final bool deviceSelectable = localAvailable || localLoading;
    final bool serverSelectable = serverAvailable;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: l10n.sttSettings),
        const SizedBox(height: Spacing.sm),
        ConduitCard(
          padding: const EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _buildIconBadge(
                    context,
                    UiUtils.platformIcon(
                      ios: CupertinoIcons.mic,
                      android: Icons.mic,
                    ),
                    color: theme.buttonPrimary,
                  ),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: Text(
                      l10n.sttEngineLabel,
                      style:
                          theme.bodyMedium?.copyWith(
                            color: theme.sidebarForeground,
                            fontWeight: FontWeight.w600,
                          ) ??
                          TextStyle(
                            color: theme.sidebarForeground,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              _AdaptiveSegmentedSelector<SttPreference>(
                value: settings.sttPreference,
                onChanged: notifier.setSttPreference,
                options: [
                  (
                    value: SttPreference.deviceOnly,
                    label: l10n.sttEngineDevice,
                    cupertinoIcon: CupertinoIcons.device_phone_portrait,
                    materialIcon: Icons.phone_android,
                    enabled: deviceSelectable,
                  ),
                  (
                    value: SttPreference.serverOnly,
                    label: l10n.sttEngineServer,
                    cupertinoIcon: CupertinoIcons.cloud,
                    materialIcon: Icons.cloud,
                    enabled: serverSelectable,
                  ),
                ],
              ),
              if (localLoading) ...[
                const SizedBox(height: Spacing.sm),
                LinearProgressIndicator(
                  minHeight: 3,
                  color: theme.buttonPrimary,
                  backgroundColor: theme.cardBorder.withValues(alpha: 0.4),
                ),
              ],
              const SizedBox(height: Spacing.sm),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Text(
                  description,
                  key: ValueKey<String>(
                    'stt-desc-${settings.sttPreference.name}',
                  ),
                  style:
                      theme.bodyMedium?.copyWith(
                        color: theme.sidebarForeground.withValues(alpha: 0.9),
                      ) ??
                      TextStyle(
                        color: theme.sidebarForeground.withValues(alpha: 0.9),
                        fontSize: 14,
                      ),
                ),
              ),
              if (warnings.isNotEmpty) ...[
                const SizedBox(height: Spacing.sm),
                ...warnings.map(
                  (warning) => Padding(
                    padding: const EdgeInsets.only(top: Spacing.xs),
                    child: Text(
                      warning,
                      style:
                          theme.bodySmall?.copyWith(
                            color: theme.error,
                            fontWeight: FontWeight.w600,
                          ) ??
                          TextStyle(
                            color: theme.error,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ),
              ],
              if (settings.sttPreference == SttPreference.serverOnly) ...[
                const SizedBox(height: Spacing.md),
                const Divider(),
                const SizedBox(height: Spacing.md),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.sttSilenceDuration,
                            style:
                                theme.bodyMedium?.copyWith(
                                  color: theme.sidebarForeground,
                                  fontWeight: FontWeight.w600,
                                ) ??
                                TextStyle(
                                  color: theme.sidebarForeground,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          const SizedBox(height: Spacing.xs),
                          Text(
                            '${settings.voiceSilenceDuration}ms',
                            style:
                                theme.bodySmall?.copyWith(
                                  color: theme.sidebarForeground.withValues(
                                    alpha: 0.7,
                                  ),
                                ) ??
                                TextStyle(
                                  color: theme.sidebarForeground.withValues(
                                    alpha: 0.7,
                                  ),
                                  fontSize: 12,
                                ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${(settings.voiceSilenceDuration / 1000).toStringAsFixed(1)}s',
                      style:
                          theme.bodyMedium?.copyWith(
                            color: theme.buttonPrimary,
                            fontWeight: FontWeight.w600,
                          ) ??
                          TextStyle(
                            color: theme.buttonPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.sm),
                AdaptiveSlider(
                  value: settings.voiceSilenceDuration.toDouble(),
                  min: 300,
                  max: 3000,
                  divisions: 27,
                  activeColor: theme.buttonPrimary,
                  onChanged: (value) {
                    notifier.setVoiceSilenceDuration(value.round());
                  },
                ),
                Text(
                  l10n.sttSilenceDurationDescription,
                  style:
                      theme.bodySmall?.copyWith(
                        color: theme.sidebarForeground.withValues(alpha: 0.7),
                      ) ??
                      TextStyle(
                        color: theme.sidebarForeground.withValues(alpha: 0.7),
                        fontSize: 12,
                      ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTtsDropdownSection(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final ttsService = ref.watch(textToSpeechServiceProvider);
    final bool deviceAvailable =
        ttsService.deviceEngineAvailable || !ttsService.isInitialized;
    final bool serverAvailable = ttsService.serverEngineAvailable;
    final bool deviceSelectable = deviceAvailable;
    final bool serverSelectable = serverAvailable;
    final ttsDescription = _ttsPreferenceDescription(l10n, settings);
    final warnings = <String>[];
    switch (settings.ttsEngine) {
      case TtsEngine.device:
        if (!deviceAvailable) {
          warnings.add(l10n.ttsDeviceUnavailableWarning);
        }
        break;
      case TtsEngine.server:
        if (!serverAvailable) {
          warnings.add(l10n.ttsServerUnavailableWarning);
        }
        break;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: l10n.ttsSettings),
        const SizedBox(height: Spacing.sm),
        ConduitCard(
          padding: const EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _buildIconBadge(
                    context,
                    UiUtils.platformIcon(
                      ios: CupertinoIcons.settings,
                      android: Icons.settings_voice,
                    ),
                    color: theme.buttonPrimary,
                  ),
                  const SizedBox(width: Spacing.md),
                  Text(
                    l10n.ttsEngineLabel,
                    style:
                        theme.bodyMedium?.copyWith(
                          color: theme.sidebarForeground,
                          fontWeight: FontWeight.w600,
                        ) ??
                        TextStyle(color: theme.sidebarForeground, fontSize: 14),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              _AdaptiveSegmentedSelector<TtsEngine>(
                value: settings.ttsEngine,
                onChanged: (engine) {
                  final notifier = ref.read(appSettingsProvider.notifier);
                  if (engine == TtsEngine.server) {
                    notifier.setTtsVoice(null);
                  }
                  notifier.setTtsEngine(engine);
                },
                options: [
                  (
                    value: TtsEngine.device,
                    label: l10n.ttsEngineDevice,
                    cupertinoIcon: CupertinoIcons.device_phone_portrait,
                    materialIcon: Icons.phone_android,
                    enabled: deviceSelectable,
                  ),
                  (
                    value: TtsEngine.server,
                    label: l10n.ttsEngineServer,
                    cupertinoIcon: CupertinoIcons.cloud,
                    materialIcon: Icons.cloud,
                    enabled: serverSelectable,
                  ),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Text(
                  ttsDescription,
                  key: ValueKey<String>('tts-desc-${settings.ttsEngine.name}'),
                  style:
                      theme.bodyMedium?.copyWith(
                        color: theme.sidebarForeground.withValues(alpha: 0.9),
                      ) ??
                      TextStyle(
                        color: theme.sidebarForeground.withValues(alpha: 0.9),
                        fontSize: 14,
                      ),
                ),
              ),
              if (warnings.isNotEmpty) ...[
                const SizedBox(height: Spacing.sm),
                ...warnings.map(
                  (warning) => Padding(
                    padding: const EdgeInsets.only(top: Spacing.xs),
                    child: Text(
                      warning,
                      style:
                          theme.bodySmall?.copyWith(
                            color: theme.error,
                            fontWeight: FontWeight.w600,
                          ) ??
                          TextStyle(
                            color: theme.error,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: Spacing.sm),
        _ExpandableCard(
          title: l10n.ttsVoice,
          subtitle: _ttsVoiceSubtitle(l10n, settings),
          icon: UiUtils.platformIcon(
            ios: CupertinoIcons.speaker_3,
            android: Icons.record_voice_over,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Voice Selection
              _CustomizationTile(
                leading: _buildIconBadge(
                  context,
                  UiUtils.platformIcon(
                    ios: CupertinoIcons.speaker_3,
                    android: Icons.record_voice_over,
                  ),
                  color: theme.buttonPrimary,
                ),
                title: l10n.ttsVoice,
                subtitle: _ttsVoiceSubtitle(l10n, settings),
                onTap: () => _showVoicePickerSheet(context, ref, settings),
              ),
              if (settings.ttsEngine == TtsEngine.device) ...[
                const SizedBox(height: Spacing.md),
                // Speech rate is device-only. Server TTS uses backend defaults.
                _buildSliderTile(
                  context,
                  ref,
                  icon: UiUtils.platformIcon(
                    ios: CupertinoIcons.speedometer,
                    android: Icons.speed,
                  ),
                  title: l10n.ttsSpeechRate,
                  value: settings.ttsSpeechRate,
                  min: 0.25,
                  max: 2.0,
                  divisions: 35,
                  label: '${(settings.ttsSpeechRate * 100).round()}%',
                  onChanged: (value) => ref
                      .read(appSettingsProvider.notifier)
                      .setTtsSpeechRate(value),
                ),
              ],
              const SizedBox(height: Spacing.md),
              // Preview Button
              _CustomizationTile(
                leading: _buildIconBadge(
                  context,
                  UiUtils.platformIcon(
                    ios: CupertinoIcons.play_fill,
                    android: Icons.play_arrow,
                  ),
                  color: theme.buttonPrimary,
                ),
                title: l10n.ttsPreview,
                subtitle: l10n.ttsPreviewText,
                onTap: () => _previewTtsVoice(context, ref),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _sttPreferenceDescription(
    AppLocalizations l10n,
    SttPreference preference,
  ) {
    switch (preference) {
      case SttPreference.deviceOnly:
        return l10n.sttEngineDeviceDescription;
      case SttPreference.serverOnly:
        return l10n.sttEngineServerDescription;
    }
  }

  String _ttsPreferenceDescription(
    AppLocalizations l10n,
    AppSettings settings,
  ) {
    switch (settings.ttsEngine) {
      case TtsEngine.device:
        return l10n.ttsEngineDeviceDescription;
      case TtsEngine.server:
        return l10n.ttsEngineServerDescription;
    }
  }

  String _ttsVoiceSubtitle(AppLocalizations l10n, AppSettings settings) {
    final deviceName = _getDisplayVoiceName(
      settings.ttsVoice,
      l10n.ttsSystemDefault,
    );
    final serverVoice =
        (settings.ttsServerVoiceName ?? settings.ttsServerVoiceId) ?? '';
    final serverName = _getDisplayVoiceName(serverVoice, l10n.ttsSystemDefault);

    switch (settings.ttsEngine) {
      case TtsEngine.device:
        return deviceName;
      case TtsEngine.server:
        return serverName;
    }
  }

  Widget _buildSliderTile(
    BuildContext context,
    WidgetRef ref, {
    required IconData icon,
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String label,
    required ValueChanged<double> onChanged,
  }) {
    final theme = context.conduitTheme;
    return ConduitCard(
      padding: const EdgeInsets.all(Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildIconBadge(context, icon, color: theme.buttonPrimary),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  title,
                  style:
                      theme.bodyMedium?.copyWith(
                        color: theme.sidebarForeground,
                        fontWeight: FontWeight.w500,
                      ) ??
                      TextStyle(color: theme.sidebarForeground, fontSize: 14),
                ),
              ),
              Text(
                label,
                style:
                    theme.bodyMedium?.copyWith(
                      color: theme.sidebarForeground.withValues(alpha: 0.75),
                      fontWeight: FontWeight.w500,
                    ) ??
                    TextStyle(
                      color: theme.sidebarForeground.withValues(alpha: 0.75),
                      fontSize: 14,
                    ),
              ),
            ],
          ),
          AdaptiveSlider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Future<void> _showVoicePickerSheet(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final ttsService = ref.read(textToSpeechServiceProvider);

    // Ensure the service uses the currently selected engine before fetching
    await ttsService.updateSettings(engine: settings.ttsEngine);

    // Fetch available voices from the active engine
    final allVoices = await ttsService.getAvailableVoices();

    if (!context.mounted) return;

    if (allVoices.isEmpty) {
      // Show error if no voices available
      AdaptiveSnackBar.show(
        context,
        message: l10n.ttsNoVoicesAvailable,
        type: AdaptiveSnackBarType.error,
      );
      return;
    }

    // Get the app's current locale
    final appLocale = ref.read(appLocaleProvider);
    final appLanguageCode =
        appLocale?.languageCode ?? Localizations.localeOf(context).languageCode;

    // Filter and sort voices: prioritize matching app language
    final matchingVoices = <Map<String, dynamic>>[];
    final otherVoices = <Map<String, dynamic>>[];

    for (final voice in allVoices) {
      final voiceName = voice['name'] as String? ?? '';
      final voiceLocale = voice['locale'] as String? ?? '';

      // Check if voice matches app language (e.g., 'en' matches 'en-us', 'en-gb')
      final matchesLanguage =
          voiceName.toLowerCase().startsWith(appLanguageCode) ||
          voiceLocale.toLowerCase().startsWith(appLanguageCode);

      if (matchesLanguage) {
        matchingVoices.add(voice);
      } else {
        otherVoices.add(voice);
      }
    }

    // Sort each group alphabetically by name
    matchingVoices.sort((a, b) {
      final nameA = a['name'] as String? ?? '';
      final nameB = b['name'] as String? ?? '';
      return nameA.compareTo(nameB);
    });

    otherVoices.sort((a, b) {
      final nameA = a['name'] as String? ?? '';
      final nameB = b['name'] as String? ?? '';
      return nameA.compareTo(nameB);
    });

    // Combine: matching voices first, then others
    final voices = [...matchingVoices, ...otherVoices];

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.sidebarBackground,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (BuildContext sheetContext) {
        return DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                _SheetHeader(
                  title: l10n.ttsSelectVoice,
                  onClose: () => Navigator.of(sheetContext).pop(),
                ),
                const Divider(height: 1),
                // System Default Option
                AdaptiveListTile(
                  leading: Icon(
                    UiUtils.platformIcon(
                      ios: CupertinoIcons.speaker_3,
                      android: Icons.record_voice_over,
                    ),
                    color: theme.sidebarForeground,
                  ),
                  title: Text(
                    l10n.ttsSystemDefault,
                    style:
                        theme.bodyMedium?.copyWith(
                          color: theme.sidebarForeground,
                          fontWeight:
                              (settings.ttsEngine == TtsEngine.server
                                  ? settings.ttsServerVoiceId == null
                                  : settings.ttsVoice == null)
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ) ??
                        TextStyle(color: theme.sidebarForeground),
                  ),
                  trailing:
                      (settings.ttsEngine == TtsEngine.server
                          ? settings.ttsServerVoiceId == null
                          : settings.ttsVoice == null)
                      ? Icon(
                          Platform.isIOS
                              ? CupertinoIcons.check_mark
                              : Icons.check,
                          color: theme.buttonPrimary,
                        )
                      : null,
                  onTap: () {
                    final notifier = ref.read(appSettingsProvider.notifier);
                    if (settings.ttsEngine == TtsEngine.server) {
                      notifier.setTtsServerVoiceId(null);
                      notifier.setTtsServerVoiceName(null);
                    } else {
                      notifier.setTtsVoice(null);
                    }
                    Navigator.of(sheetContext).pop();
                  },
                ),
                const Divider(height: 1),
                // Voices List
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount:
                        voices.length +
                        (matchingVoices.isNotEmpty && otherVoices.isNotEmpty
                            ? 2
                            : 0),
                    itemBuilder: (context, index) {
                      // Show section header for matching voices
                      if (index == 0 &&
                          matchingVoices.isNotEmpty &&
                          otherVoices.isNotEmpty) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                          child: Text(
                            l10n.ttsVoicesForLanguage(
                              appLanguageCode.toUpperCase(),
                            ),
                            style:
                                theme.bodySmall?.copyWith(
                                  color: theme.sidebarForeground.withValues(
                                    alpha: 0.75,
                                  ),
                                  fontWeight: FontWeight.bold,
                                ) ??
                                TextStyle(
                                  color: theme.sidebarForeground.withValues(
                                    alpha: 0.75,
                                  ),
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                        );
                      }

                      // Show section header for other voices
                      if (index == matchingVoices.length + 1 &&
                          matchingVoices.isNotEmpty &&
                          otherVoices.isNotEmpty) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                          child: Text(
                            l10n.ttsOtherVoices,
                            style:
                                theme.bodySmall?.copyWith(
                                  color: theme.sidebarForeground.withValues(
                                    alpha: 0.75,
                                  ),
                                  fontWeight: FontWeight.bold,
                                ) ??
                                TextStyle(
                                  color: theme.sidebarForeground.withValues(
                                    alpha: 0.75,
                                  ),
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                        );
                      }

                      // Adjust index for headers
                      int voiceIndex = index;
                      if (matchingVoices.isNotEmpty && otherVoices.isNotEmpty) {
                        if (index == 0) return const SizedBox.shrink();
                        if (index <= matchingVoices.length) {
                          voiceIndex = index - 1;
                        } else {
                          voiceIndex = index - 2;
                        }
                      }

                      final voice = voices[voiceIndex];
                      final voiceId = _getVoiceIdentifier(voice);
                      final displayName = _formatVoiceName(voice);
                      final subtitle = _getVoiceSubtitle(voice);
                      final isSelected = settings.ttsEngine == TtsEngine.server
                          ? settings.ttsServerVoiceId == voiceId
                          : settings.ttsVoice == voiceId;

                      return AdaptiveListTile(
                        leading: Icon(
                          UiUtils.platformIcon(
                            ios: CupertinoIcons.person_fill,
                            android: Icons.person,
                          ),
                          color: theme.sidebarForeground,
                        ),
                        title: Text(
                          displayName,
                          style:
                              theme.bodyMedium?.copyWith(
                                color: theme.sidebarForeground,
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ) ??
                              TextStyle(color: theme.sidebarForeground),
                        ),
                        subtitle: subtitle.isNotEmpty
                            ? Text(
                                subtitle,
                                style:
                                    theme.bodySmall?.copyWith(
                                      color: theme.sidebarForeground.withValues(
                                        alpha: 0.75,
                                      ),
                                    ) ??
                                    TextStyle(
                                      color: theme.sidebarForeground.withValues(
                                        alpha: 0.75,
                                      ),
                                      fontSize: 12,
                                    ),
                              )
                            : null,
                        trailing: isSelected
                            ? Icon(
                                Platform.isIOS
                                    ? CupertinoIcons.check_mark
                                    : Icons.check,
                                color: theme.buttonPrimary,
                              )
                            : null,
                        onTap: () {
                          final notifier = ref.read(
                            appSettingsProvider.notifier,
                          );
                          if (settings.ttsEngine == TtsEngine.server) {
                            notifier.setTtsServerVoiceId(voiceId);
                            notifier.setTtsServerVoiceName(displayName);
                          } else {
                            notifier.setTtsVoice(voiceId);
                          }
                          Navigator.of(sheetContext).pop();
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _previewTtsVoice(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;

    try {
      final ttsController = ref.read(textToSpeechControllerProvider.notifier);

      // Try to read the state, but handle if provider is in error
      TextToSpeechState? ttsState;
      try {
        ttsState = ref.read(textToSpeechControllerProvider);
      } catch (_) {
        // Provider is in error state, proceed anyway to initialize it
        ttsState = null;
      }

      // Don't preview if already speaking
      if (ttsState != null && (ttsState.isSpeaking || ttsState.isBusy)) {
        await ttsController.stop();
        return;
      }

      // Use the preview text from localization
      await ttsController.toggleForMessage(
        messageId: 'tts_preview',
        text: l10n.ttsPreviewText,
      );
    } catch (e) {
      if (!context.mounted) return;
      AdaptiveSnackBar.show(
        context,
        message: l10n.errorWithMessage(e.toString()),
        type: AdaptiveSnackBarType.error,
      );
    }
  }

  String _getDisplayVoiceName(String? voiceName, String defaultLabel) {
    if (voiceName == null || voiceName.isEmpty) {
      return defaultLabel;
    }

    // Format Android-style voice names with # separator
    if (voiceName.contains('#')) {
      final parts = voiceName.split('#');
      if (parts.length > 1) {
        var friendlyName = parts[1]
            .replaceAll('-local', '')
            .replaceAll('-network', '')
            .replaceAll('_', ' ')
            .split(' ')
            .map(
              (word) =>
                  word.isEmpty ? '' : word[0].toUpperCase() + word.substring(1),
            )
            .join(' ');

        final localeInfo = parts[0].toUpperCase().replaceAll('_', '-');
        return '$localeInfo - $friendlyName';
      }
    }

    // Handle Android-style voice IDs without # (e.g., "es-us-x-sfb-local")
    if (voiceName.contains('-x-') ||
        voiceName.endsWith('-local') ||
        voiceName.endsWith('-network') ||
        voiceName.endsWith('-language')) {
      var localePart = '';
      var qualityPart = '';

      if (voiceName.contains('-x-')) {
        final xParts = voiceName.split('-x-');
        localePart = xParts[0];
        qualityPart = xParts.length > 1 ? xParts[1] : '';
      } else if (voiceName.contains('-language')) {
        localePart = voiceName.replaceAll('-language', '');
      } else {
        final dashIndex = voiceName.indexOf('-', 3);
        if (dashIndex > 0) {
          localePart = voiceName.substring(0, dashIndex);
        } else {
          localePart = voiceName;
        }
      }

      final formattedLocale = localePart.toUpperCase();

      if (qualityPart.isNotEmpty) {
        qualityPart = qualityPart
            .replaceAll('-local', '')
            .replaceAll('-network', '')
            .toUpperCase();
        return '$formattedLocale ($qualityPart)';
      }

      return formattedLocale;
    }

    // For iOS or other platforms with proper names, return as-is
    return voiceName;
  }

  String _formatVoiceName(Map<String, dynamic> voice) {
    final name = voice['name'] as String? ?? 'Unknown';
    final locale = voice['locale'] as String? ?? '';

    // Handle Android-style voice IDs with # separator (e.g., "en-us-x-sfg#male_1-local")
    if (name.contains('#')) {
      final parts = name.split('#');
      if (parts.length > 1) {
        var friendlyName = parts[1]
            .replaceAll('-local', '')
            .replaceAll('-network', '')
            .replaceAll('_', ' ')
            .split(' ')
            .map(
              (word) =>
                  word.isEmpty ? '' : word[0].toUpperCase() + word.substring(1),
            )
            .join(' ');

        if (locale.isNotEmpty) {
          final localeUpper = locale.toUpperCase().replaceAll('_', '-');
          return '$localeUpper - $friendlyName';
        }
        return friendlyName;
      }
    }

    // Handle Android-style voice IDs without # (e.g., "es-us-x-sfb-local", "ja-jp-x-htm-network")
    if (name.contains('-x-') ||
        name.endsWith('-local') ||
        name.endsWith('-network') ||
        name.endsWith('-language')) {
      // Extract the main locale part (first 2-5 chars before -x- or other markers)
      var localePart = '';
      var qualityPart = '';

      if (name.contains('-x-')) {
        final xParts = name.split('-x-');
        localePart = xParts[0];
        qualityPart = xParts.length > 1 ? xParts[1] : '';
      } else if (name.contains('-language')) {
        localePart = name.replaceAll('-language', '');
      } else {
        // Try to extract locale (first 5 chars like "es-us" or "ja-jp")
        final dashIndex = name.indexOf('-', 3);
        if (dashIndex > 0) {
          localePart = name.substring(0, dashIndex);
        } else {
          localePart = name;
        }
      }

      // Format the locale part
      final formattedLocale = localePart.toUpperCase();

      // Format quality indicators
      if (qualityPart.isNotEmpty) {
        qualityPart = qualityPart
            .replaceAll('-local', '')
            .replaceAll('-network', '')
            .toUpperCase();
        return '$formattedLocale ($qualityPart)';
      }

      return formattedLocale;
    }

    // For iOS or other platforms with proper names, return as-is
    return name;
  }

  String _getVoiceIdentifier(Map<String, dynamic> voice) {
    // Use name as the unique identifier (this is what we set in settings)
    return voice['name'] as String? ??
        voice['identifier'] as String? ??
        voice['id'] as String? ??
        'unknown';
  }

  String _getVoiceSubtitle(Map<String, dynamic> voice) {
    final locale = voice['locale'] as String? ?? '';
    final name = voice['name'] as String? ?? '';

    // If name contains technical info, show the locale part
    if (name.contains('#')) {
      final parts = name.split('#');
      if (parts.isNotEmpty) {
        final localeInfo = parts[0].toUpperCase().replaceAll('_', '-');
        return localeInfo;
      }
    }

    return locale.isNotEmpty ? locale : '';
  }

  String _resolveLanguageLabel(BuildContext context, String code) {
    final normalizedCode = code.replaceAll('_', '-');

    switch (code) {
      case 'en':
        return AppLocalizations.of(context)!.english;
      case 'de':
        return AppLocalizations.of(context)!.deutsch;
      case 'fr':
        return AppLocalizations.of(context)!.francais;
      case 'it':
        return AppLocalizations.of(context)!.italiano;
      case 'es':
        return AppLocalizations.of(context)!.espanol;
      case 'nl':
        return AppLocalizations.of(context)!.nederlands;
      case 'ru':
        return AppLocalizations.of(context)!.russian;
      case 'zh':
        return AppLocalizations.of(context)!.chineseSimplified;
      case 'ko':
        return AppLocalizations.of(context)!.korean;
      case 'zh-Hant':
        return AppLocalizations.of(context)!.chineseTraditional;
      default:
        if (normalizedCode == 'zh-hant') {
          return AppLocalizations.of(context)!.chineseTraditional;
        }
        if (normalizedCode == 'zh') {
          return AppLocalizations.of(context)!.chineseSimplified;
        }
        if (normalizedCode == 'ko') {
          return AppLocalizations.of(context)!.korean;
        }
        return AppLocalizations.of(context)!.system;
    }
  }

  Future<void> _showTransportModeSheet(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings, {
    required bool allowPolling,
    required bool allowWebsocketOnly,
  }) async {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    var current = settings.socketTransportMode;

    final options = <({String value, String title, String subtitle})>[];
    if (allowPolling) {
      options.add((
        value: 'polling',
        title: l10n.transportModePolling,
        subtitle: l10n.transportModePollingInfo,
      ));
    }
    if (allowWebsocketOnly) {
      options.add((
        value: 'ws',
        title: l10n.transportModeWs,
        subtitle: l10n.transportModeWsInfo,
      ));
    }

    if (options.isEmpty) {
      return;
    }

    if (!options.any((option) => option.value == current)) {
      current = options.first.value;
    }

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.sidebarBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.modal),
        ),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SheetHeader(
                title: l10n.transportMode,
                onClose: () => Navigator.of(sheetContext).pop(),
              ),
              const Divider(height: 1),
              for (var i = 0; i < options.length; i++) ...[
                () {
                  final option = options[i];
                  final selected = current == option.value;
                  return AdaptiveListTile(
                    leading: Icon(
                      selected
                          ? (Platform.isIOS
                                ? CupertinoIcons.checkmark_circle_fill
                                : Icons.check_circle)
                          : (Platform.isIOS
                                ? CupertinoIcons.circle
                                : Icons.circle_outlined),
                      color: selected
                          ? theme.buttonPrimary
                          : theme.iconSecondary,
                    ),
                    title: Text(option.title),
                    subtitle: Text(option.subtitle),
                    onTap: () {
                      if (!selected) {
                        ref
                            .read(appSettingsProvider.notifier)
                            .setSocketTransportMode(option.value);
                      }
                      Navigator.of(sheetContext).pop();
                    },
                  );
                }(),
                if (i != options.length - 1) const Divider(height: 1),
              ],
              const SizedBox(height: Spacing.lg),
            ],
          ),
        );
      },
    );
  }

  Widget _buildValueBadge(BuildContext context, String label) {
    final theme = context.conduitTheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.xs,
      ),
      decoration: BoxDecoration(
        color: theme.buttonPrimary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppBorderRadius.small),
        border: Border.all(
          color: theme.buttonPrimary.withValues(alpha: 0.25),
          width: BorderWidth.thin,
        ),
      ),
      child: Text(
        label,
        style:
            theme.bodySmall?.copyWith(
              color: theme.buttonPrimary,
              fontWeight: FontWeight.w600,
            ) ??
            TextStyle(
              color: theme.buttonPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 12,
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

  Future<void> _showPaletteSelectorSheet(
    BuildContext context,
    WidgetRef ref,
    String activePaletteId,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final palettes = TweakcnThemes.all;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.sidebarBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.modal),
        ),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SheetHeader(
                title: l10n.themePalette,
                onClose: () => Navigator.of(sheetContext).pop(),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: palettes.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final palette = palettes[index];
                    final isSelected = palette.id == activePaletteId;
                    return AdaptiveListTile(
                      leading: Icon(
                        isSelected
                            ? (Platform.isIOS
                                  ? CupertinoIcons.checkmark_circle_fill
                                  : Icons.check_circle)
                            : (Platform.isIOS
                                  ? CupertinoIcons.circle
                                  : Icons.circle_outlined),
                        color: isSelected
                            ? theme.buttonPrimary
                            : theme.iconSecondary,
                      ),
                      title: Text(palette.label(l10n)),
                      subtitle: Text(palette.description(l10n)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final color in palette.preview.take(3))
                            _PaletteColorDot(color: color),
                        ],
                      ),
                      onTap: () async {
                        await ref
                            .read(appThemePaletteProvider.notifier)
                            .setPalette(palette.id);
                        if (!sheetContext.mounted) return;
                        Navigator.of(sheetContext).pop();
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: Spacing.sm),
            ],
          ),
        );
      },
    );
  }

  Future<String?> _showLanguageSelector(BuildContext context, String current) {
    final normalizedCurrent = current.replaceAll('_', '-');

    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => Container(
        decoration: BoxDecoration(
          color: sheetContext.sidebarTheme.background,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppBorderRadius.modal),
          ),
          boxShadow: ConduitShadows.modal(sheetContext),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SheetHeader(
                title: AppLocalizations.of(sheetContext)!.appLanguage,
                onClose: () => Navigator.of(sheetContext).pop(),
              ),
              const Divider(height: 1),
              AdaptiveListTile(
                title: Text(AppLocalizations.of(sheetContext)!.system),
                trailing: normalizedCurrent == 'system'
                    ? Icon(
                        Platform.isIOS
                            ? CupertinoIcons.check_mark
                            : Icons.check,
                      )
                    : null,
                onTap: () => Navigator.pop(sheetContext, 'system'),
              ),
              AdaptiveListTile(
                title: Text(AppLocalizations.of(sheetContext)!.english),
                trailing: normalizedCurrent == 'en'
                    ? Icon(
                        Platform.isIOS
                            ? CupertinoIcons.check_mark
                            : Icons.check,
                      )
                    : null,
                onTap: () => Navigator.pop(sheetContext, 'en'),
              ),
              AdaptiveListTile(
                title: Text(AppLocalizations.of(sheetContext)!.deutsch),
                trailing: normalizedCurrent == 'de'
                    ? Icon(
                        Platform.isIOS
                            ? CupertinoIcons.check_mark
                            : Icons.check,
                      )
                    : null,
                onTap: () => Navigator.pop(sheetContext, 'de'),
              ),
              AdaptiveListTile(
                title: Text(AppLocalizations.of(sheetContext)!.espanol),
                trailing: normalizedCurrent == 'es'
                    ? Icon(
                        Platform.isIOS
                            ? CupertinoIcons.check_mark
                            : Icons.check,
                      )
                    : null,
                onTap: () => Navigator.pop(sheetContext, 'es'),
              ),
              AdaptiveListTile(
                title: Text(AppLocalizations.of(sheetContext)!.francais),
                trailing: normalizedCurrent == 'fr'
                    ? Icon(
                        Platform.isIOS
                            ? CupertinoIcons.check_mark
                            : Icons.check,
                      )
                    : null,
                onTap: () => Navigator.pop(sheetContext, 'fr'),
              ),
              AdaptiveListTile(
                title: Text(AppLocalizations.of(sheetContext)!.italiano),
                trailing: normalizedCurrent == 'it'
                    ? Icon(
                        Platform.isIOS
                            ? CupertinoIcons.check_mark
                            : Icons.check,
                      )
                    : null,
                onTap: () => Navigator.pop(sheetContext, 'it'),
              ),
              AdaptiveListTile(
                title: Text(AppLocalizations.of(sheetContext)!.nederlands),
                trailing: normalizedCurrent == 'nl'
                    ? Icon(
                        Platform.isIOS
                            ? CupertinoIcons.check_mark
                            : Icons.check,
                      )
                    : null,
                onTap: () => Navigator.pop(sheetContext, 'nl'),
              ),
              AdaptiveListTile(
                title: Text(AppLocalizations.of(sheetContext)!.russian),
                trailing: normalizedCurrent == 'ru'
                    ? Icon(
                        Platform.isIOS
                            ? CupertinoIcons.check_mark
                            : Icons.check,
                      )
                    : null,
                onTap: () => Navigator.pop(sheetContext, 'ru'),
              ),
              AdaptiveListTile(
                title: Text(
                  AppLocalizations.of(sheetContext)!.chineseSimplified,
                ),
                trailing: normalizedCurrent == 'zh'
                    ? Icon(
                        Platform.isIOS
                            ? CupertinoIcons.check_mark
                            : Icons.check,
                      )
                    : null,
                onTap: () => Navigator.pop(sheetContext, 'zh'),
              ),
              AdaptiveListTile(
                title: Text(
                  AppLocalizations.of(sheetContext)!.chineseTraditional,
                ),
                trailing: normalizedCurrent == 'zh-Hant'
                    ? Icon(
                        Platform.isIOS
                            ? CupertinoIcons.check_mark
                            : Icons.check,
                      )
                    : null,
                onTap: () => Navigator.pop(sheetContext, 'zh-Hant'),
              ),
              AdaptiveListTile(
                title: Text(AppLocalizations.of(sheetContext)!.korean),
                trailing: normalizedCurrent == 'ko'
                    ? Icon(
                        Platform.isIOS
                            ? CupertinoIcons.check_mark
                            : Icons.check,
                      )
                    : null,
                onTap: () => Navigator.pop(sheetContext, 'ko'),
              ),
              const SizedBox(height: Spacing.sm),
            ],
          ),
        ),
      ),
    );
  }
}

Locale? _parseLocaleTag(String code) {
  final normalized = code.replaceAll('_', '-');
  final parts = normalized.split('-');
  if (parts.isEmpty || parts.first.isEmpty) return null;

  final language = parts.first;
  String? script;
  String? country;

  for (var i = 1; i < parts.length; i++) {
    final part = parts[i];
    if (part.length == 4) {
      script = '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}';
    } else if (part.length == 2 || part.length == 3) {
      country = part.toUpperCase();
    }
  }

  return Locale.fromSubtags(
    languageCode: language,
    scriptCode: script,
    countryCode: country,
  );
}

class _PaletteColorDot extends StatelessWidget {
  const _PaletteColorDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Container(
      margin: const EdgeInsets.only(right: Spacing.xs),
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.3),
          width: BorderWidth.thin,
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Text(
      title,
      style:
          theme.headingSmall?.copyWith(color: theme.sidebarForeground) ??
          TextStyle(color: theme.sidebarForeground, fontSize: 18),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.title, required this.onClose});

  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style:
                  theme.headingSmall?.copyWith(
                    color: theme.sidebarForeground,
                  ) ??
                  TextStyle(
                    color: theme.sidebarForeground,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          IconButton(
            onPressed: onClose,
            icon: Icon(
              Platform.isIOS ? CupertinoIcons.xmark : Icons.close,
              color: theme.iconPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _AdaptiveSegmentedSelector<T extends Object> extends StatelessWidget {
  const _AdaptiveSegmentedSelector({
    required this.value,
    required this.onChanged,
    required this.options,
  });

  final T value;
  final ValueChanged<T> onChanged;
  final List<
    ({
      T value,
      String label,
      IconData cupertinoIcon,
      IconData materialIcon,
      bool enabled,
    })
  >
  options;

  @override
  Widget build(BuildContext context) {
    final isCupertino =
        Platform.isIOS || Theme.of(context).platform == TargetPlatform.macOS;

    if (isCupertino) {
      return CupertinoSlidingSegmentedControl<T>(
        groupValue: value,
        disabledChildren: {
          for (final option in options)
            if (!option.enabled) option.value,
        },
        onValueChanged: (next) {
          if (next == null) return;
          final selected = options.any(
            (option) => option.value == next && option.enabled,
          );
          if (selected) {
            onChanged(next);
          }
        },
        children: {
          for (final option in options)
            option.value: _ThemeModeSegmentLabel(
              icon: option.cupertinoIcon,
              label: option.label,
            ),
        },
      );
    }

    return SegmentedButton<T>(
      selected: {value},
      showSelectedIcon: false,
      segments: [
        for (final option in options)
          ButtonSegment<T>(
            value: option.value,
            icon: Icon(option.materialIcon),
            label: Text(option.label),
            enabled: option.enabled,
          ),
      ],
      onSelectionChanged: (selection) {
        if (selection.isEmpty) return;
        final next = selection.first;
        final selected = options.any(
          (option) => option.value == next && option.enabled,
        );
        if (selected) {
          onChanged(next);
        }
      },
    );
  }
}

class _ThemeModeSegmentedControl extends StatelessWidget {
  const _ThemeModeSegmentedControl({
    required this.value,
    required this.onChanged,
  });

  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isCupertino =
        Platform.isIOS || Theme.of(context).platform == TargetPlatform.macOS;

    if (isCupertino) {
      return CupertinoSlidingSegmentedControl<ThemeMode>(
        groupValue: value,
        onValueChanged: (next) {
          if (next != null) {
            onChanged(next);
          }
        },
        children: {
          ThemeMode.system: _ThemeModeSegmentLabel(
            icon: CupertinoIcons.sparkles,
            label: l10n.system,
          ),
          ThemeMode.light: _ThemeModeSegmentLabel(
            icon: CupertinoIcons.sun_max,
            label: l10n.themeLight,
          ),
          ThemeMode.dark: _ThemeModeSegmentLabel(
            icon: CupertinoIcons.moon_fill,
            label: l10n.themeDark,
          ),
        },
      );
    }

    return SegmentedButton<ThemeMode>(
      selected: {value},
      segments: [
        ButtonSegment<ThemeMode>(
          value: ThemeMode.system,
          icon: const Icon(Icons.auto_mode),
          label: Text(l10n.system),
        ),
        ButtonSegment<ThemeMode>(
          value: ThemeMode.light,
          icon: const Icon(Icons.light_mode),
          label: Text(l10n.themeLight),
        ),
        ButtonSegment<ThemeMode>(
          value: ThemeMode.dark,
          icon: const Icon(Icons.dark_mode),
          label: Text(l10n.themeDark),
        ),
      ],
      showSelectedIcon: false,
      onSelectionChanged: (selection) {
        if (selection.isNotEmpty) {
          onChanged(selection.first);
        }
      },
    );
  }
}

class _ThemeModeSegmentLabel extends StatelessWidget {
  const _ThemeModeSegmentLabel({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.xs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: IconSize.small),
          const SizedBox(width: Spacing.xs),
          Text(label),
        ],
      ),
    );
  }
}

class _CustomizationTile extends StatelessWidget {
  const _CustomizationTile({
    required this.leading,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
    this.showChevron = true,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return ConduitCard(
      padding: const EdgeInsets.all(Spacing.md),
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          leading,
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.bodyMedium?.copyWith(
                    color: theme.sidebarForeground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  subtitle,
                  style: theme.bodySmall?.copyWith(
                    color: theme.sidebarForeground.withValues(alpha: 0.75),
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: Spacing.sm),
            trailing!,
          ] else if (showChevron && onTap != null) ...[
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
        ],
      ),
    );
  }
}

/// Expandable card widget for collapsible settings sections.
class _ExpandableCard extends StatefulWidget {
  const _ExpandableCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.child,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Widget child;

  @override
  State<_ExpandableCard> createState() => _ExpandableCardState();
}

class _ExpandableCardState extends State<_ExpandableCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _rotationAnimation;
  bool _isExpanded = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _rotationAnimation = Tween<double>(begin: 0, end: 0.5).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() {
      _isExpanded = !_isExpanded;
    });
    if (_isExpanded) {
      _animationController.forward();
    } else {
      _animationController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return ConduitCard(
      padding: EdgeInsets.zero,
      onTap: _toggle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Icon badge
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: theme.buttonPrimary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(AppBorderRadius.small),
                    border: Border.all(
                      color: theme.buttonPrimary.withValues(alpha: 0.2),
                      width: BorderWidth.thin,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    widget.icon,
                    color: theme.buttonPrimary,
                    size: IconSize.medium,
                  ),
                ),
                const SizedBox(width: Spacing.md),
                // Title and subtitle
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: theme.bodyMedium?.copyWith(
                          color: theme.sidebarForeground,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: Spacing.xs),
                      Text(
                        widget.subtitle,
                        style: theme.bodySmall?.copyWith(
                          color: theme.sidebarForeground.withValues(
                            alpha: 0.75,
                          ),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                // Expand/collapse icon
                RotationTransition(
                  turns: _rotationAnimation,
                  child: Icon(
                    UiUtils.platformIcon(
                      ios: CupertinoIcons.chevron_down,
                      android: Icons.expand_more,
                    ),
                    color: theme.iconSecondary,
                    size: IconSize.small,
                  ),
                ),
              ],
            ),
          ),
          // Expandable content
          if (_isExpanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: widget.child,
            ),
          ],
        ],
      ),
    );
  }
}

/// Widget that displays socket connection health with real-time updates.
class _SocketHealthCard extends StatefulWidget {
  const _SocketHealthCard({required this.socketService});

  final SocketService socketService;

  @override
  State<_SocketHealthCard> createState() => _SocketHealthCardState();
}

class _SocketHealthCardState extends State<_SocketHealthCard> {
  SocketHealth? _health;
  StreamSubscription<SocketHealth>? _subscription;

  @override
  void initState() {
    super.initState();
    _initHealth();
  }

  void _initHealth() {
    _health = widget.socketService.currentHealth;
    _subscription = widget.socketService.healthStream.listen((health) {
      if (mounted) {
        setState(() => _health = health);
      }
    });
  }

  @override
  void didUpdateWidget(covariant _SocketHealthCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.socketService != widget.socketService) {
      _subscription?.cancel();
      _initHealth();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final health = _health;

    if (health == null) {
      return ConduitCard(
        padding: const EdgeInsets.all(Spacing.md),
        child: Row(
          children: [
            Icon(
              Icons.cloud_off,
              color: theme.iconSecondary,
              size: IconSize.medium,
            ),
            const SizedBox(width: Spacing.md),
            Text(
              'Not connected',
              style: theme.bodyMedium?.copyWith(color: theme.textSecondary),
            ),
          ],
        ),
      );
    }

    final statusColor = health.isConnected ? theme.success : theme.error;
    final qualityColor = _getQualityColor(theme, health.quality);

    return ConduitCard(
      padding: const EdgeInsets.all(Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Connection Status Row
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppBorderRadius.small),
                  border: Border.all(
                    color: statusColor.withValues(alpha: 0.2),
                    width: BorderWidth.thin,
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(
                  health.isConnected ? Icons.cloud_done : Icons.cloud_off,
                  color: statusColor,
                  size: IconSize.medium,
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      health.isConnected ? 'Connected' : 'Disconnected',
                      style: theme.bodyMedium?.copyWith(
                        color: theme.sidebarForeground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: Spacing.xxs),
                    Text(
                      _getTransportLabel(health.transport),
                      style: theme.bodySmall?.copyWith(
                        color: theme.sidebarForeground.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ),
              ),
              // Connection quality indicator
              if (health.isConnected && health.hasLatencyInfo)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.sm,
                    vertical: Spacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: qualityColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(AppBorderRadius.small),
                    border: Border.all(
                      color: qualityColor.withValues(alpha: 0.3),
                      width: BorderWidth.thin,
                    ),
                  ),
                  child: Text(
                    _getQualityLabel(health.quality),
                    style: theme.bodySmall?.copyWith(
                      color: qualityColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          if (health.isConnected) ...[
            const SizedBox(height: Spacing.md),
            const Divider(height: 1),
            const SizedBox(height: Spacing.md),
            // Metrics Grid
            Row(
              children: [
                Expanded(
                  child: _MetricTile(
                    icon: Icons.speed,
                    label: 'Latency',
                    value: health.hasLatencyInfo
                        ? '${health.latencyMs}ms'
                        : '—',
                    color: qualityColor,
                  ),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: _MetricTile(
                    icon: Icons.refresh,
                    label: 'Reconnects',
                    value: '${health.reconnectCount}',
                    color: health.reconnectCount > 0
                        ? theme.warning
                        : theme.success,
                  ),
                ),
              ],
            ),
            if (health.lastHeartbeat != null) ...[
              const SizedBox(height: Spacing.md),
              Row(
                children: [
                  Icon(
                    Icons.favorite,
                    color: theme.error.withValues(alpha: 0.7),
                    size: IconSize.small,
                  ),
                  const SizedBox(width: Spacing.xs),
                  Text(
                    'Last heartbeat: ${_formatLastHeartbeat(health.lastHeartbeat!)}',
                    style: theme.bodySmall?.copyWith(
                      color: theme.sidebarForeground.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  String _getTransportLabel(String transport) {
    switch (transport) {
      case 'websocket':
        return 'WebSocket transport';
      case 'polling':
        return 'HTTP polling transport';
      default:
        return 'Unknown transport';
    }
  }

  String _getQualityLabel(String quality) {
    switch (quality) {
      case 'excellent':
        return 'Excellent';
      case 'good':
        return 'Good';
      case 'fair':
        return 'Fair';
      case 'poor':
        return 'Poor';
      default:
        return '—';
    }
  }

  Color _getQualityColor(ConduitThemeExtension theme, String quality) {
    switch (quality) {
      case 'excellent':
        return theme.success;
      case 'good':
        return theme.success.withValues(alpha: 0.8);
      case 'fair':
        return theme.warning;
      case 'poor':
        return theme.error;
      default:
        return theme.textSecondary;
    }
  }

  String _formatLastHeartbeat(DateTime lastHeartbeat) {
    final now = DateTime.now();
    final diff = now.difference(lastHeartbeat);

    if (diff.inSeconds < 5) {
      return 'just now';
    } else if (diff.inSeconds < 60) {
      return '${diff.inSeconds}s ago';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else {
      return '${diff.inHours}h ago';
    }
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return Container(
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: theme.cardBackground.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppBorderRadius.small),
        border: Border.all(
          color: theme.cardBorder.withValues(alpha: 0.3),
          width: BorderWidth.thin,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: IconSize.small),
          const SizedBox(width: Spacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.bodySmall?.copyWith(
                    color: theme.textSecondary,
                    fontSize: 10,
                  ),
                ),
                Text(
                  value,
                  style: theme.bodyMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
