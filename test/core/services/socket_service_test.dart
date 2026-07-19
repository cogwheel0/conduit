import 'dart:async';
import 'dart:io';

import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/network/conduit_user_agent.dart';
import 'package:conduit/core/services/socket_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

Future<void> _flushMicrotasks([int count = 1]) async {
  for (var i = 0; i < count; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('inactive remains foreground and does not force reconnect', () async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _flushMicrotasks();

    final service = _RecordingSocketService();
    addTearDown(service.dispose);

    service.didChangeAppLifecycleState(AppLifecycleState.inactive);
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await _flushMicrotasks(2);

    expect(service.isAppForeground, isTrue);
    expect(service.forceConnectCalls, isEmpty);
  });

  test('best-effort connect observes a throwing socket factory', () async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _flushMicrotasks();

    final service = SocketService(
      serverConfig: _serverConfig,
      socketFactory: (_, _, _) => throw StateError('factory failed'),
    );
    addTearDown(service.dispose);
    final uncaughtErrors = <Object>[];

    await runZonedGuarded<Future<void>>(() async {
      service.connectBestEffort(reason: 'test-throwing-factory');
      await _flushMicrotasks(4);
    }, (error, _) => uncaughtErrors.add(error));

    expect(uncaughtErrors, isEmpty);
    await expectLater(service.connect(force: true), throwsA(isA<StateError>()));
  });

  test('a waiterless forced fallback reports its factory failure', () async {
    final socketFactory = _RecordingSocketFactory();
    var factoryCalls = 0;
    final service = SocketService(
      serverConfig: _serverConfig,
      websocketOnly: true,
      socketFactory: (base, builder, config) {
        factoryCalls++;
        if (factoryCalls > 1) throw StateError('fallback factory failed');
        return socketFactory.create(base, builder, config);
      },
    );
    addTearDown(service.dispose);
    final originalDebugPrint = debugPrint;
    final messages = <String>[];
    debugPrint = (message, {wrapWidth}) {
      if (message != null) messages.add(message);
    };
    addTearDown(() => debugPrint = originalDebugPrint);

    await service.connect();
    socketFactory.sockets.single.emitReserved(
      'connect_error',
      StateError('websocket failed'),
    );
    await _flushMicrotasks(4);

    expect(factoryCalls, 2);
    expect(
      messages.any(
        (message) =>
            message.contains('Best-effort socket operation failed') &&
            message.contains('reason=websocket-polling-fallback'),
      ),
      isTrue,
    );
  });

  test('resuming from background forces a fresh socket connection', () async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _flushMicrotasks();

    final service = _RecordingSocketService();
    addTearDown(service.dispose);

    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(service.isAppForeground, isFalse);

    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await _flushMicrotasks(2);

    expect(service.isAppForeground, isTrue);
    expect(service.forceConnectCalls, [true]);
  });

  test(
    'resume reconnect is guarded while a forced connect is in flight',
    () async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flushMicrotasks();

      final connectGate = Completer<void>();
      final service = _RecordingSocketService(connectGate: connectGate);
      addTearDown(service.dispose);

      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _flushMicrotasks(2);

      service.didChangeAppLifecycleState(AppLifecycleState.hidden);
      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _flushMicrotasks(2);

      expect(service.forceConnectCalls, [true]);

      connectGate.complete();
      await _flushMicrotasks(2);
    },
  );

  test(
    'force reconnect restores dynamic event listeners on the new socket',
    () async {
      final socketFactory = _RecordingSocketFactory();
      final service = SocketService(
        serverConfig: _serverConfig,
        socketFactory: socketFactory.create,
      );
      addTearDown(service.dispose);

      final received = <String>[];
      service.onEvent('task-channel', (data) => received.add(data.toString()));

      await service.connect();
      expect(socketFactory.sockets, hasLength(1));

      socketFactory.sockets.single.emitReserved('task-channel', 'first');
      expect(received, ['first']);

      final oldSocket = socketFactory.sockets.single;
      oldSocket.emitReserved('connect');
      await _flushMicrotasks(2);
      await service.connect(force: true);
      expect(socketFactory.sockets, hasLength(2));

      oldSocket.emitReserved('task-channel', 'old');
      socketFactory.sockets.last.emitReserved('task-channel', 'second');

      expect(received, ['first', 'second']);
    },
  );

  test('forced reconnects coalesce until the active attempt settles', () async {
    final socketFactory = _RecordingSocketFactory();
    final service = SocketService(
      serverConfig: _serverConfig,
      authToken: 'session-token',
      socketFactory: socketFactory.create,
    );
    addTearDown(service.dispose);

    await service.connect();
    final firstSocket = socketFactory.sockets.single;
    final firstSocketEvents = <String>[];
    firstSocket.onAnyOutgoing(
      (event, _) => firstSocketEvents.add(event.toString()),
    );

    final firstForced = service.connect(force: true);
    final secondForced = service.connect(force: true);
    await _flushMicrotasks(2);

    // A force request cannot dispose or replace a negotiating socket.
    expect(socketFactory.sockets, hasLength(1));
    expect(service.socket, same(firstSocket));

    firstSocket.emitReserved('connect');
    await Future.wait([firstForced, secondForced]);
    await _flushMicrotasks(2);

    expect(socketFactory.sockets, hasLength(2));
    expect(service.socket, same(socketFactory.sockets.last));
    expect(firstSocketEvents, isNot(contains('user-join')));

    // Events queued by the retired attempt cannot trigger another fallback
    // or replace the fresh socket after ownership has moved on.
    firstSocket.emitReserved('connect_error', StateError('stale failure'));
    await _flushMicrotasks(2);
    expect(socketFactory.sockets, hasLength(2));
    expect(service.socket, same(socketFactory.sockets.last));
  });

  test('pausing during handshake allows a fresh socket on resume', () async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _flushMicrotasks();

    final socketFactory = _RecordingSocketFactory();
    final service = SocketService(
      serverConfig: _serverConfig,
      socketFactory: socketFactory.create,
    );
    addTearDown(service.dispose);

    await service.connect();
    expect(socketFactory.sockets, hasLength(1));

    // The test socket deliberately emits no disconnect terminal event while
    // it is still negotiating.
    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await _flushMicrotasks(2);

    expect(socketFactory.sockets, hasLength(2));
    expect(service.socket, same(socketFactory.sockets.last));
  });

  test('going offline during handshake allows a fresh socket online', () async {
    final socketFactory = _RecordingSocketFactory();
    final service = SocketService(
      serverConfig: _serverConfig,
      socketFactory: socketFactory.create,
    );
    addTearDown(service.dispose);

    await service.connect();
    expect(socketFactory.sockets, hasLength(1));

    service.updateNetworkAvailability(false);
    service.updateNetworkAvailability(true);
    await _flushMicrotasks(2);

    expect(socketFactory.sockets, hasLength(2));
    expect(service.socket, same(socketFactory.sockets.last));
  });

  test(
    'connect includes the Conduit User-Agent in handshake headers',
    () async {
      final socketFactory = _RecordingSocketFactory();
      final service = SocketService(
        serverConfig: _serverConfig.copyWith(
          customHeaders: const {
            'X-Proxy-Credential': 'proxy-secret',
            'user-agent': 'spoofed-agent',
          },
        ),
        authToken: 'auth-token',
        socketFactory: socketFactory.create,
      );
      addTearDown(service.dispose);

      await service.connect();

      final headers = socketFactory.handshakeHeaders.single;
      expect(headers[ConduitUserAgent.headerName], ConduitUserAgent.value);
      expect(headers['Authorization'], 'Bearer auth-token');
      expect(headers['X-Proxy-Credential'], 'proxy-secret');
      expect(headers.keys.where(ConduitUserAgent.isHeaderName), [
        ConduitUserAgent.headerName,
      ]);
    },
  );

  test('native handshake sends one Conduit User-Agent value', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final receivedUserAgents = Completer<List<String>>();
      server.listen((request) async {
        if (!receivedUserAgents.isCompleted) {
          receivedUserAgents.complete(
            request.headers[HttpHeaders.userAgentHeader] ?? const [],
          );
        }
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
      });

      final service = SocketService(
        serverConfig: ServerConfig(
          id: 'wire-user-agent',
          name: 'Wire User-Agent',
          url: 'http://${server.address.address}:${server.port}',
        ),
        websocketOnly: true,
      );

      try {
        await service.connect();
        expect(
          await receivedUserAgents.future.timeout(const Duration(seconds: 5)),
          [ConduitUserAgent.value],
        );
      } finally {
        service.dispose();
        await server.close(force: true);
      }
    }, _RealHttpOverrides());
  });

  test(
    'resume reconnect emits onReconnect after the new socket connects',
    () async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flushMicrotasks();

      final socketFactory = _RecordingSocketFactory();
      final service = SocketService(
        serverConfig: _serverConfig,
        socketFactory: socketFactory.create,
      );
      addTearDown(service.dispose);

      var reconnectCount = 0;
      final reconnectSub = service.onReconnect.listen((_) {
        reconnectCount += 1;
      });
      addTearDown(reconnectSub.cancel);

      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _flushMicrotasks(2);

      expect(socketFactory.sockets, hasLength(1));
      expect(reconnectCount, 0);

      socketFactory.sockets.single.id = 'session-after-resume';
      socketFactory.sockets.single.emitReserved('connect');
      await _flushMicrotasks(2);

      expect(reconnectCount, 1);
    },
  );

  test(
    'resume reconnect still emits onReconnect after watchdog releases latch',
    () async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flushMicrotasks();

      final socketFactory = _RecordingSocketFactory();
      final service = SocketService(
        serverConfig: _serverConfig,
        socketFactory: socketFactory.create,
        resumeReconnectWatchdogTimeout: const Duration(milliseconds: 10),
      );
      addTearDown(service.dispose);

      var reconnectCount = 0;
      final reconnectSub = service.onReconnect.listen((_) {
        reconnectCount += 1;
      });
      addTearDown(reconnectSub.cancel);

      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _flushMicrotasks(2);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(socketFactory.sockets, hasLength(1));
      expect(reconnectCount, 0);

      socketFactory.sockets.single.id = 'slow-session-after-resume';
      socketFactory.sockets.single.emitReserved('connect');
      await _flushMicrotasks(2);

      expect(reconnectCount, 1);
    },
  );

  test(
    'resume reconciles an already-connected background lease without replacing it',
    () async {
      final socketFactory = _RecordingSocketFactory();
      final service = SocketService(
        serverConfig: _serverConfig,
        socketFactory: socketFactory.create,
      );
      addTearDown(service.dispose);
      var reconnectCount = 0;
      final reconnectSub = service.onReconnect.listen((_) => reconnectCount++);
      addTearDown(reconnectSub.cancel);

      await service.connect();
      final socket = socketFactory.sockets.single;
      socket.connected = true;
      socket.id = 'leased-background-session';
      socket.emitReserved('connect');
      await _flushMicrotasks(2);
      final lease = service.acquireBackgroundActivityLease();
      addTearDown(lease.dispose);

      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(socket.connected, isTrue);
      expect(socket.io.reconnection, isTrue);

      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _flushMicrotasks(2);

      expect(socketFactory.sockets, hasLength(1));
      expect(service.socket, same(socket));
      expect(service.isConnected, isTrue);
      expect(reconnectCount, 1);
    },
  );

  test('background disables reconnect for an idle socket', () async {
    final socketFactory = _RecordingSocketFactory();
    final service = SocketService(
      serverConfig: _serverConfig,
      socketFactory: socketFactory.create,
    );
    addTearDown(service.dispose);

    await service.connect();
    final socket = socketFactory.sockets.single;
    expect(socket.io.reconnection, isTrue);

    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(socket.io.reconnection, isFalse);
    expect(service.backgroundActivityLeaseCount, 0);
  });

  test('late reconnect success is retired while transport is gated', () async {
    final socketFactory = _RecordingSocketFactory();
    final service = SocketService(
      serverConfig: _serverConfig,
      socketFactory: socketFactory.create,
    );
    addTearDown(service.dispose);
    var reconnectSignals = 0;
    final reconnectSub = service.onReconnect.listen((_) => reconnectSignals++);
    addTearDown(reconnectSub.cancel);

    await service.connect();
    final socket = socketFactory.sockets.single;
    socket.connected = true;
    socket.id = 'connected-before-pause';
    socket.emitReserved('connect');
    await _flushMicrotasks(2);
    expect(service.isConnected, isTrue);

    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    socket.connected = true;
    socket.emitReserved('reconnect', 1);
    await _flushMicrotasks(2);

    expect(socket.io.reconnection, isFalse);
    expect(socket.connected, isFalse);
    expect(reconnectSignals, 0);
  });

  test(
    'late initial connect cannot authenticate after the app pauses',
    () async {
      final socketFactory = _RecordingSocketFactory();
      final service = SocketService(
        serverConfig: _serverConfig,
        authToken: 'session-token',
        socketFactory: socketFactory.create,
      );
      addTearDown(service.dispose);

      await service.connect();
      final socket = socketFactory.sockets.single;
      final outgoingEvents = <String>[];
      socket.onAnyOutgoing((event, _) => outgoingEvents.add(event.toString()));

      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      // Model the platform delivering a successful handshake callback after the
      // pause already retired the negotiating transport.
      socket.connected = true;
      socket.emitReserved('connect');
      await _flushMicrotasks(2);

      expect(socket.connected, isFalse);
      expect(socket.io.reconnection, isFalse);
      expect(outgoingEvents, isNot(contains('user-join')));
    },
  );

  test(
    'late forced connect cannot authenticate or signal reconnect when offline',
    () async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flushMicrotasks();

      final socketFactory = _RecordingSocketFactory();
      final service = SocketService(
        serverConfig: _serverConfig,
        authToken: 'session-token',
        socketFactory: socketFactory.create,
      );
      addTearDown(service.dispose);
      var reconnectSignals = 0;
      final reconnectSub = service.onReconnect.listen(
        (_) => reconnectSignals++,
      );
      addTearDown(reconnectSub.cancel);

      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _flushMicrotasks(2);
      final socket = socketFactory.sockets.single;
      final outgoingEvents = <String>[];
      socket.onAnyOutgoing((event, _) => outgoingEvents.add(event.toString()));

      service.updateNetworkAvailability(false);
      socket.connected = true;
      socket.emitReserved('connect');
      await _flushMicrotasks(2);

      expect(socket.connected, isFalse);
      expect(socket.io.reconnection, isFalse);
      expect(outgoingEvents, isNot(contains('user-join')));
      expect(reconnectSignals, 0);
    },
  );

  test(
    'resume while offline reconciles after network recovery connects',
    () async {
      final socketFactory = _RecordingSocketFactory();
      final service = SocketService(
        serverConfig: _serverConfig,
        socketFactory: socketFactory.create,
      );
      addTearDown(service.dispose);
      var reconnectSignals = 0;
      final reconnectSub = service.onReconnect.listen((_) {
        reconnectSignals += 1;
      });
      addTearDown(reconnectSub.cancel);

      await service.connect();
      final socket = socketFactory.sockets.single;
      service.updateNetworkAvailability(false);
      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _flushMicrotasks(2);

      expect(socket.io.reconnection, isFalse);
      expect(socketFactory.sockets, hasLength(1));
      expect(reconnectSignals, 0);

      service.updateNetworkAvailability(true);
      await _flushMicrotasks(2);

      expect(socketFactory.sockets, hasLength(2));
      final recoveredSocket = socketFactory.sockets.last;
      recoveredSocket.connected = true;
      recoveredSocket.id = 'recovered-after-offline-resume';
      recoveredSocket.emitReserved('connect');
      await _flushMicrotasks(2);

      expect(service.isConnected, isTrue);
      expect(reconnectSignals, 1);
    },
  );

  test('active stream lease keeps reconnect enabled in background', () async {
    final socketFactory = _RecordingSocketFactory();
    final service = SocketService(
      serverConfig: _serverConfig,
      socketFactory: socketFactory.create,
    );
    addTearDown(service.dispose);

    await service.connect();
    final subscription = service.addChatEventHandler(
      sessionId: 'stream-session',
      requireFocus: false,
      keepsAliveInBackground: true,
      handler: (_, _) {},
    );
    service.didChangeAppLifecycleState(AppLifecycleState.paused);

    expect(socketFactory.sockets.single.io.reconnection, isTrue);
    expect(service.backgroundActivityLeaseCount, 1);

    subscription.dispose();
    expect(socketFactory.sockets.single.io.reconnection, isFalse);
    expect(service.backgroundActivityLeaseCount, 0);
  });

  test('a handler lease does not create the initial transport', () async {
    final socketFactory = _RecordingSocketFactory();
    final service = SocketService(
      serverConfig: _serverConfig,
      socketFactory: socketFactory.create,
    );
    addTearDown(service.dispose);

    final subscription = service.addChatEventHandler(
      sessionId: 'detached-stream-session',
      requireFocus: false,
      keepsAliveInBackground: true,
      handler: (_, _) {},
    );
    addTearDown(subscription.dispose);
    await _flushMicrotasks(2);

    expect(socketFactory.sockets, isEmpty);
    expect(service.backgroundActivityLeaseCount, 1);

    await service.connect();
    expect(socketFactory.sockets, hasLength(1));
  });
}

const _serverConfig = ServerConfig(
  id: 'test-server',
  name: 'Test Server',
  url: 'https://example.com',
);

class _RecordingSocketService extends SocketService {
  _RecordingSocketService({Completer<void>? connectGate})
    : _connectGate = connectGate,
      super(serverConfig: _serverConfig);

  final Completer<void>? _connectGate;
  final List<bool> forceConnectCalls = <bool>[];

  @override
  Future<void> connect({bool force = false}) async {
    forceConnectCalls.add(force);
    final gate = _connectGate;
    if (gate != null && !gate.isCompleted) {
      await gate.future;
    }
  }
}

class _RecordingSocketFactory {
  final List<io.Socket> sockets = <io.Socket>[];
  final List<Map<String, String>> handshakeHeaders = <Map<String, String>>[];

  io.Socket create(
    String base,
    io.OptionBuilder builder,
    ServerConfig serverConfig,
  ) {
    final options = builder.build();
    handshakeHeaders.add(
      Map<String, String>.from(
        options['extraHeaders'] as Map<dynamic, dynamic>? ?? const {},
      ),
    );
    final socket = io.io(
      'http://localhost:${19000 + sockets.length}',
      <String, dynamic>{
        'autoConnect': false,
        'forceNew': true,
        'reconnection': false,
      },
    );
    sockets.add(socket);
    return socket;
  }
}

class _RealHttpOverrides extends HttpOverrides {}
