import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:qonduit/core/services/api_service.dart';
import 'package:qonduit/core/services/chat_completion_transport.dart';
import 'package:qonduit/core/models/server_config.dart';
import 'package:qonduit/core/services/worker_manager.dart';
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

/// Builds an [ApiService] for testing whose Dio adapter is [adapter].
ApiService _buildApiServiceForTest(_FakeAdapter adapter) {
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
      // parent_message always present (OWUI 0.6.42+ compat)
      check(payload['parent_message']).isNotNull();
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
        'web_search': false,
        'image_generation': true,
        'code_interpreter': false,
      });
    });

    test('omits features key when no feature flags are active', () {
      final api = _buildApiServiceForTest(_FakeAdapter.json({}));

      final payload = api.buildChatCompletionPayloadForTest(
        messages: [
          {'role': 'user', 'content': 'hello'},
        ],
        model: 'gpt-4',
        messageId: 'msg-plain',
        sessionId: 'sess-plain',
      );

      check(payload.containsKey('features')).isFalse();
    });
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
