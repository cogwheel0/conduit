import 'dart:async';

import 'package:conduit/core/models/server_config.dart';
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
      await service.connect(force: true);
      expect(socketFactory.sockets, hasLength(2));

      oldSocket.emitReserved('task-channel', 'old');
      socketFactory.sockets.last.emitReserved('task-channel', 'second');

      expect(received, ['first', 'second']);
    },
  );

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

  io.Socket create(
    String base,
    io.OptionBuilder builder,
    ServerConfig serverConfig,
  ) {
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
