import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/tools/providers/tools_providers.dart';
import '../../features/chat/providers/text_to_speech_provider.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/theme/tweakcn_themes.dart';
import '../models/model.dart';
import '../network/image_header_utils.dart';
import '../providers/app_providers.dart';
import '../utils/debug_logger.dart';
import '../utils/model_icon_utils.dart';
import '../utils/model_sort_utils.dart';
import '../utils/native_sheet_utils.dart';
import 'native_sheet_avatar_bytes_hydrator.dart';
import 'native_sheet_bridge.dart';
import 'navigation_service.dart';
import 'settings_service.dart';

final nativeSheetHydrationServiceProvider =
    Provider<NativeSheetHydrationService>(NativeSheetHydrationService.new);

final nativeSheetAvatarBytesHydratorProvider =
    Provider<NativeSheetAvatarBytesHydrator>(
      (_) => NativeSheetAvatarBytesHydrator(),
    );

class NativeSheetHydrationService {
  NativeSheetHydrationService(this._ref);

  final Ref _ref;

  Future<List<Model>> loadModels({bool refreshOnError = true}) async {
    final modelsAsync = _ref.read(modelsProvider);
    if (modelsAsync.hasValue) {
      return modelsAsync.requireValue;
    }
    if (modelsAsync.hasError && refreshOnError) {
      _ref.invalidate(modelsProvider);
    }
    return _ref.read(modelsProvider.future);
  }

  Future<String?> presentModelSelector(
    BuildContext context, {
    required String title,
    required List<Model> models,
    String? selectedModelId,
    List<NativeSheetModelOption> leadingOptions =
        const <NativeSheetModelOption>[],
    bool allowsPinning = false,
    bool rethrowErrors = true,
  }) async {
    final api = _ref.read(apiServiceProvider);
    final avatarHeaders =
        buildImageHeadersFromContainer(
          ProviderScope.containerOf(context, listen: false),
        ) ??
        const <String, String>{};
    final l10n = AppLocalizations.of(context);
    final pinnedModelIds = allowsPinning
        ? _ref.read(effectivePinnedModelIdsProvider)
        : const <String>[];
    final orderedModels = allowsPinning
        ? sortModelsWithPinnedOrder(models, pinnedModelIds)
        : List<Model>.of(models, growable: false);
    final canTogglePinnedModels =
        allowsPinning && _ref.read(canTogglePinnedModelsProvider);

    final modelOptions = [
      ...leadingOptions,
      for (final model in orderedModels)
        NativeSheetModelOption(
          id: model.id,
          name: model.name,
          subtitle: model.description,
          avatarUrl: resolveModelIconUrlForModel(api, model),
          avatarHeaders: avatarHeaders,
          tags: model.modelTags,
        ),
    ];

    final hydratedModelOptions = await _ref
        .read(nativeSheetAvatarBytesHydratorProvider)
        .hydrateModelOptions(api: api, options: modelOptions);
    if (!context.mounted) {
      return null;
    }

    return NativeSheetBridge.instance.presentModelSelector(
      title: title,
      selectedModelId: selectedModelId,
      pinnedModelIds: pinnedModelIds,
      pinTitle: allowsPinning ? l10n?.pin : null,
      unpinTitle: allowsPinning ? l10n?.unpin : null,
      onTogglePinned: canTogglePinnedModels
          ? (modelId) => _ref
                .read(personalizationSettingsProvider.notifier)
                .togglePinnedModel(modelId)
          : null,
      models: hydratedModelOptions,
      rethrowErrors: rethrowErrors,
    );
  }

  Future<void> hydrateDetail(String detailId) async {
    final ctx = NavigationService.context;
    if (ctx == null || !ctx.mounted) return;
    final l10n = AppLocalizations.of(ctx);
    if (l10n == null) return;

    if (detailId.startsWith('model-prompt:')) {
      await _hydrateNativeModelPromptDetail(ctx, detailId, l10n);
      return;
    }

    switch (detailId) {
      case NativeSheetRoutes.accountSettings:
        await _hydrateNativeAccountSettingsDetail(ctx, l10n);
        return;
      case NativeSheetRoutes.appearance:
      case NativeSheetRoutes.chats:
      case NativeSheetRoutes.dataConnection:
        await _hydrateNativeSignalStyleSettingsDetails(ctx, l10n);
        return;
      case NativeSheetRoutes.aiMemory:
        await _hydrateNativeAiMemoryDetail(ctx, l10n);
        return;
      case NativeSheetRoutes.voice:
        await _hydrateNativeVoiceDetail(l10n);
        return;
      case NativeSheetRoutes.helpAbout:
        await _hydrateNativeAboutDetail(
          ctx,
          l10n,
          detailId: NativeSheetRoutes.helpAbout,
        );
        return;
      case NativeSheetRoutes.about:
        await _hydrateNativeAboutDetail(ctx, l10n);
        return;
      case NativeSheetRoutes.appCustomization:
        await _hydrateNativeAppCustomizationDetail(ctx, l10n);
        return;
      case NativeSheetRoutes.personalization:
        await _hydrateNativePersonalizationDetail(ctx, l10n);
        return;
      case NativeSheetRoutes.notificationSettings:
        await _hydrateNativeNotificationsDetail(l10n);
        return;
      case 'advanced-prompt-overrides':
        await _hydrateNativeAdvancedPromptDetail(ctx, l10n);
        return;
      case 'default-model':
        await _hydrateNativeDefaultModelDetail(ctx, l10n);
        return;
      case 'memory-manage':
        await _hydrateNativeMemoryManageDetail(ctx, l10n);
        return;
      case 'quick-pills':
        await _hydrateNativeQuickPillsDetail(ctx, l10n);
        return;
      case 'system-prompt':
        await _hydrateNativeSystemPromptDetail(ctx, l10n);
        return;
      case 'personalization-memory':
        await _hydrateNativeMemoryDetail(ctx, l10n);
        return;
    }
  }

  Future<void> _hydrateNativeAboutDetail(
    BuildContext context,
    AppLocalizations l10n, {
    String detailId = NativeSheetRoutes.about,
  }) async {
    try {
      final packageInfoFuture = _ref.read(packageInfoProvider.future);
      final aboutFuture = _ref.read(serverAboutInfoProvider.future);
      final packageInfo = await packageInfoFuture;
      final about = await aboutFuture;
      if (!context.mounted) return;

      final appVersionLabel = packageInfo.buildNumber.isEmpty
          ? packageInfo.version
          : '${packageInfo.version} (${packageInfo.buildNumber})';
      final serverName = about?.name ?? l10n.serverInfoUnavailable;
      final serverVersion = about == null
          ? l10n.serverInfoUnavailable
          : about.latestVersion != null &&
                about.latestVersion!.trim().isNotEmpty
          ? '${about.version} · ${l10n.latestVersionLabel}: ${about.latestVersion}'
          : about.version;

      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: detailId,
          title: l10n.aboutApp,
          subtitle: l10n.aboutAppSubtitle,
          items: [
            NativeSheetItemConfig(
              id: 'app-version',
              title: l10n.appVersion,
              subtitle: appVersionLabel,
              sfSymbol: 'app.badge',
              kind: NativeSheetItemKind.info,
            ),
            NativeSheetItemConfig(
              id: 'server-name',
              title: l10n.serverNameLabel,
              subtitle: serverName,
              sfSymbol: 'server.rack',
              kind: NativeSheetItemKind.info,
            ),
            NativeSheetItemConfig(
              id: 'server-version',
              title: l10n.serverVersionLabel,
              subtitle: serverVersion,
              sfSymbol: 'number',
              kind: NativeSheetItemKind.info,
            ),
            NativeSheetItemConfig(
              id: 'github',
              title: l10n.githubRepository,
              subtitle: 'github.com/cogwheel0/conduit',
              sfSymbol: 'chevron.left.forwardslash.chevron.right',
              url: 'https://github.com/cogwheel0/conduit',
            ),
          ],
        ),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-about-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError(
        detailId,
        l10n.unableToLoadOpenWebuiSettings,
      );
    }
  }

  Future<void> _hydrateNativeAccountSettingsDetail(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    try {
      final about = await _ref.read(serverAboutInfoProvider.future);
      if (!context.mounted) return;
      final passwordChangeEnabled = about?.enablePasswordChangeForm ?? true;

      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: NativeSheetRoutes.accountSettings,
          title: l10n.accountSettingsTitle,
          subtitle: l10n.passwordChangesLabel,
          items: [
            if (passwordChangeEnabled)
              NativeSheetItemConfig(
                id: 'password',
                title: l10n.changePasswordTitle,
                subtitle: l10n.passwordChangesLabel,
                sfSymbol: 'lock',
              )
            else
              NativeSheetItemConfig(
                id: 'password-unavailable',
                title: l10n.changePasswordTitle,
                subtitle: l10n.passwordChangeUnavailable,
                sfSymbol: 'lock.slash',
                kind: NativeSheetItemKind.info,
              ),
          ],
        ),
        detailSheets: passwordChangeEnabled
            ? [
                buildNativePasswordDetail(
                  l10n,
                  passwordChangeEnabled: true,
                  subtitle: l10n.passwordFieldsRequired,
                ),
              ]
            : const [],
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-account-settings-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError(
        NativeSheetRoutes.accountSettings,
        l10n.unableToLoadOpenWebuiSettings,
      );
    }
  }

  Future<void> _hydrateNativePersonalizationDetail(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    try {
      final settingsFuture = _ref.read(personalizationSettingsProvider.future);
      final modelsFuture = _ref.read(modelsProvider.future);
      final settings = await settingsFuture;
      final models = await modelsFuture;
      if (!context.mounted) return;

      final appSettings = _ref.read(appSettingsProvider);
      final defaultModelSubtitle =
          resolveNativeSheetModelName(models, appSettings.defaultModel) ??
          l10n.autoSelectDescription;

      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: NativeSheetRoutes.personalization,
          title: l10n.personalization,
          subtitle: l10n.personalizationSubtitle,
          items: [
            NativeSheetItemConfig(
              id: 'default-model',
              title: l10n.defaultModel,
              subtitle: defaultModelSubtitle,
              sfSymbol: 'wand.and.stars',
            ),
            NativeSheetItemConfig(
              id: 'system-prompt',
              title: l10n.yourSystemPrompt,
              subtitle: nativeSheetPreviewText(l10n, settings.systemPrompt),
              sfSymbol: 'person.crop.circle.badge.checkmark',
            ),
            NativeSheetItemConfig(
              id: 'personalization-memory',
              title: l10n.memoryTitle,
              subtitle: settings.memoryEnabled
                  ? l10n.memoryEnabledDescription
                  : l10n.memoryDisabledDescription,
              sfSymbol: 'bookmark',
            ),
            NativeSheetItemConfig(
              id: 'advanced-prompt-overrides',
              title: l10n.advancedPromptOverrides,
              subtitle: models.isEmpty
                  ? l10n.noAccessibleModelsFound
                  : l10n.accessibleModelsCount(models.length),
              sfSymbol: 'cube.box.fill',
            ),
          ],
        ),
        detailSheets: [
          buildNativeLoadingDetail(
            l10n: l10n,
            id: 'default-model',
            title: l10n.defaultModel,
            subtitle: l10n.autoSelectDescription,
          ),
          buildNativeLoadingDetail(
            l10n: l10n,
            id: 'system-prompt',
            title: l10n.yourSystemPrompt,
            subtitle: l10n.yourSystemPromptDescription,
          ),
          buildNativeLoadingDetail(
            l10n: l10n,
            id: 'personalization-memory',
            title: l10n.memoryTitle,
            subtitle: settings.memoryEnabled
                ? l10n.memoryEnabledDescription
                : l10n.memoryDisabledDescription,
          ),
          buildNativeLoadingDetail(
            l10n: l10n,
            id: 'advanced-prompt-overrides',
            title: l10n.advancedPromptOverrides,
            subtitle: l10n.advancedPromptOverridesDescription,
          ),
        ],
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-personalization-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError(
        NativeSheetRoutes.personalization,
        l10n.unableToLoadOpenWebuiSettings,
      );
    }
  }

  Future<void> _hydrateNativeAiMemoryDetail(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    try {
      final settingsFuture = _ref.read(personalizationSettingsProvider.future);
      final modelsFuture = _ref.read(modelsProvider.future);
      final settings = await settingsFuture;
      final models = await modelsFuture;
      if (!context.mounted) return;

      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: NativeSheetRoutes.aiMemory,
          title: nativeAiMemoryTitle(l10n),
          subtitle: l10n.personalizationSubtitle,
          items: [
            NativeSheetItemConfig(
              id: 'system-prompt',
              title: l10n.yourSystemPrompt,
              subtitle: nativeSheetPreviewText(l10n, settings.systemPrompt),
              sfSymbol: 'text.bubble',
            ),
            NativeSheetItemConfig(
              id: 'personalization-memory',
              title: l10n.memoryTitle,
              subtitle: settings.memoryEnabled
                  ? l10n.memoryEnabledDescription
                  : l10n.memoryDisabledDescription,
              sfSymbol: 'bookmark',
            ),
            NativeSheetItemConfig(
              id: 'advanced-prompt-overrides',
              title: l10n.advancedPromptOverrides,
              subtitle: models.isEmpty
                  ? l10n.noAccessibleModelsFound
                  : l10n.accessibleModelsCount(models.length),
              sfSymbol: 'cube.box.fill',
            ),
          ],
        ),
        detailSheets: [
          buildNativeLoadingDetail(
            l10n: l10n,
            id: 'system-prompt',
            title: l10n.yourSystemPrompt,
            subtitle: l10n.yourSystemPromptDescription,
          ),
          buildNativeLoadingDetail(
            l10n: l10n,
            id: 'personalization-memory',
            title: l10n.memoryTitle,
            subtitle: settings.memoryEnabled
                ? l10n.memoryEnabledDescription
                : l10n.memoryDisabledDescription,
          ),
          buildNativeLoadingDetail(
            l10n: l10n,
            id: 'advanced-prompt-overrides',
            title: l10n.advancedPromptOverrides,
            subtitle: l10n.advancedPromptOverridesDescription,
          ),
        ],
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-ai-memory-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError(
        NativeSheetRoutes.aiMemory,
        l10n.unableToLoadOpenWebuiSettings,
      );
    }
  }

  Future<void> _hydrateNativeNotificationsDetail(AppLocalizations l10n) async {
    try {
      final s = _ref.read(appSettingsProvider);
      // Dynamic detail patches only carry a flat `items` list (sections are
      // dropped by applyDetailPatch), so build a single ordered list.
      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: NativeSheetRoutes.notificationSettings,
          title: l10n.notificationsTitle,
          subtitle: l10n.notificationsSubtitle,
          items: [
            NativeSheetItemConfig(
              id: 'notifications-enabled',
              title: l10n.notificationsEnabledTitle,
              subtitle: l10n.notificationsEnabledDescription,
              sfSymbol: 'bell.fill',
              kind: NativeSheetItemKind.toggle,
              value: s.notificationsEnabled,
            ),
            NativeSheetItemConfig(
              id: 'notification-in-app-banner',
              title: l10n.notificationInAppBannerTitle,
              subtitle: l10n.notificationInAppBannerDescription,
              sfSymbol: 'rectangle.topthird.inset.filled',
              kind: NativeSheetItemKind.toggle,
              value: s.notificationInAppBanner,
            ),
            NativeSheetItemConfig(
              id: 'notification-system',
              title: l10n.notificationSystemTitle,
              subtitle: l10n.notificationSystemDescription,
              sfSymbol: 'bell.badge',
              kind: NativeSheetItemKind.toggle,
              value: s.notificationSystem,
            ),
            NativeSheetItemConfig(
              id: 'notification-sound',
              title: l10n.notificationSoundTitle,
              subtitle: l10n.notificationSoundDescription,
              sfSymbol: 'speaker.wave.2.fill',
              kind: NativeSheetItemKind.toggle,
              value: s.notificationSound,
            ),
            NativeSheetItemConfig(
              id: 'notification-sound-always',
              title: l10n.notificationSoundAlwaysTitle,
              subtitle: l10n.notificationSoundAlwaysDescription,
              sfSymbol: 'speaker.wave.3.fill',
              kind: NativeSheetItemKind.toggle,
              value: s.notificationSoundAlways,
            ),
            NativeSheetItemConfig(
              id: 'notification-chat',
              title: l10n.notificationChatTitle,
              subtitle: l10n.notificationChatDescription,
              sfSymbol: 'bubble.left.and.bubble.right.fill',
              kind: NativeSheetItemKind.toggle,
              value: s.notificationChatEnabled,
            ),
            NativeSheetItemConfig(
              id: 'notification-channel',
              title: l10n.notificationChannelTitle,
              subtitle: l10n.notificationChannelDescription,
              sfSymbol: 'number',
              kind: NativeSheetItemKind.toggle,
              value: s.notificationChannelEnabled,
            ),
          ],
        ),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-notifications-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError(
        NativeSheetRoutes.notificationSettings,
        l10n.unableToLoadOpenWebuiSettings,
      );
    }
  }

  Future<void> _hydrateNativeVoiceDetail(AppLocalizations l10n) async {
    final appSettings = _ref.read(appSettingsProvider);
    var ttsVoices = const <Map<String, dynamic>>[];
    try {
      final ttsService = _ref.read(textToSpeechServiceProvider);
      await ttsService.updateSettings(engine: appSettings.ttsEngine);
      ttsVoices = await ttsService.getAvailableVoices();
    } catch (error, stackTrace) {
      DebugLogger.warning(
        'native-tts-voices-load-failed',
        scope: 'native-sheet',
        data: {'error': error, 'stackTrace': stackTrace},
      );
    }
    final nativeAudio = buildNativeAudioSheetParts(
      l10n,
      appSettings,
      ttsVoices: ttsVoices,
    );
    await _applyNativeDetail(
      NativeSheetDetailConfig(
        id: NativeSheetRoutes.voice,
        title: l10n.voice,
        subtitle: l10n.audioSettingsSubtitle,
        items: nativeAudio.mainItems,
      ),
      detailSheets: [nativeAudio.voicePickerDetail],
    );
  }

  Future<void> _hydrateNativeSignalStyleSettingsDetails(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    try {
      final platformBrightness = MediaQuery.platformBrightnessOf(context);
      final modelsFuture = _ref.read(modelsProvider.future);
      final toolsFuture = _ref.read(toolsListProvider.future);
      final models = await modelsFuture;
      final tools = await toolsFuture;
      if (!context.mounted) return;

      final appSettings = _ref.read(appSettingsProvider);
      final themeMode = _ref.read(appThemeModeProvider);
      final appLocale = _ref.read(appLocaleProvider);
      final activePalette = _ref.read(appThemePaletteProvider);
      final transportAvail = _ref.read(socketTransportOptionsProvider);
      final selectedModel = _ref.read(selectedModelProvider);
      final socketService = _ref.read(socketServiceProvider);

      final themeDescription = switch (themeMode) {
        ThemeMode.system => l10n.followingSystem(
          platformBrightness == Brightness.dark
              ? l10n.themeDark
              : l10n.themeLight,
        ),
        ThemeMode.dark => l10n.currentlyUsingDarkTheme,
        ThemeMode.light => l10n.currentlyUsingLightTheme,
      };
      final currentLanguageTag = appLocale?.toLanguageTag() ?? 'system';
      final languageLabel = nativeLanguageLabel(l10n, currentLanguageTag);
      var effectiveTransport = appSettings.socketTransportMode;
      if (!transportAvail.allowPolling && effectiveTransport == 'polling') {
        effectiveTransport = 'ws';
      } else if (!transportAvail.allowWebsocketOnly &&
          effectiveTransport == 'ws') {
        effectiveTransport = 'polling';
      }
      final transportLabel = effectiveTransport == 'polling'
          ? l10n.transportModePolling
          : l10n.transportModeWs;
      final filters = selectedModel?.filters ?? const [];
      final allowedQuickIds = <String>{
        'web',
        'image',
        ...tools.map((tool) => tool.id),
        ...filters.map((filter) => 'filter:${filter.id}'),
      };
      final selectedQuickPills = appSettings.quickPills
          .where((id) => allowedQuickIds.contains(id))
          .toList();
      final quickActionsTitle = nativeQuickActionsTitle(l10n);
      final quickPillsSubtitle = l10n.quickActionsSelectedCount(
        selectedQuickPills.length,
      );
      final defaultModelSubtitle =
          resolveNativeSheetModelName(models, appSettings.defaultModel) ??
          l10n.autoSelect;
      final advancedPromptSubtitle = models.isEmpty
          ? l10n.noAccessibleModelsFound
          : l10n.accessibleModelsCount(models.length);

      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: NativeSheetRoutes.appearance,
          title: nativeAppearanceTitle(l10n),
          subtitle: themeDescription,
          items: [
            NativeSheetItemConfig(
              id: 'theme-light',
              title: l10n.darkMode,
              subtitle: themeDescription,
              sfSymbol: 'moon.stars',
              kind: NativeSheetItemKind.segment,
              value: themeMode.name,
              options: [
                NativeSheetOptionConfig(id: 'system', label: l10n.system),
                NativeSheetOptionConfig(id: 'light', label: l10n.themeLight),
                NativeSheetOptionConfig(id: 'dark', label: l10n.themeDark),
              ],
            ),
            NativeSheetItemConfig(
              id: 'theme-palette',
              title: l10n.themePalette,
              subtitle: activePalette.label(l10n),
              sfSymbol: 'paintpalette',
              kind: NativeSheetItemKind.dropdown,
              value: activePalette.id,
              options: [
                for (final theme in TweakcnThemes.all)
                  NativeSheetOptionConfig(
                    id: theme.id,
                    label: theme.label(l10n),
                  ),
              ],
            ),
            NativeSheetItemConfig(
              id: 'language',
              title: l10n.appLanguage,
              subtitle: languageLabel,
              sfSymbol: 'globe',
              kind: NativeSheetItemKind.dropdown,
              value: currentLanguageTag,
              options: nativeLanguageDropdownOptions(l10n),
            ),
          ],
        ),
      );

      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: NativeSheetRoutes.chats,
          title: nativeChatsTitle(l10n),
          subtitle: defaultModelSubtitle,
          items: [
            NativeSheetItemConfig(
              id: 'default-model',
              title: l10n.defaultModel,
              subtitle: defaultModelSubtitle,
              sfSymbol: 'wand.and.stars',
            ),
            NativeSheetItemConfig(
              id: 'quick-pills',
              title: quickActionsTitle,
              subtitle: quickPillsSubtitle,
              sfSymbol: 'bolt.fill',
            ),
            NativeSheetItemConfig(
              id: 'send-on-enter',
              title: l10n.sendOnEnter,
              subtitle: l10n.sendOnEnterDescription,
              sfSymbol: 'paperplane',
              kind: NativeSheetItemKind.toggle,
              value: appSettings.sendOnEnter,
            ),
            NativeSheetItemConfig(
              id: 'temporary-chat-default',
              title: l10n.temporaryChatByDefault,
              subtitle: l10n.temporaryChatByDefaultDescription,
              sfSymbol: 'clock.arrow.circlepath',
              kind: NativeSheetItemKind.toggle,
              value: appSettings.temporaryChatByDefault,
            ),
            NativeSheetItemConfig(
              id: 'advanced-prompt-overrides',
              title: l10n.advancedPromptOverrides,
              subtitle: advancedPromptSubtitle,
              sfSymbol: 'cube.box.fill',
            ),
          ],
        ),
        detailSheets: [
          buildNativeLoadingDetail(
            l10n: l10n,
            id: 'default-model',
            title: l10n.defaultModel,
            subtitle: l10n.autoSelectDescription,
          ),
          buildNativeLoadingDetail(
            l10n: l10n,
            id: 'quick-pills',
            title: quickActionsTitle,
            subtitle: quickPillsSubtitle,
          ),
          buildNativeLoadingDetail(
            l10n: l10n,
            id: 'advanced-prompt-overrides',
            title: l10n.advancedPromptOverrides,
            subtitle: l10n.advancedPromptOverridesDescription,
          ),
        ],
      );

      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: NativeSheetRoutes.dataConnection,
          title: nativeDataConnectionTitle(l10n),
          subtitle: transportLabel,
          items: [
            if (transportAvail.allowPolling &&
                transportAvail.allowWebsocketOnly)
              NativeSheetItemConfig(
                id: 'transport-mode',
                title: l10n.transportMode,
                subtitle: transportLabel,
                sfSymbol: 'network',
                kind: NativeSheetItemKind.segment,
                value: effectiveTransport == 'ws' ? 'ws' : 'polling',
                options: [
                  NativeSheetOptionConfig(
                    id: 'polling',
                    label: l10n.transportModePolling,
                  ),
                  NativeSheetOptionConfig(
                    id: 'ws',
                    label: l10n.transportModeWs,
                  ),
                ],
              )
            else
              NativeSheetItemConfig(
                id: 'transport-fixed',
                title: l10n.transportMode,
                subtitle: transportLabel,
                sfSymbol: 'network',
                kind: NativeSheetItemKind.info,
              ),
            NativeSheetItemConfig(
              id: 'disable-haptics-streaming',
              title: l10n.disableHapticsWhileStreaming,
              subtitle: l10n.disableHapticsWhileStreamingDescription,
              sfSymbol: 'waveform.path',
              kind: NativeSheetItemKind.toggle,
              value: appSettings.disableHapticsWhileStreaming,
            ),
            if (socketService != null)
              NativeSheetItemConfig(
                id: 'socket-health',
                title: l10n.connectionHealth,
                subtitle: nativeSocketHealthSummary(
                  l10n,
                  socketService.currentHealth,
                ),
                sfSymbol: 'waveform.path.ecg',
              ),
          ],
        ),
        detailSheets: [
          if (socketService != null)
            NativeSheetDetailConfig(
              id: 'socket-health',
              title: l10n.connectionHealth,
              subtitle: nativeSocketHealthSummary(
                l10n,
                socketService.currentHealth,
              ),
              items: nativeSocketHealthItems(l10n, socketService.currentHealth),
            ),
        ],
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-signal-style-settings-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError(
        NativeSheetRoutes.appearance,
        l10n.unableToLoadOpenWebuiSettings,
      );
      await _patchNativeDetailError(
        NativeSheetRoutes.chats,
        l10n.unableToLoadOpenWebuiSettings,
      );
      await _patchNativeDetailError(
        NativeSheetRoutes.dataConnection,
        l10n.unableToLoadOpenWebuiSettings,
      );
    }
  }

  Future<void> _hydrateNativeAppCustomizationDetail(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    try {
      final platformBrightness = MediaQuery.platformBrightnessOf(context);
      final modelsFuture = _ref.read(modelsProvider.future);
      final toolsFuture = _ref.read(toolsListProvider.future);
      final models = await modelsFuture;
      final tools = await toolsFuture;
      if (!context.mounted) return;
      final appSettings = _ref.read(appSettingsProvider);
      final themeMode = _ref.read(appThemeModeProvider);
      final appLocale = _ref.read(appLocaleProvider);
      final activePalette = _ref.read(appThemePaletteProvider);
      final transportAvail = _ref.read(socketTransportOptionsProvider);
      final selectedModel = _ref.read(selectedModelProvider);
      final socketService = _ref.read(socketServiceProvider);
      final quickActionsTitle = nativeQuickActionsTitle(l10n);
      final themeDescription = switch (themeMode) {
        ThemeMode.system => l10n.followingSystem(
          platformBrightness == Brightness.dark
              ? l10n.themeDark
              : l10n.themeLight,
        ),
        ThemeMode.dark => l10n.currentlyUsingDarkTheme,
        ThemeMode.light => l10n.currentlyUsingLightTheme,
      };
      final currentLanguageTag = appLocale?.toLanguageTag() ?? 'system';
      final languageLabel = nativeLanguageLabel(l10n, currentLanguageTag);
      var effectiveTransport = appSettings.socketTransportMode;
      if (!transportAvail.allowPolling && effectiveTransport == 'polling') {
        effectiveTransport = 'ws';
      } else if (!transportAvail.allowWebsocketOnly &&
          effectiveTransport == 'ws') {
        effectiveTransport = 'polling';
      }
      final transportNavLabel = effectiveTransport == 'polling'
          ? l10n.transportModePolling
          : l10n.transportModeWs;
      final filters = selectedModel?.filters ?? const [];
      final allowedQuickIds = <String>{
        'web',
        'image',
        ...tools.map((tool) => tool.id),
        ...filters.map((filter) => 'filter:${filter.id}'),
      };
      final selectedQuickPills = appSettings.quickPills
          .where((id) => allowedQuickIds.contains(id))
          .toList();
      final quickPillsSubtitle = l10n.quickActionsSelectedCount(
        selectedQuickPills.length,
      );
      final advancedPromptSubtitle = models.isEmpty
          ? l10n.noAccessibleModelsFound
          : l10n.accessibleModelsCount(models.length);

      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: NativeSheetRoutes.appCustomization,
          title: l10n.appAndChat,
          subtitle: l10n.appAndChatSubtitle,
          items: [
            NativeSheetItemConfig(
              id: 'display',
              title: l10n.display,
              subtitle: '${activePalette.label(l10n)} · $themeDescription',
              sfSymbol: 'rectangle.3.group.fill',
            ),
            NativeSheetItemConfig(
              id: 'language',
              title: l10n.appLanguage,
              subtitle: languageLabel,
              sfSymbol: 'globe',
            ),
            NativeSheetItemConfig(
              id: 'app-chat-settings',
              title: l10n.chatSettings,
              subtitle: transportNavLabel,
              sfSymbol: 'bubble.left.and.bubble.right.fill',
            ),
            NativeSheetItemConfig(
              id: 'advanced-prompt-overrides',
              title: l10n.advancedPromptOverrides,
              subtitle: advancedPromptSubtitle,
              sfSymbol: 'cube.box.fill',
            ),
            if (socketService != null)
              NativeSheetItemConfig(
                id: 'socket-health',
                title: l10n.connectionHealth,
                subtitle: nativeSocketHealthSummary(
                  l10n,
                  socketService.currentHealth,
                ),
                sfSymbol: 'waveform.path.ecg',
              ),
          ],
        ),
        detailSheets: [
          NativeSheetDetailConfig(
            id: 'display',
            title: l10n.display,
            subtitle: themeDescription,
            items: [
              NativeSheetItemConfig(
                id: 'theme-light',
                title: l10n.darkMode,
                subtitle: themeDescription,
                sfSymbol: 'moon.stars',
                kind: NativeSheetItemKind.segment,
                value: themeMode.name,
                options: [
                  NativeSheetOptionConfig(id: 'system', label: l10n.system),
                  NativeSheetOptionConfig(id: 'light', label: l10n.themeLight),
                  NativeSheetOptionConfig(id: 'dark', label: l10n.themeDark),
                ],
              ),
              NativeSheetItemConfig(
                id: 'theme-palette',
                title: l10n.themePalette,
                subtitle: activePalette.label(l10n),
                sfSymbol: 'paintpalette',
                kind: NativeSheetItemKind.dropdown,
                value: activePalette.id,
                options: [
                  for (final theme in TweakcnThemes.all)
                    NativeSheetOptionConfig(
                      id: theme.id,
                      label: theme.label(l10n),
                    ),
                ],
              ),
              NativeSheetItemConfig(
                id: 'quick-pills',
                title: quickActionsTitle,
                subtitle: quickPillsSubtitle,
                sfSymbol: 'bolt.fill',
              ),
            ],
          ),
          NativeSheetDetailConfig(
            id: 'language',
            title: l10n.appLanguage,
            subtitle: languageLabel,
            items: [
              NativeSheetItemConfig(
                id: 'language',
                title: l10n.appLanguage,
                subtitle: languageLabel,
                sfSymbol: 'globe',
                kind: NativeSheetItemKind.dropdown,
                value: currentLanguageTag,
                options: nativeLanguageDropdownOptions(l10n),
              ),
            ],
          ),
          buildNativeLoadingDetail(
            l10n: l10n,
            id: 'quick-pills',
            title: quickActionsTitle,
            subtitle: quickPillsSubtitle,
          ),
          NativeSheetDetailConfig(
            id: 'app-chat-settings',
            title: l10n.chatSettings,
            subtitle: l10n.chatSettings,
            items: [
              if (transportAvail.allowPolling &&
                  transportAvail.allowWebsocketOnly)
                NativeSheetItemConfig(
                  id: 'transport-mode',
                  title: l10n.transportMode,
                  subtitle: transportNavLabel,
                  sfSymbol: 'network',
                  kind: NativeSheetItemKind.segment,
                  value: effectiveTransport == 'ws' ? 'ws' : 'polling',
                  options: [
                    NativeSheetOptionConfig(
                      id: 'polling',
                      label: l10n.transportModePolling,
                    ),
                    NativeSheetOptionConfig(
                      id: 'ws',
                      label: l10n.transportModeWs,
                    ),
                  ],
                )
              else
                NativeSheetItemConfig(
                  id: 'transport-fixed',
                  title: l10n.transportMode,
                  subtitle: transportNavLabel,
                  sfSymbol: 'network',
                  kind: NativeSheetItemKind.info,
                ),
              NativeSheetItemConfig(
                id: 'send-on-enter',
                title: l10n.sendOnEnter,
                subtitle: l10n.sendOnEnterDescription,
                sfSymbol: 'paperplane',
                kind: NativeSheetItemKind.toggle,
                value: appSettings.sendOnEnter,
              ),
              NativeSheetItemConfig(
                id: 'temporary-chat-default',
                title: l10n.temporaryChatByDefault,
                subtitle: l10n.temporaryChatByDefaultDescription,
                sfSymbol: 'clock.arrow.circlepath',
                kind: NativeSheetItemKind.toggle,
                value: appSettings.temporaryChatByDefault,
              ),
              NativeSheetItemConfig(
                id: 'disable-haptics-streaming',
                title: l10n.disableHapticsWhileStreaming,
                subtitle: l10n.disableHapticsWhileStreamingDescription,
                sfSymbol: 'waveform.path',
                kind: NativeSheetItemKind.toggle,
                value: appSettings.disableHapticsWhileStreaming,
              ),
            ],
          ),
          buildNativeLoadingDetail(
            l10n: l10n,
            id: 'advanced-prompt-overrides',
            title: l10n.advancedPromptOverrides,
            subtitle: l10n.advancedPromptOverridesDescription,
          ),
          if (socketService != null)
            NativeSheetDetailConfig(
              id: 'socket-health',
              title: l10n.connectionHealth,
              subtitle: nativeSocketHealthSummary(
                l10n,
                socketService.currentHealth,
              ),
              items: nativeSocketHealthItems(l10n, socketService.currentHealth),
            ),
        ],
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-app-customization-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _hydrateNativeDefaultModelDetail(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    try {
      final models = await _ref.read(modelsProvider.future);
      if (!context.mounted) return;
      final appSettings = _ref.read(appSettingsProvider);
      await _applyNativeDetail(
        buildNativeDefaultModelDetail(
          l10n,
          models: models,
          selectedModelId: appSettings.defaultModel,
        ),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-default-model-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError('default-model', l10n.failedToLoadModels);
    }
  }

  Future<void> _hydrateNativeAdvancedPromptDetail(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    try {
      final models = await _ref.read(modelsProvider.future);
      if (!context.mounted) return;
      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: 'advanced-prompt-overrides',
          title: l10n.advancedPromptOverrides,
          subtitle: models.isEmpty
              ? l10n.noAccessibleModelsFound
              : l10n.accessibleModelsCount(models.length),
          items: models.isEmpty
              ? [
                  NativeSheetItemConfig(
                    id: 'advanced-prompt-empty',
                    title: l10n.noAccessibleModelsFound,
                    sfSymbol: 'exclamationmark.triangle',
                    kind: NativeSheetItemKind.info,
                  ),
                ]
              : [
                  for (final model in models)
                    NativeSheetItemConfig(
                      id: 'model-prompt:${Uri.encodeComponent(model.id)}',
                      title: model.name,
                      sfSymbol: 'cpu',
                    ),
                ],
        ),
        detailSheets: buildNativeModelPromptLoadingDetails(l10n, models),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-advanced-prompt-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError(
        'advanced-prompt-overrides',
        l10n.unableToLoadModels,
      );
    }
  }

  Future<void> _hydrateNativeSystemPromptDetail(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    try {
      final settings = await _ref.read(personalizationSettingsProvider.future);
      if (!context.mounted) return;
      await _applyNativeDetail(
        buildNativeSystemPromptDetail(l10n, value: settings.systemPrompt ?? ''),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-system-prompt-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError(
        'system-prompt',
        l10n.unableToLoadOpenWebuiSettings,
      );
    }
  }

  Future<void> _hydrateNativeMemoryDetail(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    try {
      final settingsFuture = _ref.read(personalizationSettingsProvider.future);
      final memoriesFuture = _ref.read(userMemoriesProvider.future);
      final settings = await settingsFuture;
      final memories = await memoriesFuture;
      if (!context.mounted) return;

      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: 'personalization-memory',
          title: l10n.memoryTitle,
          subtitle: settings.memoryEnabled
              ? l10n.memoryEnabledDescription
              : l10n.memoryDisabledDescription,
          items: [
            NativeSheetItemConfig(
              id: 'memory-enabled',
              title: l10n.memoryTitle,
              subtitle: settings.memoryEnabled
                  ? l10n.memoryEnabledDescription
                  : l10n.memoryDisabledDescription,
              sfSymbol: 'bookmark.fill',
              kind: NativeSheetItemKind.toggle,
              value: settings.memoryEnabled,
            ),
            NativeSheetItemConfig(
              id: 'memory-manage',
              title: l10n.manageMemories,
              subtitle: l10n.savedMemoriesCount(memories.length),
              sfSymbol: 'rectangle.stack',
            ),
          ],
        ),
        detailSheets: [
          buildNativeLoadingDetail(
            l10n: l10n,
            id: 'memory-manage',
            title: l10n.manageMemories,
            subtitle: l10n.savedMemoriesCount(memories.length),
          ),
        ],
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-memory-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError(
        'personalization-memory',
        l10n.unableToLoadOpenWebuiSettings,
      );
    }
  }

  Future<void> _hydrateNativeMemoryManageDetail(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    try {
      final memories = await _ref.read(userMemoriesProvider.future);
      if (!context.mounted) return;

      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: 'memory-manage',
          title: l10n.manageMemories,
          subtitle: l10n.savedMemoriesCount(memories.length),
          items: [
            NativeSheetItemConfig(
              id: 'memory-add',
              title: l10n.addMemory,
              subtitle: l10n.manageMemoriesDescription,
              sfSymbol: 'plus.circle',
            ),
            if (memories.isEmpty)
              NativeSheetItemConfig(
                id: 'memory-empty-info',
                title: l10n.noMemoriesSaved,
                sfSymbol: 'note.text',
                kind: NativeSheetItemKind.info,
              )
            else ...[
              for (final memory in memories)
                NativeSheetItemConfig(
                  id: 'memory-edit:${Uri.encodeComponent(memory.id)}',
                  title: truncateNativeSheetMemory(memory.content),
                  subtitle: nativeSheetMemoryUpdatedSubtitle(l10n, memory),
                  sfSymbol: 'quote.bubble',
                ),
              NativeSheetItemConfig(
                id: 'memory-clear-all',
                title: l10n.clearAllMemories,
                subtitle: l10n.clearAllMemoriesDescription,
                sfSymbol: 'clear',
                destructive: true,
              ),
            ],
          ],
        ),
        detailSheets: [
          buildNativeMemoryAddDetail(l10n),
          ...buildNativeMemoryEditDetails(l10n, memories),
        ],
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-memory-manage-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError(
        'memory-manage',
        l10n.unableToLoadOpenWebuiSettings,
      );
    }
  }

  Future<void> _hydrateNativeQuickPillsDetail(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    try {
      final tools = await _ref.read(toolsListProvider.future);
      if (!context.mounted) return;
      final quickActionsTitle = nativeQuickActionsTitle(l10n);
      final appSettings = _ref.read(appSettingsProvider);
      final selectedModel = _ref.read(selectedModelProvider);
      final filters = selectedModel?.filters ?? const [];
      final allowedIds = <String>{
        'web',
        'image',
        ...tools.map((tool) => tool.id),
        ...filters.map((filter) => 'filter:${filter.id}'),
      };
      final selected = appSettings.quickPills
          .where((id) => allowedIds.contains(id))
          .toSet();

      await NativeSheetBridge.instance.applyDetailPatch(
        detailId: 'quick-pills',
        items: [
          NativeSheetItemConfig(
            id: 'quick-pill:web',
            title: l10n.web,
            sfSymbol: 'magnifyingglass',
            kind: NativeSheetItemKind.toggle,
            value: selected.contains('web'),
          ),
          NativeSheetItemConfig(
            id: 'quick-pill:image',
            title: l10n.imageGen,
            sfSymbol: 'photo',
            kind: NativeSheetItemKind.toggle,
            value: selected.contains('image'),
          ),
          for (final tool in tools)
            NativeSheetItemConfig(
              id: 'quick-pill:${tool.id}',
              title: tool.name,
              sfSymbol: 'puzzlepiece.extension',
              kind: NativeSheetItemKind.toggle,
              value: selected.contains(tool.id),
            ),
          for (final filter in filters)
            NativeSheetItemConfig(
              id: 'quick-pill:filter:${filter.id}',
              title: filter.name,
              sfSymbol: 'sparkles',
              kind: NativeSheetItemKind.toggle,
              value: selected.contains('filter:${filter.id}'),
            ),
          if (selected.isNotEmpty)
            NativeSheetItemConfig(
              id: 'quick-pills-clear',
              title: l10n.clear,
              subtitle: quickActionsTitle,
              sfSymbol: 'xmark.circle',
              destructive: true,
            ),
        ],
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-quick-pills-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError(
        'quick-pills',
        l10n.unableToLoadOpenWebuiSettings,
      );
    }
  }

  Future<void> _hydrateNativeModelPromptDetail(
    BuildContext context,
    String detailId,
    AppLocalizations l10n,
  ) async {
    final encodedModel = detailId.substring('model-prompt:'.length);
    final modelId = Uri.decodeComponent(encodedModel);

    Future<void> patchFailure() async {
      await NativeSheetBridge.instance.applyDetailPatch(
        detailId: detailId,
        items: [
          NativeSheetItemConfig(
            id: 'model-prompt-error:$encodedModel',
            title: l10n.unableToLoadModels,
            sfSymbol: 'exclamationmark.triangle',
            kind: NativeSheetItemKind.info,
          ),
        ],
      );
    }

    final api = _ref.read(apiServiceProvider);
    if (api == null) {
      await patchFailure();
      return;
    }

    final detail = await api.getModelDetails(modelId);
    if (!context.mounted) return;
    if (detail == null) {
      await NativeSheetBridge.instance.applyDetailPatch(
        detailId: detailId,
        items: [
          NativeSheetItemConfig(
            id: 'model-prompt-error:$encodedModel',
            title: l10n.modelNoEditableServerRecord,
            sfSymbol: 'exclamationmark.triangle',
            kind: NativeSheetItemKind.info,
          ),
        ],
      );
      return;
    }

    final writeAccess = detail['write_access'] == true;
    var prompt = '';
    final params = detail['params'];
    if (params is Map && params['system'] is String) {
      prompt = (params['system'] as String).trim();
    }

    final items = writeAccess
        ? [
            NativeSheetItemConfig(
              id: 'model-system-prompt:$encodedModel',
              title: l10n.enterSystemPrompt,
              sfSymbol: 'text.bubble',
              kind: NativeSheetItemKind.multilineTextField,
              value: prompt,
              placeholder: l10n.enterSystemPrompt,
            ),
          ]
        : [
            NativeSheetItemConfig(
              id: 'model-prompt-readonly:$encodedModel',
              title: l10n.modelNoWriteAccessDescription,
              subtitle: prompt.isEmpty ? '—' : prompt,
              sfSymbol: 'lock.fill',
              kind: NativeSheetItemKind.info,
            ),
          ];

    await NativeSheetBridge.instance.applyDetailPatch(
      detailId: detailId,
      subtitle: l10n.modelSystemPromptEditorDescription,
      items: items,
    );
  }

  Future<void> _patchNativeDetailError(String detailId, String title) {
    return NativeSheetBridge.instance.applyDetailPatch(
      detailId: detailId,
      items: [
        NativeSheetItemConfig(
          id: '$detailId-error',
          title: title,
          sfSymbol: 'exclamationmark.triangle',
          kind: NativeSheetItemKind.info,
        ),
      ],
    );
  }

  Future<void> _applyNativeDetail(
    NativeSheetDetailConfig detail, {
    List<NativeSheetDetailConfig> detailSheets = const [],
  }) {
    return NativeSheetBridge.instance.applyDetailPatch(
      detailId: detail.id,
      title: detail.title,
      subtitle: detail.subtitle,
      items: detail.items,
      detailSheets: detailSheets,
    );
  }
}
