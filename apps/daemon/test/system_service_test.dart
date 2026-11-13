@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/null_sink.dart';

/// `system.handshake`'s onboarding answer and `system.shutdown`, without a
/// socket in the way.
void main() {
  late Directory temp;
  late List<String> stops;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('conduitd_system');
    stops = <String>[];
  });
  tearDown(() => temp.deleteSync(recursive: true));

  SystemService service({
    Future<bool> Function()? needsOnboarding,
    Future<int> Function()? flushOutbox,
  }) => SystemService(
    directories: DaemonDirectories.create(temp.path),
    daemonVersion: '0.0.0-test',
    log: DaemonLog(level: 'error', sink: NullSink()),
    requestStop: stops.add,
    needsOnboarding: needsOnboarding,
    flushOutbox: flushOutbox,
  );

  Future<HandshakeResponse> handshake(SystemService system) => system.handshake(
    sessionId: 's',
    request: const HandshakeRequest(
      protocolVersion: kConduitProtocolVersion,
      clientName: 'test',
      clientVersion: '0',
      windowKind: WindowKind.headless,
      locale: 'en',
    ),
  );

  group('needsOnboarding', () {
    test('is the core\'s answer once there is one', () async {
      expect(
        (await handshake(service(needsOnboarding: () async => true)))
            .needsOnboarding,
        isTrue,
      );
      expect(
        (await handshake(service(needsOnboarding: () async => false)))
            .needsOnboarding,
        isFalse,
      );
    });

    test('is false while nobody can know', () async {
      // Before the core attaches, and when asking it fails: true would send
      // a signed-in user to the welcome screen.
      expect((await handshake(service())).needsOnboarding, isFalse);
      expect(
        (await handshake(
          service(needsOnboarding: () async => throw StateError('x')),
        )).needsOnboarding,
        isFalse,
      );
    });
  });

  group('shutdown', () {
    test('stops the daemon, after the reply rather than before it', () async {
      final result = await service().shutdown();
      // Nothing to send without a core.
      expect(result.flushed, isTrue);
      expect(result.pendingOutboxEntries, 0);
      // The reply is written before the sockets close.
      expect(stops, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(stops, <String>['system.shutdown']);
    });

    test('reports what the outbox could not send', () async {
      var flushed = false;
      final result = await service(
        flushOutbox: () async {
          flushed = true;
          return 2;
        },
      ).shutdown();
      expect(flushed, isTrue);
      expect(result.flushed, isFalse);
      expect(result.pendingOutboxEntries, 2);
    });

    test('an empty outbox is flushed', () async {
      final result = await service(flushOutbox: () async => 0).shutdown();
      expect(result.flushed, isTrue);
    });

    test('a flush that fails claims nothing and still stops', () async {
      final result = await service(
        flushOutbox: () async => throw StateError('database gone'),
      ).shutdown();
      expect(result.flushed, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(stops, <String>['system.shutdown']);
    });
  });
}
