import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show
        ChatMessagesNotifier,
        chatMessagesProvider,
        forgetReplacedHermesStoredContent,
        hermesDesktopRewindTarget,
        hermesRewindCandidateTexts,
        kHermesStoredUserContentKey;
import 'package:conduit_core/features/chat/services/chat_message_actions.dart'
    show undoLastHermesTurn;
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_copied_history_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_history_edit.dart';
import 'package:conduit_core/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final class _MockWebSocketChannel extends Mock implements WebSocketChannel {}

final class _MockWebSocketSink extends Mock implements WebSocketSink {}

final class _Refusal implements Exception {
  const _Refusal(this.code, this.message, [this.data]);

  final int code;
  final String message;
  final Map<String, Object?>? data;
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
              'error': {
                'code': refusal.code,
                'message': refusal.message,
                'data': ?refusal.data,
              },
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

  /// The stored transcript an undo shortens, as Hermes does.
  _Rest? rest;

  Object? _answer(String method, Map<String, dynamic> params) {
    switch (method) {
      case 'session.resume':
        final stored = params['session_id'] ?? 'stored-1';
        return {
          'session_id': stored == 'stored-1' ? 'rt-1' : 'rt-$stored',
          'stored_session_id': stored,
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
        return {
          'revision': 6,
          'rewound_count': 2,
          if (params['operation'] == 'branch')
            'branched_session_id': 'stored-2',
        };
      case 'session.branch':
        return {
          'session_id': 'rt-2',
          'stored_session_id': 'stored-2',
          'title': 'Synthetic picnic (branch)',
        };
      case 'session.undo':
        final stored = rest;
        final last =
            stored?.transcript.lastIndexWhere((row) => row['role'] == 'user') ??
            -1;
        if (stored == null || last < 0) return {'removed': 2};
        final removed = stored.transcript.length - last;
        stored.transcript = stored.transcript.take(last).toList();
        return {'removed': removed};
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

/// Serves `/api/status` and the stored session's transcript ([others] for
/// other sessions).
final class _Rest implements HttpClientAdapter {
  _Rest(this.transcript);

  List<Map<String, Object?>> transcript;
  final others = <String, List<Map<String, Object?>>>{};

  /// When set, the next transcript read waits for it.
  Completer<void>? hold;

  /// Called with each request's path before it is answered.
  void Function(String path)? onRequest;

  /// Each request as `METHOD /path`, in order.
  final requests = <String>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    requests.add('${options.method} $path');
    onRequest?.call(path);
    final other = RegExp(r'^/api/sessions/([^/]+)/messages$').firstMatch(path);
    final Object body;
    if (path == '/api/status') {
      body = {'auth_required': false, 'gateway_running': true};
    } else if (path == '/api/sessions/stored-1/messages') {
      final held = hold;
      hold = null;
      await held?.future;
      final offset = int.parse(options.uri.queryParameters['offset'] ?? '0');
      body = {'messages': transcript.skip(offset).toList()};
    } else if (other != null && others.containsKey(other.group(1))) {
      final offset = int.parse(options.uri.queryParameters['offset'] ?? '0');
      body = {'messages': others[other.group(1)]!.skip(offset).toList()};
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
  gateway.rest = rest;
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

class _SeededConversation extends ActiveConversationNotifier {
  _SeededConversation(this.initial);

  final Conversation initial;

  @override
  Conversation? build() => initial;
}

class _SeededMessages extends ChatMessagesNotifier {
  _SeededMessages(this.initial);

  final List<ChatMessage> initial;

  @override
  List<ChatMessage> build() => initial;

  @override
  void setMessages(List<ChatMessage> messages) {
    state = List<ChatMessage>.from(messages);
  }
}

/// An API server holding [_transcript] that records the sessions it makes.
class _RestTranscript extends HermesApiService {
  _RestTranscript([this.rows = _transcript])
    : super(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          apiKey: 'synthetic-key',
        ),
      );

  final created = <String?>[];
  final deleted = <String>[];
  int forks = 0;

  /// Runs once the new session is made, before it is answered.
  void Function()? onCreated;

  @override
  Future<void> deleteSession(String id, {CancelToken? cancelToken}) async {
    deleted.add(id);
  }

  @override
  Future<List<Map<String, dynamic>>> getSessionMessages(
    String id, {
    CancelToken? cancelToken,
  }) async => [for (final row in rows) Map<String, dynamic>.from(row)];

  final List<Map<String, Object?>> rows;

  @override
  Future<String> createSession({
    String? title,
    CancelToken? cancelToken,
  }) async {
    created.add(title);
    onCreated?.call();
    return 'api_copy';
  }

  @override
  Future<String> forkSession(String id) async {
    forks++;
    return 'api_fork';
  }

  @override
  Future<List<Map<String, dynamic>>> listSessions({
    bool excludeScheduledRuns = false,
  }) async => const [];
}

final _picnic = markNativeHermesConversation(
  Conversation(
    id: 'local:hermes_stored-1',
    title: 'Synthetic picnic',
    createdAt: DateTime(2026, 11, 7),
    updatedAt: DateTime(2026, 11, 7),
    metadata: const {'backend': 'hermes', 'hermesSessionId': 'stored-1'},
  ),
);

/// Switches the connection a container's providers read.
final class _Connection extends Notifier<HermesBackendService?> {
  _Connection(this.initial);

  final HermesBackendService initial;

  @override
  HermesBackendService? build() => initial;

  void use(HermesBackendService service) => state = service;
}

ProviderContainer _chatContainer(
  HermesBackendService service,
  List<ChatMessage> messages, {
  NotifierProvider<_Connection, HermesBackendService?>? connection,
  HermesCopiedHistoryStore? copiedHistory,
}) {
  final container = ProviderContainer(
    overrides: [
      if (copiedHistory != null)
        hermesCopiedHistoryStoreProvider.overrideWithValue(copiedHistory),
      if (connection == null)
        hermesApiServiceProvider.overrideWithValue(service)
      else
        hermesApiServiceProvider.overrideWith(
          (ref) => ref.watch(connection),
        ),
      activeConversationProvider.overrideWith(
        () => _SeededConversation(_picnic),
      ),
      chatMessagesProvider.overrideWith(() => _SeededMessages(messages)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() => PreferencesStore.debugOverride(InMemoryKeyValueStore()));
  tearDown(PreferencesStore.debugReset);

  group('after an edit', () {
    List<ChatMessage> edited() => [
      ..._chat.take(2),
      _message('u2', 'user', 'Snacks?').copyWith(
        metadata: const {kHermesStoredUserContentKey: 'And drinks?'},
      ),
      _chat[3],
    ];
    Object? storedText(ProviderContainer container) => container
        .read(chatMessagesProvider)
        .firstWhere((message) => message.id == 'u2')
        .metadata?[kHermesStoredUserContentKey];

    // Left in place, the text before the edit could later name a turn
    // another app sent with it, and an edit would cut that one instead.
    test('the text before it is dropped once the session stores the new one',
        () async {
      final stored = [
        for (final row in _transcript)
          row['id'] == 15 ? {...row, 'content': 'Snacks?'} : row,
      ];
      final container = _chatContainer(
        _service(_Gateway(), _Rest(stored)),
        edited(),
      );

      await forgetReplacedHermesStoredContent(container, messageId: 'u2');

      check(storedText(container)).isNull();
    });

    test('the text before it stays while the session still stores it',
        () async {
      final container = _chatContainer(
        _service(_Gateway(), _Rest(_transcript)),
        edited(),
      );

      await forgetReplacedHermesStoredContent(container, messageId: 'u2');

      check(storedText(container)).equals('And drinks?');
    });

    // The edit's replacement failed before its cut, and another app sent
    // the edited text as a later turn: that turn matched out of place, the
    // text before the edit was dropped, and the next regenerate cut the
    // other app's turn instead.
    test('the text before it stays when only a later turn has the new one',
        () async {
      final container = _chatContainer(
        _service(
          _Gateway(),
          _Rest([
            ..._transcript,
            {'id': 17, 'role': 'user', 'content': 'Snacks?'},
            {'id': 18, 'role': 'assistant', 'content': 'Crisps.'},
          ]),
        ),
        edited(),
      );

      await forgetReplacedHermesStoredContent(container, messageId: 'u2');

      check(storedText(container)).equals('And drinks?');
    });
  });

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

    test('a prompt asked again that never reached Hermes finds nothing', () {
      final once = [
        {'id': 1, 'role': 'user', 'content': 'Hi'},
        {'id': 2, 'role': 'assistant', 'content': 'Hello.'},
      ];
      final again = [
        _message('u1', 'user', 'Hi'),
        _message('a1', 'assistant', 'Hello.'),
        _message('u2', 'user', 'Hi'),
      ];
      check(
        hermesTranscriptUserRowIndex(
          transcript: once,
          messages: again,
          index: 2,
        ),
      ).isNull();
      check(
        hermesTranscriptUserRowIndex(
          transcript: once,
          messages: again,
          index: 0,
        ),
      ).equals(0);
    });

    test('out of place, only the exact text matches', () {
      final stored = [
        {'id': 1, 'role': 'user', 'content': 'ok, now rewrite it'},
      ];
      check(
        hermesTranscriptUserRowIndex(
          transcript: stored,
          messages: [
            _message('x', 'user', 'Never sent'),
            _message('y', 'user', 'ok'),
          ],
          index: 1,
        ),
      ).isNull();
    });

    test('out of place, equal prompts match in order', () {
      final repeated = [
        {'id': 1, 'role': 'user', 'content': 'Again'},
        {'id': 2, 'role': 'assistant', 'content': 'One'},
        {'id': 3, 'role': 'user', 'content': 'Again'},
        {'id': 4, 'role': 'assistant', 'content': 'Two'},
      ];
      final drifted = [
        _message('x', 'user', 'Never sent'),
        _message('a', 'user', 'Again'),
        _message('b', 'assistant', 'One'),
        _message('c', 'user', 'Again'),
      ];
      // By place, the first would take the second stored "Again".
      check(
        hermesTranscriptUserRowIndex(
          transcript: repeated,
          messages: drifted,
          index: 1,
        ),
      ).equals(0);
      check(
        hermesTranscriptUserRowIndex(
          transcript: repeated,
          messages: drifted,
          index: 3,
        ),
      ).equals(2);
    });

    test('a stored prompt matches only past its references', () {
      final transcript = [
        {
          'id': 1,
          'role': 'user',
          'content': '[User attached file: /tmp/notes.txt]\nSummarize',
        },
        {'id': 2, 'role': 'assistant', 'content': 'Done.'},
        // Another app's turn that merely contains the text.
        {'id': 3, 'role': 'user', 'content': 'Summarize it in French'},
      ];
      final chat = [
        _message('a', 'user', 'Summarize'),
        _message('b', 'assistant', 'Done.'),
        _message('c', 'user', 'Summarize'),
      ];

      check(
        hermesTranscriptUserRowIndex(
          transcript: transcript,
          messages: chat,
          index: 0,
        ),
      ).equals(0);
      check(
        hermesTranscriptUserRowIndex(
          transcript: transcript,
          messages: chat,
          index: 2,
        ),
      ).isNull();
    });

    test('an image turn is certain only with a text turn after it', () {
      final transcript = [
        {
          'id': 1,
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': 'https://hermes.example/other.png'},
            },
          ],
        },
        {'id': 2, 'role': 'assistant', 'content': 'A photo.'},
      ];
      // The chat's image may never have reached Hermes, and another app's
      // image turn sits at its place: nothing tells them apart.
      check(
        hermesTranscriptUserRowIndex(
          transcript: transcript,
          messages: [_message('u1', 'user', '')],
          index: 0,
        ),
      ).isNull();
      check(
        hermesTranscriptUserRowIndex(
          transcript: [
            ...transcript,
            {'id': 3, 'role': 'user', 'content': 'Thanks'},
          ],
          messages: [
            _message('u1', 'user', ''),
            _message('a1', 'assistant', 'A photo.'),
            _message('u2', 'user', 'Thanks'),
          ],
          index: 0,
        ),
      ).equals(0);
    });

    test('of several equal prompts none is certain when places drift', () {
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
      // Newest in both is no proof: another app may have sent it since.
      check(
        hermesTranscriptUserRowIndex(
          transcript: repeated,
          messages: drifted,
          index: 2,
        ),
      ).isNull();
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

    // Chosen from an earlier read: a turn another app stored since then
    // was cut along with the edited one.
    test('a turn stored after the cut was chosen refuses it', () async {
      final gateway = _Gateway(authority: true);
      final rest = _Rest([
        ..._transcript,
        {'id': 17, 'role': 'user', 'content': 'And games?'},
        {'id': 18, 'role': 'assistant', 'content': 'Frisbee.'},
      ]);
      final service = _service(gateway, rest);

      final response = await service.streamDesktopResponse(
        HermesChatInput.text('And snacks?'),
        sessionId: 'stored-1',
        options: const HermesDesktopSessionOptions(),
        truncateBeforeRowId: 15,
        truncateSeenThroughRowId: 16,
      );
      final events = await response.events.toList().timeout(
        const Duration(seconds: 5),
      );

      check(events.whereType<HermesRunError>().single.message)
          .equals('The Hermes chat changed. Try again.');
      check(gateway.calls('session.mutate')).isEmpty();
      check(gateway.calls('prompt.submit')).isEmpty();
    });

    // Retried at fresh fences, the cut reached a turn stored meanwhile.
    test('a cut refused for changed fences is not sent again', () async {
      final gateway = _Gateway(authority: true);
      gateway.handler = (method, params) {
        if (method == 'session.mutate') {
          throw const _Refusal(4001, 'revision_conflict', {
            'reason': 'revision_conflict',
            'revision': 6,
          });
        }
        return null;
      };
      final service = _service(gateway, _Rest(_transcript));

      final response = await service.streamDesktopResponse(
        HermesChatInput.text('And snacks?'),
        sessionId: 'stored-1',
        options: const HermesDesktopSessionOptions(),
        truncateBeforeRowId: 15,
        truncateSeenThroughRowId: 16,
      );
      final events = await response.events.toList().timeout(
        const Duration(seconds: 5),
      );

      check(events.whereType<HermesRunError>().single.message)
          .equals('The Hermes chat changed. Try again.');
      check(gateway.calls('session.mutate')).length.equals(1);
      check(gateway.calls('prompt.submit')).isEmpty();
    });

    test('an edit into a command that sends nothing cuts nothing', () async {
      final gateway = _Gateway(authority: true);
      gateway.handler = (method, params) =>
          method == 'slash.exec' ? {'output': 'Synthetic status.'} : null;
      final service = _service(gateway, _Rest(_transcript));

      final response = await service.streamDesktopResponse(
        HermesChatInput.text('/status'),
        sessionId: 'stored-1',
        options: const HermesDesktopSessionOptions(),
        truncateBeforeRowId: 15,
      );
      final events = await response.events.toList().timeout(
        const Duration(seconds: 5),
      );

      check(events.whereType<HermesRunError>()).isEmpty();
      check(gateway.calls('slash.exec')).length.equals(1);
      check(gateway.calls('session.mutate')).isEmpty();
      check(gateway.calls('prompt.submit')).isEmpty();
    });

    test('an edit stopped while its command resolves cuts nothing',
        () async {
      final gateway = _Gateway(authority: true);
      final cancel = CancelToken();
      gateway.handler = (method, params) {
        if (method != 'slash.exec') return null;
        // Stopped while Hermes expands the command.
        cancel.cancel();
        return {'type': 'send', 'message': 'Expanded prompt'};
      };
      final service = _service(gateway, _Rest(_transcript));

      final response = await service.streamDesktopResponse(
        HermesChatInput.text('/plan'),
        sessionId: 'stored-1',
        options: const HermesDesktopSessionOptions(),
        truncateBeforeRowId: 15,
        cancelToken: cancel,
      );
      await response.events.toList().timeout(const Duration(seconds: 5));
      await _settle();

      check(gateway.calls('session.mutate')).isEmpty();
      check(gateway.calls('prompt.submit')).isEmpty();
    });

    // Stopped while the fences were read, the edit still cut the turns it
    // replaces, and sent nothing in their place.
    test('an edit stopped while its fences are read cuts nothing', () async {
      final gateway = _Gateway(authority: true);
      final cancel = CancelToken();
      final rest = _Rest(_transcript)
        ..onRequest = (path) {
          if (path == '/api/sessions/stored-1/messages') cancel.cancel();
        };
      final service = _service(gateway, rest);

      final response = await service.streamDesktopResponse(
        HermesChatInput.text('And snacks?'),
        sessionId: 'stored-1',
        options: const HermesDesktopSessionOptions(),
        truncateBeforeRowId: 15,
        truncateSeenThroughRowId: 16,
        cancelToken: cancel,
      );
      await response.events.toList().timeout(const Duration(seconds: 5));
      await _settle();

      check(cancel.isCancelled).isTrue();
      check(gateway.calls('session.mutate')).isEmpty();
      check(gateway.calls('prompt.submit')).isEmpty();
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

    test('a retried edit finds a turn whose new text was stored', () async {
      // The edit's replacement went out: the session stores the new text.
      final stored = [
        for (final row in _transcript)
          row['id'] == 15 ? {...row, 'content': 'Snacks?'} : row,
      ];
      final service = _service(_Gateway(), _Rest(stored));
      final edited = [..._chat.take(2), _message('u2', 'user', 'Snacks?')];

      final target = await hermesDesktopRewindTarget(
        service: service,
        conversation: conversation,
        messages: edited,
        replayedUserIndex: 2,
        originalText: 'And drinks?',
      );

      check(target).isNotNull().has((t) => t.rowId, 'rowId').equals(15);
    });

    // After an edit went through, the turn's metadata still named the text
    // before it: a second edit looked for that text, or the new one, and
    // found neither.
    test('a second edit finds the text the first one stored', () async {
      final stored = [
        for (final row in _transcript)
          row['id'] == 15 ? {...row, 'content': 'Snacks?'} : row,
      ];
      final service = _service(_Gateway(), _Rest(stored));
      final edited = [..._chat.take(2), _message('u2', 'user', 'Games?')];

      final target = await hermesDesktopRewindTarget(
        service: service,
        conversation: conversation,
        messages: edited,
        replayedUserIndex: 2,
        originalText: 'And drinks?',
        previousText: 'Snacks?',
      );

      check(target).isNotNull()
        ..has((t) => t.rowId, 'rowId').equals(15)
        ..has((t) => t.lastRowId, 'lastRowId').equals(16);
    });

    // The first text matched a later turn another app sent with it, the
    // second the edited turn itself: the first match won, and the edit cut
    // the wrong turn. A text the chat no longer shows now counts only at
    // the turn's place, so the edited turn is found.
    test('a text another app sent later counts only at the turn\'s place',
        () async {
      final stored = [
        for (final row in _transcript)
          row['id'] == 15 ? {...row, 'content': 'Snacks?'} : row,
        {'id': 17, 'role': 'user', 'content': 'And drinks?'},
        {'id': 18, 'role': 'assistant', 'content': 'Water.'},
      ];
      final service = _service(_Gateway(), _Rest(stored));
      final edited = [..._chat.take(2), _message('u2', 'user', 'Games?')];

      final target = await hermesDesktopRewindTarget(
        service: service,
        conversation: conversation,
        messages: edited,
        replayedUserIndex: 2,
        originalText: 'And drinks?',
        previousText: 'Snacks?',
      );

      check(target).isNotNull()
        ..has((t) => t.rowId, 'rowId').equals(15)
        ..has((t) => t.lastRowId, 'lastRowId').equals(18);
    });

    // A plain regenerate passed only the text kept from before an edit: a
    // later turn sent with it matched alone, and the cut took that turn.
    test('a regenerate tries the text shown with the text kept before an '
        'edit', () async {
      final stored = [
        for (final row in _transcript)
          row['id'] == 15 ? {...row, 'content': 'Snacks?'} : row,
        {'id': 17, 'role': 'user', 'content': 'And drinks?'},
        {'id': 18, 'role': 'assistant', 'content': 'Water.'},
      ];
      final service = _service(_Gateway(), _Rest(stored));
      final replayed = _message('u2', 'user', 'Snacks?').copyWith(
        metadata: const {kHermesStoredUserContentKey: 'And drinks?'},
      );
      final texts = hermesRewindCandidateTexts(replayed: replayed);
      check(texts.originalText).equals('And drinks?');
      check(texts.previousText).equals('Snacks?');

      // The kept text matches the later turn only out of place, which does
      // not count; the text shown is at the turn's place.
      final target = await hermesDesktopRewindTarget(
        service: service,
        conversation: conversation,
        messages: [..._chat.take(2), replayed],
        replayedUserIndex: 2,
        originalText: texts.originalText,
        previousText: texts.previousText,
      );
      check(target?.rowId).equals(15);
      // An edit's own texts are kept as given.
      check(
        hermesRewindCandidateTexts(
          replayed: replayed,
          originalUserContent: 'A',
          previousUserContent: 'B',
        ),
      ).equals((originalText: 'A', previousText: 'B'));
      check(
        hermesRewindCandidateTexts(replayed: _message('u2', 'user', 'X')),
      ).equals((originalText: null, previousText: null));
    });

    // The text kept from before an edit (its clean-up not yet done) was the
    // only match once another app replaced the edited turn: a later turn it
    // sent with that text was cut, with its reply.
    test('a kept text that matches only a later turn refuses the cut',
        () async {
      final stored = [
        for (final row in _transcript)
          row['id'] == 15 ? {...row, 'content': 'Snacks from elsewhere?'} : row,
        {'id': 17, 'role': 'user', 'content': 'And drinks?'},
        {'id': 18, 'role': 'assistant', 'content': 'Water.'},
      ];
      final service = _service(_Gateway(), _Rest(stored));
      final replayed = _message('u2', 'user', 'Snacks?').copyWith(
        metadata: const {kHermesStoredUserContentKey: 'And drinks?'},
      );
      final texts = hermesRewindCandidateTexts(replayed: replayed);

      await check(
        hermesDesktopRewindTarget(
          service: service,
          conversation: conversation,
          messages: [..._chat.take(2), replayed],
          replayedUserIndex: 2,
          originalText: texts.originalText,
          previousText: texts.previousText,
        ),
      ).throws<StateError>(
        (it) => it
            .has((error) => error.message, 'message')
            .contains('could not be found'),
      );
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

    test('reads the session as it is now, not a longer earlier read', () async {
      final rest = _Rest(_transcript);
      final service = _service(_Gateway(), rest);
      await service.getSessionMessages('stored-1');
      // Another app undid the second turn.
      rest.transcript = _transcript.take(4).toList();

      final target = await hermesDesktopRewindTarget(
        service: service,
        conversation: conversation,
        messages: _chat,
        replayedUserIndex: 2,
      );

      check(target).isNotNull().has((t) => t.rowId, 'rowId').isNull();
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

  group('a branch from a reply', () {
    final transcript = [
      for (final row in _transcript) Map<String, dynamic>.from(row),
    ];

    test('keeps the whole turn the reply belongs to', () {
      final first = hermesBranchCut(
        transcript: transcript,
        messages: _chat,
        index: 1,
      );
      // Rows 11-14: the prompt, the tool call and its result, the answer.
      check(first).isNotNull()
        ..has((cut) => cut.end, 'end').equals(4)
        ..has((cut) => cut.throughRowId, 'throughRowId').equals(14)
        // A legacy branch counts only user and assistant rows with text.
        ..has((cut) => cut.visibleCount, 'visibleCount').equals(2);
      final last = hermesBranchCut(
        transcript: transcript,
        messages: _chat,
        index: 3,
      );
      check(last).isNotNull()
        ..has((cut) => cut.end, 'end').equals(6)
        ..has((cut) => cut.throughRowId, 'throughRowId').equals(16)
        ..has((cut) => cut.visibleCount, 'visibleCount').equals(4);
    });

    test('a legacy branch counts the rows Hermes keeps', () {
      check(
        hermesLegacyBranchKeepsRow({
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': 'https://hermes.example/photo.png'},
            },
          ],
        }),
      ).isTrue();
      check(
        hermesLegacyBranchKeepsRow({
          'role': 'user',
          'content': [
            {'type': 'input_audio'},
          ],
        }),
      ).isTrue();
      check(
        hermesLegacyBranchKeepsRow({'role': 'assistant', 'content': '  '}),
      ).isFalse();
      check(
        hermesLegacyBranchKeepsRow({
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': ' '},
          ],
        }),
      ).isFalse();
      // Hermes reads `role` as written.
      check(
        hermesLegacyBranchKeepsRow({'role': 'User', 'content': 'Hi'}),
      ).isFalse();
      check(
        hermesLegacyBranchKeepsRow({'author': 'user', 'content': 'Hi'}),
      ).isFalse();
      check(
        hermesLegacyBranchKeepsRow({'role': 'tool', 'content': 'ok'}),
      ).isFalse();

      final withPhoto = [
        {
          'id': 1,
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': 'https://hermes.example/photo.png'},
            },
          ],
        },
        {'id': 2, 'role': 'assistant', 'content': 'A synthetic photo.'},
        {'id': 3, 'role': 'user', 'content': 'Thanks'},
        {'id': 4, 'role': 'assistant', 'content': 'Welcome.'},
      ];
      check(
        hermesBranchCut(
          transcript: withPhoto,
          messages: [
            _message('u1', 'user', ''),
            _message('a1', 'assistant', 'A synthetic photo.'),
            _message('u2', 'user', 'Thanks'),
            _message('a2', 'assistant', 'Welcome.'),
          ],
          index: 1,
        ),
      ).isNotNull().has((cut) => cut.visibleCount, 'visibleCount').equals(2);
    });

    test('is counted on the legacy wire', () async {
      final gateway = _Gateway();
      final service = _service(gateway, _Rest(_transcript));

      final branch = await service.branchSession(
        'stored-1',
        count: 2,
        throughRowId: 14,
      );

      check(branch).equals('stored-2');
      final params = gateway.calls('session.branch').single;
      check(params['count']).equals(2);
      // The legacy contract refuses keys it does not know.
      check(params.containsKey('through_message_id')).isFalse();
    });

    test('ends at a row on the canonical wire', () async {
      final gateway = _Gateway(authority: true);
      final service = _service(gateway, _Rest(_transcript));

      final branch = await service.branchSession(
        'stored-1',
        count: 2,
        throughRowId: 14,
      );

      check(branch).equals('stored-2');
      final edit = gateway.calls('session.mutate').single;
      check(edit['operation']).equals('branch');
      check(edit['payload'] as Map).deepEquals({'through_message_id': 14});
    });

    test('a Desktop chat branches on its server', () async {
      final gateway = _Gateway();
      final service = _service(gateway, _Rest(_transcript));
      final container = _chatContainer(service, _chat);

      final branch = await container
          .read(hermesSessionsProvider.notifier)
          .branchFromMessage(
            sessionId: 'stored-1',
            title: 'Synthetic picnic',
            messages: _chat,
            index: 1,
          );

      check(branch).isNotNull()
        ..has((b) => b.session.id, 'id').equals('stored-2')
        ..has((b) => b.transcript, 'transcript').isNull();
      check(gateway.calls('session.branch').single['count']).equals(2);
    });

    // A branch chosen again while the first was made created a second
    // copy on the server, and only one of them opened.
    test('a second branch while one is made does nothing', () async {
      final gateway = _Gateway();
      final rest = _Rest(_transcript);
      final service = _service(gateway, rest);
      final container = _chatContainer(service, _chat);
      final held = rest.hold = Completer<void>();
      Future<Object?> branch() => container
          .read(hermesSessionsProvider.notifier)
          .branchFromMessage(
            sessionId: 'stored-1',
            title: 'Synthetic picnic',
            messages: _chat,
            index: 1,
          );

      final first = branch();
      await _settle();
      check(await branch()).isNull();
      held.complete();

      check(await first).isNotNull();
      check(gateway.calls('session.branch')).length.equals(1);
    });

    test('a branch made while the connection changed is not opened', () async {
      final gateway = _Gateway();
      final rest = _Rest(_transcript);
      final service = _service(gateway, rest);
      final connection = NotifierProvider<_Connection, HermesBackendService?>(
        () => _Connection(service),
      );
      final container = _chatContainer(
        service,
        _chat,
        connection: connection,
      );
      rest.onRequest = (path) {
        if (path == '/api/sessions/stored-2') {
          container
              .read(connection.notifier)
              .use(_service(_Gateway(), _Rest(_transcript)));
        }
      };

      final branch = await container
          .read(hermesSessionsProvider.notifier)
          .branchFromMessage(
            sessionId: 'stored-1',
            title: 'Synthetic picnic',
            messages: _chat,
            index: 1,
          );

      check(gateway.calls('session.branch')).length.equals(1);
      check(branch).isNull();
      // It stayed on the server the user left, in that connection's list.
      check(rest.requests).contains('DELETE /api/sessions/stored-2');
    });

    test('a branch whose connection changed as it was made is removed',
        () async {
      final gateway = _Gateway();
      final rest = _Rest(_transcript);
      final service = _service(gateway, rest);
      final connection = NotifierProvider<_Connection, HermesBackendService?>(
        () => _Connection(service),
      );
      final container = _chatContainer(
        service,
        _chat,
        connection: connection,
      );
      gateway.handler = (method, params) {
        if (method == 'session.branch') {
          container
              .read(connection.notifier)
              .use(_service(_Gateway(), _Rest(_transcript)));
        }
        return null;
      };

      final branch = await container
          .read(hermesSessionsProvider.notifier)
          .branchFromMessage(
            sessionId: 'stored-1',
            title: 'Synthetic picnic',
            messages: _chat,
            index: 1,
          );

      check(branch).isNull();
      check(rest.requests).contains('DELETE /api/sessions/stored-2');
      // Never read: the branch is not opened.
      check(
        rest.requests,
      ).not((it) => it.contains('GET /api/sessions/stored-2'));
    });

    test('a Desktop branch keeps the document cards of the rows it '
        'copied', () async {
      const envelope = '<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_1>>>notes';
      const prompt = 'Summarize\n\n$envelope';
      final rest = _Rest([
        {'id': 'm1', 'role': 'user', 'content': prompt},
        {'id': 'm2', 'role': 'assistant', 'content': 'Synthetic summary.'},
        {'id': 'm3', 'role': 'user', 'content': 'Shorter?'},
        {'id': 'm4', 'role': 'assistant', 'content': 'Yes.'},
      ]);
      rest.others['stored-2'] = [
        {'id': 'b1', 'role': 'user', 'content': prompt},
        {'id': 'b2', 'role': 'assistant', 'content': 'Synthetic summary.'},
      ];
      final service = _service(_Gateway(), rest);
      final chat = [
        _message('u1', 'user', 'Summarize'),
        _message('a1', 'assistant', 'Synthetic summary.'),
        _message('u2', 'user', 'Shorter?'),
        _message('a2', 'assistant', 'Yes.'),
      ];
      final container = _chatContainer(service, chat);
      final identity = HermesLocalDocumentTrustStore.connectionIdentity(
        endpointIdentity: HermesConfigController.connectionEndpoint(
          'https://hermes.example',
        )!,
        principalId: container
            .read(hermesConfigProvider.notifier)
            .documentTrustPrincipalId(),
      );
      await HermesLocalDocumentTrustStore.remember(
        connectionIdentity: identity,
        sessionId: 'stored-1',
        messageId: 'm1',
        promptText: prompt,
        documentEnvelopes: const [envelope],
      );

      final branch = await container
          .read(hermesSessionsProvider.notifier)
          .branchFromMessage(
            sessionId: 'stored-1',
            title: 'Synthetic notes',
            messages: chat,
            index: 1,
          );

      check(branch).isNotNull();
      check(
        HermesLocalDocumentTrustStore.trustedDocumentKeys(
          connectionIdentity: identity,
          sessionId: 'stored-2',
        ),
      ).isNotEmpty();
    });

    test('an API server chat opens a new session with the transcript '
        'through the reply, not a fork', () async {
      final service = _RestTranscript();
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final copiedHistory = HermesCopiedHistoryStore(database);
      final container = _chatContainer(
        service,
        _chat,
        copiedHistory: copiedHistory,
      );

      final branch = await container
          .read(hermesSessionsProvider.notifier)
          .branchFromMessage(
            sessionId: 'stored-1',
            title: 'Synthetic picnic',
            messages: _chat,
            index: 1,
          );

      check(branch).isNotNull()
        ..has((b) => b.session.id, 'id').equals('api_copy')
        ..has((b) => b.session.title, 'title').equals('Synthetic picnic');
      // Saved here, so a branch left before it opens keeps them.
      check(branch!.transcript).isNull();
      final identity = HermesLocalDocumentTrustStore.connectionIdentity(
        endpointIdentity: HermesConfigController.connectionEndpoint(
          'https://hermes.example',
        )!,
        principalId: container
            .read(hermesConfigProvider.notifier)
            .documentTrustPrincipalId(),
      );
      check(
        (await copiedHistory.load(
          connectionIdentity: identity,
          sessionId: 'api_copy',
        ))?.map((row) => row['id']).toList(),
      ).isNotNull().deepEquals([11, 12, 13, 14]);
      // Untitled: Hermes refuses a second session with the same title.
      check(service.created).deepEquals([null]);
      check(service.forks).equals(0);
      check(service.deleted).isEmpty();
    });

    // A branch whose connection changed once its copy was made returned
    // nothing, but left the copy on the server and its history here.
    test('an API server branch made while the connection changed is removed',
        () async {
      final service = _RestTranscript();
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final copiedHistory = HermesCopiedHistoryStore(database);
      final connection = NotifierProvider<_Connection, HermesBackendService?>(
        () => _Connection(service),
      );
      final container = _chatContainer(
        service,
        _chat,
        connection: connection,
        copiedHistory: copiedHistory,
      );
      final identity = HermesLocalDocumentTrustStore.connectionIdentity(
        endpointIdentity: HermesConfigController.connectionEndpoint(
          'https://hermes.example',
        )!,
        principalId: container
            .read(hermesConfigProvider.notifier)
            .documentTrustPrincipalId(),
      );
      service.onCreated = () =>
          container.read(connection.notifier).use(_RestTranscript());

      final branch = await container
          .read(hermesSessionsProvider.notifier)
          .branchFromMessage(
            sessionId: 'stored-1',
            title: 'Synthetic picnic',
            messages: _chat,
            index: 1,
          );

      check(branch).isNull();
      check(service.deleted).deepEquals(['api_copy']);
      check(
        await copiedHistory.load(
          connectionIdentity: identity,
          sessionId: 'api_copy',
        ),
      ).isNull();
    });

    test('an API server branch whose newest reply alone outgrows the '
        'device is removed', () async {
      final huge = 'x' * (1024 * 1024 + 16);
      final service = _RestTranscript([
        {'id': 11, 'role': 'user', 'content': 'Write it all out'},
        {'id': 12, 'role': 'assistant', 'content': huge},
      ]);
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final chat = [
        _message('u1', 'user', 'Write it all out'),
        _message('a1', 'assistant', huge),
      ];
      final container = _chatContainer(
        service,
        chat,
        copiedHistory: HermesCopiedHistoryStore(database),
      );

      await check(
        container
            .read(hermesSessionsProvider.notifier)
            .branchFromMessage(
              sessionId: 'stored-1',
              title: 'Synthetic essay',
              messages: chat,
              index: 1,
            ),
      ).throws<StateError>();
      check(service.deleted).deepEquals(['api_copy']);
    });

    test('an API server branch whose history cannot be kept is removed',
        () async {
      final service = _RestTranscript();
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await database.customSelect('SELECT 1').get();
      await database.customStatement('PRAGMA query_only = ON');
      final container = _chatContainer(
        service,
        _chat,
        copiedHistory: HermesCopiedHistoryStore(database),
      );

      await check(
        container
            .read(hermesSessionsProvider.notifier)
            .branchFromMessage(
              sessionId: 'stored-1',
              title: 'Synthetic picnic',
              messages: _chat,
              index: 1,
            ),
      ).throws<Object>();
      check(service.deleted).deepEquals(['api_copy']);
    });
  });

  group('undoing the last turn', () {
    test('is a session undo on the legacy wire', () async {
      final gateway = _Gateway();
      final service = _service(gateway, _Rest(_transcript));

      check(await service.undoLastTurn('stored-1')).isTrue();
      check(gateway.calls('session.undo').single['session_id']).equals('rt-1');
    });

    test('rewinds to the last prompt on the canonical wire', () async {
      final gateway = _Gateway(authority: true);
      final service = _service(gateway, _Rest(_transcript));

      check(await service.undoLastTurn('stored-1')).isTrue();
      final edit = gateway.calls('session.mutate').single;
      check(edit['operation']).equals('rewind');
      check(edit['payload'] as Map).deepEquals({'target_message_id': 15});
      check(gateway.calls('session.undo')).isEmpty();
    });

    test('a chat reopened while it was undone reads its transcript again',
        () async {
      final gateway = _Gateway();
      final service = _service(gateway, _Rest(_transcript));
      final container = _chatContainer(service, _chat);
      final reopened = [
        for (final message in _chat) message.copyWith(id: 'r-${message.id}'),
      ];
      gateway.handler = (method, params) {
        if (method != 'session.undo') return null;
        // Opened again from the list while Hermes undoes the turn.
        container.read(chatMessagesProvider.notifier).setMessages(reopened);
        return null;
      };
      final reloads = <String>[];
      service.transcriptChanges.listen(reloads.add);

      check(await undoLastHermesTurn(container)).isTrue();
      await _settle();

      check(reloads).contains('stored-1');
      check(container.read(chatMessagesProvider)).deepEquals(reopened);
      // That read is shorter than the chat shows, and is taken as it is.
      check(service.takeShortenedTranscript('stored-1')).isTrue();
      check(service.takeShortenedTranscript('stored-1')).isFalse();
    });

    test('drops the turn from the chat and the session', () async {
      final gateway = _Gateway();
      final service = _service(gateway, _Rest(_transcript));
      final container = _chatContainer(service, _chat);

      check(await undoLastHermesTurn(container)).isTrue();

      check(gateway.calls('session.undo')).length.equals(1);
      check(
        container.read(chatMessagesProvider).map((message) => message.id),
      ).deepEquals(['u1', 'a1']);
      check(
        container.read(activeConversationProvider)!.messages.length,
      ).equals(2);
    });

    test('a last turn that never reached the session leaves only the '
        'chat', () async {
      final gateway = _Gateway();
      final service = _service(gateway, _Rest(_transcript));
      final container = _chatContainer(service, [
        ..._chat,
        _message('u3', 'user', 'Lost on the way'),
        _message('a3', 'assistant', ''),
      ]);

      check(await undoLastHermesTurn(container)).isTrue();

      check(gateway.calls('session.undo')).isEmpty();
      check(
        container.read(chatMessagesProvider).map((message) => message.id),
      ).deepEquals(['u1', 'a1', 'u2', 'a2']);
    });

    test('rewinds to the row it checked on the canonical wire', () async {
      final gateway = _Gateway(authority: true);
      final service = _service(gateway, _Rest(_transcript));

      check(await service.undoLastTurn('stored-1', rowId: 15)).isTrue();
      final rewind = gateway.calls('session.mutate').single;
      check(rewind['payload'] as Map).deepEquals({'target_message_id': 15});
      check(rewind['expected_revision']).equals(5);
    });

    // The row was checked before the fences were read: a turn stored in
    // between was rewound along with it.
    test('a turn stored after the row it checked refuses the undo', () async {
      final gateway = _Gateway(authority: true);
      final service = _service(gateway, _Rest(_transcript));

      await check(
        service.undoLastTurn('stored-1', rowId: 11),
      ).throws<StateError>();
      check(gateway.calls('session.mutate')).isEmpty();
    });

    test('a second undo while one runs does nothing', () async {
      final gateway = _Gateway();
      final rest = _Rest(_transcript);
      final service = _service(gateway, rest);
      final container = _chatContainer(service, _chat);
      final held = rest.hold = Completer<void>();

      final first = undoLastHermesTurn(container);
      await _settle();
      check(await undoLastHermesTurn(container)).isFalse();
      held.complete();

      check(await first).isTrue();
      check(gateway.calls('session.undo')).length.equals(1);
      check(
        container.read(chatMessagesProvider).map((message) => message.id),
      ).deepEquals(['u1', 'a1']);
    });

    test('a message sent while the transcript is read stops the '
        'undo', () async {
      final gateway = _Gateway();
      final rest = _Rest(_transcript);
      final service = _service(gateway, rest);
      final container = _chatContainer(service, _chat);
      final held = rest.hold = Completer<void>();

      final undo = undoLastHermesTurn(container);
      await _settle();
      container.read(chatMessagesProvider.notifier).setMessages([
        ..._chat,
        _message('u3', 'user', 'One more thing'),
      ]);
      held.complete();

      await check(undo).throws<StateError>();
      check(gateway.calls('session.undo')).isEmpty();
      check(container.read(chatMessagesProvider)).length.equals(5);
    });

    test('a turn Hermes did not drop stays in the chat', () async {
      final gateway = _Gateway();
      gateway.handler = (method, params) =>
          method == 'session.undo' ? {'removed': 0} : null;
      final service = _service(gateway, _Rest(_transcript));
      final container = _chatContainer(service, _chat);

      await check(undoLastHermesTurn(container)).throws<StateError>();
      check(container.read(chatMessagesProvider)).length.equals(4);
    });

    // On the legacy wire Hermes refuses an undo when the turns it stored no
    // longer match the ones it holds, as when another process stored one.
    // Its refusal leaves the chat as it was.
    test('an undo Hermes refuses for a changed history leaves the chat',
        () async {
      final gateway = _Gateway();
      gateway.handler = (method, params) {
        if (method == 'session.undo') {
          throw const _Refusal(
            5008,
            'undo: session history changed before the rewind could be '
            'persisted',
          );
        }
        return null;
      };
      final service = _service(gateway, _Rest(_transcript));
      final container = _chatContainer(service, _chat);

      await check(undoLastHermesTurn(container)).throws<Object>();
      check(
        container.read(chatMessagesProvider).map((message) => message.id),
      ).deepEquals(['u1', 'a1', 'u2', 'a2']);
    });

    // The legacy undo names no turn, and clients attached to one gateway
    // share its session: a turn another one finished after the chat read
    // the transcript was the one dropped.
    test('a turn stored before the legacy undo is sent refuses it', () async {
      final gateway = _Gateway();
      final rest = _Rest(_transcript);
      final service = _service(gateway, rest);
      final container = _chatContainer(service, _chat);
      var reads = 0;
      rest.onRequest = (path) {
        if (path != '/api/sessions/stored-1/messages' || ++reads != 2) return;
        rest.transcript = [
          ..._transcript,
          {'id': 17, 'role': 'user', 'content': 'Sent from elsewhere'},
          {'id': 18, 'role': 'assistant', 'content': 'Noted.'},
        ];
      };

      await check(undoLastHermesTurn(container)).throws<StateError>();
      check(gateway.calls('session.undo')).isEmpty();
      check(container.read(chatMessagesProvider)).length.equals(4);
    });

    // A turn stored after that last read and dropped in its place: the
    // chat's own turn is still in the session, so it stays in the chat.
    test('a legacy undo that dropped another turn keeps the chat\'s', () async {
      final gateway = _Gateway();
      gateway.handler = (method, params) =>
          method == 'session.undo' ? {'removed': 2} : null;
      final service = _service(gateway, _Rest(_transcript));
      final container = _chatContainer(service, _chat);

      await check(undoLastHermesTurn(container)).throws<StateError>();
      check(gateway.calls('session.undo')).length.equals(1);
      check(container.read(chatMessagesProvider)).length.equals(4);
    });

    // Reported as not undone, the turn would be undone again, and the one
    // before it dropped too.
    test('a legacy undo whose result cannot be read counts as done', () async {
      final gateway = _Gateway();
      final rest = _Rest(_transcript);
      final service = _service(gateway, rest);
      final container = _chatContainer(service, _chat);
      var reads = 0;
      rest.onRequest = (path) {
        if (path == '/api/sessions/stored-1/messages' && ++reads == 3) {
          throw StateError('Hermes could not be reached.');
        }
      };

      check(await undoLastHermesTurn(container)).isTrue();
      check(gateway.calls('session.undo')).length.equals(1);
      check(
        container.read(chatMessagesProvider).map((message) => message.id),
      ).deepEquals(['u1', 'a1']);
    });

    test('a turn another app already undid leaves only the chat', () async {
      final gateway = _Gateway();
      final rest = _Rest(_transcript);
      final service = _service(gateway, rest);
      await service.getSessionMessages('stored-1');
      rest.transcript = _transcript.take(4).toList();
      final container = _chatContainer(service, _chat);

      check(await undoLastHermesTurn(container)).isTrue();

      // The session's last turn now is the first one: it stays.
      check(gateway.calls('session.undo')).isEmpty();
      check(
        container.read(chatMessagesProvider).map((message) => message.id),
      ).deepEquals(['u1', 'a1']);
    });

    test('a last turn the chat cannot match is not undone', () async {
      final gateway = _Gateway();
      final service = _service(gateway, _Rest(_transcript));
      final container = _chatContainer(service, [
        ..._chat.take(2),
        _message('u2', 'user', 'Not what the session holds'),
        _message('a2', 'assistant', 'Lemonade.'),
      ]);

      await check(undoLastHermesTurn(container)).throws<StateError>();
      check(gateway.calls('session.undo')).isEmpty();
      check(container.read(chatMessagesProvider)).length.equals(4);
    });
  });
}
