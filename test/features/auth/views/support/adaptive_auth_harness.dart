import 'package:conduit/core/models/backend_config.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/features/auth/views/authentication_page.dart';
import 'package:conduit/features/auth/views/backend_chooser_page.dart';
import 'package:conduit/features/auth/views/server_connection_page.dart';
import 'package:conduit/features/direct_connections/views/direct_connection_editor_page.dart';
import 'package:conduit/features/direct_connections/controllers/direct_connection_editor_draft.dart';
import 'package:conduit/features/direct_connections/views/direct_connections_page.dart';
import 'package:conduit/features/hermes/views/hermes_settings_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AdaptiveAuthHarness {
  AdaptiveAuthHarness({
    required this.server,
    this.platform = TargetPlatform.android,
    this.backendConfig = const BackendConfig(),
    this.disableAnimations = false,
    this.textScaler,
  }) {
    when(() => _storage.getSavedCredentials()).thenAnswer((_) async => null);
    when(() => _storage.getAuthTokenStrict()).thenAnswer((_) async => '');
    when(
      () => _storage.getSavedCredentialsStrict(),
    ).thenAnswer((_) async => null);
    when(() => _storage.saveLocalUser(null)).thenAnswer((_) async {});
    when(() => _storage.saveLocalUserAvatar(null)).thenAnswer((_) async {});
    when(() => _storage.getReviewerMode()).thenAnswer((_) async => false);
  }

  final ServerConfig server;
  final TargetPlatform platform;
  final BackendConfig? backendConfig;
  final bool disableAnimations;
  final TextScaler? textScaler;
  final _MockOptimizedStorageService _storage = _MockOptimizedStorageService();
  final ErrorWidgetBuilder _previousErrorWidgetBuilder = ErrorWidget.builder;
  final void Function(FlutterErrorDetails)? _previousFlutterOnError =
      FlutterError.onError;

  late GoRouter router;
  bool _disposed = false;

  Widget build({required String initialLocation}) {
    router = GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(
          path: Routes.authentication,
          name: RouteNames.authentication,
          builder: (_, _) => AuthenticationPage(
            serverConfig: server,
            backendConfig: backendConfig,
          ),
        ),
        GoRoute(
          path: Routes.serverConnection,
          name: RouteNames.serverConnection,
          builder: (_, _) => const ServerConnectionPage(),
        ),
        GoRoute(
          path: Routes.backendChooser,
          name: RouteNames.backendChooser,
          builder: (_, _) => const BackendChooserPage(),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(_storage),
        activeServerProvider.overrideWith((_) async => server),
      ],
      child: MaterialApp.router(
        theme: ThemeData(platform: platform),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: disableAnimations,
            textScaler: textScaler,
          ),
          child: child!,
        ),
        routerConfig: router,
      ),
    );
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    dispose();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    router.dispose();
    ErrorWidget.builder = _previousErrorWidgetBuilder;
    FlutterError.onError = _previousFlutterOnError;
  }
}

class BackendOnboardingHarness {
  BackendOnboardingHarness() {
    router = GoRouter(
      routes: [
        GoRoute(
          path: Routes.backendChooser,
          name: RouteNames.backendChooser,
          builder: (_, _) => const BackendChooserPage(),
        ),
        GoRoute(
          path: Routes.hermesSettings,
          name: RouteNames.hermesSettings,
          builder: (_, state) =>
              HermesSettingsPage(isOnboarding: state.extra == true),
        ),
        GoRoute(
          path: Routes.directConnections,
          name: RouteNames.directConnections,
          builder: (_, state) => DirectConnectionsPage(
            isOnboarding: state.uri.queryParameters['onboarding'] == 'true',
          ),
        ),
        GoRoute(
          path: Routes.directConnectionEditor,
          name: RouteNames.directConnectionEditor,
          builder: (_, state) => DirectConnectionEditorPage(
            mode: DirectConnectionEditorMode.fromRoute(
              profileId: state.pathParameters['id']!,
              source: DirectConnectionEditorSource.local,
            ),
            isOnboarding: state.uri.queryParameters['onboarding'] == 'true',
            entry: state.uri.queryParameters['entry'] == 'chooser'
                ? DirectEditorEntry.chooser
                : DirectEditorEntry.overview,
          ),
        ),
      ],
    );
  }

  late final GoRouter router;
  bool _disposed = false;

  Widget build({required String initialLocation}) {
    router.go(initialLocation);
    return ProviderScope(
      overrides: [
        secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
      ],
      child: MaterialApp.router(
        theme: ThemeData(platform: TargetPlatform.iOS),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    );
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    dispose();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    router.dispose();
  }
}

Future<void> initializeBackendOnboardingStorage() async {
  SharedPreferences.setMockInitialValues({});
  PreferencesStore.debugReset();
  PreferencesStore.debugOverride(await SharedPreferences.getInstance());
  FlutterSecureStorage.setMockInitialValues({});
}

void usePhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(375, 812);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _MockOptimizedStorageService extends Mock
    implements OptimizedStorageService {}
