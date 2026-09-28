import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/router/app_router.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

final class _DirectPreferredBackend extends PreferredBackendController {
  @override
  PreferredBackend build() => PreferredBackend.direct;
}

final class _UsableDirectProfiles extends DirectConnectionProfilesController {
  @override
  Future<List<DirectConnectionProfile>> build() async => [
    DirectConnectionProfile(
      id: 'direct-profile',
      name: 'Local Ollama',
      adapterKey: 'ollama',
      baseUrl: 'http://localhost:11434',
      manualModelIds: const ['llama3'],
    ),
  ];
}

final class _DisabledHermes extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig();
}

final class _SignInAuthStateManager extends AuthStateManager {
  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.unauthenticated);

  void completeSignIn() => state = const AsyncData(
    AuthState(status: AuthStatus.authenticated, token: 'openwebui-token'),
  );
}

final class _ActiveServer extends Notifier<ServerConfig?> {
  @override
  ServerConfig? build() => null;

  void publish(ServerConfig server) => state = server;
}

final _activeServerHolder = NotifierProvider<_ActiveServer, ServerConfig?>(
  _ActiveServer.new,
);

const _server = ServerConfig(
  id: 'openwebui',
  name: 'Open WebUI',
  url: 'https://openwebui.example',
  isActive: true,
);

void main() {
  testWidgets('signing in from the native settings sheet returns to chat', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(false),
        preferredBackendProvider.overrideWith(_DirectPreferredBackend.new),
        directConnectionProfilesProvider.overrideWith(
          _UsableDirectProfiles.new,
        ),
        hermesConfigProvider.overrideWith(_DisabledHermes.new),
        authStateManagerProvider.overrideWith(_SignInAuthStateManager.new),
        activeServerProvider.overrideWith(
          (ref) async => ref.watch(_activeServerHolder),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(directConnectionProfilesProvider.future);
    await container.read(authStateManagerProvider.future);
    await container.read(activeServerProvider.future);

    final notifier = container.read(routerNotifierProvider);
    Widget page(String key) => SizedBox(key: ValueKey<String>(key));
    final router = GoRouter(
      initialLocation: Routes.chat,
      refreshListenable: notifier,
      redirect: notifier.redirect,
      routes: [
        GoRoute(
          path: Routes.chat,
          name: RouteNames.chat,
          builder: (_, _) => page('chat'),
        ),
        GoRoute(
          path: Routes.serverConnection,
          name: RouteNames.serverConnection,
          builder: (_, _) => page('server-connection'),
        ),
        GoRoute(
          path: Routes.authentication,
          name: RouteNames.authentication,
          builder: (_, _) => page('authentication'),
        ),
      ],
    );
    addTearDown(router.dispose);
    NavigationService.attachRouter(router);
    await tester.pumpWidget(
      WidgetsApp.router(routerConfig: router, color: const Color(0xFF000000)),
    );
    await tester.pumpAndSettle();
    check(router.routerDelegate.currentConfiguration.uri.path)
        .equals(Routes.chat);

    // The native sheet row, then the server page's push to Sign in.
    NavigationService.openOpenWebUIConnectFromNativeSheet();
    await tester.pumpAndSettle();
    unawaited(router.pushNamed<void>(RouteNames.authentication));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('authentication')), findsOneWidget);

    container.read(_activeServerHolder.notifier).publish(_server);
    (container.read(
      authStateManagerProvider.notifier,
    ) as _SignInAuthStateManager).completeSignIn();
    await container.read(activeServerProvider.future);
    // RouterNotifier debounces refreshes by 50ms.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    final configuration = router.routerDelegate.currentConfiguration;
    check(configuration.uri.path).equals(Routes.chat);
    check(configuration.last.matchedLocation).equals(Routes.chat);
    expect(find.byKey(const ValueKey('authentication')), findsNothing);
    expect(find.byKey(const ValueKey('chat')), findsOneWidget);
  });
}
