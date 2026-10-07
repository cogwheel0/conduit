import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/chat_entry_readiness_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit/features/auth/views/authentication_page.dart';
import 'package:conduit/features/auth/views/backend_chooser_page.dart';
import 'package:conduit/features/auth/views/server_connection_page.dart';
import 'package:conduit/features/direct_connections/views/direct_connection_editor_page.dart';
import 'package:conduit_core/features/direct_connections/controllers/direct_connection_editor_draft.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/services/apple_pcc_adapter.dart';
import 'package:conduit/features/direct_connections/views/direct_connections_page.dart';
import 'package:conduit/features/hermes/views/hermes_settings_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:conduit/platform/flutter_secure_key_value_store.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit/features/direct_connections/providers/apple_pcc_providers.dart';

class AdaptiveAuthHarness {
  AdaptiveAuthHarness({
    required this.server,
    this.platform = TargetPlatform.android,
    this.backendConfig = const BackendConfig(),
    this.disableAnimations = false,
    this.textScaler,
    this.appleOnDeviceStatus,
    this.applePccStatus,
    this.accountlessBackendUsable = false,
    this.authActions,
    this.savedUsername,
    this.addingAccountFrom,
    this.abandonablePendingSignIn = false,
    this.accountsController,
  }) {
    when(() => _storage.getSavedCredentials()).thenAnswer(
      (_) async => savedUsername == null ? null : {'username': savedUsername!},
    );
    when(() => _storage.getAuthTokenStrict()).thenAnswer((_) async => '');
    when(() => _storage.getSavedCredentialsStrict())
        .thenAnswer((_) async => null);
    when(() => _storage.saveLocalUser(null)).thenAnswer((_) async {});
    when(() => _storage.saveLocalUserAvatar(null)).thenAnswer((_) async {});
    when(() => _storage.getReviewerMode()).thenAnswer((_) async => false);
    if (authActions != null) {
      // A sign-in attempt first saves the server it was opened for.
      registerFallbackValue(server);
      when(
        () => _storage.selectUnauthenticatedServerConfig(
          any(),
          canCommit: any(named: 'canCommit'),
          onRollbackUncertain: any(named: 'onRollbackUncertain'),
          publish: any(named: 'publish'),
        ),
      ).thenAnswer((_) async => true);
      registerFallbackValue(const BackendConfig());
      when(() => _storage.getLocalBackendConfig())
          .thenAnswer((_) async => null);
      when(() => _storage.saveLocalBackendConfig(any()))
          .thenAnswer((_) async {});
      when(() => _storage.saveLocalTransportOptions(any()))
          .thenAnswer((_) async {});
    }
  }

  final ServerConfig server;
  final TargetPlatform platform;
  final BackendConfig? backendConfig;
  final bool disableAnimations;
  final TextScaler? textScaler;
  final PlatformPccStatus? appleOnDeviceStatus;
  final PlatformPccStatus? applePccStatus;

  /// Whether an Apple, Direct, or Hermes backend already works, as when Open
  /// WebUI is added from settings rather than during first-time setup.
  final bool accountlessBackendUsable;

  /// Replaces the sign-in actions, so a test controls the outcome of an attempt.
  final AuthActions? authActions;

  /// The username of the sign-in saved on the device, if any.
  final String? savedUsername;

  /// The account another one is being added from, if one is.
  final String? addingAccountFrom;

  /// Whether the active account is an added one whose sign-in never
  /// finished, which sign-in pages offer to drop.
  final bool abandonablePendingSignIn;

  /// Replaces the account actions, so a test sees which it asked for.
  final OpenWebUiAccountsController? accountsController;
  final _MockOptimizedStorageService _storage = _MockOptimizedStorageService();
  final ErrorWidgetBuilder _previousErrorWidgetBuilder = ErrorWidget.builder;
  final void Function(FlutterErrorDetails)? _previousFlutterOnError =
      FlutterError.onError;

  /// When set, the route rebuilds the page as the app's router does when the
  /// route's `extra` is gone: with no server or backend config.
  final routeExtraLost = ValueNotifier<bool>(false);

  late GoRouter router;
  bool _disposed = false;

  Widget build({required String initialLocation}) {
    PlatformUiCapabilities.debugPlatformOverride = platform;
    router = GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(
          path: Routes.authentication,
          name: RouteNames.authentication,
          builder: (_, _) => ValueListenableBuilder<bool>(
            valueListenable: routeExtraLost,
            builder: (_, extraLost, _) => extraLost
                ? const AuthenticationPage()
                : AuthenticationPage(
                    serverConfig: server,
                    backendConfig: backendConfig,
                  ),
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
        GoRoute(
          path: Routes.chat,
          name: RouteNames.chat,
          builder: (_, _) => const SizedBox(key: ValueKey<String>('chat')),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        if (authActions != null) ...[
          authActionsProvider.overrideWithValue(authActions!),
          // A sign-in attempt first waits for the API client of the selected
          // server.
          apiServiceProvider.overrideWithValue(_selectedServerApi()),
        ],
        accountlessPrimaryBackendUsableProvider.overrideWithValue(
          accountlessBackendUsable,
        ),
        optimizedStorageServiceProvider.overrideWithValue(_storage),
        if (addingAccountFrom != null)
          accountAdditionOriginProvider.overrideWith(
            () => _AddingAccountFrom(addingAccountFrom!),
          ),
        if (abandonablePendingSignIn)
          pendingSignInAbandonableProvider.overrideWith((_) async => true),
        if (accountsController != null)
          openWebUiAccountsControllerProvider.overrideWithValue(
            accountsController!,
          ),
        activeServerProvider.overrideWith((_) async => server),
        appleOnDeviceStatusProvider.overrideWith(
          (_) async => appleOnDeviceStatus ?? _unavailableAppleStatus(),
        ),
        applePccStatusProvider.overrideWith(
          (_) async => applePccStatus ?? _unavailableAppleStatus(),
        ),
      ],
      child: MaterialApp.router(
        theme: ThemeData(platform: platform),
        localizationsDelegates: conduitLocalizationsDelegates,
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

  ApiService _selectedServerApi() {
    final api = _MockApiService();
    when(() => api.authToken).thenReturn(null);
    when(() => api.serverConfig).thenReturn(server);
    return api;
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    dispose();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    PlatformUiCapabilities.debugPlatformOverride = null;
    router.dispose();
    routeExtraLost.dispose();
    ErrorWidget.builder = _previousErrorWidgetBuilder;
    FlutterError.onError = _previousFlutterOnError;
  }
}

final class _AddingAccountFrom extends AccountAdditionOrigin {
  _AddingAccountFrom(this.accountId);

  final String accountId;

  @override
  String? build() => accountId;
}

PlatformPccStatus _unavailableAppleStatus() => PlatformPccStatus(
  availability: PlatformPccAvailability.unavailable,
  quotaStatus: PlatformPccQuotaStatus.unknown,
  quotaLimitReached: false,
  canIncreaseQuota: false,
);

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
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    router.go(initialLocation);
    return ProviderScope(
      overrides: [
        secureStorageProvider.overrideWithValue(FlutterSecureKeyValueStore()),
        // The host test platform is never iOS; keep the Apple rows reachable so
        // onboarding coverage still exercises them.
        applePccPlatformSupportedProvider.overrideWithValue(true),
        applePccAdapterProvider.overrideWithValue(
          ApplePccAdapter(host: _AvailablePccHost()),
        ),
        appleOnDeviceStatusProvider.overrideWith(
          (_) async => _unavailableAppleStatus(),
        ),
        applePccStatusProvider.overrideWith(
          (_) async => _unavailableAppleStatus(),
        ),
      ],
      child: MaterialApp.router(
        theme: ThemeData(platform: TargetPlatform.iOS),
        localizationsDelegates: conduitLocalizationsDelegates,
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
    PlatformUiCapabilities.debugPlatformOverride = null;
    router.dispose();
  }
}

/// Answers status probes instantly so Apple discovery never leaves a pending
/// platform-channel timer behind in widget tests.
final class _AvailablePccHost extends UnavailableApplePccHost {
  @override
  Future<PlatformPccStatus> getStatus(PlatformAppleModel model) async =>
      PlatformPccStatus(
        availability: PlatformPccAvailability.available,
        quotaStatus: PlatformPccQuotaStatus.belowLimit,
        quotaLimitReached: false,
        canIncreaseQuota: false,
      );
}

Future<void> initializeBackendOnboardingStorage() async {
  SharedPreferences.setMockInitialValues({});
  PreferencesStore.debugReset();
  PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  FlutterSecureStorage.setMockInitialValues({});
}

void usePhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(375, 812);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _MockApiService extends Mock implements ApiService {}

class _MockOptimizedStorageService extends Mock
    implements OptimizedStorageService {}
