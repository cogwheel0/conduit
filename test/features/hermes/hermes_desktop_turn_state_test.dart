import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/features/hermes/models/hermes_bot.dart';
import 'package:conduit/features/hermes/models/hermes_run_event.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit/features/hermes/services/hermes_desktop_transport.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

Dio _statusDio([_StubAdapter? adapter]) {
  final dio = Dio();
  dio.httpClientAdapter = adapter ?? _StubAdapter();
  return dio;
}

/// Serves `/api/status` (auth not required) so `_connect` can reach the socket,
/// and records every REST URI so tests can assert profile scoping.
final class _StubAdapter implements HttpClientAdapter {
  final requested = <Uri>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri);
    if (options.uri.path.endsWith('/messages')) {
      return ResponseBody.fromString(
        jsonEncode({'messages': const []}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
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
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(PreferencesStore.debugReset);

  test(
    'session.info clears an unsupportedGateway state keyed by stored id',
    () async {
      final harness = _GatewayHarness();
      final rpc = HermesDesktopRpcClient(
        channelFactory: (_, _, {httpClient}) => harness.channel,
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
      channelFactory: (_, _, {httpClient}) => harness.channel,
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

  test(
    'bot chat transcript reads carry the bot profile, not the connection one',
    () async {
      SharedPreferences.setMockInitialValues({});
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      final harness = _GatewayHarness();
      final adapter = _StubAdapter();
      final rpc = HermesDesktopRpcClient(
        channelFactory: (_, _, {httpClient}) => harness.channel,
      );
      final service = HermesDesktopApiService(
        config: HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          mode: HermesBackendMode.desktopGateway,
          // The CONNECTION profile. A bot chat lives in another profile, and
          // an unscoped read silently resolves against this one instead,
          // returning a different conversation that shares the session id.
          desktopProfile: 'default',
          desktopCredentials: HermesDesktopCredentials(
            legacyToken: 'session-token',
          ),
        ),
        dio: _statusDio(adapter),
        rpc: rpc,
      );
      addTearDown(() async {
        service.close();
        await harness.dispose();
      });

      harness.responder = (method) => switch (method) {
        'session.resume' => {
          'session_id': 'runtime-bot',
          'stored_session_id': 'stored-bot',
          'info': const {'running': false},
          'running': false,
        },
        _ => const {},
      };

      await service.openBotChat(
        const HermesBot(
          name: 'researcher',
          title: 'Research',
          chatSessionId: 'stored-bot',
        ),
      );
      await service.getSessionMessages('stored-bot');

      final reads = adapter.requested
          .where((uri) => uri.path.endsWith('/messages'))
          .toList();
      check(reads).isNotEmpty();
      for (final uri in reads) {
        check(
          uri.queryParameters['profile'],
          because: 'unscoped bot transcript read: \$uri',
        ).equals('researcher');
      }
    },
  );

  test(
    'every bot-chat RPC names the bot profile, never the connection one',
    () async {
      SharedPreferences.setMockInitialValues({});
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      final harness = _GatewayHarness();
      final rpc = HermesDesktopRpcClient(
        channelFactory: (_, _, {httpClient}) => harness.channel,
      );
      final service = HermesDesktopApiService(
        config: HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          mode: HermesBackendMode.desktopGateway,
          desktopProfile: 'default',
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
        'session.resume' => {
          'session_id': 'runtime-bot',
          'stored_session_id': 'stored-bot',
          'info': const {'running': false},
          'running': false,
        },
        'session.steer' => {'status': 'queued'},
        _ => const {},
      };

      await service.openBotChat(
        const HermesBot(
          name: 'researcher',
          title: 'Research',
          chatSessionId: 'stored-bot',
        ),
      );
      await service.interrupt('stored-bot');
      await service.steer('stored-bot', 'hello');
      await service.queue('stored-bot', 'later');
      await service.renameSession('stored-bot', 'Renamed');
      await service.resolveApprovalForSession(
        'stored-bot',
        approvalId: 'req-1',
        approved: true,
      );
      await service.respondToDecision(
        storedSessionId: 'stored-bot',
        runtimeId: 'runtime-bot',
        requestId: 'req-2',
        kind: HermesDecisionKind.clarification,
        value: 'answer',
      );
      await service.reloadMcp(runtimeId: 'runtime-bot');
      // A DENIED MCP setup skips install/enable/authorize and goes straight
      // to mcp.setup.respond, which must also name the bot profile.
      await service.respondToDecision(
        storedSessionId: 'stored-bot',
        runtimeId: 'runtime-bot',
        requestId: 'req-3',
        kind: HermesDecisionKind.mcpSetup,
        value: 'deny',
        mcpServer: 'docs',
        mcpAction: 'enable',
      );

      // The transport injects the CONNECTION profile as a default, so any bot
      // frame that fails to name its own profile silently travels as 'default'.
      final botFrames = harness.sent
          .where((frame) => (frame['params'] as Map)['session_id'] != null)
          .toList();
      check(botFrames).isNotEmpty();
      for (final frame in botFrames) {
        final params = frame['params'] as Map;
        check(
          params['profile'],
          because:
              '${frame['method']} left the bot session on the connection '
              'profile: $params',
        ).equals('researcher');
      }
    },
  );
}
