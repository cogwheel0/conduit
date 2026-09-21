@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

import 'support/null_sink.dart';

/// 43+ chars, as [BootstrapConfig] requires.
const String _token = 'cJkVQ1mEo3nT7pZs9YbXwF2gH5LdRaUvNi0KqMtBxCe';
const String _wrongToken = 'ZZZZZ1mEo3nT7pZs9YbXwF2gH5LdRaUvNi0KqMtBxCe';
final String _masterKey = base64.encode(List<int>.filled(32, 7));

void main() {
  late Directory tempDir;
  late DaemonServer server;
  late int port;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('conduitd_test');
    server = DaemonServer(
      config: BootstrapConfig(
        sessionToken: _token,
        masterKey: _masterKey,
        userDataDir: tempDir.path,
      ),
      directories: DaemonDirectories.create(tempDir.path),
      daemonVersion: '0.0.0-test',
      // Silence the log; a failing test should print expectations, not noise.
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    port = await server.start();
  });

  tearDown(() async {
    await server.stop();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Opens an authenticated RPC peer the way the renderer does.
  Future<json_rpc.Peer> connect({
    String token = _token,
    String origin = kConduitAppOrigin,
  }) async {
    final socket = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:$port${ConduitHttpRoutes.rpc}'),
      protocols: buildSubprotocols(token),
      headers: <String, dynamic>{'Origin': origin},
    );
    await socket.ready;
    final peer = json_rpc.Peer(socket.cast<String>());
    unawaited(peer.listen());
    return peer;
  }

  Future<HandshakeResponse> handshake(
    json_rpc.Peer peer, {
    String version = kConduitProtocolVersion,
  }) => callTyped<HandshakeResponse>(
    peer,
    ConduitMethods.systemHandshake,
    params: HandshakeRequest(
      protocolVersion: version,
      clientName: 'test',
      clientVersion: '0.0.0',
      windowKind: WindowKind.headless,
      locale: 'en',
    ).toJson(),
    decodeResult: HandshakeResponse.fromJson,
  );

  group('auth gate', () {
    test('rejects an RPC socket with no Origin header', () async {
      // shelf_web_socket only checks Origin when it is present, so the
      // daemon must reject a missing one itself. A local process that is not
      // the renderer would otherwise walk straight in.
      final socket = IOWebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:$port${ConduitHttpRoutes.rpc}'),
        protocols: buildSubprotocols(_token),
      );
      await expectLater(socket.ready, throwsA(isA<Exception>()));
    });

    test('rejects an RPC socket from a foreign origin', () async {
      final socket = IOWebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:$port${ConduitHttpRoutes.rpc}'),
        protocols: buildSubprotocols(_token),
        headers: <String, dynamic>{'Origin': 'https://evil.example'},
      );
      await expectLater(socket.ready, throwsA(isA<Exception>()));
    });

    test('rejects an RPC socket with no token', () async {
      final socket = IOWebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:$port${ConduitHttpRoutes.rpc}'),
        protocols: <String>[kConduitSubprotocol],
        headers: <String, dynamic>{'Origin': kConduitAppOrigin},
      );
      await expectLater(socket.ready, throwsA(isA<Exception>()));
    });

    test('rejects an RPC socket with the wrong token', () async {
      final socket = IOWebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:$port${ConduitHttpRoutes.rpc}'),
        protocols: buildSubprotocols(_wrongToken),
        headers: <String, dynamic>{'Origin': kConduitAppOrigin},
      );
      await expectLater(socket.ready, throwsA(isA<Exception>()));
    });

    test('echoes only the version tag as the negotiated subprotocol', () async {
      final socket = IOWebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:$port${ConduitHttpRoutes.rpc}'),
        protocols: buildSubprotocols(_token),
        headers: <String, dynamic>{'Origin': kConduitAppOrigin},
      );
      await socket.ready;
      // The token must never come back in a response header.
      expect(socket.protocol, negotiatedSubprotocol);
      await socket.sink.close();
    });

    test('HTTP endpoints require a bearer token', () async {
      final client = HttpClient();
      addTearDown(client.close);

      final anonymous = await (await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/health'),
      )).close();
      expect(anonymous.statusCode, HttpStatus.unauthorized);

      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/health'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      final authorized = await request.close();
      expect(authorized.statusCode, HttpStatus.ok);
      final body = jsonDecode(
        await authorized.transform(utf8.decoder).join(),
      ) as Map<String, dynamic>;
      expect(body['ok'], isTrue);
      expect(body['protocolVersion'], kConduitProtocolVersion);
    });

    test('HTTP endpoints reject a wrong bearer token', () async {
      final client = HttpClient();
      addTearDown(client.close);
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/health'),
      );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $_wrongToken',
      );
      expect((await request.close()).statusCode, HttpStatus.unauthorized);
    });
  });

  group('system.*', () {
    test('handshake reports paths, platform and protocol version', () async {
      final peer = await connect();
      addTearDown(peer.close);

      final response = await handshake(peer);
      expect(response.protocolVersion, kConduitProtocolVersion);
      expect(response.daemonVersion, '0.0.0-test');
      expect(response.sessionId, isNotEmpty);
      expect(response.paths.userData, tempDir.path);
      expect(response.platform, isNotEmpty);
      // Nothing is configured yet, so every M0 launch is an onboarding launch.
      expect(response.needsOnboarding, isTrue);
      expect(response.capabilities, Capabilities.none);
    });

    test('a version mismatch is refused, not negotiated', () async {
      final peer = await connect();
      addTearDown(peer.close);

      await expectLater(
        handshake(peer, version: '0.9.9'),
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.protocolVersionMismatch,
          ),
        ),
      );
    });

    test('other methods are refused before the handshake', () async {
      final peer = await connect();
      addTearDown(peer.close);

      await expectLater(
        callTyped<PongResult>(
          peer,
          ConduitMethods.systemPing,
          decodeResult: PongResult.fromJson,
        ),
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.protocolViolation,
          ),
        ),
      );
    });

    test('ping returns uptime and clock', () async {
      final peer = await connect();
      addTearDown(peer.close);
      await handshake(peer);

      final pong = await callTyped<PongResult>(
        peer,
        ConduitMethods.systemPing,
        decodeResult: PongResult.fromJson,
      );
      expect(pong.uptimeMs, greaterThanOrEqualTo(0));
      expect(
        pong.serverTimeMs,
        greaterThan(DateTime.utc(2020).millisecondsSinceEpoch),
      );
    });

    test('exportDiagnostics writes a file that actually exists', () async {
      final peer = await connect();
      addTearDown(peer.close);
      await handshake(peer);

      final export = await callTyped<DiagnosticsExport>(
        peer,
        ConduitMethods.systemExportDiagnostics,
        decodeResult: DiagnosticsExport.fromJson,
      );
      expect(File(export.path).existsSync(), isTrue);
      expect(export.sizeBytes, greaterThan(0));
    });

    test(
      'an unknown method is a typo; a reserved one is a missing milestone',
      () async {
        final peer = await connect();
        addTearDown(peer.close);
        await handshake(peer);

        await expectLater(
          callVoid(peer, 'bogus.method'),
          throwsA(
            isA<RpcError>().having(
              (e) => e.code,
              'code',
              ConduitErrorCodes.methodNotFound,
            ),
          ),
        );
        await expectLater(
          callVoid(peer, 'chats.list'),
          throwsA(
            isA<RpcError>().having(
              (e) => e.code,
              'code',
              ConduitErrorCodes.unsupported,
            ),
          ),
        );
      },
    );

    test('shutdown replies before the socket goes away', () async {
      final peer = await connect();
      await handshake(peer);

      final result = await callTyped<ShutdownResult>(
        peer,
        ConduitMethods.systemShutdown,
        decodeResult: ShutdownResult.fromJson,
      );
      expect(result.flushed, isTrue);
      await server.onStopped;
    });
  });

  group('events', () {
    test('subscription filters by event name and scope', () async {
      final peer = await connect();
      addTearDown(peer.close);
      await handshake(peer);

      final received = <EventEnvelope>[];
      registerEventSink(peer, onEvent: received.add);

      await callTyped<EventSubscription>(
        peer,
        ConduitMethods.eventsSubscribe,
        params: const EventSubscription(
          events: <String>[ConduitEvents.turnDelta, ConduitEvents.syncStatus],
          scopes: <String>['chat_a'],
        ).toJson(),
        decodeResult: EventSubscription.fromJson,
      );

      server.events.publish(
        ConduitEvents.turnDelta,
        scope: 'chat_a',
        payload: <String, dynamic>{'text': 'yes'},
      );
      // Filtered out: right event, wrong scope.
      server.events.publish(ConduitEvents.turnDelta, scope: 'chat_b');
      // Filtered out: not in the requested event set.
      server.events.publish(ConduitEvents.notesChanged);
      // Session-wide events are always delivered when the name matches.
      server.events.publish(ConduitEvents.syncStatus);

      await _settle();

      expect(received.map((e) => e.event).toList(), <String>[
        ConduitEvents.turnDelta,
        ConduitEvents.syncStatus,
      ]);
      expect(received.first.payload['text'], 'yes');
      // Sequence numbers are allocated globally, so the gap from the two
      // filtered events is visible — that is what lets a reconnecting client
      // notice it missed something.
      expect(received.last.seq - received.first.seq, 3);
    });

    test('an unknown event name is rejected', () async {
      final peer = await connect();
      addTearDown(peer.close);
      await handshake(peer);

      await expectLater(
        callTyped<EventSubscription>(
          peer,
          ConduitMethods.eventsSubscribe,
          params: const EventSubscription(events: <String>['turn.nope'])
              .toJson(),
          decodeResult: EventSubscription.fromJson,
        ),
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.invalidParams,
          ),
        ),
      );
    });

    test('two windows both receive a broadcast', () async {
      final a = await connect();
      final b = await connect();
      addTearDown(a.close);
      addTearDown(b.close);
      await handshake(a);
      await handshake(b);

      final seenByA = <EventEnvelope>[];
      final seenByB = <EventEnvelope>[];
      registerEventSink(a, onEvent: seenByA.add);
      registerEventSink(b, onEvent: seenByB.add);

      server.events.publish(ConduitEvents.socketHealth);
      await _settle();

      expect(seenByA, hasLength(1));
      expect(seenByB, hasLength(1));
      // One allocation, two deliveries: every window sees one ordering.
      expect(seenByA.single.seq, seenByB.single.seq);
    });
  });
}

/// Lets queued microtasks and socket frames drain.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 150));
