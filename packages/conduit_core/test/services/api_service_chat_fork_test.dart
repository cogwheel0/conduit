import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  late _Adapter adapter;
  late ApiService api;

  setUp(() {
    adapter = _Adapter();
    api = ApiService(
      serverConfig: const ServerConfig(
        id: 'server',
        name: 'Server',
        url: 'https://server.example',
      ),
      workerManager: WorkerManager(),
      authToken: 'session-a',
    );
    api.dio.httpClientAdapter = adapter;
  });

  tearDown(() => api.dispose());

  group('forkChatRaw', () {
    test('posts the exact upstream route and body once', () async {
      final chat = await api.forkChatRaw('chat-1', 'msg-7');

      final request = adapter.requests.single;
      check(request.method).equals('POST');
      check(request.path).equals('/api/v1/chats/chat-1/fork');
      check(request.data)
          .isA<Map<String, dynamic>>()
          .deepEquals({'message_id': 'msg-7'});
      // The whole authoritative envelope comes back, unknown keys included.
      check(chat['id']).equals('fork-1');
      check(chat['futureKey']).equals('kept');
    });

    test('never falls back to the whole-chat clone', () async {
      adapter.status = 404;
      adapter.body = {'detail': 'Not Found'};

      await expectLater(
        api.forkChatRaw('chat-1', 'msg-7'),
        throwsA(isA<DioException>()),
      );

      check(adapter.requests.map((r) => r.path))
          .deepEquals(['/api/v1/chats/chat-1/fork']);
    });

    test('rethrows the server refusals for the caller to classify', () async {
      for (final status in [401, 403, 409]) {
        adapter.status = status;
        adapter.body = {'detail': 'refused'};
        await expectLater(
          api.forkChatRaw('chat-1', 'msg-7'),
          throwsA(
            isA<DioException>().having(
              (e) => e.response?.statusCode,
              'status',
              status,
            ),
          ),
          reason: '$status',
        );
      }
      // One request per refusal, never a retry.
      check(adapter.requests).length.equals(3);
    });

    test('a 2xx without a chat is an error, not a fork', () async {
      for (final body in <Object?>[
        null,
        <String, dynamic>{},
        <String, dynamic>{'id': ''},
      ]) {
        adapter.body = body;
        await expectLater(
          api.forkChatRaw('chat-1', 'msg-7'),
          throwsA(isA<FormatException>()),
          reason: '$body',
        );
      }
    });

    // The same ApiService serves the next account. A fork is a write that
    // creates a chat, so one authorized for account A must never reach the
    // server with account B's bearer.
    test('is cancelled before the wire once the account changed', () async {
      final accountA = api.captureAuthSnapshot();
      api.updateAuthToken('session-b');

      await expectLater(
        api.forkChatRaw('chat-1', 'msg-7', authSnapshot: accountA),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      check(adapter.requests).isEmpty();
    });

    test('a snapshot of the current account is sent with its token', () async {
      api.updateAuthToken('session-b');

      await api.forkChatRaw(
        'chat-1',
        'msg-7',
        authSnapshot: api.captureAuthSnapshot(),
      );

      check(adapter.requests.single.headers['Authorization'])
          .equals('Bearer session-b');
    });
  });

  group('getConversation', () {
    test('is cancelled before the wire once the account changed', () async {
      adapter.body = {'id': 'chat-1', 'chat': <String, dynamic>{}};
      final accountA = api.captureAuthSnapshot();
      api.updateAuthToken('session-b');

      await expectLater(
        api.getConversation('chat-1', authSnapshot: accountA),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      check(adapter.requests).isEmpty();
    });

    test('a snapshot of the current account reads with its token', () async {
      adapter.body = {'id': 'chat-1', 'chat': <String, dynamic>{}};
      api.updateAuthToken('session-b');

      final conversation = await api.getConversation(
        'chat-1',
        authSnapshot: api.captureAuthSnapshot(),
      );

      check(conversation.id).equals('chat-1');
      check(adapter.requests.single.headers['Authorization'])
          .equals('Bearer session-b');
    });
  });

  group('getChatRaw', () {
    test('is cancelled before the wire once the account changed', () async {
      final accountA = api.captureAuthSnapshot();
      api.updateAuthToken('session-b');

      await expectLater(
        api.getChatRaw('chat-1', authSnapshot: accountA),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      check(adapter.requests).isEmpty();
    });

    test('a snapshot of the current account reads with its token', () async {
      adapter.body = {'id': 'chat-1', 'chat': <String, dynamic>{}};
      api.updateAuthToken('session-b');

      await api.getChatRaw('chat-1', authSnapshot: api.captureAuthSnapshot());
      await api.getChatRaw('chat-1');

      check(adapter.requests[0].path).equals('/api/v1/chats/chat-1');
      check(adapter.requests[0].headers['Authorization'])
          .equals('Bearer session-b');
      // Without a snapshot the existing contract is unchanged.
      check(adapter.requests[1].headers['Authorization'])
          .equals('Bearer session-b');
    });

    test('keeps its existing contract for callers with no snapshot', () async {
      adapter.status = 404;
      check(await api.getChatRaw('gone')).isNull();
    });
  });
}

/// Records every request that reaches the wire and answers each with [body].
final class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int status = 200;
  Object? body = const <String, dynamic>{
    'id': 'fork-1',
    'title': 'Chat (fork)',
    'chat': <String, dynamic>{},
    'futureKey': 'kept',
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromBytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
