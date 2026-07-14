import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/models/socket_transport_availability.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/connectivity_service.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/core/services/socket_service.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _TestAuthState = ({bool authenticated, String? token, Object epoch});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const serverA = ServerConfig(
    id: 'server-a',
    name: 'Server A',
    url: 'https://a.example.test',
  );
  const serverB = ServerConfig(
    id: 'server-b',
    name: 'Server B',
    url: 'https://b.example.test',
  );

  group('SocketServiceManager async ownership', () {
    test('revoked auth cannot install a socket from a pending build', () async {
      final pendingServer = Completer<ServerConfig?>();
      final harness = _SocketManagerHarness(
        initialServer: pendingServer.future,
        initialAuth: (authenticated: true, token: 'token-a', epoch: Object()),
      );
      final container = harness.createContainer();
      addTearDown(container.dispose);
      final subscription = container.listen(
        socketServiceManagerProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await _flushMicrotasks();

      harness.setAuth(container, (
        authenticated: false,
        token: null,
        epoch: Object(),
      ));
      await _flushMicrotasks();
      check(container.read(socketServiceProvider)).isNull();

      pendingServer.complete(serverA);
      await _flushMicrotasks();

      check(harness.services).isEmpty();
      check(
        container.read(socketServiceManagerProvider.notifier).currentService,
      ).isNull();
      check(container.read(socketServiceProvider)).isNull();
    });

    test('an old build cannot replace a newer server and token', () async {
      final pendingServerA = Completer<ServerConfig?>();
      final harness = _SocketManagerHarness(
        initialServer: pendingServerA.future,
        initialAuth: (authenticated: true, token: 'token-a', epoch: Object()),
      );
      final container = harness.createContainer();
      addTearDown(container.dispose);
      final subscription = container.listen(
        socketServiceManagerProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await _flushMicrotasks();

      harness.setAuth(container, (
        authenticated: true,
        token: 'token-b',
        epoch: Object(),
      ));
      harness.setServer(container, Future<ServerConfig?>.value(serverB));
      final current = await container.read(socketServiceManagerProvider.future);

      check(current).isA<_TestSocketService>()
        ..has((service) => service.serverConfig, 'serverConfig').equals(serverB)
        ..has((service) => service.authToken, 'authToken').equals('token-b');
      final serviceB = current! as _TestSocketService;
      check(harness.services).deepEquals(<_TestSocketService>[serviceB]);

      pendingServerA.complete(serverA);
      await _flushMicrotasks();

      check(harness.services).deepEquals(<_TestSocketService>[serviceB]);
      check(serviceB.disposeCalls).equals(0);
      check(
        container.read(socketServiceManagerProvider.notifier).currentService,
      ).identicalTo(serviceB);
      check(container.read(socketServiceProvider)).identicalTo(serviceB);
    });

    test('a pending server switch cannot expose the previous socket', () async {
      final harness = _SocketManagerHarness(
        initialServer: Future<ServerConfig?>.value(serverA),
        initialAuth: (authenticated: true, token: 'token-a', epoch: Object()),
      );
      final container = harness.createContainer();
      addTearDown(container.dispose);
      final subscription = container.listen(
        socketServiceManagerProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      final serviceA =
          await container.read(socketServiceManagerProvider.future)
              as _TestSocketService;
      final pendingServerB = Completer<ServerConfig?>();

      harness.setServer(container, pendingServerB.future);
      await _flushMicrotasks();

      check(serviceA.disposeCalls).equals(1);
      check(container.read(socketServiceProvider)).isNull();
      check(
        container.read(socketServiceManagerProvider.notifier).currentService,
      ).isNull();

      pendingServerB.complete(serverB);
      final serviceB =
          await container.read(socketServiceManagerProvider.future)
              as _TestSocketService;
      check(serviceB.serverConfig).equals(serverB);
      check(serviceB.authToken).equals('token-a');
      check(harness.services).deepEquals([serviceA, serviceB]);
    });

    test(
      'dispose fences a pending rebuild and tears down the live socket',
      () async {
        final harness = _SocketManagerHarness(
          initialServer: Future<ServerConfig?>.value(serverA),
          initialAuth: (authenticated: true, token: 'token-a', epoch: Object()),
        );
        final container = harness.createContainer();
        final subscription = container.listen(
          socketServiceManagerProvider,
          (_, _) {},
          fireImmediately: true,
        );
        final service =
            await container.read(socketServiceManagerProvider.future)
                as _TestSocketService;
        final pendingServerB = Completer<ServerConfig?>();

        harness.setServer(container, pendingServerB.future);
        await _flushMicrotasks();
        container.dispose();
        pendingServerB.complete(serverB);
        await _flushMicrotasks();

        subscription.close();
        check(service.disposeCalls).equals(1);
        check(harness.services).deepEquals(<_TestSocketService>[service]);
      },
    );

    test(
      'dispose tears down the socket installed by a rebuilt generation',
      () async {
        final harness = _SocketManagerHarness(
          initialServer: Future<ServerConfig?>.value(serverA),
          initialAuth: (authenticated: true, token: 'token-a', epoch: Object()),
        );
        final container = harness.createContainer();
        final subscription = container.listen(
          socketServiceManagerProvider,
          (_, _) {},
          fireImmediately: true,
        );
        final serviceA =
            await container.read(socketServiceManagerProvider.future)
                as _TestSocketService;

        harness.setAuth(container, (
          authenticated: true,
          token: 'token-b',
          epoch: Object(),
        ));
        final serviceB =
            await container.read(socketServiceManagerProvider.future)
                as _TestSocketService;

        check(serviceA.disposeCalls).equals(1);
        check(serviceB.disposeCalls).equals(0);

        container.dispose();
        await _flushMicrotasks();
        subscription.close();

        check(serviceB.disposeCalls).equals(1);
        check(
          harness.services,
        ).deepEquals(<_TestSocketService>[serviceA, serviceB]);
      },
    );

    test('same-context rebuild retains the live socket', () async {
      final harness = _SocketManagerHarness(
        initialServer: Future<ServerConfig?>.value(serverA),
        initialAuth: (authenticated: true, token: 'token-a', epoch: Object()),
      );
      final container = harness.createContainer();
      final subscription = container.listen(
        socketServiceManagerProvider,
        (_, _) {},
        fireImmediately: true,
      );
      final service =
          await container.read(socketServiceManagerProvider.future)
              as _TestSocketService;

      container.invalidate(socketServiceManagerProvider);
      final rebuiltService = await container.read(
        socketServiceManagerProvider.future,
      );
      await _flushMicrotasks();

      check(rebuiltService).identicalTo(service);
      check(service.disposeCalls).equals(0);
      check(harness.services).deepEquals(<_TestSocketService>[service]);

      container.dispose();
      await _flushMicrotasks();
      subscription.close();

      check(service.disposeCalls).equals(1);
    });
  });
}

final class _SocketManagerHarness {
  _SocketManagerHarness({
    required Future<ServerConfig?> initialServer,
    required _TestAuthState initialAuth,
  }) : authProvider = NotifierProvider<_AuthNotifier, _TestAuthState>(
         () => _AuthNotifier(initialAuth),
       ),
       serverProvider =
           NotifierProvider<_ServerFutureNotifier, Future<ServerConfig?>>(
             () => _ServerFutureNotifier(initialServer),
           );

  final NotifierProvider<_AuthNotifier, _TestAuthState> authProvider;
  final NotifierProvider<_ServerFutureNotifier, Future<ServerConfig?>>
  serverProvider;
  final List<_TestSocketService> services = <_TestSocketService>[];

  ProviderContainer createContainer() {
    return ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(false),
        isAuthenticatedProvider2.overrideWith(
          (ref) => ref.watch(authProvider).authenticated,
        ),
        authTokenProvider3.overrideWith((ref) => ref.watch(authProvider).token),
        openWebUiAuthSessionEpochProvider.overrideWith(
          (ref) => ref.watch(authProvider).epoch,
        ),
        activeServerProvider.overrideWith((ref) => ref.watch(serverProvider)),
        appSettingsProvider.overrideWithValue(const AppSettings()),
        socketTransportOptionsProvider.overrideWithValue(
          const SocketTransportAvailability(
            allowPolling: true,
            allowWebsocketOnly: true,
          ),
        ),
        connectivityStatusProvider.overrideWithValue(ConnectivityStatus.online),
        socketServiceFactoryProvider.overrideWithValue(({
          required serverConfig,
          required authToken,
          required websocketOnly,
          required allowWebsocketUpgrade,
        }) {
          final service = _TestSocketService(
            serverConfig: serverConfig,
            authToken: authToken,
            websocketOnly: websocketOnly,
            allowWebsocketUpgrade: allowWebsocketUpgrade,
          );
          services.add(service);
          return service;
        }),
      ],
    );
  }

  void setAuth(ProviderContainer container, _TestAuthState auth) {
    container.read(authProvider.notifier).set(auth);
  }

  void setServer(ProviderContainer container, Future<ServerConfig?> server) {
    container.read(serverProvider.notifier).set(server);
  }
}

final class _AuthNotifier extends Notifier<_TestAuthState> {
  _AuthNotifier(this.initial);

  final _TestAuthState initial;

  @override
  _TestAuthState build() => initial;

  void set(_TestAuthState next) => state = next;
}

final class _ServerFutureNotifier extends Notifier<Future<ServerConfig?>> {
  _ServerFutureNotifier(this.initial);

  final Future<ServerConfig?> initial;

  @override
  Future<ServerConfig?> build() => initial;

  void set(Future<ServerConfig?> next) => state = next;
}

final class _TestSocketService implements SocketService {
  _TestSocketService({
    required this.serverConfig,
    required this.authToken,
    required this.websocketOnly,
    required this.allowWebsocketUpgrade,
  });

  @override
  final ServerConfig serverConfig;
  @override
  final String authToken;
  @override
  final bool websocketOnly;
  @override
  final bool allowWebsocketUpgrade;

  int connectCalls = 0;
  int disposeCalls = 0;

  @override
  Future<void> connect({bool force = false}) async {
    connectCalls += 1;
  }

  @override
  void dispose() {
    disposeCalls += 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<void> _flushMicrotasks() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
