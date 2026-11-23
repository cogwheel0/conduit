@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_core/models/socket_health.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// The socket's health, as Settings › Data & Connection follows it.
void main() {
  test(
    'once disposed, a socket that replaces the last is not followed',
    () async {
      final container = ProviderContainer(
        overrides: [
          socketServiceProvider.overrideWith((ref) => ref.watch(_socketInUse)),
        ],
      );
      addTearDown(container.dispose);
      final events = EventBus();
      final seen = <String>[];
      events.tap((event, _, _) {
        if (event == ConduitEvents.socketHealth) seen.add(event);
      });
      final data = DataService(container, events: events);
      container.read(_socketInUse.notifier).inUse = _Socket();
      expect(seen, isNotEmpty);

      await data.dispose();
      seen.clear();
      final next = _Socket();
      container.read(_socketInUse.notifier).inUse = next;
      next.health.add(_health);
      await pumpEventQueue();

      expect(seen, isEmpty);
      expect(next.health.hasListener, isFalse);
    },
  );
}

final SocketHealth _health = SocketHealth(
  latencyMs: 12,
  isConnected: true,
  transport: 'websocket',
  reconnectCount: 0,
);

final class _Socket implements SocketService {
  final StreamController<SocketHealth> health =
      StreamController<SocketHealth>.broadcast();

  @override
  Stream<SocketHealth> get healthStream => health.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// The socket in use, which an account change replaces.
final _socketInUse = NotifierProvider<_SocketInUse, SocketService?>(
  _SocketInUse.new,
);

final class _SocketInUse extends Notifier<SocketService?> {
  @override
  SocketService? build() => null;

  set inUse(SocketService? socket) => state = socket;
}
