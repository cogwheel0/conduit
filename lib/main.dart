import 'dart:async';
import 'dart:developer' as developer;
import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/widgets/error_boundary.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'core/providers/app_providers.dart';
import 'core/persistence/hive_bootstrap.dart';
import 'core/persistence/persistence_migrator.dart';
import 'core/persistence/persistence_providers.dart';
import 'core/router/app_router.dart';
import 'core/services/native_sheet_bridge.dart';
import 'core/services/navigation_service.dart';
import 'core/services/performance_profiler.dart';
import 'core/services/settings_service.dart';
import 'features/auth/providers/unified_auth_providers.dart';
import 'features/chat/providers/text_to_speech_provider.dart';
import 'features/chat/providers/chat_providers.dart' show restoreDefaultModel;
import 'features/tools/providers/tools_providers.dart';
import 'core/utils/debug_logger.dart';
import 'core/utils/native_sheet_utils.dart';
import 'core/utils/system_ui_style.dart';
import 'core/models/tool.dart';

import 'package:conduit/l10n/app_localizations.dart';
import 'core/services/quick_actions_service.dart';
import 'core/providers/app_startup_providers.dart';
import 'shared/theme/tweakcn_themes.dart';

const bool _enableFlutterDriverExtension = bool.fromEnvironment(
  'ENABLE_FLUTTER_DRIVER_EXTENSION',
  defaultValue: false,
);

Locale? _localeFromNativeTag(String code) {
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

developer.TimelineTask? _startupTimeline;

void main() {
  if (_enableFlutterDriverExtension) {
    enableFlutterDriverExtension();
  }

  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      PerformanceProfiler.instance.attachFrameTimings();

      // Global error handlers
      FlutterError.onError = (FlutterErrorDetails details) {
        DebugLogger.error(
          'flutter-error',
          scope: 'app/framework',
          error: details.exception,
        );
        final stack = details.stack;
        if (stack != null) {
          debugPrintStack(stackTrace: stack);
        }
      };
      WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
        DebugLogger.error(
          'platform-error',
          scope: 'app/platform',
          error: error,
          stackTrace: stack,
        );
        debugPrintStack(stackTrace: stack);
        return true;
      };

      // Start startup timeline instrumentation
      _startupTimeline = developer.TimelineTask();
      _startupTimeline!.start('app_startup');
      _startupTimeline!.instant('bindings_initialized');

      // Edge-to-edge is now handled natively in MainActivity.kt for Android 15+
      // No need for SystemUiMode.edgeToEdge which is deprecated
      _startupTimeline?.instant('edge_to_edge_configured');

      try {
        await QuickActionsBootstrap.initialize();
      } catch (error, stackTrace) {
        DebugLogger.error(
          'quick-actions-bootstrap',
          scope: 'app/platform',
          error: error,
          stackTrace: stackTrace,
        );
      }

      const secureStorage = FlutterSecureStorage(
        aOptions: AndroidOptions(
          // Keep legacy Android storage readable until a storageNamespace
          // migration can move both encrypted data and wrapped keys.
          // ignore: deprecated_member_use
          sharedPreferencesName: 'conduit_secure_prefs',
          preferencesKeyPrefix: 'conduit_',
          resetOnError: false,
        ),
        iOptions: IOSOptions(
          accountName: 'conduit_secure_storage',
          synchronizable: false,
        ),
      );

      // Warm up secure storage on cold start. iOS Keychain access can be slow
      // on first read, which causes race conditions where auth token returns
      // null even when it exists. This pre-warms the keychain connection.
      try {
        await secureStorage
            .read(key: '_warmup')
            .timeout(const Duration(milliseconds: 500), onTimeout: () => null);
      } catch (_) {
        // Ignore warmup errors - this is best-effort
      }
      _startupTimeline?.instant('secure_storage_ready');

      // Initialize Hive (now optimized with migration state caching)
      final hiveBoxes = await HiveBootstrap.instance.ensureInitialized();
      _startupTimeline?.instant('hive_ready');

      // Run migration check (now fast-pathed after first run)
      final migrator = PersistenceMigrator(hiveBoxes: hiveBoxes);
      await migrator.migrateIfNeeded();
      _startupTimeline?.instant('migration_complete');

      // Finish timeline after first frame paints
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _startupTimeline?.instant('first_frame_rendered');
        _startupTimeline?.finish();
        _startupTimeline = null;
      });

      runApp(
        ProviderScope(
          overrides: [
            secureStorageProvider.overrideWithValue(secureStorage),
            hiveBoxesProvider.overrideWithValue(hiveBoxes),
          ],
          child: const ConduitApp(),
        ),
      );
      developer.Timeline.instantSync('runApp_called');
    },
    (error, stack) {
      DebugLogger.error(
        'zone-error',
        scope: 'app',
        error: error,
        stackTrace: stack,
      );
      debugPrintStack(stackTrace: stack);
    },
  );
}

class ConduitApp extends ConsumerStatefulWidget {
  const ConduitApp({super.key});

  @override
  ConsumerState<ConduitApp> createState() => _ConduitAppState();
}

class _ConduitAppState extends ConsumerState<ConduitApp> {
  Brightness? _lastAppliedOverlayBrightness;
  StreamSubscription<NativeSheetEvent>? _nativeSheetSubscription;
  final Map<String, String> _nativeSheetDraftValues = {};

  @override
  void initState() {
    super.initState();
    ref.read(quickActionsCoordinatorProvider);
    _nativeSheetSubscription = NativeSheetBridge.instance.events.listen(
      _handleNativeSheetEvent,
    );

    // Delay heavy provider initialization until after the first frame so the
    // initial paint stays responsive.
    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeAppState());
  }

  void _handleNativeSheetEvent(NativeSheetEvent event) {
    switch (event) {
      case NativeSheetLogoutRequested():
        unawaited(ref.read(authActionsProvider).logout());
      case NativeSheetDismissed():
        _nativeSheetDraftValues.clear();
        break;
      case NativeSheetControlChanged():
        unawaited(_handleNativeSheetControlChanged(event));
      case NativeSheetDetailAppeared(:final detailId):
        unawaited(_hydrateNativeSheetDetail(detailId));
      case NativeEditProfileCommitted():
        unawaited(_handleNativeEditProfileCommitted(event));
    }
  }

  Future<void> _handleNativeEditProfileCommitted(
    NativeEditProfileCommitted event,
  ) async {
    try {
      final account =
          ref.read(accountProfileProvider).asData?.value ??
          await ref.read(accountProfileProvider.future);
      if (account == null) return;

      await ref
          .read(accountProfileProvider.notifier)
          .save(
            name: event.name.trim(),
            profileImageUrl: event.profileImageUrl.trim(),
            bio: event.bio,
            gender: _normalizeOptionalNativeText(event.gender),
            dateOfBirth: _normalizeOptionalNativeText(event.dateOfBirth),
            timezone: account.timezone,
          );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-edit-profile-commit-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _hydrateNativeSheetDetail(String detailId) async {
    final ctx = NavigationService.context;
    if (ctx == null || !ctx.mounted) return;
    final l10n = AppLocalizations.of(ctx);
    if (l10n == null) return;

    switch (detailId) {
      case NativeSheetRoutes.accountSettings:
        await _hydrateNativeAccountSettingsDetail(l10n);
        return;
      case NativeSheetRoutes.appearance:
      case NativeSheetRoutes.chats:
      case NativeSheetRoutes.dataConnection:
        await _hydrateNativeSignalStyleSettingsDetails(ctx, l10n);
        return;
      case NativeSheetRoutes.aiMemory:
        await _hydrateNativeAiMemoryDetail(l10n);
        return;
      case NativeSheetRoutes.helpAbout:
        await _hydrateNativeAboutDetail(
          l10n,
          detailId: NativeSheetRoutes.helpAbout,
        );
        return;
      case NativeSheetRoutes.about:
        await _hydrateNativeAboutDetail(l10n);
        return;
      case NativeSheetRoutes.appCustomization:
        await _hydrateNativeAppCustomizationDetail(ctx, l10n);
        return;
      case NativeSheetRoutes.personalization:
        await _hydrateNativePersonalizationDetail(l10n);
        return;
      case 'advanced-prompt-overrides':
        await _hydrateNativeAdvancedPromptDetail(l10n);
        return;
      case 'default-model':
        await _hydrateNativeDefaultModelDetail(l10n);
        return;
      case 'memory-manage':
        await _hydrateNativeMemoryManageDetail(l10n);
        return;
      case 'quick-pills':
        await _hydrateNativeQuickPillsDetail(l10n);
        return;
      case 'system-prompt':
        await _hydrateNativeSystemPromptDetail(l10n);
        return;
      case 'personalization-memory':
        await _hydrateNativeMemoryDetail(l10n);
        return;
    }

    if (!detailId.startsWith('model-prompt:')) return;
    await _hydrateNativeModelPromptDetail(detailId, l10n);
  }

  Future<void> _hydrateNativeAboutDetail(
    AppLocalizations l10n, {
    String detailId = NativeSheetRoutes.about,
  }) async {
    try {
      final packageInfoFuture = ref.read(packageInfoProvider.future);
      final aboutFuture = ref.read(serverAboutInfoProvider.future);
      final packageInfo = await packageInfoFuture;
      final about = await aboutFuture;
      if (!mounted) return;

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
    AppLocalizations l10n,
  ) async {
    try {
      final about = await ref.read(serverAboutInfoProvider.future);
      if (!mounted) return;
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
    AppLocalizations l10n,
  ) async {
    try {
      final settingsFuture = ref.read(personalizationSettingsProvider.future);
      final modelsFuture = ref.read(modelsProvider.future);
      final settings = await settingsFuture;
      final models = await modelsFuture;
      if (!mounted) return;

      final appSettings = ref.read(appSettingsProvider);
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

  Future<void> _hydrateNativeAiMemoryDetail(AppLocalizations l10n) async {
    try {
      final settingsFuture = ref.read(personalizationSettingsProvider.future);
      final modelsFuture = ref.read(modelsProvider.future);
      final settings = await settingsFuture;
      final models = await modelsFuture;
      if (!mounted) return;

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

  Future<void> _hydrateNativeSignalStyleSettingsDetails(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    try {
      final platformBrightness = MediaQuery.platformBrightnessOf(context);
      final modelsFuture = ref.read(modelsProvider.future);
      final toolsFuture = ref.read(toolsListProvider.future);
      final models = await modelsFuture;
      final tools = await toolsFuture;
      if (!mounted) return;

      final appSettings = ref.read(appSettingsProvider);
      final themeMode = ref.read(appThemeModeProvider);
      final appLocale = ref.read(appLocaleProvider);
      final activePalette = ref.read(appThemePaletteProvider);
      final transportAvail = ref.read(socketTransportOptionsProvider);
      final selectedModel = ref.read(selectedModelProvider);
      final socketService = ref.read(socketServiceProvider);

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
      final modelsFuture = ref.read(modelsProvider.future);
      final toolsFuture = ref.read(toolsListProvider.future);
      final models = await modelsFuture;
      final tools = await toolsFuture;
      if (!mounted) return;
      final appSettings = ref.read(appSettingsProvider);
      final themeMode = ref.read(appThemeModeProvider);
      final appLocale = ref.read(appLocaleProvider);
      final activePalette = ref.read(appThemePaletteProvider);
      final transportAvail = ref.read(socketTransportOptionsProvider);
      final selectedModel = ref.read(selectedModelProvider);
      final socketService = ref.read(socketServiceProvider);
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

  Future<void> _hydrateNativeDefaultModelDetail(AppLocalizations l10n) async {
    try {
      final models = await ref.read(modelsProvider.future);
      if (!mounted) return;
      final appSettings = ref.read(appSettingsProvider);
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

  Future<void> _hydrateNativeAdvancedPromptDetail(AppLocalizations l10n) async {
    try {
      final models = await ref.read(modelsProvider.future);
      if (!mounted) return;
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

  Future<void> _hydrateNativeSystemPromptDetail(AppLocalizations l10n) async {
    try {
      final settings = await ref.read(personalizationSettingsProvider.future);
      if (!mounted) return;
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

  Future<void> _hydrateNativeMemoryDetail(AppLocalizations l10n) async {
    try {
      final settingsFuture = ref.read(personalizationSettingsProvider.future);
      final memoriesFuture = ref.read(userMemoriesProvider.future);
      final settings = await settingsFuture;
      final memories = await memoriesFuture;
      if (!mounted) return;

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

  Future<void> _hydrateNativeMemoryManageDetail(AppLocalizations l10n) async {
    try {
      final memories = await ref.read(userMemoriesProvider.future);
      if (!mounted) return;

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

  Future<void> _hydrateNativeQuickPillsDetail(AppLocalizations l10n) async {
    try {
      final tools = await ref.read(toolsListProvider.future);
      if (!mounted) return;
      final quickActionsTitle = nativeQuickActionsTitle(l10n);
      final appSettings = ref.read(appSettingsProvider);
      final selectedModel = ref.read(selectedModelProvider);
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

  Future<void> _hydrateNativeModelPromptDetail(
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

    final api = ref.read(apiServiceProvider);
    if (api == null) {
      await patchFailure();
      return;
    }

    final detail = await api.getModelDetails(modelId);
    if (!mounted) return;
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

  Future<void> _handleNativeSheetControlChanged(
    NativeSheetControlChanged event,
  ) async {
    final value = event.value;
    try {
      if (event.id.startsWith('tts-voice-pick:')) {
        await _handleNativeTtsVoicePick(event);
        return;
      }

      if (event.id.startsWith('memory-save:')) {
        final encoded = event.id.substring('memory-save:'.length);
        final memoryId = Uri.decodeComponent(encoded);
        if (value is String) {
          await ref
              .read(userMemoriesProvider.notifier)
              .updateItem(memoryId, value);
        }
        return;
      }

      if (event.id.startsWith('memory-delete:')) {
        final encoded = event.id.substring('memory-delete:'.length);
        await ref
            .read(userMemoriesProvider.notifier)
            .deleteItem(Uri.decodeComponent(encoded));
        return;
      }

      if (event.id.startsWith('quick-pill:')) {
        final pillId = event.id.substring('quick-pill:'.length);
        if (value is! bool) return;
        final tools = ref
            .read(toolsListProvider)
            .maybeWhen(data: (v) => v, orElse: () => const <Tool>[]);
        final selectedModel = ref.read(selectedModelProvider);
        final allowed = <String>{
          'web',
          'image',
          ...tools.map((t) => t.id),
          ...(selectedModel?.filters ?? const []).map((f) => 'filter:${f.id}'),
        };
        if (!allowed.contains(pillId)) return;
        final current = List<String>.from(
          ref.read(appSettingsProvider).quickPills,
        );
        if (value) {
          if (!current.contains(pillId)) current.add(pillId);
        } else {
          current.remove(pillId);
        }
        await ref.read(appSettingsProvider.notifier).setQuickPills(current);
        return;
      }

      if (event.id.startsWith('model-system-prompt:')) {
        final encoded = event.id.substring('model-system-prompt:'.length);
        final modelId = Uri.decodeComponent(encoded);
        if (value is! String) return;
        final api = ref.read(apiServiceProvider);
        if (api == null) return;
        await api.updateModelSystemPrompt(modelId, value);
        ref.invalidate(modelsProvider);
        return;
      }

      switch (event.id) {
        case 'default-model':
          if (value is String) {
            final modelId = value == 'auto-select' ? null : value;
            await ref
                .read(appSettingsProvider.notifier)
                .setDefaultModel(modelId);
            await restoreDefaultModel(ref);
          }
        case 'stt-silence-duration':
          final ms = switch (value) {
            final int i => i,
            final double d => d.round(),
            _ => int.tryParse('$value'),
          };
          if (ms != null) {
            await ref
                .read(appSettingsProvider.notifier)
                .setVoiceSilenceDuration(ms);
          }
        case 'tts-speech-rate':
          final rate = switch (value) {
            final double d => d,
            final int i => i.toDouble(),
            _ => double.tryParse('$value'),
          };
          if (rate != null) {
            await ref.read(appSettingsProvider.notifier).setTtsSpeechRate(rate);
          }
        case 'tts-preview':
          final text = value is String ? value : null;
          if (text == null || text.isEmpty) return;
          final controller = ref.read(textToSpeechControllerProvider.notifier);
          final speechState = ref.read(textToSpeechControllerProvider);
          if (speechState.isSpeaking || speechState.isBusy) {
            await controller.stop();
          } else {
            await controller.toggleForMessage(
              messageId: 'tts_preview',
              text: text,
            );
          }
        case 'memory-add-content':
          if (value is String && value.trim().isNotEmpty) {
            await ref.read(userMemoriesProvider.notifier).add(value.trim());
          }
        case 'memory-clear-all':
          await ref.read(userMemoriesProvider.notifier).clearAll();
        case 'memory-enabled':
          if (value is bool) {
            await ref
                .read(personalizationSettingsProvider.notifier)
                .setMemoryEnabled(value);
          }
        case 'system-prompt':
          if (value is String) {
            await ref
                .read(personalizationSettingsProvider.notifier)
                .setSystemPrompt(value);
          }
        case 'stt-engine':
          if (value == SttPreference.serverOnly.name) {
            await ref
                .read(appSettingsProvider.notifier)
                .setSttPreference(SttPreference.serverOnly);
          } else if (value == SttPreference.deviceOnly.name) {
            await ref
                .read(appSettingsProvider.notifier)
                .setSttPreference(SttPreference.deviceOnly);
          }
        case 'tts-engine':
          final notifier = ref.read(appSettingsProvider.notifier);
          if (value == TtsEngine.server.name) {
            await notifier.setTtsVoice(null);
            await notifier.setTtsEngine(TtsEngine.server);
          } else if (value == TtsEngine.device.name) {
            await notifier.setTtsEngine(TtsEngine.device);
          }
        case 'theme-light':
          switch (value) {
            case 'system':
              ref
                  .read(appThemeModeProvider.notifier)
                  .setTheme(ThemeMode.system);
            case 'light':
              ref.read(appThemeModeProvider.notifier).setTheme(ThemeMode.light);
            case 'dark':
              ref.read(appThemeModeProvider.notifier).setTheme(ThemeMode.dark);
          }
        case 'language':
          if (value == 'system') {
            await ref.read(appLocaleProvider.notifier).setLocale(null);
          } else if (value is String && value.isNotEmpty) {
            final locale = _localeFromNativeTag(value);
            if (locale != null) {
              await ref.read(appLocaleProvider.notifier).setLocale(locale);
            }
          }
        case 'theme-palette':
          if (value is String && value.isNotEmpty) {
            await ref.read(appThemePaletteProvider.notifier).setPalette(value);
          }
        case 'quick-pills-clear':
          await ref.read(appSettingsProvider.notifier).setQuickPills(const []);
        case 'send-on-enter':
          if (value is bool) {
            await ref.read(appSettingsProvider.notifier).setSendOnEnter(value);
          }
        case 'temporary-chat-default':
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setTemporaryChatByDefault(value);
          }
        case 'disable-haptics-streaming':
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setDisableHapticsWhileStreaming(value);
          }
        case 'transport-auto':
          await ref
              .read(appSettingsProvider.notifier)
              .setSocketTransportMode('auto');
        case 'transport-streaming':
          await ref
              .read(appSettingsProvider.notifier)
              .setSocketTransportMode('ws');
        case 'transport-mode':
          if (value == 'ws' || value == 'streaming') {
            await ref
                .read(appSettingsProvider.notifier)
                .setSocketTransportMode('ws');
          } else if (value == 'polling' || value == 'auto') {
            await ref
                .read(appSettingsProvider.notifier)
                .setSocketTransportMode('auto');
          }
        case 'current-password':
        case 'new-password':
        case 'confirm-password':
          await _saveNativePasswordDraft(event.id, value);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-sheet-control-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  String? _normalizeOptionalNativeText(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  Future<void> _saveNativePasswordDraft(String id, Object? value) async {
    if (value is! String) return;
    _nativeSheetDraftValues[id] = value;

    final current = _nativeSheetDraftValues['current-password'];
    final next = _nativeSheetDraftValues['new-password'];
    final confirm = _nativeSheetDraftValues['confirm-password'];
    if (current == null ||
        current.isEmpty ||
        next == null ||
        next.isEmpty ||
        confirm == null ||
        confirm.isEmpty) {
      return;
    }
    if (confirm != next) {
      return;
    }

    await ref
        .read(accountProfileProvider.notifier)
        .updatePassword(password: current, newPassword: next);
    _nativeSheetDraftValues.remove('current-password');
    _nativeSheetDraftValues.remove('new-password');
    _nativeSheetDraftValues.remove('confirm-password');
  }

  Future<void> _handleNativeTtsVoicePick(
    NativeSheetControlChanged event,
  ) async {
    final encoded = event.id.substring('tts-voice-pick:'.length);
    final voiceKey = Uri.decodeComponent(encoded);
    final settings = ref.read(appSettingsProvider);
    final notifier = ref.read(appSettingsProvider.notifier);

    if (voiceKey == '__default__') {
      if (settings.ttsEngine == TtsEngine.server) {
        await notifier.setTtsServerVoiceId(null);
        await notifier.setTtsServerVoiceName(null);
      } else {
        await notifier.setTtsVoice(null);
      }
      return;
    }

    final displayName = event.value is String
        ? event.value as String
        : voiceKey;
    if (settings.ttsEngine == TtsEngine.server) {
      await notifier.setTtsServerVoiceId(voiceKey);
      await notifier.setTtsServerVoiceName(displayName);
    } else {
      await notifier.setTtsVoice(voiceKey);
    }
  }

  void _initializeAppState() {
    DebugLogger.auth('init', scope: 'app');
    ref.read(appStartupFlowProvider.notifier).start();
  }

  @override
  void dispose() {
    _nativeSheetSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(appThemeModeProvider.select((mode) => mode));
    final router = ref.watch(goRouterProvider);
    final locale = ref.watch(appLocaleProvider);
    final lightTheme = ref.watch(appLightThemeProvider);
    final darkTheme = ref.watch(appDarkThemeProvider);
    final cupertinoLight = ref.watch(appCupertinoLightThemeProvider);
    final cupertinoDark = ref.watch(appCupertinoDarkThemeProvider);

    return ErrorBoundary(
      child: AdaptiveApp.router(
        routerConfig: router,
        onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
        materialLightTheme: lightTheme,
        materialDarkTheme: darkTheme,
        cupertinoLightTheme: cupertinoLight,
        cupertinoDarkTheme: cupertinoDark,
        themeMode: themeMode,
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        localeListResolutionCallback: (deviceLocales, supported) {
          if (locale != null) return locale;
          if (deviceLocales == null || deviceLocales.isEmpty) {
            return supported.first;
          }
          final resolved = _resolveSupportedLocale(deviceLocales, supported);
          return resolved ?? supported.first;
        },
        material: (_, _) =>
            const MaterialAppData(debugShowCheckedModeBanner: false),
        cupertino: (_, _) =>
            const CupertinoAppData(debugShowCheckedModeBanner: false),
        builder: (context, child) {
          // Resolve brightness from themeMode rather than
          // Theme.of(context) — on iOS, CupertinoApp's
          // auto-generated Theme may not reflect themeMode.
          final Brightness brightness;
          switch (themeMode) {
            case ThemeMode.dark:
              brightness = Brightness.dark;
            case ThemeMode.light:
              brightness = Brightness.light;
            case ThemeMode.system:
              brightness = MediaQuery.platformBrightnessOf(context);
          }
          if (_lastAppliedOverlayBrightness != brightness) {
            _lastAppliedOverlayBrightness = brightness;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              applySystemUiOverlayStyleOnce(brightness: brightness);
            });
          }
          final mediaQuery = MediaQuery.of(context);
          final safeChild = child ?? const SizedBox.shrink();

          // On iOS, AdaptiveApp creates CupertinoApp which
          // doesn't propagate Material ThemeExtensions.
          // Wrap with Theme to ensure all custom extensions
          // (ConduitThemeExtension, AppColorTokens, etc.)
          // are available via Theme.of(context) on every
          // platform.
          final materialTheme = brightness == Brightness.dark
              ? darkTheme
              : lightTheme;

          return Theme(
            data: materialTheme,
            child: MediaQuery(
              data: mediaQuery.copyWith(
                textScaler: mediaQuery.textScaler.clamp(
                  minScaleFactor: 1.0,
                  maxScaleFactor: 3.0,
                ),
              ),
              child: _KeyboardDismissOnScroll(child: safeChild),
            ),
          );
        },
      ),
    );
  }

  bool _prefersTraditionalChinese(Locale deviceLocale) {
    final script = deviceLocale.scriptCode?.toLowerCase();
    if (script == 'hant') return true;

    final country = deviceLocale.countryCode?.toUpperCase();
    return country == 'TW' || country == 'HK' || country == 'MO';
  }

  Locale? _resolveSupportedLocale(
    List<Locale>? deviceLocales,
    Iterable<Locale> supported,
  ) {
    if (deviceLocales == null || deviceLocales.isEmpty) return null;

    for (final device in deviceLocales) {
      final prefersTraditional = _prefersTraditionalChinese(device);
      final deviceLanguage = device.languageCode.toLowerCase();
      final deviceScript = device.scriptCode?.toLowerCase();
      final deviceCountry = device.countryCode?.toUpperCase();

      // Pass 1: match language with script (or preferred Traditional)
      for (final loc in supported) {
        final languageMatches =
            loc.languageCode.toLowerCase() == deviceLanguage;
        if (!languageMatches) continue;

        final locScript = loc.scriptCode?.toLowerCase();
        final scriptMatches =
            locScript != null &&
            locScript.isNotEmpty &&
            (locScript == deviceScript ||
                (loc.languageCode == 'zh' &&
                    locScript == 'hant' &&
                    prefersTraditional));
        if (!scriptMatches) continue;

        final locCountry = loc.countryCode?.toUpperCase();
        final countryMatches =
            locCountry == null ||
            locCountry.isEmpty ||
            locCountry == deviceCountry;

        if (countryMatches) {
          return loc;
        }
      }

      // Pass 2: prefer Traditional Chinese when applicable
      if (prefersTraditional) {
        for (final loc in supported) {
          if (loc.languageCode == 'zh' && loc.scriptCode == 'Hant') {
            return loc;
          }
        }
      }

      // Pass 3: language-only match
      for (final loc in supported) {
        if (loc.languageCode.toLowerCase() == deviceLanguage) {
          return loc;
        }
      }
    }

    return null;
  }
}

/// Dismisses the soft keyboard whenever the user scrolls.
class _KeyboardDismissOnScroll extends StatelessWidget {
  const _KeyboardDismissOnScroll({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<UserScrollNotification>(
      onNotification: (notification) {
        if (notification.direction == ScrollDirection.idle) {
          return false;
        }
        final focusedNode = FocusManager.instance.primaryFocus;
        if (focusedNode != null && focusedNode.hasFocus) {
          focusedNode.unfocus();
        }
        return false;
      },
      child: child,
    );
  }
}
