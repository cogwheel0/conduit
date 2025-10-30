import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

class AppCustomizationPage extends ConsumerWidget {
  const AppCustomizationPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final themeMode = ref.watch(appThemeModeProvider);
    final platformBrightness = MediaQuery.platformBrightnessOf(context);
    final themeDescription = () {
      if (themeMode == ThemeMode.system) {
        final systemThemeLabel = platformBrightness == Brightness.dark
            ? AppLocalizations.of(context)!.themeDark
            : AppLocalizations.of(context)!.themeLight;
        return AppLocalizations.of(context)!.followingSystem(systemThemeLabel);
      }
      if (themeMode == ThemeMode.dark) {
        return AppLocalizations.of(context)!.currentlyUsingDarkTheme;
      }
      return AppLocalizations.of(context)!.currentlyUsingLightTheme;
    }();
    final locale = ref.watch(appLocaleProvider);
    final currentLanguageCode = locale?.languageCode ?? 'system';
    final languageLabel = _resolveLanguageLabel(context, currentLanguageCode);
    final activeTheme = ref.watch(appThemePaletteProvider);

    return Scaffold(
      backgroundColor: context.sidebarTheme.background,
      appBar: _buildAppBar(context),
      body: SafeArea(
        child: ListView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.pagePadding,
            vertical: Spacing.pagePadding,
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
            const SizedBox(height: Spacing.md),
            _buildLanguageSection(
              context,
              ref,
              currentLanguageCode,
              languageLabel,
            ),
            const SizedBox(height: Spacing.xl),
            _buildTtsDropdownSection(context, ref, settings),
            const SizedBox(height: Spacing.xl),
            _buildChatSection(context, ref, settings),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    return AppBar(
      backgroundColor: context.sidebarTheme.background,
      surfaceTintColor: Colors.transparent,
      elevation: Elevation.none,
      toolbarHeight: kToolbarHeight,
      automaticallyImplyLeading: false,
      leading: canPop
          ? IconButton(
              icon: Icon(
                UiUtils.platformIcon(
                  ios: CupertinoIcons.back,
                  android: Icons.arrow_back,
                ),
                color: context.conduitTheme.iconPrimary,
              ),
              onPressed: () => Navigator.of(context).maybePop(),
              tooltip: AppLocalizations.of(context)!.back,
            )
          : null,
      titleSpacing: 0,
      title: Text(
        AppLocalizations.of(context)!.appCustomization,
        style: AppTypography.headlineSmallStyle.copyWith(
          color: context.conduitTheme.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      centerTitle: true,
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
    final theme = context.conduitTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppLocalizations.of(context)!.display,
          style:
              theme.headingSmall?.copyWith(color: theme.sidebarForeground) ??
              TextStyle(color: theme.sidebarForeground, fontSize: 18),
        ),
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
              Wrap(
                spacing: Spacing.sm,
                runSpacing: Spacing.sm,
                children: [
                  _buildThemeChip(
                    context,
                    ref,
                    mode: ThemeMode.system,
                    isSelected: themeMode == ThemeMode.system,
                    label: AppLocalizations.of(context)!.system,
                    icon: UiUtils.platformIcon(
                      ios: CupertinoIcons.sparkles,
                      android: Icons.auto_mode,
                    ),
                  ),
                  _buildThemeChip(
                    context,
                    ref,
                    mode: ThemeMode.light,
                    isSelected: themeMode == ThemeMode.light,
                    label: AppLocalizations.of(context)!.themeLight,
                    icon: UiUtils.platformIcon(
                      ios: CupertinoIcons.sun_max,
                      android: Icons.light_mode,
                    ),
                  ),
                  _buildThemeChip(
                    context,
                    ref,
                    mode: ThemeMode.dark,
                    isSelected: themeMode == ThemeMode.dark,
                    label: AppLocalizations.of(context)!.themeDark,
                    icon: UiUtils.platformIcon(
                      ios: CupertinoIcons.moon_fill,
                      android: Icons.dark_mode,
                    ),
                  ),
                ],
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
    String currentLanguageCode,
    String languageLabel,
  ) {
    final theme = context.conduitTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
              currentLanguageCode,
            );
            if (selected == null) return;
            if (selected == 'system') {
              await ref.read(appLocaleProvider.notifier).setLocale(null);
            } else {
              await ref
                  .read(appLocaleProvider.notifier)
                  .setLocale(Locale(selected));
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
    final palettes = TweakcnThemes.all;

    return _ExpandableCard(
      title: AppLocalizations.of(context)!.themePalette,
      subtitle: activeTheme.label,
      icon: UiUtils.platformIcon(
        ios: CupertinoIcons.square_fill_on_square_fill,
        android: Icons.palette,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final palette in palettes)
            _PaletteOption(
              themeDefinition: palette,
              activeId: activeTheme.id,
              onSelect: () => ref
                  .read(appThemePaletteProvider.notifier)
                  .setPalette(palette.id),
            ),
        ],
      ),
    );
  }

  Widget _buildThemeChip(
    BuildContext context,
    WidgetRef ref, {
    required ThemeMode mode,
    required bool isSelected,
    required String label,
    required IconData icon,
  }) {
    return ConduitChip(
      label: label,
      icon: icon,
      isSelected: isSelected,
      onTap: () => ref.read(appThemeModeProvider.notifier).setTheme(mode),
    );
  }

  Widget _buildQuickPillsSection(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) {
    final selectedRaw = ref.watch(
      appSettingsProvider.select((s) => s.quickPills),
    );
    final toolsAsync = ref.watch(toolsListProvider);
    final tools = toolsAsync.maybeWhen(
      data: (value) => value,
      orElse: () => const <Tool>[],
    );
    final allowed = <String>{'web', 'image', ...tools.map((t) => t.id)};

    final selected = selectedRaw
        .where((id) => allowed.contains(id))
        .take(2)
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
        if (next.length >= 2) return;
        next.add(id);
      }
      await ref.read(appSettingsProvider.notifier).setQuickPills(next);
    }

    List<Widget> buildToolChips() {
      return tools.map((tool) {
        final isSelected = selected.contains(tool.id);
        final canSelect = selectedCount < 2 || isSelected;
        return ConduitChip(
          label: tool.name,
          icon: Icons.extension,
          isSelected: isSelected,
          onTap: canSelect ? () => toggle(tool.id) : null,
        );
      }).toList();
    }

    final l10n = AppLocalizations.of(context)!;
    final selectedCountText = selectedCount == 0
        ? 'No actions'
        : '$selectedCount action${selectedCount == 1 ? '' : 's'} selected';

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
          if (selected.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.md),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => ref
                      .read(appSettingsProvider.notifier)
                      .setQuickPills(const []),
                  child: Text(l10n.clear),
                ),
              ),
            ),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              ConduitChip(
                label: l10n.web,
                icon: Platform.isIOS ? CupertinoIcons.search : Icons.search,
                isSelected: selected.contains('web'),
                onTap: (selectedCount < 2 || selected.contains('web'))
                    ? () => toggle('web')
                    : null,
              ),
              ConduitChip(
                label: l10n.imageGen,
                icon: Platform.isIOS ? CupertinoIcons.photo : Icons.image,
                isSelected: selected.contains('image'),
                onTap: (selectedCount < 2 || selected.contains('image'))
                    ? () => toggle('image')
                    : null,
              ),
              ...buildToolChips(),
            ],
          ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.chatSettings,
          style:
              theme.headingSmall?.copyWith(color: theme.sidebarForeground) ??
              TextStyle(color: theme.sidebarForeground, fontSize: 18),
        ),
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
          trailing: Switch.adaptive(
            value: settings.sendOnEnter,
            onChanged: (value) =>
                ref.read(appSettingsProvider.notifier).setSendOnEnter(value),
          ),
          showChevron: false,
          onTap: () => ref
              .read(appSettingsProvider.notifier)
              .setSendOnEnter(!settings.sendOnEnter),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.ttsSettings,
          style:
              theme.headingSmall?.copyWith(color: theme.sidebarForeground) ??
              TextStyle(color: theme.sidebarForeground, fontSize: 18),
        ),
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
                  const SizedBox(width: Spacing.sm),
                  const Text('Engine'),
                  const Spacer(),
                  Wrap(
                    spacing: Spacing.sm,
                    children: [
                      ChoiceChip(
                        label: const Text('On Device'),
                        selected: settings.ttsEngine == TtsEngine.device,
                        showCheckmark: false,
                        selectedColor: theme.buttonPrimary,
                        backgroundColor: theme.cardBackground,
                        side: BorderSide(
                          color: settings.ttsEngine == TtsEngine.device
                              ? theme.buttonPrimary.withValues(alpha: 0.6)
                              : theme.textPrimary.withValues(alpha: 0.2),
                        ),
                        labelStyle: TextStyle(
                          color: settings.ttsEngine == TtsEngine.device
                              ? theme.buttonPrimaryText
                              : theme.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                        onSelected: (v) {
                          if (v) {
                            final notifier = ref.read(
                              appSettingsProvider.notifier,
                            );
                            notifier.setTtsEngine(TtsEngine.device);
                            // Keep previous voice (device voices)
                          }
                        },
                      ),
                      ChoiceChip(
                        label: const Text('Server'),
                        selected: settings.ttsEngine == TtsEngine.server,
                        showCheckmark: false,
                        selectedColor: theme.buttonPrimary,
                        backgroundColor: theme.cardBackground,
                        side: BorderSide(
                          color: settings.ttsEngine == TtsEngine.server
                              ? theme.buttonPrimary.withValues(alpha: 0.6)
                              : theme.textPrimary.withValues(alpha: 0.2),
                        ),
                        labelStyle: TextStyle(
                          color: settings.ttsEngine == TtsEngine.server
                              ? theme.buttonPrimaryText
                              : theme.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                        onSelected: (v) {
                          if (v) {
                            final notifier = ref.read(
                              appSettingsProvider.notifier,
                            );
                            // Clear device-specific voice so server can default
                            notifier.setTtsVoice(null);
                            notifier.setTtsEngine(TtsEngine.server);
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.sm),
        _ExpandableCard(
          title: l10n.ttsVoice,
          subtitle: _getDisplayVoiceName(
            settings.ttsEngine == TtsEngine.server
                ? ((settings.ttsServerVoiceName ?? settings.ttsServerVoiceId) ??
                      '')
                : (settings.ttsVoice ?? ''),
            l10n.ttsSystemDefault,
          ),
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
                subtitle: _getDisplayVoiceName(
                  settings.ttsEngine == TtsEngine.server
                      ? ((settings.ttsServerVoiceName ??
                                settings.ttsServerVoiceId) ??
                            '')
                      : (settings.ttsVoice ?? ''),
                  l10n.ttsSystemDefault,
                ),
                onTap: () => _showVoicePickerSheet(context, ref, settings),
              ),
              const SizedBox(height: Spacing.md),
              // Speech Rate Slider
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
                divisions: 7,
                label: '${(settings.ttsSpeechRate * 100).round()}%',
                onChanged: (value) => ref
                    .read(appSettingsProvider.notifier)
                    .setTtsSpeechRate(value),
              ),
              const SizedBox(height: Spacing.md),
              // Pitch Slider
              _buildSliderTile(
                context,
                ref,
                icon: UiUtils.platformIcon(
                  ios: CupertinoIcons.waveform,
                  android: Icons.graphic_eq,
                ),
                title: l10n.ttsPitch,
                value: settings.ttsPitch,
                min: 0.5,
                max: 2.0,
                divisions: 6,
                label: settings.ttsPitch.toStringAsFixed(1),
                onChanged: (value) =>
                    ref.read(appSettingsProvider.notifier).setTtsPitch(value),
              ),
              const SizedBox(height: Spacing.md),
              // Volume Slider
              _buildSliderTile(
                context,
                ref,
                icon: UiUtils.platformIcon(
                  ios: CupertinoIcons.volume_up,
                  android: Icons.volume_up,
                ),
                title: l10n.ttsVolume,
                value: settings.ttsVolume,
                min: 0.0,
                max: 1.0,
                divisions: 10,
                label: '${(settings.ttsVolume * 100).round()}%',
                onChanged: (value) =>
                    ref.read(appSettingsProvider.notifier).setTtsVolume(value),
              ),
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
          Slider(
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.ttsNoVoicesAvailable),
          backgroundColor: theme.error,
        ),
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
                // Header
                Padding(
                  padding: const EdgeInsets.all(Spacing.md),
                  child: Row(
                    children: [
                      Text(
                        l10n.ttsSelectVoice,
                        style:
                            theme.headingSmall?.copyWith(
                              color: theme.sidebarForeground,
                            ) ??
                            TextStyle(
                              color: theme.sidebarForeground,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: Icon(Icons.close, color: theme.iconPrimary),
                        onPressed: () => Navigator.of(sheetContext).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                // System Default Option
                ListTile(
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
                      ? Icon(Icons.check, color: theme.buttonPrimary)
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

                      return ListTile(
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
                            ? Icon(Icons.check, color: theme.buttonPrimary)
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
    final theme = context.conduitTheme;

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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${l10n.error}: $e'),
          backgroundColor: theme.error,
        ),
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
        return AppLocalizations.of(context)!.chinese;
      default:
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
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.lg,
                  vertical: Spacing.md,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.transportMode,
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
                      icon: Icon(Icons.close, color: theme.iconPrimary),
                      onPressed: () => Navigator.of(sheetContext).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              for (var i = 0; i < options.length; i++) ...[
                () {
                  final option = options[i];
                  final selected = current == option.value;
                  return ListTile(
                    leading: Icon(
                      selected ? Icons.check_circle : Icons.circle_outlined,
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

  Future<String?> _showLanguageSelector(BuildContext context, String current) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: context.sidebarTheme.background,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppBorderRadius.modal),
          ),
          boxShadow: ConduitShadows.modal(context),
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
                title: Text(AppLocalizations.of(context)!.espanol),
                trailing: current == 'es' ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, 'es'),
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
              ListTile(
                title: Text(AppLocalizations.of(context)!.nederlands),
                trailing: current == 'nl' ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, 'nl'),
              ),
              ListTile(
                title: Text(AppLocalizations.of(context)!.russian),
                trailing: current == 'ru' ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, 'ru'),
              ),
              ListTile(
                title: Text(AppLocalizations.of(context)!.chinese),
                trailing: current == 'zh' ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, 'zh'),
              ),
              const SizedBox(height: Spacing.sm),
            ],
          ),
        ),
      ),
    );
  }
}

class _PaletteOption extends StatelessWidget {
  const _PaletteOption({
    required this.themeDefinition,
    required this.activeId,
    required this.onSelect,
  });

  final TweakcnThemeDefinition themeDefinition;
  final String activeId;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final isSelected = themeDefinition.id == activeId;
    final previewColors = themeDefinition.preview;

    return InkWell(
      onTap: onSelect,
      borderRadius: BorderRadius.circular(AppBorderRadius.small),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: isSelected ? theme.buttonPrimary : theme.iconSecondary,
              size: IconSize.small,
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          themeDefinition.label,
                          style: theme.bodyMedium?.copyWith(
                            color: theme.sidebarForeground,
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isSelected)
                        Padding(
                          padding: const EdgeInsets.only(left: Spacing.xs),
                          child: Icon(
                            Icons.check_circle,
                            color: theme.buttonPrimary,
                            size: IconSize.small,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    themeDefinition.description,
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
                        ),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Row(
                    children: [
                      for (final color in previewColors)
                        _PaletteColorDot(color: color),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
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
