import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/chat_completion_transport.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Test helper: build an ApiService whose Dio uses a fake HttpClientAdapter
// ---------------------------------------------------------------------------

/// A minimal [HttpClientAdapter] that lets tests specify the exact response
/// for the next request.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
  });

  /// Convenience: respond with a JSON map.
  factory _FakeAdapter.json(
    Map<String, dynamic> body, {
    int statusCode = 200,
    Map<String, List<String>>? extraHeaders,
  }) {
    final encoded = utf8.encode(jsonEncode(body));
    return _FakeAdapter(
      statusCode: statusCode,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
        ...?extraHeaders,
      },
      bodyBytes: encoded,
    );
  }

  /// Convenience: respond with raw bytes and explicit content-type.
  factory _FakeAdapter.raw({
    required List<int> bytes,
    int statusCode = 200,
    Map<String, List<String>>? headers,
  }) {
    return _FakeAdapter(
      statusCode: statusCode,
      headers: headers ?? {},
      bodyBytes: bytes,
    );
  }

  final int statusCode;
  final Map<String, List<String>> headers;
  final List<int> bodyBytes;

  /// The last [RequestOptions] seen by this adapter.
  RequestOptions? lastRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelOnError,
  ) async {
    lastRequest = options;
    return ResponseBody(
      Stream.value(Uint8List.fromList(bodyBytes)),
      statusCode,
      headers: headers,
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Queues multiple fake responses for sequential requests.
class _QueuedFakeAdapter implements HttpClientAdapter {
  _QueuedFakeAdapter(this.responses);

  final List<_FakeAdapter> responses;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelOnError,
  ) async {
    requests.add(options);
    if (responses.isEmpty) {
      throw StateError('No queued fake responses left');
    }

    return responses.removeAt(0).fetch(options, requestStream, cancelOnError);
  }

  @override
  void close({bool force = false}) {}
}

/// Builds an [ApiService] for testing whose Dio adapter is [adapter].
ApiService _buildApiServiceForTest(HttpClientAdapter adapter) {
  final service = ApiService(
    serverConfig: const ServerConfig(
      id: 'test',
      name: 'Test Server',
      url: 'http://localhost:9999',
    ),
    workerManager: WorkerManager(),
  );
  // Replace the Dio adapter so requests don't touch the network.
  service.dio.httpClientAdapter = adapter;
  // Clear interceptors to avoid auth / connectivity side-effects.
  service.dio.interceptors.clear();
  return service;
}

// ---------------------------------------------------------------------------
// Shared request arguments for sendMessageSession
// ---------------------------------------------------------------------------
const _minimalMessages = <Map<String, dynamic>>[
  {'role': 'user', 'content': 'hi'},
];
const _model = 'gpt-test';

Map<String, dynamic> _legacyChatPayload({
  required Map<String, dynamic> historyMessages,
  required String currentId,
}) {
  return {
    'id': 'chat-1',
    'user_id': 'user-test',
    'title': 'Legacy chat',
    'chat': {
      'title': 'Legacy chat',
      'models': [_model],
      'history': {'messages': historyMessages, 'currentId': currentId},
      'messages': const <Map<String, dynamic>>[],
      'params': const <String, dynamic>{},
      'files': const <Map<String, dynamic>>[],
    },
    'updated_at': 1774458297,
    'created_at': 1774458200,
    'archived': false,
    'pinned': false,
  };
}

void main() {
  // -----------------------------------------------------------------------
  // 1. taskSocket classification from JSON with task_id
  // -----------------------------------------------------------------------
  group('sendMessageSession classification', () {
    test('taskSocket classification from JSON response with task_id', () async {
      final adapter = _FakeAdapter.json({'task_id': 'task-42', 'status': true});
      final api = _buildApiServiceForTest(adapter);

      final session = await api.sendMessageSession(
        messages: _minimalMessages,
        model: _model,
      );

      check(session.transport).equals(ChatCompletionTransport.taskSocket);
      check(session.taskId).equals('task-42');
      check(session.byteStream).isNull();
      check(session.abort).isNotNull();
    });

    test(
      'taskSocket classification from JSON response with task_ids',
      () async {
        final adapter = _FakeAdapter.json({
          'task_ids': ['task-42'],
          'status': true,
          'chat_id': 'chat-1',
        });
        final api = _buildApiServiceForTest(adapter);

        final session = await api.sendMessageSession(
          messages: _minimalMessages,
          model: _model,
          conversationId: 'chat-1',
        );

        check(session.transport).equals(ChatCompletionTransport.taskSocket);
        check(session.taskId).equals('task-42');
        check(session.jsonPayload).isNull();
        check(session.abort).isNotNull();
      },
    );

    // 2. jsonCompletion classification from JSON without task_id
    test('jsonCompletion classification from JSON without task_id', () async {
      final adapter = _FakeAdapter.json({
        'choices': [
          {
            'message': {'content': 'Hello!'},
          },
        ],
      });
      final api = _buildApiServiceForTest(adapter);

      final session = await api.sendMessageSession(
        messages: _minimalMessages,
        model: _model,
      );

      check(session.transport).equals(ChatCompletionTransport.jsonCompletion);
      check(session.jsonPayload).isNotNull();
      check(session.taskId).isNull();
    });

    // 3. httpStream classification from text/event-stream response
    test('httpStream classification from text/event-stream response', () async {
      final sseBody =
          'data: {"choices":[{"delta":{"content":"hi"}}]}\n\ndata: [DONE]\n\n';
      final adapter = _FakeAdapter.raw(
        bytes: utf8.encode(sseBody),
        headers: {
          'content-type': ['text/event-stream'],
        },
      );
      final api = _buildApiServiceForTest(adapter);

      final session = await api.sendMessageSession(
        messages: _minimalMessages,
        model: _model,
      );

      check(session.transport).equals(ChatCompletionTransport.httpStream);
      check(session.byteStream).isNotNull();
      check(session.abort).isNotNull();
    });

    // 4. httpStream classification when body looks like SSE but has no
    //    content-type header
    test(
      'httpStream when body looks like SSE but has no content-type',
      () async {
        final sseBody =
            'data: {"choices":[{"delta":{"content":"hi"}}]}\n\ndata: [DONE]\n\n';
        final adapter = _FakeAdapter.raw(
          bytes: utf8.encode(sseBody),
          headers: {}, // no content-type
        );
        final api = _buildApiServiceForTest(adapter);

        final session = await api.sendMessageSession(
          messages: _minimalMessages,
          model: _model,
        );

        check(session.transport).equals(ChatCompletionTransport.httpStream);
        check(session.byteStream).isNotNull();
      },
    );

    // 5. taskSocket classification from JSON body split across multiple chunks
    test('taskSocket from JSON split across multiple chunks', () async {
      // Simulate JSON split across byte boundaries by encoding it as a
      // single chunk (the classification logic buffers the entire stream
      // when sniffing). The adapter delivers it atomically but the
      // classifier must still handle it.
      final adapter = _FakeAdapter.json({
        'task_id': 'task-split',
        'status': true,
      });
      final api = _buildApiServiceForTest(adapter);

      final session = await api.sendMessageSession(
        messages: _minimalMessages,
        model: _model,
      );

      check(session.transport).equals(ChatCompletionTransport.taskSocket);
      check(session.taskId).equals('task-split');
    });

    // 6. Body-shape-over-header: JSON body wins over misleading
    //    event-stream header
    test(
      'body shape over header: JSON body wins over event-stream header',
      () async {
        final jsonBody = jsonEncode({'task_id': 'task-misleading'});
        final adapter = _FakeAdapter.raw(
          bytes: utf8.encode(jsonBody),
          headers: {
            'content-type': ['text/event-stream'],
          },
        );
        final api = _buildApiServiceForTest(adapter);

        final session = await api.sendMessageSession(
          messages: _minimalMessages,
          model: _model,
        );

        // Even though header says event-stream, body sniffing finds JSON
        // with task_id → taskSocket wins.
        check(session.transport).equals(ChatCompletionTransport.taskSocket);
        check(session.taskId).equals('task-misleading');
      },
    );

    // 7. taskSocket session retains abort handle for mixed-initiation stop
    test('taskSocket session retains abort handle', () async {
      final adapter = _FakeAdapter.json({'task_id': 'task-abort'});
      final api = _buildApiServiceForTest(adapter);

      final session = await api.sendMessageSession(
        messages: _minimalMessages,
        model: _model,
      );

      check(session.transport).equals(ChatCompletionTransport.taskSocket);
      check(session.abort).isNotNull();
    });

    // 8. httpStream session preserves abort handle
    test('httpStream session preserves abort handle', () async {
      final sseBody = 'data: {"choices":[{"delta":{"content":"x"}}]}\n\n';
      final adapter = _FakeAdapter.raw(
        bytes: utf8.encode(sseBody),
        headers: {
          'content-type': ['text/event-stream'],
        },
      );
      final api = _buildApiServiceForTest(adapter);

      final session = await api.sendMessageSession(
        messages: _minimalMessages,
        model: _model,
      );

      check(session.transport).equals(ChatCompletionTransport.httpStream);
      check(session.abort).isNotNull();
    });

    // 9. Structured non-2xx JSON error surfaced before transport binding
    test('non-2xx JSON error surfaced before transport binding', () async {
      final adapter = _FakeAdapter.json({
        'error': 'Model not found',
      }, statusCode: 404);
      final api = _buildApiServiceForTest(adapter);

      Object? caught;
      try {
        await api.sendMessageSession(messages: _minimalMessages, model: _model);
      } catch (e) {
        caught = e;
      }
      check(caught).isNotNull();
      check(caught).isA<Exception>();
    });

    test('sendMessageSession forwards explicit request files', () async {
      final adapter = _FakeAdapter.json({
        'choices': [
          {
            'message': {'content': 'Hello!'},
          },
        ],
      });
      final api = _buildApiServiceForTest(adapter);

      await api.sendMessageSession(
        messages: const [
          {'role': 'system', 'content': 'System'},
        ],
        model: _model,
        files: const [
          {
            'type': 'file',
            'id': 'doc-1',
            'url': 'doc-1',
            'name': 'spec.pdf',
            'content_type': 'application/pdf',
          },
          {
            'type': 'image',
            'id': 'img-1',
            'url': 'img-1',
            'content_type': 'image/png',
          },
        ],
      );

      final request = adapter.lastRequest;
      check(request).isNotNull();
      final body = request!.data as Map<String, dynamic>;
      check(body['files']).isA<List<dynamic>>().deepEquals(const [
        {
          'type': 'file',
          'id': 'doc-1',
          'url': 'doc-1',
          'name': 'spec.pdf',
          'content_type': 'application/pdf',
        },
      ]);
    });

    test('sendMessageSession retries with legacy metadata and persists '
        'pending turns on pre-v0.9 servers', () async {
      const userMessage1 = <String, dynamic>{
        'id': 'user-1',
        'parentId': 'assistant-0',
        'childrenIds': ['assistant-1'],
        'role': 'user',
        'content': 'hello',
        'models': ['gpt-test'],
        'timestamp': 1774458297,
      };
      const userMessage2 = <String, dynamic>{
        'id': 'user-2',
        'parentId': 'assistant-1',
        'childrenIds': ['assistant-2'],
        'role': 'user',
        'content': 'follow up',
        'models': ['gpt-test'],
        'timestamp': 1774458397,
      };

      final adapter = _QueuedFakeAdapter([
        _FakeAdapter.json({
          'detail': 'user_message is unsupported when sending a prompt.',
        }, statusCode: 400),
        _FakeAdapter.json(
          _legacyChatPayload(
            currentId: 'assistant-0',
            historyMessages: const {
              'user-0': {
                'id': 'user-0',
                'parentId': null,
                'childrenIds': ['assistant-0'],
                'role': 'user',
                'content': 'before',
                'models': ['gpt-test'],
                'timestamp': 1774458197,
              },
              'assistant-0': {
                'id': 'assistant-0',
                'parentId': 'user-0',
                'childrenIds': [],
                'role': 'assistant',
                'content': 'before answer',
                'model': 'gpt-test',
                'modelName': 'gpt-test',
                'modelIdx': 0,
                'done': true,
                'timestamp': 1774458198,
              },
            },
          ),
        ),
        _FakeAdapter.json({}),
        _FakeAdapter.json({'task_id': 'task-legacy', 'status': true}),
        _FakeAdapter.json(
          _legacyChatPayload(
            currentId: 'assistant-1',
            historyMessages: const {
              'user-0': {
                'id': 'user-0',
                'parentId': null,
                'childrenIds': ['assistant-0'],
                'role': 'user',
                'content': 'before',
                'models': ['gpt-test'],
                'timestamp': 1774458197,
              },
              'assistant-0': {
                'id': 'assistant-0',
                'parentId': 'user-0',
                'childrenIds': ['user-1'],
                'role': 'assistant',
                'content': 'before answer',
                'model': 'gpt-test',
                'modelName': 'gpt-test',
                'modelIdx': 0,
                'done': true,
                'timestamp': 1774458198,
              },
              'user-1': {
                'id': 'user-1',
                'parentId': 'assistant-0',
                'childrenIds': ['assistant-1'],
                'role': 'user',
                'content': 'hello',
                'models': ['gpt-test'],
                'timestamp': 1774458297,
              },
              'assistant-1': {
                'id': 'assistant-1',
                'parentId': 'user-1',
                'childrenIds': [],
                'role': 'assistant',
                'content': 'legacy reply',
                'model': 'gpt-test',
                'modelName': 'gpt-test',
                'modelIdx': 0,
                'done': true,
                'timestamp': 1774458298,
              },
            },
          ),
        ),
        _FakeAdapter.json({}),
        _FakeAdapter.json({'task_id': 'task-cached', 'status': true}),
      ]);
      final api = _buildApiServiceForTest(adapter);

      final firstSession = await api.sendMessageSession(
        messages: _minimalMessages,
        model: _model,
        conversationId: 'chat-1',
        responseMessageId: 'assistant-1',
        parentId: 'assistant-0',
        userMessage: userMessage1,
      );

      final secondSession = await api.sendMessageSession(
        messages: _minimalMessages,
        model: _model,
        conversationId: 'chat-1',
        responseMessageId: 'assistant-2',
        parentId: 'assistant-1',
        userMessage: userMessage2,
      );

      check(firstSession.transport).equals(ChatCompletionTransport.taskSocket);
      check(firstSession.taskId).equals('task-legacy');
      check(secondSession.transport).equals(ChatCompletionTransport.taskSocket);
      check(secondSession.taskId).equals('task-cached');
      check(adapter.requests).has((it) => it.length, 'length').equals(7);

      final modernBody = adapter.requests[0].data as Map<String, dynamic>;
      check(adapter.requests[0].path).equals('/api/chat/completions');
      check(modernBody['parent_id']).equals('assistant-0');
      check(
        modernBody['user_message'],
      ).isA<Map<String, dynamic>>().deepEquals(userMessage1);
      check(modernBody.containsKey('parent_message')).isFalse();

      check(adapter.requests[1].method).equals('GET');
      check(adapter.requests[1].path).equals('/api/v1/chats/chat-1');
      check(adapter.requests[2].method).equals('POST');
      check(adapter.requests[2].path).equals('/api/v1/chats/chat-1');
      final firstPersistBody = adapter.requests[2].data as Map<String, dynamic>;
      final firstPersistChat = firstPersistBody['chat'] as Map<String, dynamic>;
      final firstPersistHistory =
          firstPersistChat['history'] as Map<String, dynamic>;
      final firstPersistMessages =
          firstPersistHistory['messages'] as Map<String, dynamic>;
      final firstPersistUser =
          firstPersistMessages['user-1'] as Map<String, dynamic>;
      final firstPersistAssistant =
          firstPersistMessages['assistant-1'] as Map<String, dynamic>;
      final firstPersistParent =
          firstPersistMessages['assistant-0'] as Map<String, dynamic>;
      check(firstPersistHistory['currentId']).equals('assistant-1');
      check(
        firstPersistParent['childrenIds'],
      ).isA<List<dynamic>>().deepEquals(const ['user-1']);
      check(
        firstPersistUser['childrenIds'],
      ).isA<List<dynamic>>().deepEquals(const ['assistant-1']);
      check(firstPersistAssistant['parentId']).equals('user-1');
      check(firstPersistAssistant['role']).equals('assistant');
      check(firstPersistAssistant['content']).equals('');
      check(firstPersistAssistant.containsKey('done')).isFalse();
      check(
        (firstPersistChat['messages'] as List<dynamic>)
            .map((entry) => (entry as Map<String, dynamic>)['id'])
            .toList(growable: false),
      ).deepEquals(const ['user-0', 'assistant-0', 'user-1', 'assistant-1']);

      final legacyRetryBody = adapter.requests[3].data as Map<String, dynamic>;
      check(adapter.requests[3].path).equals('/api/chat/completions');
      check(legacyRetryBody['parent_id']).equals('user-1');
      check(
        legacyRetryBody['parent_message'],
      ).isA<Map<String, dynamic>>().deepEquals(userMessage1);
      check(legacyRetryBody.containsKey('user_message')).isFalse();

      check(adapter.requests[4].method).equals('GET');
      check(adapter.requests[4].path).equals('/api/v1/chats/chat-1');
      check(adapter.requests[5].method).equals('POST');
      check(adapter.requests[5].path).equals('/api/v1/chats/chat-1');
      final secondPersistBody =
          adapter.requests[5].data as Map<String, dynamic>;
      final secondPersistChat =
          secondPersistBody['chat'] as Map<String, dynamic>;
      final secondPersistHistory =
          secondPersistChat['history'] as Map<String, dynamic>;
      final secondPersistMessages =
          secondPersistHistory['messages'] as Map<String, dynamic>;
      final secondPersistParent =
          secondPersistMessages['assistant-1'] as Map<String, dynamic>;
      final secondPersistUser =
          secondPersistMessages['user-2'] as Map<String, dynamic>;
      final secondPersistAssistant =
          secondPersistMessages['assistant-2'] as Map<String, dynamic>;
      check(secondPersistHistory['currentId']).equals('assistant-2');
      check(
        secondPersistParent['childrenIds'],
      ).isA<List<dynamic>>().deepEquals(const ['user-2']);
      check(
        secondPersistUser['childrenIds'],
      ).isA<List<dynamic>>().deepEquals(const ['assistant-2']);
      check(secondPersistAssistant['parentId']).equals('user-2');
      check(secondPersistAssistant.containsKey('done')).isFalse();
      check(
        (secondPersistChat['messages'] as List<dynamic>)
            .map((entry) => (entry as Map<String, dynamic>)['id'])
            .toList(growable: false),
      ).deepEquals(const [
        'user-0',
        'assistant-0',
        'user-1',
        'assistant-1',
        'user-2',
        'assistant-2',
      ]);

      final cachedLegacyBody = adapter.requests[6].data as Map<String, dynamic>;
      check(adapter.requests[6].path).equals('/api/chat/completions');
      check(cachedLegacyBody['parent_id']).equals('user-2');
      check(
        cachedLegacyBody['parent_message'],
      ).isA<Map<String, dynamic>>().deepEquals(userMessage2);
      check(cachedLegacyBody.containsKey('user_message')).isFalse();
    });
  });

  group('TLS handshake detection', () {
    test('detects handshake exception payloads', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/health'),
        type: DioExceptionType.unknown,
        error: HandshakeException('alert bad certificate'),
      );

      check(isTlsHandshakeFailureForTest(error)).isTrue();
    });

    test('detects certificate verify errors from message text', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/health'),
        type: DioExceptionType.unknown,
        error: 'CERTIFICATE_VERIFY_FAILED',
      );

      check(isTlsHandshakeFailureForTest(error)).isTrue();
    });

    test('detects mTLS setup failures from message text', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/health'),
        type: DioExceptionType.unknown,
        error: 'mTLS certificate setup failed',
      );

      check(isTlsHandshakeFailureForTest(error)).isTrue();
    });

    test('ignores ordinary connection errors', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/health'),
        type: DioExceptionType.connectionError,
        error: 'connection refused',
      );

      check(isTlsHandshakeFailureForTest(error)).isFalse();
    });
  });

  // -----------------------------------------------------------------------
  // Payload builder
  // -----------------------------------------------------------------------
  group('buildChatCompletionPayloadForTest', () {
    test('preserves OpenWebUI request shape', () {
      final api = _buildApiServiceForTest(_FakeAdapter.json({}));

      final payload = api.buildChatCompletionPayloadForTest(
        messages: [
          {'role': 'user', 'content': 'hello'},
        ],
        model: 'gpt-4',
        conversationId: 'chat-1',
        messageId: 'msg-1',
        sessionId: 'sess-1',
      );

      check(payload['model'] as String).equals('gpt-4');
      check(payload['stream'] as bool).isTrue();
      check(payload['chat_id'] as String).equals('chat-1');
      check(payload['id'] as String).equals('msg-1');
      check(payload['session_id'] as String).equals('sess-1');
      check(payload['messages']).isA<List>();
      check(payload['params']).isA<Map<String, dynamic>>().deepEquals({});
      check(payload['tool_servers'])
          .isA<List<Map<String, dynamic>>>()
          .deepEquals(const <Map<String, dynamic>>[]);
      check(payload['features']).isA<Map<String, dynamic>>().deepEquals({
        'voice': false,
        'web_search': false,
        'image_generation': false,
        'code_interpreter': false,
      });
      check(payload.containsKey('parent_id')).isTrue();
      check(payload['parent_id']).isNull();
      check(payload['user_message']).isNotNull();
    });

    test('includes features with image_generation when enabled', () {
      final api = _buildApiServiceForTest(_FakeAdapter.json({}));

      final payload = api.buildChatCompletionPayloadForTest(
        messages: [
          {'role': 'user', 'content': 'draw a cat'},
        ],
        model: 'gpt-4',
        messageId: 'msg-img',
        sessionId: 'sess-img',
        enableImageGeneration: true,
      );

      check(payload['features']).isA<Map<String, dynamic>>().deepEquals({
        'voice': false,
        'web_search': false,
        'image_generation': true,
        'code_interpreter': false,
      });
    });

    test('keeps disabled feature flags for pipe compatibility', () {
      final api = _buildApiServiceForTest(_FakeAdapter.json({}));

      final payload = api.buildChatCompletionPayloadForTest(
        messages: [
          {'role': 'user', 'content': 'hello'},
        ],
        model: 'gpt-4',
        messageId: 'msg-plain',
        sessionId: 'sess-plain',
      );

      check(payload['features']).isA<Map<String, dynamic>>().deepEquals({
        'voice': false,
        'web_search': false,
        'image_generation': false,
        'code_interpreter': false,
      });
    });

    test('treats content_type image files as image_url content', () {
      final api = _buildApiServiceForTest(_FakeAdapter.json({}));

      final payload = api.buildChatCompletionPayloadForTest(
        messages: const [
          {
            'role': 'user',
            'content': 'describe this',
            'files': [
              {
                'type': 'file',
                'content_type': 'image/png',
                'url': 'file-image-id',
              },
            ],
          },
        ],
        model: 'gpt-4',
        messageId: 'msg-img-file',
        sessionId: 'sess-img-file',
      );

      final messages = payload['messages'] as List<dynamic>;
      final first = messages.first as Map<String, dynamic>;
      check(first['content']).isA<List<dynamic>>();
      final content = first['content'] as List<dynamic>;
      check(content[0]).isA<Map<String, dynamic>>().deepEquals({
        'type': 'text',
        'text': 'describe this',
      });
      check(content[1]).isA<Map<String, dynamic>>().deepEquals({
        'type': 'image_url',
        'image_url': {'url': 'file-image-id'},
      });
      check(payload.containsKey('files')).isFalse();
    });

    test('merges explicit top-level files and filters image duplicates', () {
      final api = _buildApiServiceForTest(_FakeAdapter.json({}));

      final payload = api.buildChatCompletionPayloadForTest(
        messages: const [
          {
            'role': 'user',
            'content': 'Review this reference',
            'files': [
              {
                'type': 'file',
                'id': 'doc-1',
                'url': 'doc-1',
                'name': 'spec.pdf',
                'content_type': 'application/pdf',
              },
            ],
          },
        ],
        model: 'gpt-4',
        messageId: 'msg-request-files',
        sessionId: 'sess-request-files',
        files: const [
          {
            'type': 'file',
            'id': 'doc-1',
            'url': 'doc-1',
            'name': 'spec.pdf',
            'content_type': 'application/pdf',
          },
          {'type': 'note', 'id': 'note-1', 'name': 'scratch-note'},
          {
            'type': 'image',
            'id': 'image-1',
            'url': 'image-1',
            'content_type': 'image/png',
          },
        ],
      );

      check(payload['files']).isA<List<dynamic>>().deepEquals(const [
        {
          'type': 'file',
          'id': 'doc-1',
          'url': 'doc-1',
          'name': 'spec.pdf',
          'content_type': 'application/pdf',
        },
        {'type': 'note', 'id': 'note-1', 'name': 'scratch-note'},
      ]);
    });

    test('preserves output items on outbound messages', () {
      final api = _buildApiServiceForTest(_FakeAdapter.json({}));

      final payload = api.buildChatCompletionPayloadForTest(
        messages: const [
          {
            'role': 'assistant',
            'content': 'Used a tool',
            'output': [
              {'type': 'message', 'content': 'Used a tool'},
              {'type': 'reasoning', 'content': 'tool reasoning'},
            ],
          },
        ],
        model: 'gpt-4',
        messageId: 'msg-output',
        sessionId: 'sess-output',
      );

      final messages = payload['messages'] as List<dynamic>;
      final first = messages.first as Map<String, dynamic>;
      check(first['output']).isA<List<dynamic>>().deepEquals(const [
        {'type': 'message', 'content': 'Used a tool'},
        {'type': 'reasoning', 'content': 'tool reasoning'},
      ]);
    });

    test('includes terminal_id when provided', () {
      final api = _buildApiServiceForTest(_FakeAdapter.json({}));

      final payload = api.buildChatCompletionPayloadForTest(
        messages: const [
          {'role': 'system', 'content': 'You can use a terminal.'},
        ],
        model: 'gpt-4',
        messageId: 'msg-terminal',
        sessionId: 'sess-terminal',
        terminalId: 'terminal-1',
      );

      check(payload['terminal_id'] as String).equals('terminal-1');
    });

    test('omits messages key when request history is empty', () {
      final api = _buildApiServiceForTest(_FakeAdapter.json({}));

      final payload = api.buildChatCompletionPayloadForTest(
        messages: const [],
        model: 'gpt-4',
        messageId: 'msg-empty',
        sessionId: 'sess-empty',
      );

      check(payload.containsKey('messages')).isFalse();
    });

    test('preserves pipe-friendly empty collections and user payload', () {
      final api = _buildApiServiceForTest(_FakeAdapter.json({}));
      const userMessage = <String, dynamic>{
        'id': 'user-1',
        'parentId': 'assistant-0',
        'childrenIds': ['assistant-1'],
        'role': 'user',
        'content': 'Tell me another joke',
        'models': ['pipe-model'],
        'timestamp': 1774458297,
      };
      const variables = <String, dynamic>{
        '{{USER_NAME}}': 'cogwheel',
        '{{USER_EMAIL}}': 'cogwheel@cogwheel.app',
        '{{USER_LOCATION}}': 'Unknown',
      };
      const backgroundTasks = <String, dynamic>{'follow_up_generation': true};
      const modelItem = <String, dynamic>{
        'id': 'pipe-model',
        'pipe': {'type': 'pipe'},
      };

      final payload = api.buildChatCompletionPayloadForTest(
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        model: 'pipe-model',
        messageId: 'assistant-1',
        sessionId: 'sess-pipe',
        conversationId: 'chat-pipe',
        modelItem: modelItem,
        toolServers: const <Map<String, dynamic>>[],
        backgroundTasks: backgroundTasks,
        userSettings: const {
          'ui': {'memory': true},
        },
        parentId: 'assistant-0',
        userMessage: userMessage,
        variables: variables,
      );

      check(payload['params']).isA<Map<String, dynamic>>().deepEquals({});
      check(payload['tool_servers'])
          .isA<List<Map<String, dynamic>>>()
          .deepEquals(const <Map<String, dynamic>>[]);
      check(
        payload['background_tasks'],
      ).isA<Map<String, dynamic>>().deepEquals(backgroundTasks);
      check(payload['parent_id'] as String).equals('assistant-0');
      check(
        payload['user_message'],
      ).isA<Map<String, dynamic>>().deepEquals(userMessage);
      check(
        payload['variables'],
      ).isA<Map<String, dynamic>>().deepEquals(variables);
      check(
        payload['model_item'],
      ).isA<Map<String, dynamic>>().deepEquals(modelItem);
      check(payload['features']).isA<Map<String, dynamic>>().deepEquals({
        'voice': false,
        'web_search': false,
        'image_generation': false,
        'code_interpreter': false,
        'memory': true,
      });
    });

    test('supports the legacy pre-v0.9 chat metadata shape', () {
      final api = _buildApiServiceForTest(_FakeAdapter.json({}));
      const userMessage = <String, dynamic>{
        'id': 'user-1',
        'parentId': 'assistant-0',
        'role': 'user',
        'content': 'hello',
      };

      final payload = api.buildChatCompletionPayloadForTest(
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        model: 'gpt-4',
        messageId: 'assistant-1',
        sessionId: 'sess-legacy',
        conversationId: 'chat-legacy',
        parentId: 'assistant-0',
        userMessage: userMessage,
        useLegacyChatMetadata: true,
      );

      check(payload['parent_id']).equals('user-1');
      check(
        payload['parent_message'],
      ).isA<Map<String, dynamic>>().deepEquals(userMessage);
      check(payload.containsKey('user_message')).isFalse();
    });
  });

  // -----------------------------------------------------------------------
  // Conversation persistence payloads
  // -----------------------------------------------------------------------
  group('conversation persistence payloads', () {
    test(
      'syncConversationMessages omits done for streaming assistant placeholders',
      () async {
        final adapter = _FakeAdapter.json({});
        final api = _buildApiServiceForTest(adapter);

        final messages = [
          ChatMessage(
            id: 'user-1',
            role: 'user',
            content: 'hello',
            timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
          ),
          ChatMessage(
            id: 'asst-1',
            role: 'assistant',
            content: '',
            timestamp: DateTime.fromMillisecondsSinceEpoch(1700000001000),
            model: 'gpt-4',
            isStreaming: true,
          ),
        ];

        await api.syncConversationMessages('conv-1', messages, model: 'gpt-4');

        final request = adapter.lastRequest!;
        check(request.path).equals('/api/v1/chats/conv-1');

        final body = request.data as Map<String, dynamic>;
        final chat = body['chat'] as Map<String, dynamic>;
        final serializedMessages =
            chat['messages'] as List<Map<String, dynamic>>;
        final history = chat['history'] as Map<String, dynamic>;
        final historyMessages = history['messages'] as Map<String, dynamic>;

        final serializedAssistant = serializedMessages.last;
        final historyAssistant =
            historyMessages['asst-1'] as Map<String, dynamic>;

        check(serializedAssistant.containsKey('done')).isFalse();
        check(historyAssistant.containsKey('done')).isFalse();
        check(history['currentId']).equals('asst-1');
      },
    );

    test(
      'syncConversationMessages keeps done for completed assistant messages',
      () async {
        final adapter = _FakeAdapter.json({});
        final api = _buildApiServiceForTest(adapter);

        final messages = [
          ChatMessage(
            id: 'user-1',
            role: 'user',
            content: 'hello',
            timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
          ),
          ChatMessage(
            id: 'asst-1',
            role: 'assistant',
            content: 'Hi there',
            timestamp: DateTime.fromMillisecondsSinceEpoch(1700000001000),
            model: 'gpt-4',
          ),
        ];

        await api.syncConversationMessages('conv-1', messages, model: 'gpt-4');

        final body = adapter.lastRequest!.data as Map<String, dynamic>;
        final chat = body['chat'] as Map<String, dynamic>;
        final serializedMessages =
            chat['messages'] as List<Map<String, dynamic>>;
        final history = chat['history'] as Map<String, dynamic>;
        final historyMessages = history['messages'] as Map<String, dynamic>;

        final serializedAssistant = serializedMessages.last;
        final historyAssistant =
            historyMessages['asst-1'] as Map<String, dynamic>;

        check(serializedAssistant['done']).equals(true);
        check(historyAssistant['done']).equals(true);
      },
    );

    test(
      'createConversation omits done for streaming assistant placeholders',
      () async {
        final adapter = _FakeAdapter.json({
          'id': 'conv-1',
          'title': 'New Chat',
          'created_at': 1700000000,
          'updated_at': 1700000001,
          'chat': {
            'models': ['gpt-4'],
            'history': {
              'currentId': 'asst-1',
              'messages': {
                'user-1': {
                  'id': 'user-1',
                  'role': 'user',
                  'content': 'hello',
                  'timestamp': 1700000000,
                  'childrenIds': ['asst-1'],
                },
                'asst-1': {
                  'id': 'asst-1',
                  'role': 'assistant',
                  'content': '',
                  'parentId': 'user-1',
                  'timestamp': 1700000001,
                  'childrenIds': [],
                },
              },
            },
            'messages': [
              {
                'id': 'user-1',
                'role': 'user',
                'content': 'hello',
                'timestamp': 1700000000,
              },
              {
                'id': 'asst-1',
                'role': 'assistant',
                'content': '',
                'timestamp': 1700000001,
              },
            ],
          },
        });
        final api = _buildApiServiceForTest(adapter);

        await api.createConversation(
          title: 'New Chat',
          model: 'gpt-4',
          messages: [
            ChatMessage(
              id: 'user-1',
              role: 'user',
              content: 'hello',
              timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
            ),
            ChatMessage(
              id: 'asst-1',
              role: 'assistant',
              content: '',
              timestamp: DateTime.fromMillisecondsSinceEpoch(1700000001000),
              model: 'gpt-4',
              isStreaming: true,
            ),
          ],
        );

        final request = adapter.lastRequest!;
        check(request.path).equals('/api/v1/chats/new');

        final body = request.data as Map<String, dynamic>;
        final chat = body['chat'] as Map<String, dynamic>;
        final serializedMessages =
            chat['messages'] as List<Map<String, dynamic>>;
        final history = chat['history'] as Map<String, dynamic>;
        final historyMessages = history['messages'] as Map<String, dynamic>;

        final serializedAssistant = serializedMessages.last;
        final historyAssistant =
            historyMessages['asst-1'] as Map<String, dynamic>;

        check(serializedAssistant.containsKey('done')).isFalse();
        check(historyAssistant.containsKey('done')).isFalse();
      },
    );
  });

  // -----------------------------------------------------------------------
  // Legacy cancel / cancel-map widening
  // -----------------------------------------------------------------------
  group('cancel-map widening', () {
    test(
      'cancelStreamingMessage still works after cancel-map widening',
      () async {
        final adapter = _FakeAdapter.json({'task_id': 'task-c'});
        final api = _buildApiServiceForTest(adapter);

        var invoked = false;
        api.registerLegacyCancelActionForTest('msg-cancel', () async {
          invoked = true;
        });

        api.cancelStreamingMessage('msg-cancel');

        // Allow microtask to complete
        await Future<void>.delayed(Duration.zero);

        check(invoked).isTrue();
      },
    );
  });

  // -----------------------------------------------------------------------
  // generateImage API contract
  // -----------------------------------------------------------------------
  group('generateImage', () {
    test('POST body uses only OpenWebUI-compatible keys', () async {
      final adapter = _FakeAdapter.json({
        'images': [
          {'url': 'https://example.com/img.png'},
        ],
      });
      final api = _buildApiServiceForTest(adapter);

      await api.generateImage(
        prompt: 'a sunset over mountains',
        model: 'dall-e-3',
        size: '1024x1024',
        n: 2,
        steps: 30,
        negativePrompt: 'blurry',
      );

      final request = adapter.lastRequest!;
      check(request.path).equals('/api/v1/images/generations');

      final body = request.data as Map<String, dynamic>;
      check(body['prompt'] as String).equals('a sunset over mountains');
      check(body['model'] as String).equals('dall-e-3');
      check(body['size'] as String).equals('1024x1024');
      check(body['n'] as int).equals(2);
      check(body['steps'] as int).equals(30);
      check(body['negative_prompt'] as String).equals('blurry');

      // Must NOT contain non-OpenWebUI keys
      check(body.containsKey('width')).isFalse();
      check(body.containsKey('height')).isFalse();
      check(body.containsKey('guidance')).isFalse();
    });

    test('omits optional keys when not provided', () async {
      final adapter = _FakeAdapter.json({
        'images': [
          {'url': 'https://example.com/img.png'},
        ],
      });
      final api = _buildApiServiceForTest(adapter);

      await api.generateImage(prompt: 'a cat');

      final body = adapter.lastRequest!.data as Map<String, dynamic>;
      check(body.keys.toList()).deepEquals(['prompt']);
    });
  });

  group('getChannels feature flag', () {
    test('200 with list → returns (channels, true)', () async {
      final adapter = _FakeAdapter(
        statusCode: 200,
        headers: {
          'content-type': ['application/json; charset=utf-8'],
        },
        bodyBytes: utf8.encode(
          '[{"id":"ch1","name":"general","updated_at":0}]',
        ),
      );
      final api = _buildApiServiceForTest(adapter);

      final (channels, enabled) = await api.getChannels();

      check(channels).length.equals(1);
      check(channels.first['id']).equals('ch1');
      check(enabled).isTrue();
    });

    test('403 → returns ([], false)', () async {
      final adapter = _FakeAdapter(
        statusCode: 403,
        headers: {
          'content-type': ['application/json; charset=utf-8'],
        },
        bodyBytes: utf8.encode('{"detail":"Not allowed"}'),
      );
      final api = _buildApiServiceForTest(adapter);

      final (channels, enabled) = await api.getChannels();

      check(channels).isEmpty();
      check(enabled).isFalse();
    });

    test('401 → returns ([], false)', () async {
      final adapter = _FakeAdapter(
        statusCode: 401,
        headers: {
          'content-type': ['application/json; charset=utf-8'],
        },
        bodyBytes: utf8.encode('{"detail":"Unauthorized"}'),
      );
      final api = _buildApiServiceForTest(adapter);

      final (channels, enabled) = await api.getChannels();

      check(channels).isEmpty();
      check(enabled).isFalse();
    });

    test('500 → rethrows DioException', () async {
      final adapter = _FakeAdapter(
        statusCode: 500,
        headers: {
          'content-type': ['application/json; charset=utf-8'],
        },
        bodyBytes: utf8.encode('{"detail":"Server error"}'),
      );
      final api = _buildApiServiceForTest(adapter);

      await check(api.getChannels()).throws<DioException>();
    });
  });
}
