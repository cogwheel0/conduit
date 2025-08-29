import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/services/navigation_service.dart';
import 'core/widgets/error_boundary.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/providers/app_providers.dart';
import 'shared/theme/app_theme.dart';
import 'shared/theme/theme_extensions.dart';
import 'shared/widgets/offline_indicator.dart';
import 'features/auth/views/connect_signin_page.dart';
import 'features/auth/providers/unified_auth_providers.dart';
import 'core/auth/auth_state_manager.dart';
import 'core/utils/debug_logger.dart';

import 'features/onboarding/views/onboarding_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'features/chat/views/chat_page.dart';
import 'features/navigation/views/splash_launcher_page.dart';
import 'core/services/share_receiver_service.dart';
import 'core/services/assist_intent_service.dart';
import 'core/services/tts_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Enable edge-to-edge globally (back-compat on pre-Android 15)
  // Pairs with Activity's EdgeToEdge.enable and our SafeArea usage.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  final sharedPrefs = await SharedPreferences.getInstance();
  const secureStorage = FlutterSecureStorage();

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(sharedPrefs),
        secureStorageProvider.overrideWithValue(secureStorage),
      ],
      child: const ConduitApp(),
    ),
  );
}

class ConduitApp extends ConsumerStatefulWidget {
  const ConduitApp({super.key});

  @override
  ConsumerState<ConduitApp> createState() => _ConduitAppState();
}

class _ConduitAppState extends ConsumerState<ConduitApp> {
  bool _attemptedSilentAutoLogin = false;
  @override
  void initState() {
    super.initState();
    _initializeAppState();
  }

  Widget _buildInitialLoadingSkeleton(BuildContext context) {
    // Replace skeleton with branded splash during initialization
    return const SplashLauncherPage();
  }

  void _initializeAppState() {
    // Initialize unified auth state manager and API integration synchronously
    // This ensures auth state is loaded before first widget build
    DebugLogger.auth('Initializing unified auth system');

    // Initialize auth state manager (will handle token validation automatically)
    ref.read(authStateManagerProvider);

    // Ensure API service auth integration is active
    ref.read(authApiIntegrationProvider);

    // Initialize auto-selection listener for default model changes in settings
    ref.read(defaultModelAutoSelectionProvider);

    // Initialize OS share receiver so users can share text/files to Conduit
    ref.read(shareReceiverInitializerProvider);

    // Initialize ASSIST intent service for Android assistant integration
    ref.read(assistIntentInitializerProvider);

    // Initialize TTS language updater for reactive language changes
    ref.read(ttsLanguageUpdaterProvider);
  }

  @override
  Widget build(BuildContext context) {
    // Use select to watch only the specific themeMode property to reduce rebuilds
    final themeMode = ref.watch(themeModeProvider.select((mode) => mode));

    // Reduced debug noise - only log when necessary
    // debugPrint('DEBUG: Building app');

    // Determine the current theme based on themeMode
    // Default to Conduit brand theme globally
    final currentTheme = themeMode == ThemeMode.dark
        ? AppTheme.conduitDarkTheme
        : themeMode == ThemeMode.light
        ? AppTheme.conduitLightTheme
        : MediaQuery.platformBrightnessOf(context) == Brightness.dark
        ? AppTheme.conduitDarkTheme
        : AppTheme.conduitLightTheme;

    final locale = ref.watch(localeProvider);

    return AnimatedThemeWrapper(
      theme: currentTheme,
      duration: AnimationDuration.medium,
      child: ErrorBoundary(
        child: MaterialApp(
          onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
          theme: AppTheme.conduitLightTheme,
          darkTheme: AppTheme.conduitDarkTheme,
          themeMode: themeMode,
          debugShowCheckedModeBanner: false,
          navigatorKey: NavigationService.navigatorKey,
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          localeListResolutionCallback: (deviceLocales, supported) {
            if (locale != null) return locale; // User override wins
            if (deviceLocales == null || deviceLocales.isEmpty) {
              return supported.first;
            }
            for (final device in deviceLocales) {
              for (final loc in supported) {
                if (loc.languageCode == device.languageCode) return loc;
              }
            }
            return supported.first;
          },
          builder: (context, child) {
            // Apply edge-to-edge inset handling and responsive design
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(
                // Ensure proper text scaling for edge-to-edge
                textScaler: MediaQuery.of(
                  context,
                ).textScaler.clamp(minScaleFactor: 0.8, maxScaleFactor: 1.3),
              ),
              child: OfflineIndicator(child: child ?? const SizedBox.shrink()),
            );
          },
          home: _getInitialPageWithReactiveState(),
          onGenerateRoute: NavigationService.generateRoute,
          navigatorObservers: [_NavigationObserver()],
        ),
      ),
    );
  }

  Widget _getInitialPageWithReactiveState() {
    return Consumer(
      builder: (context, ref, child) {
        // Watch for server connection state changes
        final activeServerAsync = ref.watch(activeServerProvider);
        final reviewerMode = ref.watch(reviewerModeProvider);

        if (reviewerMode) {
          // In reviewer mode, skip server/auth flows and go to chat
          NavigationService.setCurrentRoute(Routes.chat);
          return const ChatPage();
        }

        return activeServerAsync.when(
          data: (activeServer) {
            if (activeServer == null) {
              return const ConnectAndSignInPage();
            }

            // Server is connected, now check authentication reactively
            final authNavState = ref.watch(authNavigationStateProvider);

            if (authNavState == AuthNavigationState.needsLogin) {
              // Try one-shot silent login if credentials are saved
              if (!_attemptedSilentAutoLogin) {
                _attemptedSilentAutoLogin = true;
                Future.microtask(() async {
                  try {
                    final hasCreds = await ref.read(
                      hasSavedCredentialsProvider2.future,
                    );
                    if (hasCreds) {
                      await ref.read(authActionsProvider).silentLogin();
                    }
                  } catch (_) {
                    // Ignore errors, fallback to showing unified page
                  }
                });
              }
              return const ConnectAndSignInPage();
            }

            if (authNavState == AuthNavigationState.loading) {
              return _buildInitialLoadingSkeleton(context);
            }

            if (authNavState == AuthNavigationState.error) {
              return _buildErrorState(
                ref.watch(authErrorProvider3) ??
                    AppLocalizations.of(context)!.errorMessage,
              );
            }

            // User is authenticated, navigate directly to chat page
            _initializeBackgroundResources(ref);

            // Set the current route for navigation tracking
            NavigationService.setCurrentRoute(Routes.chat);

            return const ChatPage();
          },
          loading: () => _buildInitialLoadingSkeleton(context),
          error: (error, stackTrace) {
            DebugLogger.error('Server provider error', error);
            return _buildErrorState(
              AppLocalizations.of(context)!.unableToConnectServer,
            );
          },
        );
      },
    );
  }

  void _initializeBackgroundResources(WidgetRef ref) {
    // Initialize resources in the background without blocking UI
    Future.microtask(() async {
      try {
        // Get the API service
        final api = ref.read(apiServiceProvider);
        if (api == null) {
          DebugLogger.warning(
            'API service not available for background initialization',
          );
          return;
        }

        // Explicitly get the current auth token and set it on the API service
        final authToken = ref.read(authTokenProvider3);
        if (authToken != null && authToken.isNotEmpty) {
          api.updateAuthToken(authToken);
          DebugLogger.auth('Background: Set auth token on API service');
        } else {
          DebugLogger.warning('Background: No auth token available yet');
          return;
        }

        // Initialize the token updater for future updates
        ref.read(apiTokenUpdaterProvider);

        // Load models and set default in background
        await ref.read(defaultModelProvider.future);
        DebugLogger.info('Background initialization completed');

        // Onboarding: show once if not seen
        final storage = ref.read(optimizedStorageServiceProvider);
        final seen = await storage.getOnboardingSeen();

        if (!seen && mounted) {
          await Future.delayed(const Duration(milliseconds: 300));
          if (!mounted) return;

          WidgetsBinding.instance.addPostFrameCallback((_) async {
            final navContext = NavigationService.navigatorKey.currentContext;
            if (!mounted || navContext == null) return;

            _showOnboarding(navContext);
            await storage.setOnboardingSeen(true);
          });
        }
      } catch (e) {
        DebugLogger.error('Background initialization failed', e);
        // Don't throw - this is background initialization
      }
    });
  }

  void _showOnboarding(BuildContext context) {
    showModalBottomSheet(
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
        child: const OnboardingSheet(),
      ),
    );
  }

  Widget _buildErrorState(String error) {
    return Scaffold(
      backgroundColor: context.conduitTheme.surfaceBackground,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: IconSize.xxl + Spacing.md,
                color: context.conduitTheme.error,
              ),
              const SizedBox(height: Spacing.md),
              Text(
                AppLocalizations.of(context)!.initializationFailed,
                style: TextStyle(
                  fontSize: AppTypography.headlineLarge,
                  fontWeight: FontWeight.bold,
                  color: context.conduitTheme.textPrimary,
                ),
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                error,
                style: TextStyle(color: context.conduitTheme.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: Spacing.lg),
              ElevatedButton(
                onPressed: () {
                  // Restart the app
                  WidgetsBinding.instance.reassembleApplication();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: context.conduitTheme.buttonPrimary,
                  foregroundColor: context.conduitTheme.buttonPrimaryText,
                ),
                child: Text(AppLocalizations.of(context)!.retry),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavigationObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    // Log navigation for debugging and analytics
    DebugLogger.navigation('Pushed: ${route.settings.name}');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    DebugLogger.navigation('Popped: ${route.settings.name}');
  }
}
