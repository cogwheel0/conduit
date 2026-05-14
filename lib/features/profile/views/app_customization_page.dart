import 'dart:async';
import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/model.dart';
import '../../../core/services/ios_native_dropdown_bridge.dart';
import '../../../core/services/native_sheet_bridge.dart';
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
import '../widgets/adaptive_segmented_selector.dart';
import '../widgets/customization_tile.dart';
import '../widgets/expandable_card.dart';
import '../widgets/settings_page_scaffold.dart';
import '../widgets/socket_health_card.dart';

const _sectionGap = SizedBox(height: Spacing.lg);

class AppCustomizationPage extends ConsumerWidget {
  const AppCustomizationPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    assert(() {
      _buildSttSection;
      _buildTtsDropdownSection;
      _buildPromptLoadingTile;
      _buildPromptErrorTile;
      _extractSystemPrompt;
      _showGlobalSystemPromptEditor;
      return true;
    }());

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

    return SettingsPageScaffold(
      title: l10n.appAndChat,
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
        _buildLanguageSection(context, ref, currentLanguageCode, languageLabel),
        _sectionGap,
        _buildChatSection(context, ref, settings),
        _sectionGap,
        _buildSystemPromptsSection(context, ref),
        _sectionGap,
        _buildSocketHealthSection(context, ref),
      ],
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
        ExpandableCard(
          title: AppLocalizations.of(context)!.darkMode,
          subtitle: themeDescription,
          icon: UiUtils.platformIcon(
            ios: CupertinoIcons.moon_stars,
            android: Icons.dark_mode,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ThemeModeSegmentedControl(
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
        CustomizationTile(
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

    return CustomizationTile(
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

    return ExpandableCard(
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
                        style: context.conduitTheme.bodyMedium?.copyWith(
                          color: context.conduitTheme.sidebarForeground,
                        ),
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
        CustomizationTile(
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
        CustomizationTile(
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
        const SizedBox(height: Spacing.sm),
        CustomizationTile(
          leading: _buildIconBadge(
            context,
            Icons.history_toggle_off,
            color: theme.buttonPrimary,
          ),
          title: l10n.temporaryChatByDefault,
          subtitle: l10n.temporaryChatByDefaultDescription,
          trailing: AdaptiveSwitch(
            value: settings.temporaryChatByDefault,
            onChanged: (value) => ref
                .read(appSettingsProvider.notifier)
                .setTemporaryChatByDefault(value),
          ),
          showChevron: false,
          onTap: () => ref
              .read(appSettingsProvider.notifier)
              .setTemporaryChatByDefault(!settings.temporaryChatByDefault),
        ),
        const SizedBox(height: Spacing.sm),
        CustomizationTile(
          leading: _buildIconBadge(
            context,
            Icons.vibration,
            color: theme.buttonPrimary,
          ),
          title: l10n.disableHapticsWhileStreaming,
          subtitle: l10n.disableHapticsWhileStreamingDescription,
          trailing: AdaptiveSwitch(
            value: settings.disableHapticsWhileStreaming,
            onChanged: (value) => ref
                .read(appSettingsProvider.notifier)
                .setDisableHapticsWhileStreaming(value),
          ),
          showChevron: false,
          onTap: () => ref
              .read(appSettingsProvider.notifier)
              .setDisableHapticsWhileStreaming(
                !settings.disableHapticsWhileStreaming,
              ),
        ),
        if (Platform.isAndroid) ...[
          const SizedBox(height: Spacing.sm),
          CustomizationTile(
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

  Widget _buildSystemPromptsSection(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final models = ref.watch(modelsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: l10n.advancedPromptOverrides),
        const SizedBox(height: Spacing.sm),
        ExpandableCard(
          title: l10n.modelSystemPrompts,
          subtitle: models.maybeWhen(
            data: (items) => l10n.accessibleModelsCount(items.length),
            orElse: () => l10n.openWebuiModelSettings,
          ),
          icon: UiUtils.platformIcon(
            ios: CupertinoIcons.cube_box,
            android: Icons.smart_toy_outlined,
          ),
          child: models.when(
            data: (items) => _buildModelPromptList(context, ref, items),
            loading: () => _buildCenteredProgress(),
            error: (_, _) =>
                _buildPromptErrorText(context, l10n.unableToLoadModels),
          ),
        ),
      ],
    );
  }

  Widget _buildModelPromptList(
    BuildContext context,
    WidgetRef ref,
    List<Model> models,
  ) {
    final l10n = AppLocalizations.of(context)!;
    if (models.isEmpty) {
      return _buildPromptErrorText(context, l10n.noAccessibleModelsFound);
    }

    return Column(
      children: [
        for (var i = 0; i < models.length; i++) ...[
          CustomizationTile(
            leading: _buildIconBadge(
              context,
              UiUtils.platformIcon(
                ios: CupertinoIcons.cube_box,
                android: Icons.smart_toy_outlined,
              ),
              color: context.conduitTheme.buttonPrimary,
            ),
            title: models[i].name,
            subtitle: l10n.tapToLoadServerPromptSettings,
            onTap: () => _showModelSystemPromptEditor(context, ref, models[i]),
          ),
          if (i != models.length - 1) const SizedBox(height: Spacing.xs),
        ],
      ],
    );
  }

  Widget _buildPromptLoadingTile(BuildContext context, String title) {
    final theme = context.conduitTheme;
    final color = theme.buttonPrimary;
    return CustomizationTile(
      leading: Container(
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
        child: const ConduitLoadingIndicator(isCompact: true),
      ),
      title: title,
      subtitle: '',
      showChevron: false,
    );
  }

  Widget _buildPromptErrorTile(
    BuildContext context, {
    required String title,
    required String subtitle,
  }) {
    return CustomizationTile(
      leading: _buildIconBadge(
        context,
        Icons.warning_amber_rounded,
        color: context.conduitTheme.error,
      ),
      title: title,
      subtitle: subtitle,
      showChevron: false,
    );
  }

  Widget _buildCenteredProgress() {
    return const Padding(
      padding: EdgeInsets.all(Spacing.md),
      child: Center(child: ConduitLoadingIndicator(isCompact: true)),
    );
  }

  Widget _buildPromptErrorText(BuildContext context, String text) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.all(Spacing.md),
      child: Text(
        text,
        style: theme.bodyMedium?.copyWith(
          color: theme.sidebarForeground.withValues(alpha: 0.75),
        ),
      ),
    );
  }

  Future<void> _showGlobalSystemPromptEditor(
    BuildContext context,
    WidgetRef ref, {
    required String initialValue,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return _showServerPromptEditor(
      context,
      title: l10n.globalSystemPrompt,
      description: l10n.globalSystemPromptEditorDescription,
      initialValue: initialValue,
      onSave: (value) async {
        final api = ref.read(apiServiceProvider);
        if (api == null) throw StateError('No API service available');
        await api.updateUserSystemPrompt(value);
      },
      afterSave: () => ref.invalidate(rawUserSettingsProvider),
    );
  }

  Future<void> _showModelSystemPromptEditor(
    BuildContext context,
    WidgetRef ref,
    Model model,
  ) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) return;

    final detail = await api.getModelDetails(model.id);
    if (!context.mounted) return;
    final l10n = AppLocalizations.of(context)!;
    if (detail == null) {
      _showPromptSnackBar(context, l10n.modelNoEditableServerRecord);
      return;
    }

    final writeAccess = detail['write_access'] == true;
    await _showServerPromptEditor(
      context,
      title: l10n.modelSystemPromptTitle(model.name),
      description: writeAccess
          ? l10n.modelSystemPromptEditorDescription
          : l10n.modelNoWriteAccessDescription,
      initialValue: _extractModelPrompt(detail) ?? '',
      readOnly: !writeAccess,
      onSave: (value) async {
        await api.updateModelSystemPrompt(model.id, value);
      },
      afterSave: () => ref.invalidate(modelsProvider),
    );
  }

  Future<void> _showServerPromptEditor(
    BuildContext context, {
    required String title,
    required String description,
    required String initialValue,
    required Future<void> Function(String value) onSave,
    VoidCallback? afterSave,
    bool readOnly = false,
  }) async {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    void showMessage(String message) {
      if (context.mounted) {
        UiUtils.showMessage(context, message);
      }
    }

    if (Platform.isIOS) {
      try {
        final result = await NativeSheetBridge.instance.presentSheet(
          root: NativeSheetDetailConfig(
            id: 'server-prompt-editor',
            title: title,
            subtitle: description,
            confirmActionId: readOnly ? null : 'save',
            confirmActionLabel: readOnly
                ? null
                : AppLocalizations.of(context)!.save,
            items: [
              NativeSheetItemConfig(
                id: 'server-prompt-value',
                title: title,
                subtitle: readOnly ? description : l10n.enterSystemPrompt,
                sfSymbol: 'text.bubble',
                kind: readOnly
                    ? NativeSheetItemKind.readOnlyText
                    : NativeSheetItemKind.multilineTextField,
                value: initialValue,
                placeholder: readOnly ? null : l10n.enterSystemPrompt,
              ),
            ],
          ),
          rethrowErrors: true,
        );
        if (readOnly || result?.actionId != 'save') {
          return;
        }
        final value = result?.values['server-prompt-value'] as String? ?? '';
        try {
          await onSave(value);
          afterSave?.call();
          showMessage(l10n.saved);
        } catch (_) {
          showMessage(l10n.errorMessage);
        }
        return;
      } catch (_) {
        if (!context.mounted) {
          return;
        }
      }
    }

    if (!context.mounted) {
      return;
    }

    await showSettingsSheet<void>(
      context: context,
      builder: (sheetContext) => _ServerPromptEditorSheet(
        title: title,
        description: description,
        initialValue: initialValue,
        readOnly: readOnly,
        theme: theme,
        cancelLabel: l10n.cancel,
        closeLabel: l10n.close,
        saveLabel: l10n.save,
        promptHint: l10n.enterSystemPrompt,
        errorMessage: l10n.errorMessage,
        savedMessage: l10n.saved,
        showMessage: showMessage,
        afterSave: afterSave,
        onSave: onSave,
      ),
    );
  }

  void _showPromptSnackBar(BuildContext context, String message) {
    UiUtils.showMessage(context, message);
  }

  String? _extractSystemPrompt(Map<String, dynamic> settings) {
    final root = settings['system'];
    if (root is String && root.trim().isNotEmpty) return root.trim();
    final ui = settings['ui'];
    if (ui is Map && ui['system'] is String) {
      final value = (ui['system'] as String).trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  String? _extractModelPrompt(Map<String, dynamic> model) {
    final params = model['params'];
    if (params is Map && params['system'] is String) {
      final value = (params['system'] as String).trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  Widget _buildSocketHealthSection(BuildContext context, WidgetRef ref) {
    final socketService = ref.watch(socketServiceProvider);

    if (socketService == null) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: AppLocalizations.of(context)!.connectionHealth),
        const SizedBox(height: Spacing.sm),
        SocketHealthCard(socketService: socketService),
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

    await showSettingsSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SettingsSelectorSheet(
          title: l10n.androidAssistantTitle,
          description: l10n.androidAssistantDescription,
          itemCount: options.length,
          initialChildSize: 0.46,
          minChildSize: 0.34,
          maxChildSize: 0.72,
          itemBuilder: (context, index) {
            final option = options[index];
            final selected = settings.androidAssistantTrigger == option.value;
            return SettingsSelectorTile(
              title: option.label,
              selected: selected,
              onTap: () {
                if (!selected) {
                  ref
                      .read(appSettingsProvider.notifier)
                      .setAndroidAssistantTrigger(option.value);
                }
                Navigator.of(sheetContext).pop();
              },
            );
          },
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
                      style: theme.bodyMedium?.copyWith(
                        color: theme.sidebarForeground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              AdaptiveSegmentedSelector<SttPreference>(
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
                  style: theme.bodyMedium?.copyWith(
                    color: theme.sidebarForeground.withValues(alpha: 0.9),
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
                      style: theme.bodySmall?.copyWith(
                        color: theme.error,
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
                            style: theme.bodyMedium?.copyWith(
                              color: theme.sidebarForeground,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: Spacing.xs),
                          Text(
                            '${settings.voiceSilenceDuration}ms',
                            style: theme.bodySmall?.copyWith(
                              color: theme.sidebarForeground.withValues(
                                alpha: 0.7,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${(settings.voiceSilenceDuration / 1000).toStringAsFixed(1)}s',
                      style: theme.bodyMedium?.copyWith(
                        color: theme.buttonPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.sm),
                AdaptiveSlider(
                  value: settings.voiceSilenceDuration.toDouble(),
                  min: SettingsService.minVoiceSilenceDurationMs.toDouble(),
                  max: SettingsService.maxVoiceSilenceDurationMs.toDouble(),
                  divisions:
                      (SettingsService.maxVoiceSilenceDurationMs -
                          SettingsService.minVoiceSilenceDurationMs) ~/
                      100,
                  activeColor: theme.buttonPrimary,
                  onChanged: (value) {
                    notifier.setVoiceSilenceDuration(value.round());
                  },
                ),
                Text(
                  l10n.sttSilenceDurationDescription,
                  style: theme.bodySmall?.copyWith(
                    color: theme.sidebarForeground.withValues(alpha: 0.7),
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
                    style: theme.bodyMedium?.copyWith(
                      color: theme.sidebarForeground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              AdaptiveSegmentedSelector<TtsEngine>(
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
                  style: theme.bodyMedium?.copyWith(
                    color: theme.sidebarForeground.withValues(alpha: 0.9),
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
                      style: theme.bodySmall?.copyWith(
                        color: theme.error,
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
        ExpandableCard(
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
              CustomizationTile(
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
              CustomizationTile(
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
                  style: theme.bodyMedium?.copyWith(
                    color: theme.sidebarForeground,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text(
                label,
                style: theme.bodyMedium?.copyWith(
                  color: theme.sidebarForeground.withValues(alpha: 0.75),
                  fontWeight: FontWeight.w500,
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
    const systemDefaultId = '__system_default__';
    if (Platform.isIOS) {
      try {
        final selectedId = await NativeSheetBridge.instance
            .presentOptionsSelector(
              title: l10n.ttsSelectVoice,
              selectedOptionId:
                  ((settings.ttsEngine == TtsEngine.server
                              ? settings.ttsServerVoiceId
                              : settings.ttsVoice)
                          ?.isNotEmpty ??
                      false)
                  ? settings.ttsEngine == TtsEngine.server
                        ? settings.ttsServerVoiceId
                        : settings.ttsVoice
                  : systemDefaultId,
              options: [
                NativeSheetOptionConfig(
                  id: systemDefaultId,
                  label: l10n.ttsSystemDefault,
                ),
                for (final voice in voices)
                  NativeSheetOptionConfig(
                    id: _getVoiceIdentifier(voice, settings.ttsEngine),
                    label: _formatVoiceName(l10n, voice),
                    subtitle: _getVoiceSubtitle(voice),
                  ),
              ],
              rethrowErrors: true,
            );
        if (selectedId == null) {
          return;
        }
        final notifier = ref.read(appSettingsProvider.notifier);
        if (selectedId == systemDefaultId) {
          if (settings.ttsEngine == TtsEngine.server) {
            notifier.setTtsServerVoiceId(null);
            notifier.setTtsServerVoiceName(null);
          } else {
            notifier.setTtsVoice(null);
          }
          return;
        }
        final selectedVoice = voices.firstWhere(
          (voice) =>
              _getVoiceIdentifier(voice, settings.ttsEngine) == selectedId,
        );
        final displayName = _formatVoiceName(l10n, selectedVoice);
        if (settings.ttsEngine == TtsEngine.server) {
          notifier.setTtsServerVoiceId(selectedId);
          notifier.setTtsServerVoiceName(displayName);
        } else {
          notifier.setTtsVoice(selectedId);
        }
        return;
      } catch (_) {
        if (!context.mounted) {
          return;
        }
      }
    }

    final entries = <({String? section, Map<String, dynamic>? voice})>[
      (section: null, voice: null),
      if (matchingVoices.isNotEmpty && otherVoices.isNotEmpty)
        (
          section: l10n.ttsVoicesForLanguage(appLanguageCode.toUpperCase()),
          voice: null,
        ),
      if (matchingVoices.isNotEmpty && otherVoices.isNotEmpty)
        for (final voice in matchingVoices) (section: null, voice: voice),
      if (matchingVoices.isNotEmpty && otherVoices.isNotEmpty)
        (section: l10n.ttsOtherVoices, voice: null),
      if (matchingVoices.isNotEmpty && otherVoices.isNotEmpty)
        for (final voice in otherVoices) (section: null, voice: voice),
      if (matchingVoices.isEmpty || otherVoices.isEmpty)
        for (final voice in voices) (section: null, voice: voice),
    ];

    if (!context.mounted) {
      return;
    }

    showSettingsSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) {
        return SettingsSelectorSheet(
          title: l10n.ttsSelectVoice,
          itemCount: entries.length,
          initialChildSize: 0.7,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          itemBuilder: (context, index) {
            final entry = entries[index];
            if (entry.section != null) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.sm,
                  Spacing.md,
                  Spacing.sm,
                  Spacing.xs,
                ),
                child: Text(
                  entry.section!,
                  style: theme.bodySmall?.copyWith(
                    color: theme.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              );
            }

            final voice = entry.voice;
            if (voice == null) {
              final selected = settings.ttsEngine == TtsEngine.server
                  ? settings.ttsServerVoiceId == null
                  : settings.ttsVoice == null;
              return SettingsSelectorTile(
                title: l10n.ttsSystemDefault,
                selected: selected,
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
              );
            }

            final voiceId = _getVoiceIdentifier(voice, settings.ttsEngine);
            final displayName = _formatVoiceName(l10n, voice);
            final subtitle = _getVoiceSubtitle(voice);
            final selected = settings.ttsEngine == TtsEngine.server
                ? settings.ttsServerVoiceId == voiceId
                : settings.ttsVoice == voiceId;

            return SettingsSelectorTile(
              title: displayName,
              subtitle: subtitle.isEmpty ? null : subtitle,
              selected: selected,
              onTap: () {
                final notifier = ref.read(appSettingsProvider.notifier);
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

  String _formatVoiceName(AppLocalizations l10n, Map<String, dynamic> voice) {
    final name = voice['name'] as String? ?? l10n.unknownLabel;
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

  String _getVoiceIdentifier(Map<String, dynamic> voice, TtsEngine engine) {
    final id = voice['id'] as String?;
    final name = voice['name'] as String?;
    final identifier = voice['identifier'] as String?;

    return switch (engine) {
      TtsEngine.server => id ?? name ?? identifier ?? 'unknown',
      TtsEngine.device => name ?? identifier ?? id ?? 'unknown',
    };
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
      case 'ja':
        return AppLocalizations.of(context)!.japanese;
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
        if (normalizedCode == 'ja') {
          return AppLocalizations.of(context)!.japanese;
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

    if (Platform.isIOS) {
      try {
        final selected = await NativeSheetBridge.instance
            .presentOptionsSelector(
              title: l10n.transportMode,
              selectedOptionId: current,
              options: [
                for (final option in options)
                  NativeSheetOptionConfig(
                    id: option.value,
                    label: option.title,
                    subtitle: option.subtitle,
                  ),
              ],
              rethrowErrors: true,
            );
        if (selected != null && selected != current) {
          ref
              .read(appSettingsProvider.notifier)
              .setSocketTransportMode(selected);
        }
        return;
      } catch (_) {
        if (!context.mounted) {
          return;
        }
      }
    }

    if (!context.mounted) {
      return;
    }

    await showSettingsSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SettingsSelectorSheet(
          title: l10n.transportMode,
          itemCount: options.length,
          initialChildSize: 0.42,
          minChildSize: 0.32,
          maxChildSize: 0.68,
          itemBuilder: (context, index) {
            final option = options[index];
            final selected = current == option.value;
            return SettingsSelectorTile(
              title: option.title,
              subtitle: option.subtitle,
              selected: selected,
              onTap: () {
                if (!selected) {
                  ref
                      .read(appSettingsProvider.notifier)
                      .setSocketTransportMode(option.value);
                }
                Navigator.of(sheetContext).pop();
              },
            );
          },
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
        style: theme.bodySmall?.copyWith(
          color: theme.buttonPrimary,
          fontWeight: FontWeight.w600,
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
    final palettes = TweakcnThemes.all;

    if (Platform.isIOS) {
      try {
        final selectedId = await NativeSheetBridge.instance
            .presentOptionsSelector(
              title: l10n.themePalette,
              selectedOptionId: activePaletteId,
              options: [
                for (final palette in palettes)
                  NativeSheetOptionConfig(
                    id: palette.id,
                    label: palette.label(l10n),
                    subtitle: palette.description(l10n),
                  ),
              ],
              rethrowErrors: true,
            );
        if (selectedId != null) {
          await ref
              .read(appThemePaletteProvider.notifier)
              .setPalette(selectedId);
        }
        return;
      } catch (_) {
        if (!context.mounted) {
          return;
        }
      }
    }

    if (!context.mounted) {
      return;
    }

    await showSettingsSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SettingsSelectorSheet(
          title: l10n.themePalette,
          itemCount: palettes.length,
          initialChildSize: 0.66,
          minChildSize: 0.42,
          maxChildSize: 0.86,
          itemBuilder: (context, index) {
            final palette = palettes[index];
            return SettingsSelectorTile(
              title: palette.label(l10n),
              subtitle: palette.description(l10n),
              selected: palette.id == activePaletteId,
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
        );
      },
    );
  }

  Future<String?> _showLanguageSelector(
    BuildContext context,
    String current,
  ) async {
    final normalizedCurrent = current.replaceAll('_', '-');
    final l10n = AppLocalizations.of(context)!;
    final options = <({String value, String label})>[
      (value: 'system', label: l10n.system),
      (value: 'en', label: l10n.english),
      (value: 'de', label: l10n.deutsch),
      (value: 'es', label: l10n.espanol),
      (value: 'fr', label: l10n.francais),
      (value: 'it', label: l10n.italiano),
      (value: 'nl', label: l10n.nederlands),
      (value: 'ru', label: l10n.russian),
      (value: 'zh', label: l10n.chineseSimplified),
      (value: 'zh-Hant', label: l10n.chineseTraditional),
      (value: 'ko', label: l10n.korean),
      (value: 'ja', label: l10n.japanese),
    ];

    if (Platform.isIOS) {
      try {
        return await IosNativeDropdownBridge.instance.showFromContext(
          context: context,
          title: l10n.appLanguage,
          cancelLabel: l10n.cancel,
          options: [
            for (final option in options)
              IosNativeDropdownOption(
                id: option.value,
                label: option.label,
                sfSymbol: normalizedCurrent == option.value
                    ? 'checkmark'
                    : null,
              ),
          ],
          rethrowErrors: true,
        );
      } catch (_) {
        if (!context.mounted) {
          return null;
        }
      }
    }

    if (!context.mounted) {
      return null;
    }

    return showSettingsSheet<String>(
      context: context,
      builder: (sheetContext) {
        return SettingsSelectorSheet(
          title: AppLocalizations.of(sheetContext)!.appLanguage,
          itemCount: options.length,
          initialChildSize: 0.72,
          minChildSize: 0.42,
          maxChildSize: 0.86,
          itemBuilder: (context, index) {
            final option = options[index];
            return SettingsSelectorTile(
              title: option.label,
              selected: normalizedCurrent == option.value,
              onTap: () => Navigator.pop(sheetContext, option.value),
            );
          },
        );
      },
    );
  }
}

class _ServerPromptEditorSheet extends StatefulWidget {
  const _ServerPromptEditorSheet({
    required this.title,
    required this.description,
    required this.initialValue,
    required this.readOnly,
    required this.theme,
    required this.cancelLabel,
    required this.closeLabel,
    required this.saveLabel,
    required this.promptHint,
    required this.errorMessage,
    required this.savedMessage,
    required this.onSave,
    required this.showMessage,
    this.afterSave,
  });

  final String title;
  final String description;
  final String initialValue;
  final bool readOnly;
  final ConduitThemeExtension theme;
  final String cancelLabel;
  final String closeLabel;
  final String saveLabel;
  final String promptHint;
  final String errorMessage;
  final String savedMessage;
  final Future<void> Function(String value) onSave;
  final ValueChanged<String> showMessage;
  final VoidCallback? afterSave;

  @override
  State<_ServerPromptEditorSheet> createState() =>
      _ServerPromptEditorSheetState();
}

class _ServerPromptEditorSheetState extends State<_ServerPromptEditorSheet> {
  late final TextEditingController _controller;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.onSave(_controller.text);
      if (!mounted) return;
      Navigator.of(context).pop();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.afterSave?.call();
        widget.showMessage(widget.savedMessage);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      widget.showMessage(widget.errorMessage);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    return Container(
      decoration: BoxDecoration(
        color: theme.sidebarBackground,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.modal),
        ),
        boxShadow: ConduitShadows.modal(context),
      ),
      padding: EdgeInsets.only(
        left: Spacing.lg,
        right: Spacing.lg,
        top: Spacing.md,
        bottom: MediaQuery.viewInsetsOf(context).bottom + Spacing.lg,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.title,
              style: theme.headingSmall?.copyWith(
                color: theme.sidebarForeground,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              widget.description,
              style: theme.bodySmall?.copyWith(
                color: theme.sidebarForeground.withValues(alpha: 0.75),
              ),
            ),
            const SizedBox(height: Spacing.md),
            ConduitInput(
              controller: _controller,
              readOnly: widget.readOnly || _saving,
              minLines: 5,
              maxLines: 10,
              hint: widget.promptHint,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
            ),
            const SizedBox(height: Spacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                ConduitButton(
                  text: widget.readOnly
                      ? widget.closeLabel
                      : widget.cancelLabel,
                  isSecondary: true,
                  isCompact: true,
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                ),
                if (!widget.readOnly) ...[
                  const SizedBox(width: Spacing.sm),
                  ConduitButton(
                    text: widget.saveLabel,
                    isLoading: _saving,
                    isCompact: true,
                    onPressed: _saving ? null : _save,
                  ),
                ],
              ],
            ),
          ],
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
      style: theme.headingSmall?.copyWith(color: theme.sidebarForeground),
    );
  }
}
