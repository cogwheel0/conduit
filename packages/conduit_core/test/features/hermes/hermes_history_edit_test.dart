import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show hermesDesktopRewindTarget;
import 'package:conduit_core/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_history_edit.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final class _MockWebSocketChannel extends Mock implements WebSocketChannel {}

final class _MockWebSocketSink extends Mock implements WebSocketSink {}

final class _Refusal implements Exception {
  const _Refusal(this.code, this.message);

  final int code;
  final String message;
}

/// A gateway socket: the legacy wire, or a session authority's canonical
/// wire when [authority]. Every request is recorded with its params.
final class _Gateway {
  _Gateway({this.authority = false}) {
    when(() => channel.ready).thenAnswer((_) async {});
    when(() => channel.stream).thenAnswer((_) {
      scheduleMicrotask(
        () => incoming.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'session_authority': authority},
            },
          }),
        ),
      );
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
      final method = frame['method'];
      if (id == null || method is! String) return;
      final params = Map<String, dynamic>.from(
        (frame['params'] as Map?) ?? const {},
      );
      Object? result;
      try {
        result = (handler?.call(method, params)) ?? _answer(method, params);
      } on _Refusal catch (refusal) {
        scheduleMicrotask(
          () => incoming.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'error': {'code': refusal.code, 'message': refusal.message},
            }),
          ),
        );
        return;
      }
      scheduleMicrotask(
        () => incoming.add(
          jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
        ),
      );
    });
  }

  final bool authority;
  final channel = _MockWebSocketChannel();
  final sink = _MockWebSocketSink();
  final incoming = StreamController<dynamic>.broadcast();
  final sent = <Map<String, dynamic>>[];

  /// Answers a request in place of the defaults; null falls back to them.
  Object? Function(String method, Map<String, dynamic> params)? handler;

  Object? _answer(String method, Map<String, dynamic> params) {
    switch (method) {
      case 'session.resume':
        return {
          'session_id': 'rt-1',
          'stored_session_id': 'stored-1',
          'running': false,
          if (authority) ...{
            'revision': 5,
            'execution_generation': 2,
            'subscription_id': 'sub-1',
            'info': {'desktop_protocol': kHermesCanonicalGatewayProtocol},
          },
        };
      case 'prompt.submit':
        return authority ? {'admission_id': 'adm-1'} : {'status': 'streaming'};
      case 'session.mutate':
        return {'revision': 6, 'rewound_count': 2};
      case 'config.get':
        return {'value': 'medium'};
    }
    return const <String, Object?>{};
  }

  /// Ends the turn on [session] as Hermes does.
  void finishTurn() {
    for (final (type, payload) in [
      ('message.start', <String, Object?>{}),
      ('message.complete', {'text': 'Synthetic reply.'}),
      ('session.info', {'running': false}),
    ]) {
      incoming.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': type,
            'session_id': 'rt-1',
            'payload': payload,
            if (authority) 'admission_id': 'adm-1',
          },
        }),
      );
    }
  }

  List<Map<String, dynamic>> calls(String method) => [
    for (final frame in sent)
      if (frame['method'] == method)
        Map<String, dynamic>.from(frame['params'] as Map),
  ];

  List<String> get methods => [
    for (final frame in sent)
      if (frame['id'] != null) frame['method'] as String,
  ];
}

/// Serves `/api/status` and the stored session's transcript.
final class _Rest implements HttpClientAdapter {
  _Rest(this.transcript);

  List<Map<String, Object?>> transcript;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    final Object body;
    if (path == '/api/status') {
      body = {'auth_required': false, 'gateway_running': true};
    } else if (path == '/api/sessions/stored-1/messages') {
      final offset = int.parse(options.uri.queryParameters['offset'] ?? '0');
      body = {'messages': transcript.skip(offset).toList()};
    } else {
      body = <String, Object?>{};
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

HermesDesktopApiService _service(_Gateway gateway, _Rest rest) {
  final service = HermesDesktopApiService(
    config: HermesConfig(
      enabled: true,
      baseUrl: 'https://hermes.example',
      mode: HermesBackendMode.desktopGateway,
      desktopAuthKind: HermesDesktopAuthKind.legacyToken,
      desktopCredentials: HermesDesktopCredentials(
        legacyToken: 'session-token',
      ),
    ),
    dio: Dio()..httpClientAdapter = rest,
    rpc: HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => gateway.channel,
    ),
    gatewayStartRetryDelays: const [Duration.zero],
  );
  addTearDown(() async {
    service.close();
    await gateway.incoming.close();
  });
  return service;
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

ChatMessage _message(String id, String role, String content) => ChatMessage(
  id: id,
  role: role,
  content: content,
  timestamp: DateTime(2026, 11, 7),
);

const List<Map<String, Object?>> _transcript = [
  {'id': 11, 'role': 'user', 'content': 'Plan a synthetic picnic'},
  {
    'id': 12,
    'role': 'assistant',
    'content': '',
    'tool_calls': [
      {
        'id': 'call-1',
        'function': {'name': 'web_search', 'arguments': '{}'},
      },
    ],
  },
  {'id': 13, 'role': 'tool', 'tool_call_id': 'call-1', 'content': 'ok'},
  {'id': 14, 'role': 'assistant', 'content': 'Bring sandwiches.'},
  {'id': 15, 'role': 'user', 'content': 'And drinks?'},
  {'id': 16, 'role': 'assistant', 'content': 'Lemonade.'},
];

/// The chat as Conduit shows [_transcript]: one assistant message per turn.
final _chat = [
  _message('u1', 'user', 'Plan a synthetic picnic'),
  _message('a1', 'assistant', 'Bring sandwiches.'),
  _message('u2', 'user', 'And drinks?'),
  _message('a2', 'assistant', 'Lemonade.'),
];

void main() {
  setUp(() => PreferencesStore.debugOverride(InMemoryKeyValueStore()));
  tearDown(PreferencesStore.debugReset);

  group('a chat message in its transcript', () {
    final transcript = [
      for (final row in _transcript) Map<String, dynamic>.from(row),
    ];

    test('is found by its place among the user messages', () {
      final row = hermesTranscriptUserRowIndex(
        transcript: transcript,
        messages: _chat,
        index: 2,
      );
      check(row).equals(4);
      check(hermesTranscriptRowId(transcript[row!])).equals(15);
    });

    test('an edited message is found by the text it replaced', () {
      final edited = [..._chat.take(2), _message('u2', 'user', 'Snacks?')];
      check(
        hermesTranscriptUserRowIndex(
          transcript: transcript,
          messages: edited,
          index: 2,
        ),
      ).isNull();
      check(
        hermesTranscriptUserRowIndex(
          transcript: transcript,
          messages: edited,
          index: 2,
          text: 'And drinks?',
        ),
      ).equals(4);
    });

    test('a message the transcript does not hold finds nothing', () {
      final unsent = [..._chat, _message('u3', 'user', 'Never stored')];
      check(
        hermesTranscriptUserRowIndex(
          transcript: transcript,
          messages: unsent,
          index: 4,
        ),
      ).isNull();
    });

    test('of several equal prompts only the newest is certain', () {
      final repeated = [
        {'id': 1, 'role': 'user', 'content': 'Again'},
        {'id': 2, 'role': 'assistant', 'content': 'One'},
        {'id': 3, 'role': 'user', 'content': 'Again'},
        {'id': 4, 'role': 'assistant', 'content': 'Two'},
      ];
      // Two prompts on screen never reached the session: places no longer
      // line up, and the text matches twice.
      final drifted = [
        _message('a', 'user', 'Unsent one'),
        _message('b', 'user', 'Unsent two'),
        _message('c', 'user', 'Again'),
      ];
      check(
        hermesTranscriptUserRowIndex(
          transcript: repeated,
          messages: drifted,
          index: 2,
        ),
      ).equals(2);
      check(
        hermesTranscriptUserRowIndex(
          transcript: repeated,
          messages: [...drifted, _message('d', 'user', 'Later')],
          index: 2,
        ),
      ).isNull();
    });
  });

  test('a cutting submit confirms the cut', () {
    check(
      hermesPromptSubmitParams(
        runtimeId: 'rt-1',
        text: 'Edited',
        truncateBeforeRowId: 15,
      ),
    ).deepEquals({
      'session_id': 'rt-1',
      'text': 'Edited',
      'truncate_before_row_id': 15,
      'confirm_truncate': true,
      'confirm_empty_truncate': true,
      'confirm_deep_truncate': true,
    });
    check(
      hermesPromptSubmitParams(runtimeId: 'rt-1', text: 'Plain').keys,
    ).deepEquals(['session_id', 'text']);
  });

  group('an edit sent into its Desktop session', () {
    Future<List<HermesRunEvent>> send(
      HermesDesktopApiService service,
      _Gateway gateway,
    ) async {
      final response = await service.streamDesktopResponse(
        HermesChatInput.text('And snacks?'),
        sessionId: 'stored-1',
        options: const HermesDesktopSessionOptions(),
        truncateBeforeRowId: 15,
      );
      final events = response.events.toList();
      await _settle();
      gateway.finishTurn();
      return events.timeout(const Duration(seconds: 5));
    }

    test('cuts the transcript with the submit on the legacy wire', () async {
      final gateway = _Gateway();
      final service = _service(gateway, _Rest(_transcript));

      final events = await send(service, gateway);

      check(events.whereType<HermesRunError>()).isEmpty();
      final submit = gateway.calls('prompt.submit').single;
      check(submit['truncate_before_row_id']).equals(15);
      check(submit['confirm_truncate']).equals(true);
      check(submit['confirm_deep_truncate']).equals(true);
      check(gateway.calls('session.mutate')).isEmpty();
    });

    test('a gateway before v0.23 gets the cut without the deep '
        'confirmation it does not know', () async {
      final gateway = _Gateway();
      var submits = 0;
      gateway.handler = (method, params) {
        if (method == 'prompt.submit' && submits++ == 0) {
          throw const _Refusal(
            4000,
            'invalid params for prompt.submit: confirm_deep_truncate: '
            'extra inputs are not permitted',
          );
        }
        return null;
      };
      final service = _service(gateway, _Rest(_transcript));

      final events = await send(service, gateway);

      check(events.whereType<HermesRunError>()).isEmpty();
      final sent = gateway.calls('prompt.submit');
      check(sent).length.equals(2);
      check(sent.last['truncate_before_row_id']).equals(15);
      check(sent.last.containsKey('confirm_deep_truncate')).isFalse();
    });

    test('rewinds as a session edit before the prompt on the canonical '
        'wire', () async {
      final gateway = _Gateway(authority: true);
      final service = _service(gateway, _Rest(_transcript));

      final events = await send(service, gateway);

      check(events.whereType<HermesRunError>()).isEmpty();
      final rewind = gateway.calls('session.mutate').single;
      check(rewind['operation']).equals('rewind');
      check(rewind['payload'] as Map).deepEquals({'target_message_id': 15});
      check(rewind['expected_revision']).equals(5);
      check(rewind['expected_generation']).equals(2);
      final methods = gateway.methods;
      check(
        methods.indexOf('session.mutate'),
      ).isLessThan(methods.indexOf('prompt.submit'));
      final submit = gateway.calls('prompt.submit').single;
      check(submit.containsKey('truncate_before_row_id')).isFalse();
    });

    test('a refused rewind sends no prompt', () async {
      final gateway = _Gateway(authority: true);
      gateway.handler = (method, params) {
        if (method == 'session.mutate') {
          throw const _Refusal(4009, 'session busy');
        }
        return null;
      };
      final service = _service(gateway, _Rest(_transcript));

      final response = await service.streamDesktopResponse(
        HermesChatInput.text('And snacks?'),
        sessionId: 'stored-1',
        options: const HermesDesktopSessionOptions(),
        truncateBeforeRowId: 15,
      );
      final events = await response.events.toList().timeout(
        const Duration(seconds: 5),
      );

      check(events.whereType<HermesRunError>()).isNotEmpty();
      check(gateway.calls('prompt.submit')).isEmpty();
    });
  });

  group('where a Desktop edit cuts', () {
    final conversation = markNativeHermesConversation(
      Conversation(
        id: 'local:hermes_stored-1',
        title: 'Synthetic picnic',
        createdAt: DateTime(2026, 11, 7),
        updatedAt: DateTime(2026, 11, 7),
        metadata: const {'backend': 'hermes', 'hermesSessionId': 'stored-1'},
      ),
    );

    test('is the row the session stores for the replayed prompt', () async {
      final gateway = _Gateway();
      final service = _service(gateway, _Rest(_transcript));
      final edited = [..._chat.take(2), _message('u2', 'user', 'Snacks?')];

      final target = await hermesDesktopRewindTarget(
        service: service,
        conversation: conversation,
        messages: edited,
        replayedUserIndex: 2,
        originalText: 'And drinks?',
      );

      check(target).isNotNull()
        ..has((t) => t.sessionId, 'sessionId').equals('stored-1')
        ..has((t) => t.rowId, 'rowId').equals(15);
    });

    test('a turn that never reached the session is only sent again', () async {
      final service = _service(_Gateway(), _Rest(_transcript));
      final retried = [..._chat, _message('u3', 'user', 'Lost on the way')];

      final target = await hermesDesktopRewindTarget(
        service: service,
        conversation: conversation,
        messages: retried,
        replayedUserIndex: 4,
      );

      check(target).isNotNull().has((t) => t.rowId, 'rowId').isNull();
    });

    test('a stored turn that cannot be told apart is not sent uncut', () async {
      final service = _service(_Gateway(), _Rest(_transcript));
      final drifted = [
        ..._chat.take(2),
        _message('u2', 'user', 'Something else entirely'),
      ];

      await check(
        hermesDesktopRewindTarget(
          service: service,
          conversation: conversation,
          messages: drifted,
          replayedUserIndex: 2,
        ),
      ).throws<StateError>();
    });

    test('the API server replays its history instead', () async {
      check(
        await hermesDesktopRewindTarget(
          service: null,
          conversation: conversation,
          messages: _chat,
          replayedUserIndex: 2,
        ),
      ).isNull();
    });
  });
}
