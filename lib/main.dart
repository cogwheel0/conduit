import 'dart:async';
import 'dart:developer' as developer;
import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/widgets/error_boundary.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'core/providers/app_providers.dart';
import 'core/persistence/hive_bootstrap.dart';
import 'core/persistence/hive_prefs_migrator.dart';
import 'core/persistence/persistence_migrator.dart';
import 'core/persistence/persistence_providers.dart';
import 'core/persistence/preferences_store.dart';
import 'core/router/app_router.dart';
import 'core/services/native_sheet_bridge.dart';
import 'core/services/native_sheet_hydration_service.dart';
import 'core/services/performance_profiler.dart';
import 'core/services/carplay_service.dart';
import 'core/services/settings_service.dart';
import 'core/sync/request_completion_runner_provider.dart';
import 'core/utils/tts_voice_utils.dart';
import 'core/utils/current_localizations.dart';
import 'features/auth/providers/unified_auth_providers.dart';
import 'features/chat/services/request_completion_runner.dart';
import 'features/chat/providers/text_to_speech_provider.dart';
import 'features/chat/providers/chat_providers.dart' show restoreDefaultModel;
import 'features/tools/providers/tools_providers.dart';
import 'core/utils/debug_logger.dart';
import 'core/utils/system_ui_style.dart';
import 'core/models/tool.dart';

import 'package:conduit/l10n/app_localizations.dart';
import 'core/services/quick_actions_service.dart';
import 'core/providers/app_startup_providers.dart';
import 'features/notifications/services/local_notification_service.dart';

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
      unawaited(
        pdfrxFlutterInitialize().catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          DebugLogger.error(
            'pdf-engine-warmup',
            scope: 'app/startup',
            error: error,
            stackTrace: stackTrace,
          );
        }),
      );
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

      // Preload shared_preferences so synchronous preference reads (theme,
      // locale, settings, drawer/sidebar state) are available before the first
      // build. MUST complete before the ProviderContainer is created.
      await PreferencesStore.ensureInitialized();
      _startupTimeline?.instant('prefs_ready');

      // Run migration checks (fast-pathed after first run).
      final migrator = PersistenceMigrator(hiveBoxes: hiveBoxes);
      await migrator.migrateIfNeeded();
      // Copy Hive-resident preferences into shared_preferences (PR-1 of the
      // Hive removal). Runs once; gated + crash-safe.
      await HivePrefsMigrator(hiveBoxes: hiveBoxes).migrateIfNeeded();
      _startupTimeline?.instant('migration_complete');

      // Finish timeline after first frame paints
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _startupTimeline?.instant('first_frame_rendered');
        _startupTimeline?.finish();
        _startupTimeline = null;
      });

      final providerContainer = ProviderContainer(
        overrides: [
          secureStorageProvider.overrideWithValue(secureStorage),
          hiveBoxesProvider.overrideWithValue(hiveBoxes),
          // Inversion seam (E3): the core/sync drainer reads the no-op
          // RequestCompletionRunner stub; bind it to the chat implementation so
          // queued completions re-enter the streaming pipeline.
          requestCompletionRunnerProvider.overrideWith(
            (ref) => ref.watch(chatRequestCompletionRunnerProvider),
          ),
        ],
      );
      // CarPlay can cold-launch Conduit without a visible Flutter scene, so
      // install its method-channel handler before frame-scheduled startup work.
      providerContainer.read(carPlayCoordinatorProvider);

      runApp(
        UncontrolledProviderScope(
          container: providerContainer,
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
    ref.read(userScopedProviderCleanupProvider);
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
        unawaited(
          ref.read(nativeSheetHydrationServiceProvider).hydrateDetail(detailId),
        );
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
        scope: 'native/sheet',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Mirrors the three Open WebUI-aligned notification prefs to the server when
  /// toggled from the iOS native sheet. Fire-and-forget: local persistence has
  /// already succeeded, so a failed sync only loses cross-device parity.
  void _syncNotificationPrefsToServer({
    bool? enabled,
    bool? sound,
    bool? soundAlways,
  }) {
    final api = ref.read(apiServiceProvider);
    if (api == null) return;
    unawaited(
      api
          .updateUserNotificationSettings(
            notificationEnabled: enabled,
            notificationSound: sound,
            notificationSoundAlways: soundAlways,
          )
          .then(
            (_) {},
            onError: (Object e, StackTrace st) {
              DebugLogger.error(
                'failed to sync notification prefs to server',
                error: e,
                stackTrace: st,
                scope: 'notifications/settings',
              );
            },
          ),
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

      if (event.id == 'tts-voice-picker' && value is String) {
        await _handleNativeTtsVoiceSelection(
          value == '__default__' ? ttsSystemDefaultVoiceId : value,
        );
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
            await _refreshNativeVoiceDetail();
          } else if (value == SttPreference.deviceOnly.name) {
            await ref
                .read(appSettingsProvider.notifier)
                .setSttPreference(SttPreference.deviceOnly);
            await _refreshNativeVoiceDetail();
          }
        case 'stt-language-code':
          if (value is String) {
            final normalized = SettingsService.normalizeSttLanguageCode(value);
            if (normalized != null ||
                SettingsService.isSttLanguageAutoInput(value)) {
              await ref
                  .read(appSettingsProvider.notifier)
                  .setSttLanguageCode(normalized);
              await _refreshNativeVoiceDetail();
            } else {
              DebugLogger.validation(
                'Ignoring invalid native STT language code',
                scope: 'native/sheet',
                data: {'value': value},
              );
              await _refreshNativeVoiceDetail();
            }
          }
        case 'tts-engine':
          final notifier = ref.read(appSettingsProvider.notifier);
          if (value == TtsEngine.server.name) {
            await notifier.setTtsEngineSelection(TtsEngine.server);
            await _refreshNativeVoiceDetail();
          } else if (value == TtsEngine.device.name) {
            await notifier.setTtsEngineSelection(TtsEngine.device);
            await _refreshNativeVoiceDetail();
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
        case 'notifications-enabled':
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setNotificationsEnabled(value);
            _syncNotificationPrefsToServer(enabled: value);
            if (value) {
              // Best-effort OS permission on opt-in; OS governs delivery.
              await ref
                  .read(localNotificationServiceProvider)
                  .requestPermissions();
            }
          }
        case 'notification-in-app-banner':
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setNotificationInAppBanner(value);
          }
        case 'notification-system':
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setNotificationSystem(value);
          }
        case 'notification-sound':
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setNotificationSound(value);
            _syncNotificationPrefsToServer(sound: value);
          }
        case 'notification-sound-always':
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setNotificationSoundAlways(value);
            _syncNotificationPrefsToServer(soundAlways: value);
          }
        case 'notification-chat':
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setNotificationChatEnabled(value);
          }
        case 'notification-channel':
          if (value is bool) {
            await ref
                .read(appSettingsProvider.notifier)
                .setNotificationChannelEnabled(value);
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
        scope: 'native/sheet',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  String? _normalizeOptionalNativeText(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  Future<void> _refreshNativeVoiceDetail() {
    return ref
        .read(nativeSheetHydrationServiceProvider)
        .hydrateDetail(NativeSheetRoutes.voice);
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
    final fallbackDisplayName = event.value is String
        ? event.value as String
        : null;
    await _handleNativeTtsVoiceSelection(
      voiceKey == '__default__' ? ttsSystemDefaultVoiceId : voiceKey,
      fallbackDisplayName: fallbackDisplayName,
    );
  }

  Future<void> _handleNativeTtsVoiceSelection(
    String voiceKey, {
    String? fallbackDisplayName,
  }) async {
    final settings = ref.read(appSettingsProvider);
    final notifier = ref.read(appSettingsProvider.notifier);

    if (voiceKey == ttsSystemDefaultVoiceId) {
      if (settings.ttsEngine == TtsEngine.server) {
        await notifier.setTtsServerVoiceSelection(null, null);
      } else {
        await notifier.setTtsDeviceVoiceSelection(null, null);
      }
      await _refreshNativeVoiceDetail();
      return;
    }

    var selectedId = voiceKey;
    var displayName = fallbackDisplayName ?? voiceKey;
    final l10n = currentAppLocalizations();
    try {
      final ttsService = ref.read(textToSpeechServiceProvider);
      await ttsService.updateSettings(engine: settings.ttsEngine);
      final voices = await ttsService.getAvailableVoices();
      final selected = findTtsVoiceOption(
        l10n,
        settings.ttsEngine,
        voices,
        voiceKey,
      );
      if (selected != null) {
        selectedId = selected.id;
        displayName = selected.label;
      }
    } catch (error, stackTrace) {
      DebugLogger.warning(
        'native-tts-voice-selection-lookup-failed',
        scope: 'native/sheet',
        data: {'error': error, 'stackTrace': stackTrace},
      );
    }

    if (settings.ttsEngine == TtsEngine.server) {
      await notifier.setTtsServerVoiceSelection(selectedId, displayName);
    } else {
      await notifier.setTtsDeviceVoiceSelection(selectedId, displayName);
    }
    await _refreshNativeVoiceDetail();
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
            child: _KeyboardDismissOnScroll(child: safeChild),
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
