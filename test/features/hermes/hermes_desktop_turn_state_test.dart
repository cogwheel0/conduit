import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit/features/hermes/services/hermes_desktop_transport.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final class _MockWebSocketChannel extends Mock implements WebSocketChannel {}

final class _MockWebSocketSink extends Mock implements WebSocketSink {}

/// Minimal gateway stub: answers `session.create` WITHOUT a `running` field,
/// which is what a real Hermes 0.20.x gateway does, then lets the test push
/// `session.info` frames by hand.
final class _GatewayHarness {
  _GatewayHarness() {
    when(() => channel.ready).thenAnswer((_) async {});
    when(() => channel.stream).thenAnswer((_) {
      // The client subscribes inside connect(); announce readiness right after
      // so the handshake completes without the test guessing at timing.
      scheduleMicrotask(ready);
      return incoming.stream;
    });
    when(() => channel.sink).thenReturn(sink);
    when(() => sink.close()).thenAnswer((_) async {});
    when(() => sink.add(any())).thenAnswer((invocation) {
      final frame = Map<String, dynamic>.from(
        jsonDecode(invocation.positionalArguments.single as String) as Map,
      );
      sent.add(frame);
      final id = frame['id'];
      if (id == null) return;
      final result = responder(frame['method']?.toString() ?? '');
      if (result == null) return;
      scheduleMicrotask(
        () => incoming.add(
          jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
        ),
      );
    });
  }

  final channel = _MockWebSocketChannel();
  final sink = _MockWebSocketSink();
  final incoming = StreamController<dynamic>.broadcast();
  final sent = <Map<String, dynamic>>[];

  Map<String, dynamic>? Function(String method) responder = (_) => null;

  void ready() {
    if (incoming.isClosed) return;
    incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': {}},
      }),
    );
  }

  /// Pushes the `session.info` the gateway emits when a turn settles.
  void sessionInfo(String runtimeId, {required bool running}) => incoming.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {
        'type': 'session.info',
        'session_id': runtimeId,
        'payload': {'running': running},
      },
    }),
  );

  Future<void> dispose() => incoming.close();
}

Dio _statusDio() {
  final dio = Dio();
  dio.httpClientAdapter = _StubAdapter();
  return dio;
}

/// Serves `/api/status` (auth not required) so `_connect` can reach the socket.
final class _StubAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = jsonEncode({
      'version': '0.20.1',
      'auth_required': false,
      'gateway_running': true,
    });
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

void main() {
  test(
    'session.info clears an unsupportedGateway state keyed by stored id',
    () async {
      final harness = _GatewayHarness();
      final rpc = HermesDesktopRpcClient(
        channelFactory: (_, _) => harness.channel,
      );
      final service = HermesDesktopApiService(
        config: HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          mode: HermesBackendMode.desktopGateway,
          desktopCredentials: HermesDesktopCredentials(
            legacyToken: 'session-token',
          ),
        ),
        dio: _statusDio(),
        rpc: rpc,
      );
      addTearDown(() async {
        service.close();
        await harness.dispose();
      });

      // A real gateway answers session.create with no `running` field.
      harness.responder = (method) => switch (method) {
        'session.create' => {
          'session_id': 'runtime-1',
          'stored_session_id': 'stored-1',
          'message_count': 0,
          'messages': const [],
          'info': const {},
        },
        _ => const {},
      };
      final stored = await service.createDesktopSession();
      check(stored).equals('stored-1');

      // Absent `running`, the stored id parks at unsupportedGateway — the
      // state that made every turn after the first fail with the generic
      // "Hermes run failed." until a resume repaired it.
      check(service.turnStateFor('stored-1'))
          .equals(HermesDesktopTurnState.unsupportedGateway);

      // The turn settles: the gateway emits session.info against the RUNTIME
      // id. That must repair the stored id too, not just its own key.
      harness.sessionInfo('runtime-1', running: false);
      await Future<void>.delayed(Duration.zero);

      check(service.turnStateFor('stored-1'))
          .equals(HermesDesktopTurnState.idle);
      check(service.turnStateFor('runtime-1'))
          .equals(HermesDesktopTurnState.idle);
    },
  );

  test('a running session.info reports the turn as running', () async {
    final harness = _GatewayHarness();
    final rpc = HermesDesktopRpcClient(
      channelFactory: (_, _) => harness.channel,
    );
    final service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        mode: HermesBackendMode.desktopGateway,
        desktopCredentials: HermesDesktopCredentials(
          legacyToken: 'session-token',
        ),
      ),
      dio: _statusDio(),
      rpc: rpc,
    );
    addTearDown(() async {
      service.close();
      await harness.dispose();
    });

    harness.responder = (method) => switch (method) {
      'session.create' => {
        'session_id': 'runtime-2',
        'stored_session_id': 'stored-2',
        'info': const {},
      },
      _ => const {},
    };
    await service.createDesktopSession();

    harness.sessionInfo('runtime-2', running: true);
    await Future<void>.delayed(Duration.zero);

    check(service.turnStateFor('stored-2'))
        .equals(HermesDesktopTurnState.running);
  });
}
