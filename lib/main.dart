import 'dart:async';
import 'dart:developer' as developer;
import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/widgets/error_boundary.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'core/providers/app_providers.dart';
import 'core/persistence/hive_bootstrap.dart';
import 'core/persistence/persistence_migrator.dart';
import 'core/persistence/persistence_providers.dart';
import 'core/router/app_router.dart';
import 'features/auth/providers/unified_auth_providers.dart';
import 'core/auth/auth_state_manager.dart';
import 'core/utils/debug_logger.dart';
import 'core/utils/system_ui_style.dart';

import 'package:conduit/l10n/app_localizations.dart';
import 'core/services/share_receiver_service.dart';
import 'core/providers/app_startup_providers.dart';

developer.TimelineTask? _startupTimeline;

void main() {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

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

      const secureStorage = FlutterSecureStorage(
        aOptions: AndroidOptions(
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
      _startupTimeline!.instant('secure_storage_ready');

      // Initialize Hive (now optimized with migration state caching)
      final hiveBoxes = await HiveBootstrap.instance.ensureInitialized();
      _startupTimeline!.instant('hive_ready');

      // Run migration check (now fast-pathed after first run)
      final migrator = PersistenceMigrator(hiveBoxes: hiveBoxes);
      await migrator.migrateIfNeeded();
      _startupTimeline!.instant('migration_complete');

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
  @override
  void initState() {
    super.initState();
    // Delay heavy provider initialization until after the first frame so the
    // initial paint stays responsive.
    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeAppState());
  }

  void _initializeAppState() {
    DebugLogger.auth('init', scope: 'app');

    void queueInit(void Function() action, {Duration delay = Duration.zero}) {
      Future<void>.delayed(delay, () {
        if (!mounted) return;
        action();
      });
    }

    queueInit(() => ref.read(authStateManagerProvider));
    queueInit(
      () => ref.read(authApiIntegrationProvider),
      delay: const Duration(milliseconds: 16),
    );
    // Note: defaultModelAutoSelectionProvider is now initialized in
    // AppStartupFlow after authentication to avoid loading tools too early
    queueInit(
      () => ref.read(shareReceiverInitializerProvider),
      delay: const Duration(milliseconds: 24),
    );

    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(appStartupFlowProvider.notifier).start();
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(
      appThemeModeProvider.select((mode) => mode),
    );
    final router = ref.watch(goRouterProvider);
    final locale = ref.watch(appLocaleProvider);
    final lightTheme = ref.watch(appLightThemeProvider);
    final darkTheme = ref.watch(appDarkThemeProvider);
    final cupertinoLight = ref.watch(
      appCupertinoLightThemeProvider,
    );
    final cupertinoDark = ref.watch(
      appCupertinoDarkThemeProvider,
    );

    return ErrorBoundary(
      child: AdaptiveApp.router(
        routerConfig: router,
        onGenerateTitle: (context) =>
            AppLocalizations.of(context)!.appTitle,
        materialLightTheme: lightTheme,
        materialDarkTheme: darkTheme,
        cupertinoLightTheme: cupertinoLight,
        cupertinoDarkTheme: cupertinoDark,
        themeMode: themeMode,
        locale: locale,
        localizationsDelegates:
            AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        localeListResolutionCallback: (
          deviceLocales,
          supported,
        ) {
          if (locale != null) return locale;
          if (deviceLocales == null ||
              deviceLocales.isEmpty) {
            return supported.first;
          }
          final resolved = _resolveSupportedLocale(
            deviceLocales,
            supported,
          );
          return resolved ?? supported.first;
        },
        material: (_, _) => const MaterialAppData(
          debugShowCheckedModeBanner: false,
        ),
        cupertino: (_, _) => const CupertinoAppData(
          debugShowCheckedModeBanner: false,
        ),
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
              brightness =
                  MediaQuery.platformBrightnessOf(context);
          }
          if (_lastAppliedOverlayBrightness != brightness) {
            _lastAppliedOverlayBrightness = brightness;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              applySystemUiOverlayStyleOnce(
                brightness: brightness,
              );
            });
          }
          final mediaQuery = MediaQuery.of(context);
          final safeChild =
              child ?? const SizedBox.shrink();

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
              child: _KeyboardDismissOnScroll(
                child: safeChild,
              ),
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
