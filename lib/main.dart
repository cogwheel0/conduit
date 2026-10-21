import 'dart:async';
import 'dart:developer' as developer;

import 'package:conduit_core/conduit_core.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart'
    show
        LicenseEntryWithLineBreaks,
        LicenseRegistry,
        TargetPlatform,
        defaultTargetPlatform,
        kIsWeb;
import 'package:flutter_driver/driver_extension.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'shared/widgets/error_boundary.dart';
import 'platform/android_ime_inset_resync.dart';
import 'platform/flutter_app_lifecycle.dart';
import 'platform/flutter_clipboard_port.dart';
import 'platform/flutter_connectivity_port.dart';
import 'platform/realtime_pcm_audio.dart';
import 'platform/webrtc_realtime_media.dart';
import 'platform/url_launcher_open_external_url_port.dart';
import 'platform/pigeon_browser_auth_port.dart';
import 'platform/flutter_cookie_jar.dart';
import 'platform/flutter_flush_scheduler.dart';
import 'platform/flutter_post_frame_scheduler.dart';
import 'platform/ios_display_boost.dart';
import 'platform/mobile_background_execution.dart';
import 'platform/mobile_push_platform.dart';

import 'package:conduit_core/services/share_staging_cleanup.dart'
    show shareStagingDirectoryName;

import 'platform/ios_share_staging.dart';
import 'platform/just_audio_playback.dart';
import 'platform/record_audio_capture.dart';
import 'platform/flutter_secure_key_value_store.dart';
import 'platform/flutter_key_value_store.dart';
import 'platform/flutter_log_sink.dart';
import 'platform/flutter_worker_port.dart';
import 'platform/flutter_database_opener.dart';
import 'platform/geolocator_location_port.dart';
import 'platform/go_router_navigator.dart';
import 'platform/wakelock_plus_port.dart';

import 'package:conduit_core/providers/app_providers.dart';

import 'package:conduit_core/providers/host_ports.dart';

import 'package:conduit_core/network/conduit_user_agent.dart';

import 'core/persistence/hive_bootstrap.dart';
import 'core/utils/model_logos.dart';

import 'package:conduit_core/persistence/hive_prefs_migrator.dart';

import 'package:conduit_core/persistence/persistence_migrator.dart';

import 'package:conduit_core/persistence/persistence_providers.dart';
import 'package:conduit_core/persistence/preferences_store.dart';

import 'core/router/app_router.dart';
import 'core/services/native_sheet_bridge.dart';
import 'features/settings/settings_controller.dart';
import 'features/navigation/widgets/sidebar_user_pill.dart'
    show registerAppSettingsOpener;
import 'shared/services/flutter_ui_requests.dart';
import 'shared/services/raster_media_policy.dart';
import 'platform/carplay_service.dart';
import 'core/services/native_symbol_image_service.dart';

import 'package:conduit_core/services/readiness_gated_secure_storage.dart';
import 'package:conduit_core/features/chat/realtime_call/realtime_call_availability.dart';

import 'package:conduit_core/sync/request_completion_runner_provider.dart';

import 'core/utils/current_localizations.dart';
import 'features/push/push_host_bindings.dart';

import 'package:conduit_core/features/chat/services/request_completion_runner.dart';

import 'features/chat/providers/text_to_speech_provider.dart';
import 'core/services/callkit_service.dart';
import 'features/chat/services/voice_input_service.dart';
import 'features/chat/voice_mode/chat_voice_audio_session_coordinator.dart';
import 'features/chat/voice_mode/chat_voice_mode_controller.dart';

import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show
        chatWakelockCoordinatorProvider,
        isChatStreamingProvider,
        localChatGenerationActiveProvider;
import 'package:conduit_core/features/release_notes/release_notes_bootstrap.dart';

import 'features/release_notes/release_notes_coordinator.dart';
import 'l10n/conduit_localizations.dart';
import 'shared/widgets/legacy_design_compatibility.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import 'core/utils/system_ui_style.dart';

import 'package:conduit/l10n/app_localizations.dart';

import 'platform/quick_actions_service.dart';
import 'core/providers/app_startup_providers.dart';
import 'features/notifications/services/local_notification_service.dart';
import 'features/notifications/providers/notification_socket_listener.dart'
    show notificationRouterProvider;
import 'package:conduit_core/features/notifications/models/notification_scope.dart';
import 'shared/theme/theme_extensions.dart';
import 'shared/theme/theme_providers.dart';
import 'platform/frame_profiler.dart';
import 'features/direct_connections/providers/apple_pcc_providers.dart';
import 'features/direct_connections/services/apple_pcc_adapter.dart'
    show PigeonApplePccHost;

import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';

import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';

import 'features/hermes/services/hermes_dashboard_rest_bridge.dart';
import 'features/hermes/widgets/hermes_connection_switcher.dart';
import 'features/hermes/widgets/hermes_model_switch_prompt.dart';

import 'package:conduit_core/features/chat/providers/chat_handoff_providers.dart';

import 'features/chat/services/chat_handoff_host.dart';

import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/providers/openwebui_route_resolver.dart'
    show openWebUiRouteResolverProvider;

import 'core/services/background_streaming_handler.dart';

const bool _enableFlutterDriverExtension = bool.fromEnvironment(
  'ENABLE_FLUTTER_DRIVER_EXTENSION',
  defaultValue: false,
);

developer.TimelineTask? _startupTimeline;

Future<void> _configureUserAgent() async {
  try {
    final packageInfo = await PackageInfo.fromPlatform();
    ConduitUserAgent.configure(appVersion: packageInfo.version);
    _startupTimeline?.instant('user_agent_ready');
  } catch (error, stackTrace) {
    DebugLogger.error(
      'user-agent-version-unavailable',
      scope: 'app/startup',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

void _registerBundledLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const ['noVNC', 'pako'],
      await rootBundle.loadString('assets/computer/novnc-LICENSE.txt'),
    );
  });
  LicenseRegistry.addLicense(() async* {
    final notice = await rootBundle.loadString('THIRD_PARTY_NOTICES.md');
    yield LicenseEntryWithLineBreaks(const [
      'Open WebUI icon',
      'ddgs',
      'models.dev',
    ], notice);
  });
}

/// Whether this device runs realtime voice calls' audio: the native engine
/// and WebRTC exist on iOS and Android.
bool get _hasRealtimeAudio =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);

/// Whether this device signs in through the system browser: the
/// `BrowserAuthBridge` exists on iOS and Android.
bool get _hasBrowserAuth =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);

void main() {
  // Diagnostics have no destination until a host gives them one.
  // Installed first, so startup itself is logged.
  DebugLogger.sink = const FlutterLogSink();
  AudioPlaybackPort.hostFactory = JustAudioPlayback.new;
  BackgroundExecutionPort.hostDefault = const MobileBackgroundExecution();
  DisplayBoostPort.hostDefault = const IosDisplayBoost();
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    NativeSymbolImageService.hostRenderer = renderNativeSymbolThroughChannel;
  }
  LocationPort.hostDefault = const GeolocatorLocationPort();
  WakelockPort.hostDefault = const WakelockPlusPort();
  ShareStagingPort.hostDefault = IosShareStaging(
    stagingDirectoryName: shareStagingDirectoryName,
  );
  AudioCapturePort.hostFactory = RecordAudioCapture.new;
  // End-to-end-encrypted push: the keys and decryption live in the iOS
  // Notification Service Extension and the Android receiver.
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android)) {
    PushPlatformPort.hostDefault = MobilePushPlatform();
  }
  // The preference store is a host capability too; installed
  // before bootstrap awaits its first synchronous read.
  PreferencesStore.installLoader(FlutterKeyValueStore.load);

  if (_enableFlutterDriverExtension) {
    enableFlutterDriverExtension();
  }

  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      // Conduit intentionally owns separate direct-local and per-server files.
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      RasterMediaPolicy.configureGlobalImageCache();
      // Measure the complete Dart-side startup path, including the first plugin
      // calls. Package metadata is not required to paint the auth/theme shell;
      // ConduitUserAgent has a safe fallback until this best-effort update lands.
      _startupTimeline = developer.TimelineTask();
      _startupTimeline!.start('app_startup');
      _startupTimeline!.instant('bindings_initialized');
      unawaited(_configureUserAgent());

      _registerBundledLicenses();
      // Read by the synchronous avatar resolver; awaited before runApp.
      final modelLogosLoaded = ModelLogos.load();
      FrameProfiler.instance.attachFrameTimings();
      AndroidImeInsetResync.instance.install();

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

      // Edge-to-edge is now handled natively in MainActivity.kt for Android 15+
      // No need for SystemUiMode.edgeToEdge which is deprecated
      _startupTimeline?.instant('edge_to_edge_configured');

      // Platform options now live inside the adapter, so they cannot drift
      // apart from the ones SecureCredentialStorage used to keep separately.
      final secureStorage = FlutterSecureKeyValueStore();

      // Start independent platform/file work together. Quick Actions still
      // completes before runApp so a cold-launch action cannot be lost, while
      // storage initialization progresses in parallel with that plugin call.
      // Keep the underlying Keychain operation separate from the bounded
      // startup wait. `Future.timeout` does not cancel its source; awaiting
      // only the wrapper would let auth bootstrap start a second Keychain
      // read while the first one was still executing on iOS.
      final keychainWarmupRead = secureStorage
          .read(key: '_warmup')
          .catchError((Object _) => null);
      final keychainWarmupBarrier = keychainWarmupRead.then<void>((_) {});
      final keychainWarmupDeadline = waitForSecureStorageStartupDeadline(
        keychainWarmupBarrier,
      );
      unawaited(
        keychainWarmupRead.then<void>((_) {
          _startupTimeline?.instant('secure_storage_ready');
        }),
      );
      final hiveBoxesFuture = HiveBootstrap.instance.ensureInitialized();
      final preferencesFuture = PreferencesStore.ensureInitialized();
      final platformUiFuture = PlatformUiCapabilities.initialize();

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

      // Initialize Hive and preferences concurrently. Preferences must still be
      // ready before ProviderContainer construction because theme/locale reads
      // are synchronous.
      final hiveBoxes = await hiveBoxesFuture;
      _startupTimeline?.instant('hive_ready');
      await preferencesFuture;
      _startupTimeline?.instant('prefs_ready');
      await platformUiFuture;
      _startupTimeline?.instant('platform_ui_ready');

      // Run migration checks (fast-pathed after first run).
      final migrator = PersistenceMigrator(hiveBoxes: hiveBoxes);
      await migrator.migrateIfNeeded();
      // Copy Hive-resident preferences into shared_preferences (PR-1 of the
      // Hive removal). Runs once; gated + crash-safe.
      await HivePrefsMigrator(hiveBoxes: hiveBoxes).migrateIfNeeded();
      await captureReleaseNotesInstallProvenance();
      _startupTimeline?.instant('migration_complete');

      // Bound time-to-first-paint even if the platform call stalls. Provider
      // reads use the original in-flight operation as their barrier below, so
      // timing out here never starts a concurrent second Keychain access.
      await keychainWarmupDeadline;

      // Finish timeline after first frame paints
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _startupTimeline?.instant('first_frame_rendered');
        _startupTimeline?.finish();
        _startupTimeline = null;
      });

      // One WidgetsBindingObserver for the whole app; every engine that
      // cares about foreground/background now shares it.
      final appLifecycle = FlutterAppLifecycle();

      final providerContainer = ProviderContainer(
        overrides: [
          // Host ports. `lib/core` declares these without a value so it
          // stays free of Flutter plugins; each host binds its own.
          databaseOpenerProvider.overrideWithValue(
            const FlutterDatabaseOpener(),
          ),
          appLifecycleProvider.overrideWithValue(appLifecycle),
          workerPortProvider.overrideWithValue(const FlutterWorkerPort()),
          connectivityPortProvider.overrideWithValue(FlutterConnectivityPort()),
          cookieJarProvider.overrideWithValue(const FlutterCookieJar()),
          flushSchedulerProvider.overrideWithValue(
            const FlutterFlushScheduler(),
          ),
          postFrameSchedulerProvider.overrideWithValue(
            const FlutterPostFrameScheduler(),
          ),
          signOutResetTargetsProvider.overrideWithValue(
            themePreferenceResetTargets,
          ),
          // A reply streaming in the background (screen locked, another chat
          // open) is cut off by an account switch just like a visible one.
          accountChangeReplyGuardProvider.overrideWith((ref) {
            return () {
              try {
                return ref.read(isChatStreamingProvider) ||
                    ref.read(localChatGenerationActiveProvider) ||
                    BackgroundStreamingHandler.instance.hasActiveReplyStreams;
              } catch (_) {
                return false;
              }
            };
          }),
          // Replies still being written in the background are Open WebUI's,
          // which arrive through the active account's address.
          addressChangeReplyGuardProvider.overrideWith((ref) {
            return () {
              try {
                return (ref.read(isChatStreamingProvider) &&
                        conversationUsesOpenWebUiStorage(
                          ref.read(activeConversationProvider),
                        )) ||
                    BackgroundStreamingHandler.instance.hasActiveReplyStreams;
              } catch (_) {
                return false;
              }
            };
          }),
          // Posted notifications open in the account that posted them, so a
          // switch keeps them. Signing out of an account clears its own;
          // signing out of everything clears them all.
          hostSignedOutProvider.overrideWith((ref) {
            return (accountId) {
              // One still being routed (waiting on its sound or claim) for
              // that account shows nothing either.
              if (ref.read(notificationRouterProvider.exists)) {
                ref
                    .read(notificationRouterProvider)
                    .signedOut(
                      accountId == null
                          ? null
                          : NotificationScope.openWebUi(accountId).value,
                    );
              }
              final local = ref.read(localNotificationServiceProvider);
              final clearing = accountId == null
                  ? local.cancelAll()
                  : Future.wait([
                      local.cancelScope(
                        NotificationScope.openWebUi(accountId).value,
                      ),
                      // Pushes that arrived while the sign-out ran.
                      ref
                          .read(pushPlatformPortProvider)
                          .cancelScope(
                            NotificationScope.openWebUi(accountId).value,
                          ),
                    ]);
              unawaited(
                clearing.catchError((Object error, StackTrace stackTrace) {
                  DebugLogger.error(
                    'sign-out-notification-clear-failed',
                    scope: 'notifications/system',
                    error: error,
                    stackTrace: stackTrace,
                  );
                }),
              );
            };
          }),
          // A deleted Hermes connection takes its push subscription and its
          // posted notifications with it. Push goes first, while the
          // connection's key still works.
          hostHermesConnectionRemovingProvider.overrideWith((ref) {
            return (connectionId) async {
              await ref
                  .read(pushSignOutHookProvider)
                  .beforeHermesConnectionRemoved(connectionId);
              final scope = NotificationScope.hermes(connectionId).value;
              try {
                await ref
                    .read(localNotificationServiceProvider)
                    .cancelScope(scope);
              } catch (error, stackTrace) {
                DebugLogger.error(
                  'hermes-removal-notification-clear-failed',
                  scope: 'notifications/system',
                  error: error,
                  stackTrace: stackTrace,
                );
              }
            };
          }),
          // The in-memory selection, so a language change applies to the
          // next request before the preference write lands.
          appLanguageTagProvider.overrideWith(
            (ref) => ref.watch(appLocaleProvider)?.toLanguageTag(),
          ),
          // What a push shows when it carries no title of its own, in the
          // app's language; the core cannot localize.
          pushLocalizedStringsProvider.overrideWith((ref) {
            ref.watch(appLocaleProvider);
            return pushDisplayStrings(currentAppLocalizations());
          }),
          // The Conduit Push function bundled for one-tap installs.
          pushOpenWebUiFunctionSourceProvider.overrideWithValue(
            loadBundledConduitPushFunction,
          ),
          // Apple Foundation Models through the Pigeon bridge
          // (ios/Runner/PccBridge.swift); the adapter lives in conduit_core.
          applePccHostProvider.overrideWith((ref) => PigeonApplePccHost()),
          hostDirectProviderAdaptersProvider.overrideWith(
            (ref) => [ref.watch(applePccAdapterProvider)],
          ),
          // The CarPlay scene's channel (ConduitCarPlayBridge.swift); the
          // coordinator in conduit_core stays idle without it.
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS)
            carPlayBridgeProvider.overrideWithValue(
              const MethodChannelCarPlayBridge(),
            ),
          hostHermesDashboardBridgeFactoryProvider.overrideWith(
            (ref) =>
                ({required root, required accessHeaders}) =>
                    HermesDashboardRestBridge(
                      root: root,
                      accessHeaders: accessHeaders,
                    ),
          ),
          hostHermesDashboardSignOutProvider.overrideWithValue(
            HermesDashboardRestBridge.signOutOf,
          ),
          clipboardPortProvider.overrideWithValue(const FlutterClipboardPort()),
          uiRequestPortProvider.overrideWithValue(const FlutterUiRequests()),
          hermesConnectionSwitchPromptProvider.overrideWith(
            (ref) =>
                (name) => confirmHermesConnectionSwitch(
                  ref.read(uiRequestPortProvider),
                  name,
                ),
          ),
          hermesModelSwitchPromptProvider.overrideWith(
            (ref) =>
                (held) => confirmHermesModelSwitch(
                  ref.read(uiRequestPortProvider),
                  held,
                ),
          ),
          chatHandoffPromptProvider.overrideWith(
            (ref) =>
                (modelName) => confirmChatHandoff(
                  ref.read(uiRequestPortProvider),
                  modelName,
                ),
          ),
          chatHandoffOpenerProvider.overrideWith(
            (ref) =>
                (model, prompt) => openChatHandoffInApp(ref, model, prompt),
          ),
          routeNavigatorProvider.overrideWithValue(const GoRouterNavigator()),
          openExternalUrlProvider.overrideWithValue(
            const UrlLauncherOpenExternalUrlPort(),
          ),
          if (_hasBrowserAuth)
            browserAuthPortProvider.overrideWithValue(PigeonBrowserAuthPort()),
          secureStorageProvider.overrideWithValue(
            ReadinessGatedSecureStorage(
              delegate: secureStorage,
              readiness: keychainWarmupBarrier,
            ),
          ),
          hiveBoxesProvider.overrideWithValue(hiveBoxes),
          // Inversion seam (E3): the core/sync drainer reads the no-op
          // RequestCompletionRunner stub; bind it to the chat implementation so
          // queued completions re-enter the streaming pipeline.
          requestCompletionRunnerProvider.overrideWith(
            (ref) => ref.watch(chatRequestCompletionRunnerProvider),
          ),
          // The voice-call controller lives in conduit_core; these are the
          // host capabilities it drives (voice_mode_ports.dart).
          voiceModeInputProvider.overrideWith(
            (ref) => ref.watch(voiceInputServiceProvider),
          ),
          voiceModeSpeechProvider.overrideWith(
            (ref) => ref.watch(textToSpeechServiceProvider),
          ),
          voiceCallKitProvider.overrideWith(
            (ref) => ref.watch(callKitServiceProvider),
          ),
          voiceAudioSessionProvider.overrideWith(
            (ref) => ref.watch(chatVoiceAudioSessionCoordinatorProvider),
          ),
          chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
            ChatVoiceModeBackgroundCoordinator(),
          ),
          voiceModePlatformProvider.overrideWithValue(
            const FlutterVoiceModePlatform(),
          ),
          // A realtime voice needs the native echo-cancelled audio engine.
          realtimePcmAudioFactoryProvider.overrideWithValue(
            () => _hasRealtimeAudio ? MethodChannelRealtimePcmAudio() : null,
          ),
          // Hermes's GPT-Live calls run over WebRTC.
          realtimeWebRtcMediaFactoryProvider.overrideWithValue(
            () => _hasRealtimeAudio ? WebRtcRealtimeMedia() : null,
          ),
        ],
      );
      // CarPlay can cold-launch Conduit without a visible Flutter scene, so
      // install its method-channel handler before frame-scheduled startup work.
      providerContainer.read(carPlayCoordinatorProvider);

      installConduitErrorWidgetBuilder();

      await modelLogosLoaded;
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
  VoidCallback? _unregisterSettingsOpener;

  @override
  void initState() {
    super.initState();
    ref.read(userScopedProviderCleanupProvider);
    ref.read(openWebUiDuplicateAccountReconcilerProvider);
    ref.read(openWebUiRouteResolverProvider);
    ref.read(quickActionsCoordinatorProvider);
    ref.read(chatWakelockCoordinatorProvider);
    // Settings rows changed in the native sheet go to the same controller the
    // Flutter Settings pages send theirs to.
    final settingsController = ref.read(settingsControllerProvider)
      ..attach(ref);
    _nativeSheetSubscription = NativeSheetBridge.instance.events.listen(
      settingsController.handle,
    );
    // The account button, Command-comma and any other entry open Settings
    // here, so each presents the same sheet with the same account.
    _unregisterSettingsOpener = registerAppSettingsOpener(ref);

    // Delay heavy provider initialization until after the first frame so the
    // initial paint stays responsive.
    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeAppState());
  }

  void _initializeAppState() {
    DebugLogger.auth('init', scope: 'app');
    ref.read(appStartupFlowProvider.notifier).start();
  }

  @override
  void dispose() {
    _unregisterSettingsOpener?.call();
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

    return AdaptiveApp.router(
      routerConfig: router,
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
      materialLightTheme: lightTheme,
      materialDarkTheme: darkTheme,
      cupertinoLightTheme: cupertinoLight,
      cupertinoDarkTheme: cupertinoDark,
      themeMode: themeMode,
      locale: locale,
      localizationsDelegates: conduitLocalizationsDelegates,
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
        final nativeTheme = materialTheme.extension<ConduitThemeExtension>();
        if (nativeTheme != null) {
          // Sheets share the grouped settings colors with the Flutter
          // settings screens so both read as one surface system.
          final isDarkSheet = brightness == Brightness.dark;
          final sheetBackground = nativeTheme.groupedBackground;
          final sheetSurface = nativeTheme.groupedSurface;
          unawaited(
            NativeSheetBridge.instance.syncTheme(
              NativeSheetThemeConfig(
                isDark: isDarkSheet,
                backgroundArgb: sheetBackground.toARGB32(),
                surfaceArgb: sheetSurface.toARGB32(),
                elevatedSurfaceArgb: nativeTheme.surfaceContainerHighest
                    .toARGB32(),
                inputArgb: nativeTheme.inputBackground.toARGB32(),
                foregroundArgb: nativeTheme.textPrimary.toARGB32(),
                secondaryForegroundArgb: nativeTheme.textSecondary.toARGB32(),
                iconArgb: nativeTheme.iconSecondary.toARGB32(),
                borderArgb: nativeTheme.cardBorder.toARGB32(),
                accentArgb: nativeTheme.buttonPrimary.toARGB32(),
                onAccentArgb: nativeTheme.buttonPrimaryText.toARGB32(),
                destructiveArgb: nativeTheme.error.toARGB32(),
              ),
            ),
          );
        }

        return Theme(
          data: materialTheme,
          child: Builder(
            builder: (context) => LegacyDesignCompatibility(
              child: ReleaseNotesCoordinator(
                child: _KeyboardDismissOnScroll(child: safeChild),
              ),
            ),
          ),
        );
      },
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
