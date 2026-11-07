import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/ports/external_url_port.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';

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
      final method = frame['method']?.toString() ?? '';
      final error = errorResponder(method);
      if (error != null) {
        scheduleMicrotask(
          () => incoming.add(
            jsonEncode({'jsonrpc': '2.0', 'id': id, 'error': error}),
          ),
        );
        return;
      }
      final result = responder(method);
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

  /// When non-null for a method, the gateway answers with a JSON-RPC error
  /// instead of a result.
  Map<String, dynamic>? Function(String method) errorResponder = (_) => null;

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

  /// Pushes a turn event for [runtimeId], e.g. `message.start`.
  void event(
    String runtimeId,
    String type, [
    Map<String, dynamic> payload = const {},
  ]) => incoming.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {'type': type, 'session_id': runtimeId, 'payload': payload},
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
  _StubAdapter({this.messages = const <Map<String, dynamic>>[]});

  final List<Map<String, dynamic>> messages;
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
        jsonEncode({'messages': messages}),
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

/// Answers dashboard REST requests from a `METHOD /path` table (status and
/// JSON body), serving `/api/status` with auth off, and records each request.
final class _RoutesAdapter implements HttpClientAdapter {
  _RoutesAdapter(this.routes);

  final Map<String, (int, Object?)> routes;
  final requests = <String>[];

  /// Each request's headers, by `METHOD /path`.
  final headers = <String, Map<String, dynamic>>{};

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final key = '${options.method} ${options.uri.path}';
    headers[key] = options.headers;
    if (options.uri.path != '/api/status') {
      requests.add('$key?${options.uri.query}');
    }
    final (status, body) =
        routes[key] ??
        (options.uri.path == '/api/status'
            ? (200, {'auth_required': false, 'gateway_running': true})
            : (404, {'detail': 'Not Found'}));
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

HermesDesktopApiService _restService(_RoutesAdapter adapter) {
  final service = HermesDesktopApiService(
    config: HermesConfig(
      enabled: true,
      baseUrl: 'https://hermes.example',
      mode: HermesBackendMode.desktopGateway,
      desktopCredentials: HermesDesktopCredentials(
        legacyToken: 'session-token',
      ),
    ),
    dio: Dio()..httpClientAdapter = adapter,
  );
  addTearDown(service.close);
  return service;
}

/// Serves `/api/status` like [_StubAdapter] but fails the transcript request.
final class _FailingMessagesAdapter extends _StubAdapter {
  _FailingMessagesAdapter({required this.status});

  final int status;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path.endsWith('/messages')) {
      requested.add(options.uri);
      return ResponseBody.fromString(
        jsonEncode({'error': 'session_not_found'}),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return super.fetch(options, requestStream, cancelFuture);
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

  test('continued chats request the latest transcript page', () async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
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
        'session_id': 'runtime-existing',
        'stored_session_id': 'stored-existing',
        'running': false,
      },
      'config.get' => {'value': 'medium'},
      _ => const {},
    };

    final response = await service.streamDesktopResponse(
      HermesChatInput.text('second message'),
      sessionId: 'stored-existing',
      options: const HermesDesktopSessionOptions(),
    );
    harness.event('runtime-existing', 'message.start');
    harness.sessionInfo('runtime-existing', running: false);
    await response.events.toList();

    final historyRequest = adapter.requested.singleWhere(
      (uri) => uri.path.endsWith('/messages'),
    );
    check(historyRequest.queryParameters['order']).equals('latest');
  });

  test(
    'a session the gateway refuses to resume still loads over REST',
    () async {
      SharedPreferences.setMockInitialValues({});
      PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
      final harness = _GatewayHarness();
      final adapter = _StubAdapter(
        messages: const [
          {'role': 'user', 'content': 'hello from telegram'},
          {'role': 'assistant', 'content': 'hi'},
        ],
      );
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
        dio: _statusDio(adapter),
        rpc: rpc,
      );
      addTearDown(() async {
        service.close();
        await harness.dispose();
      });
      final turnStates = <HermesDesktopTurnState>[];
      final subscription = service.turnStates.listen(turnStates.add);
      addTearDown(subscription.cancel);

      harness.errorResponder = (method) => switch (method) {
        'session.resume' => {
          'code': 4130,
          'message': 'Session too large to resume',
        },
        _ => null,
      };

      final messages = await service.getSessionMessages('telegram:123');
      await Future<void>.delayed(Duration.zero);

      check(messages).length.equals(2);
      check(messages.last['content']).equals('hi');
      final historyRequest = adapter.requested.singleWhere(
        (uri) => uri.path.endsWith('/messages'),
      );
      check(historyRequest.path)
          .endsWith('/api/sessions/telegram%3A123/messages');
      check(historyRequest.queryParameters['order']).equals('oldest');
      check(historyRequest.queryParameters['limit']).equals('200');
      check(turnStates.last).equals(HermesDesktopTurnState.idle);
    },
  );

  test('a REST failure after a refused resume is not swallowed', () async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    final harness = _GatewayHarness();
    final adapter = _FailingMessagesAdapter(status: 404);
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
      dio: _statusDio(adapter),
      rpc: rpc,
    );
    addTearDown(() async {
      service.close();
      await harness.dispose();
    });

    harness.errorResponder = (method) => switch (method) {
      'session.resume' => {'code': 4007, 'message': 'Session not found'},
      _ => null,
    };

    Object? failure;
    try {
      await service.getSessionMessages('stored-missing');
    } catch (error) {
      failure = error;
    }
    check(failure)
        .isA<DioException>()
        .has((error) => error.response?.statusCode, 'status')
        .equals(404);
  });

  test('a new bot chat opens before its first prompt is persisted', () async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
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
      // No existing "Bot Chat" title match.
      'session.resume' => const {},
      'session.create' => {
        'session_id': 'runtime-new-bot',
        'stored_session_id': 'stored-new-bot',
        'info': const {},
      },
      _ => const {},
    };

    final storedId = await service.openBotChat(
      const HermesBot(name: 'researcher', title: 'Research'),
    );
    check(storedId).equals('stored-new-bot');
    check(await service.getSessionMessages(storedId)).isEmpty();

    check(
      harness.sent.where((frame) => frame['method'] == 'session.resume').length,
    ).equals(1);
    check(adapter.requested.where((uri) => uri.path.endsWith('/messages')))
        .isEmpty();
  });

  test(
    'bot chat transcripts use gateway history instead of dashboard REST',
    () async {
      SharedPreferences.setMockInitialValues({});
      PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
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
        'session.history' => {
          'messages': const [
            {'role': 'assistant', 'content': 'Hello from Research'},
          ],
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
      final messages = await service.getSessionMessages('stored-bot');

      check(messages.single['content']).equals('Hello from Research');
      check(adapter.requested.where((uri) => uri.path.endsWith('/messages')))
          .isEmpty();
      final history = harness.sent.singleWhere(
        (frame) => frame['method'] == 'session.history',
      );
      check((history['params'] as Map)['session_id']).equals('runtime-bot');
      check((history['params'] as Map)['profile']).equals('researcher');
    },
  );

  test(
    'every bot-chat RPC names the bot profile, never the connection one',
    () async {
      SharedPreferences.setMockInitialValues({});
      PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
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
      await service.resolveApprovalChoiceForSession(
        'stored-bot',
        approvalId: 'req-1',
        choice: 'once',
      );
      await service.respondToDecision(
        storedSessionId: 'stored-bot',
        runtimeId: 'runtime-bot',
        requestId: 'srq-2/q0',
        kind: HermesDecisionKind.clarification,
        value: 'answer',
      );
      await service.reloadMcp(runtimeId: 'runtime-bot');
      // A skipped connection target goes straight to connection.respond,
      // which must also name the bot profile.
      await service.respondToDecision(
        storedSessionId: 'stored-bot',
        runtimeId: 'runtime-bot',
        requestId: 'op-3/docs',
        kind: HermesDecisionKind.mcpSetup,
        value: 'deny',
        mcpServer: 'docs',
        mcpAction: 'enable',
      );

      // reload.mcp takes no profile (Hermes refuses one); its session id
      // scopes it to the bot's profile.
      final reload = harness.sent.singleWhere(
        (frame) => frame['method'] == 'reload.mcp',
      );
      check(
        reload['params'] as Map<String, dynamic>,
      ).deepEquals({'confirm': true, 'session_id': 'runtime-bot'});

      // The transport injects the CONNECTION profile as a default, so any bot
      // frame that fails to name its own profile silently travels as 'default'.
      // Answers carry no session id but act on the bot's session too.
      const answers = {'request.answer', 'clarify.lock', 'connection.respond'};
      final botFrames = harness.sent
          .where(
            (frame) =>
                frame['method'] != 'reload.mcp' &&
                ((frame['params'] as Map)['session_id'] != null ||
                    answers.contains(frame['method'])),
          )
          .toList();
      check(
        botFrames.map((frame) => frame['method']).toSet().containsAll(answers),
      ).isTrue();
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

  test('bot sends keep the bot profile model settings', () async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    final harness = _GatewayHarness();
    final rpc = HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => harness.channel,
    );
    final adapter = _StubAdapter();
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
      'session.history' => {'messages': const []},
      _ => const {},
    };

    await service.openBotChat(
      const HermesBot(
        name: 'researcher',
        title: 'Research',
        chatSessionId: 'stored-bot',
      ),
    );
    final response = await service.streamDesktopResponse(
      HermesChatInput.text('hello'),
      sessionId: 'stored-bot',
      options: const HermesDesktopSessionOptions(
        model: 'other-model',
        provider: 'other-provider',
        reasoningEffort: 'high',
        fast: true,
      ),
    );
    harness.event('runtime-bot', 'message.start');
    harness.sessionInfo('runtime-bot', running: false);
    await response.events.toList();

    check(
      harness.sent
          .map((frame) => frame['method'])
          .where((method) => method == 'config.get' || method == 'config.set'),
    ).isEmpty();
    final submit = harness.sent.singleWhere(
      (frame) => frame['method'] == 'prompt.submit',
    );
    final params = submit['params'] as Map;
    check(params['profile']).equals('researcher');
    for (final key in ['model', 'provider', 'reasoningEffort', 'fast']) {
      check(params.containsKey(key)).isFalse();
    }
    check(adapter.requested.where((uri) => uri.path.endsWith('/messages')))
        .isEmpty();
  });
  // the gateway reports `session.info` asynchronously after a session is
  // created or resumed. An idle one that lands while `prompt.submit` is in
  // flight was replayed after the acknowledgement and ended the turn before
  // its first delta, leaving an empty reply.
  test('an idle session.info from before the turn does not end it', () async {
    final deltas = await _replyAfterPreTurnFrames(
      (harness) => harness.sessionInfo('runtime-race', running: false),
    );
    check(deltas).equals('Hello there.');
  });

  test(
    'a late tool event does not let an idle session.info end the turn',
    () async {
      final deltas = await _replyAfterPreTurnFrames((harness) {
        harness.event('runtime-race', 'tool.complete', {'name': 'earlier'});
        harness.sessionInfo('runtime-race', running: false);
      });
      check(deltas).equals('Hello there.');
    },
  );

  test('a re-sent reply segment is shown once', () async {
    final turn = await _streamTurn((harness) {
      harness.event('runtime-race', 'message.start', {'turn_id': 't1'});
      for (final (offset, text) in [
        (0, 'Hello '),
        (6, 'there.'),
        // A replay re-sends the segment from its start.
        (0, 'Hello there.'),
      ]) {
        harness.event('runtime-race', 'message.delta', {
          'text': text,
          'turn_id': 't1',
          'segment': 0,
          'offset': offset,
        });
      }
      harness.event('runtime-race', 'message.complete', {
        'text': 'Hello there.',
      });
      harness.sessionInfo('runtime-race', running: false);
    });
    check(
      turn.events.whereType<HermesTokenDelta>().map((e) => e.content).join(),
    ).equals('Hello there.');
  });

  test('a forwarded prompt ends at message.complete', () async {
    final turn = await _streamTurn(
      submitResult: {
        'status': 'queued',
        'forwarded': true,
        'admission_id': 'adm-1',
      },
      (harness) {
        harness.event('runtime-race', 'message.start');
        harness.event('runtime-race', 'message.complete', {
          'text': 'Answered by the owner.',
        });
      },
    );
    check(
      turn.events.whereType<HermesFinalOutput>().single.text,
    ).equals('Answered by the owner.');
    check(turn.events.last).isA<HermesRunDone>();
    check(turn.events.whereType<HermesRunError>()).isEmpty();
  });

  group('session delete', () {
    const path = '/api/sessions/stored-1';

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    });

    test('names the revision its snapshot reports', () async {
      final adapter = _RoutesAdapter({
        'GET $path/mutation-snapshot': (
          200,
          {
            'session_id': 'stored-1',
            'exists': true,
            'runtime_revision': 2,
            'runtime_generation': 1,
          },
        ),
        'DELETE $path': (200, {'ok': true}),
      });
      await _restService(adapter).deleteSession('stored-1');

      final delete = Uri.parse(
        'https://hermes.example/${adapter.requests.last.split(' ').last}',
      );
      check(adapter.requests.last).startsWith('DELETE $path?');
      check(delete.queryParameters['expected_revision']).equals('2');
      check(delete.queryParameters['expected_generation']).equals('1');
      check(delete.queryParameters['request_id']).isNotNull().isNotEmpty();
      check(delete.queryParameters['profile']).isNotNull();
    });

    test('takes the plain delete on a dashboard without snapshots', () async {
      final adapter = _RoutesAdapter({'DELETE $path': (200, {'ok': true})});
      await _restService(adapter).deleteSession('stored-1');

      check(adapter.requests.last).startsWith('DELETE $path?');
      check(adapter.requests.last).not((it) => it.contains('request_id'));
    });

    test('skips a session that is already gone', () async {
      final adapter = _RoutesAdapter({
        'GET $path/mutation-snapshot': (
          200,
          {'session_id': 'stored-1', 'exists': false, 'runtime_revision': 0},
        ),
      });
      await _restService(adapter).deleteSession('stored-1');

      check(adapter.requests.where((r) => r.startsWith('DELETE'))).isEmpty();
    });
  });

  test('a profile without a session store lists no sessions', () async {
    final missing = _RoutesAdapter({
      'GET /api/sessions': (
        503,
        {
          'detail':
              "Session store is not initialized. Start this profile's "
              'gateway to initialize it.',
        },
      ),
    });
    check(await _restService(missing).listSessions()).isEmpty();

    final broken = _RoutesAdapter({
      'GET /api/sessions': (503, {'detail': 'storage_unavailable'}),
    });
    await check(_restService(broken).listSessions()).throws<Exception>();
  });

  test('a token-gated dashboard gets the session token as a bearer', () async {
    final adapter = _RoutesAdapter({
      'GET /api/status': (
        200,
        {
          'auth_required': true,
          'auth_providers': ['session-token'],
          'auth_flows': ['cookie'],
        },
      ),
      'GET /api/sessions': (200, {'sessions': <Object?>[]}),
    });
    check(await _restService(adapter).listSessions()).isEmpty();
    check(
      adapter.headers['GET /api/sessions']?['Authorization'],
    ).equals('Bearer session-token');
  });

  test('a partial session.info does not block the next send', () async {
    final turn = await _streamTurn((harness) {
      harness.event('runtime-race', 'message.start');
      // An owner relay's info: pending submissions, no `running`.
      harness.event('runtime-race', 'session.info', {
        'stored_session_id': 'stored-race',
        'pending_submissions': <Object?>[],
      });
      harness.event('runtime-race', 'message.delta', {'text': 'Done.'});
      harness.event('runtime-race', 'message.complete', {'text': 'Done.'});
      harness.sessionInfo('runtime-race', running: false);
    });
    check(turn.events.whereType<HermesRunError>()).isEmpty();
    check(
      turn.service.turnStateFor('stored-race'),
    ).equals(HermesDesktopTurnState.idle);
  });

  group('decisions in a restored chat', () {
    test('the next question skips ones answered elsewhere', () async {
      final chat = await _restoredChat({
        'open_requests': [
          {
            'id': 'srq-c1',
            'method': 'clarify',
            'params': {
              'session_id': 'runtime-1',
              'questions': [
                for (final qid in ['q0', 'q1', 'q2'])
                  {'qid': qid, 'question': 'Pick $qid?'},
              ],
            },
          },
        ],
      }, lock: {'status': 'ok', 'remaining': ['q2']});

      await chat.service.respondToDecision(
        storedSessionId: 'stored-1',
        runtimeId: 'runtime-1',
        requestId: 'srq-c1/q0',
        kind: HermesDecisionKind.clarification,
        value: 'Teal',
      );
      await pumpEventQueue();

      check(
        chat.events
            .where((event) => event.type == 'clarify.request')
            .map((event) => event.payload['request_id']),
      ).deepEquals(['srq-c1/q0', 'srq-c1/q2']);
    });

    test('approving a started sign-in opens its link', () async {
      const link = 'https://auth.example/authorize?state=abc';
      final chat = await _restoredChat({
        'pending_connection': {
          'op_id': 'op-1',
          'owner': {'type': 'session', 'session_id': 'runtime-1'},
          'targets': [
            {
              'name': 'docs',
              'kind': 'mcp',
              'action': 'authorize',
              'state': 'initiated',
              'resolved': false,
              'connect_url': link,
            },
          ],
        },
      });
      check(
        (await chat.service.pendingDecisionsForSession(
          'stored-1',
        )).map((decision) => decision.requestId),
      ).deepEquals(['op-1/docs']);

      await chat.service.respondToDecision(
        storedSessionId: 'stored-1',
        runtimeId: 'runtime-1',
        requestId: 'op-1/docs',
        kind: HermesDecisionKind.mcpSetup,
        value: 'approve',
      );

      check(chat.opened).deepEquals([Uri.parse(link)]);
      check(
        chat.harness.sent.where(
          (frame) => frame['method'] == 'connection.respond',
        ),
      ).isEmpty();
    });

    // The approval was used up before the link opened, so a device that
    // refused the link left the target with no way to try again.
    test('an approved link the device refuses is offered again', () async {
      final chat = await _restoredChat(const {}, opens: false);
      Map<String, Object?> docs(String state, {String? url}) => {
        'name': 'docs',
        'kind': 'mcp',
        'action': 'install',
        'state': state,
        'connect_url': ?url,
      };
      chat.harness.event('runtime-1', 'connection.request', {
        'op_id': 'op-5',
        'targets': [docs('pending')],
      });
      await pumpEventQueue();
      await chat.service.respondToDecision(
        storedSessionId: 'stored-1',
        runtimeId: 'runtime-1',
        requestId: 'op-5/docs',
        kind: HermesDecisionKind.mcpSetup,
        value: 'approve',
      );
      chat.harness.event('runtime-1', 'connection.update', {
        'op_id': 'op-5',
        'targets': [docs('initiated', url: 'https://auth.example/docs')],
      });
      await pumpEventQueue();

      check(chat.opened).deepEquals([Uri.parse('https://auth.example/docs')]);
      check(
        chat.events
            .where((event) => event.type == 'mcp.setup.request')
            .map((event) => event.payload['request_id']),
      ).deepEquals(['op-5/docs', 'op-5/docs']);
    });

    // Reading a restored chat resumes it, which replays its open requests;
    // each replay re-saved the request and asked for another read.
    test(
      'a replayed request that changed nothing reads the chat once',
      () async {
        final chat = await _restoredChat({
          'open_requests': [
            {
              'id': 'srq-s7',
              'method': 'sudo',
              'params': {'session_id': 'runtime-1', 'command': 'apt update'},
            },
          ],
        });
        final changes = <String>[];
        final sub = chat.service.transcriptChanges.listen(changes.add);
        addTearDown(sub.cancel);

        await chat.service.getSessionMessages('stored-1');
        await pumpEventQueue();
        await chat.service.getSessionMessages('stored-1');
        await pumpEventQueue();

        check(changes).isEmpty();
      },
    );

    test('the next target re-reads the chat once it is saved', () async {
      final chat = await _restoredChat(const {});
      Map<String, Object?> target(String name, String state) => {
        'name': name,
        'kind': 'mcp',
        'action': 'enable',
        'state': state,
      };
      chat.harness.event('runtime-1', 'connection.request', {
        'op_id': 'op-2',
        'targets': [target('docs', 'pending'), target('notes', 'pending')],
      });
      await pumpEventQueue();
      final reads = <Future<List<String>>>[];
      final changes = chat.service.transcriptChanges.listen((storedId) {
        reads.add(
          chat.service
              .pendingDecisionsForSession(storedId)
              .then((all) => [for (final d in all) d.requestId]),
        );
      });
      addTearDown(changes.cancel);

      // The first card's buffered event keeps the queue non-empty.
      chat.harness.event('runtime-1', 'connection.update', {
        'op_id': 'op-2',
        'targets': [target('docs', 'connected'), target('notes', 'pending')],
      });
      await pumpEventQueue();

      check(reads).isNotEmpty();
      check(await reads.last).deepEquals(['op-2/notes']);
    });
  });
}

/// A Desktop chat restored with no turn running: `session.resume` returns
/// [snapshot]'s extras, `clarify.lock` returns [lock]. Collects the RPC
/// events and the links opened.
Future<
  ({
    HermesDesktopApiService service,
    _GatewayHarness harness,
    List<HermesDesktopEvent> events,
    List<Uri> opened,
  })
>
_restoredChat(
  Map<String, Object?> snapshot, {
  Map<String, Object?> lock = const {'status': 'ok', 'remaining': <String>[]},
  bool opens = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  final harness = _GatewayHarness();
  final rpc = HermesDesktopRpcClient(
    channelFactory: (_, _, {httpClient}) => harness.channel,
  );
  final events = <HermesDesktopEvent>[];
  rpc.events.listen(events.add);
  final opener = _RecordingUrlOpener(opens: opens);
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
    openExternalUrl: opener,
  );
  addTearDown(() async {
    service.close();
    await harness.dispose();
  });
  harness.responder = (method) => switch (method) {
    'session.resume' => {
      'session_id': 'runtime-1',
      'stored_session_id': 'stored-1',
      'running': false,
      ...snapshot,
    },
    'clarify.lock' => lock,
    _ => const {},
  };
  await service.pendingDecisionsForSession('stored-1');
  await pumpEventQueue();
  return (
    service: service,
    harness: harness,
    events: events,
    opened: opener.opened,
  );
}

final class _RecordingUrlOpener implements OpenExternalUrlPort {
  _RecordingUrlOpener({this.opens = true});

  /// What [open] answers: false is a device that refuses the link.
  final bool opens;
  final opened = <Uri>[];

  @override
  Future<bool> open(Uri url) async {
    opened.add(url);
    return opens;
  }
}

/// Streams one turn on a resumed session: Hermes acknowledges
/// `prompt.submit` with [submitResult], then [frames] arrive. Returns the
/// events that reached the caller, and the service.
Future<({List<HermesRunEvent> events, HermesDesktopApiService service})>
_streamTurn(
  void Function(_GatewayHarness harness) frames, {
  Map<String, dynamic> submitResult = const {'status': 'streaming'},
}) async {
  SharedPreferences.setMockInitialValues({});
  PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
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
    'prompt.submit' => submitResult,
    'session.resume' => {
      'session_id': 'runtime-race',
      'stored_session_id': 'stored-race',
      'running': false,
    },
    'config.get' => {'value': 'medium'},
    _ => const {},
  };

  final response = await service.streamDesktopResponse(
    HermesChatInput.text('hello'),
    sessionId: 'stored-race',
    options: const HermesDesktopSessionOptions(),
  );
  final events = response.events.toList();
  await Future<void>.delayed(Duration.zero);
  frames(harness);
  return (
    events: await events.timeout(const Duration(seconds: 5)),
    service: service,
  );
}

/// Streams a reply while [preTurnFrames] arrive before `prompt.submit` is
/// acknowledged, and returns the text that reached the caller.
Future<String> _replyAfterPreTurnFrames(
  void Function(_GatewayHarness harness) preTurnFrames,
) async {
  SharedPreferences.setMockInitialValues({});
  PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
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

  harness.responder = (method) {
    if (method == 'prompt.submit') {
      // Delivered before the acknowledgement, as on the wire.
      preTurnFrames(harness);
      return {'status': 'streaming'};
    }
    return switch (method) {
      'session.resume' => {
        'session_id': 'runtime-race',
        'stored_session_id': 'stored-race',
        'running': false,
      },
      'config.get' => {'value': 'medium'},
      _ => const {},
    };
  };

  final response = await service.streamDesktopResponse(
    HermesChatInput.text('hello'),
    sessionId: 'stored-race',
    options: const HermesDesktopSessionOptions(),
  );
  final events = response.events.toList();
  await Future<void>.delayed(Duration.zero);
  harness.event('runtime-race', 'message.start');
  harness.event('runtime-race', 'message.delta', {'text': 'Hello there.'});
  harness.event('runtime-race', 'message.complete', {'text': 'Hello there.'});
  harness.sessionInfo('runtime-race', running: false);

  final deltas = (await events).whereType<HermesTokenDelta>();
  return deltas.map((event) => event.content).join();
}
