import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/services/ollama_adapter.dart';
import 'package:conduit/features/direct_connections/services/openai_compatible_adapter.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'OpenAI adapter discovers models at the exact configured API root',
    () async {
      final http = _QueuedAdapter([
        _Reply.json({
          'object': 'list',
          'data': [
            {'id': 'gpt-test', 'name': 'GPT Test'},
            {'id': 'gpt-test'},
          ],
        }),
      ]);
      final adapter = OpenAiCompatibleAdapter(
        dioFactory: (_) => _dio(http),
        closeClients: false,
      );

      final models = await adapter.listModels(_openAiProfile());

      expect(models, hasLength(1));
      expect(models.single.id, 'gpt-test');
      expect(models.single.isMultimodal, isTrue);
      expect(http.requests.single.uri.toString(), 'https://api.test/v1/models');
      expect(http.requests.single.followRedirects, isFalse);
      expect(http.requests.single.headers['Authorization'], 'Bearer secret');
    },
  );

  test('OpenAI adapter normalizes SSE and owns request routing keys', () async {
    final sse = utf8.encode(
      'data: {"choices":[{"delta":{"reasoning_content":"think","content":"Hi 你"}}]}\n\n'
      'data: {"usage":{"total_tokens":3}}\n\n'
      'data: [DONE]\n\n',
    );
    final runeSplit = sse.indexOf(0xE4) + 1;
    final http = _QueuedAdapter([
      _Reply.stream([
        sse.sublist(0, runeSplit),
        sse.sublist(runeSplit),
      ], contentType: 'text/event-stream'),
    ]);
    final adapter = OpenAiCompatibleAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );
    final run = adapter.startCompletion(
      _openAiProfile(),
      DirectCompletionRequest(
        remoteModelId: 'trusted-model',
        messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
        parameters: const {
          'model': 'forged-model',
          'stream': false,
          'temperature': 0.2,
        },
      ),
    );

    final events = await run.events.toList();
    await run.done;

    expect(events.whereType<DirectReasoningDelta>().single.content, 'think');
    expect(events.whereType<DirectContentDelta>().single.content, 'Hi 你');
    expect(
      events.whereType<DirectUsageUpdate>().single.usage['total_tokens'],
      3,
    );
    expect(events.whereType<DirectStreamDone>(), hasLength(1));
    final request = http.requests.single;
    expect(request.uri.toString(), 'https://api.test/v1/chat/completions');
    expect((request.data as Map)['model'], 'trusted-model');
    expect((request.data as Map)['stream'], isTrue);
    expect((request.data as Map)['temperature'], 0.2);
  });

  test('OpenAI adapter normalizes a non-stream JSON completion', () async {
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'whole answer'},
              },
            ],
            'usage': {'total_tokens': 4},
          }),
        ),
      ], contentType: 'application/json'),
    ]);
    final adapter = OpenAiCompatibleAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );
    final run = adapter.startCompletion(
      _openAiProfile(),
      DirectCompletionRequest(
        remoteModelId: 'model',
        messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
      ),
    );

    final events = await run.events.toList();

    expect(
      events.whereType<DirectContentDelta>().single.content,
      'whole answer',
    );
    expect(
      events.whereType<DirectUsageUpdate>().single.usage['total_tokens'],
      4,
    );
    expect(events.whereType<DirectStreamDone>(), hasLength(1));
  });

  test(
    'OpenAI adapter rejects JSON without usable completion content',
    () async {
      final http = _QueuedAdapter([
        _Reply.json({
          'choices': [
            {
              'message': {'content': ''},
            },
          ],
          'usage': {'total_tokens': 4},
        }),
      ]);
      final adapter = OpenAiCompatibleAdapter(
        dioFactory: (_) => _dio(http),
        closeClients: false,
      );
      final run = adapter.startCompletion(
        _openAiProfile(),
        DirectCompletionRequest(
          remoteModelId: 'model',
          messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
        ),
      );

      final events = await run.events.toList();

      expect(events.whereType<DirectContentDelta>(), isEmpty);
      expect(
        events.whereType<DirectStreamError>().single.message,
        contains('invalid response'),
      );
      expect(events.whereType<DirectStreamDone>(), isEmpty);
    },
  );

  test('manual model ids bypass both adapter HTTP factories', () async {
    var openAiFactoryCalls = 0;
    var ollamaFactoryCalls = 0;
    final openAi = OpenAiCompatibleAdapter(
      dioFactory: (_) {
        openAiFactoryCalls++;
        return Dio();
      },
    );
    final ollama = OllamaAdapter(
      dioFactory: (_) {
        ollamaFactoryCalls++;
        return Dio();
      },
    );

    final openAiModels = await openAi.listModels(
      _openAiProfile(manualModelIds: const ['manual-a', 'manual-b']),
    );
    final ollamaModels = await ollama.listModels(
      _ollamaProfile(manualModelIds: const ['manual-vision']),
    );

    expect(openAiFactoryCalls, 0);
    expect(ollamaFactoryCalls, 0);
    expect(openAiModels.map((model) => model.id), ['manual-a', 'manual-b']);
    expect(ollamaModels.single.id, 'manual-vision');
    expect(openAiModels.every((model) => model.isMultimodal), isTrue);
    expect(ollamaModels.single.isMultimodal, isTrue);
  });

  test(
    'manual OpenAI probe performs a non-generative liveness request',
    () async {
      final http = _QueuedAdapter([
        _Reply.stream(
          const [],
          contentType: 'application/json',
          statusCode: 405,
        ),
      ]);
      final adapter = OpenAiCompatibleAdapter(
        dioFactory: (_) => _dio(http),
        closeClients: false,
      );

      final result = await adapter.probe(
        _openAiProfile(manualModelIds: const ['manual-a', 'manual-b']),
      );

      expect(result.reachable, isTrue);
      expect(result.modelCount, 2);
      expect(http.requests, hasLength(1));
      expect(http.requests.single.method, 'HEAD');
      expect(
        http.requests.single.uri.toString(),
        'https://api.test/v1/chat/completions',
      );
      expect(http.requests.single.data, isNull);
    },
  );

  test('manual OpenAI probe reports authentication failure', () async {
    final http = _QueuedAdapter([
      _Reply.stream(const [], contentType: 'application/json', statusCode: 401),
    ]);
    final adapter = OpenAiCompatibleAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );

    final result = await adapter.probe(
      _openAiProfile(manualModelIds: const ['manual-a']),
    );

    expect(result.reachable, isFalse);
    expect(result.message, contains('HTTP 401'));
    expect(http.requests, hasLength(1));
  });

  test('manual Ollama probe uses api/version liveness endpoint', () async {
    final http = _QueuedAdapter([
      _Reply.json({'version': '0.6.0'}),
    ]);
    final adapter = OllamaAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );

    final result = await adapter.probe(
      _ollamaProfile(manualModelIds: const ['manual-vision']),
    );

    expect(result.reachable, isTrue);
    expect(result.modelCount, 1);
    expect(http.requests, hasLength(1));
    expect(http.requests.single.method, 'GET');
    expect(
      http.requests.single.uri.toString(),
      'http://localhost:11434/api/version',
    );
  });

  test(
    'manual Ollama probe cannot succeed on an unreachable provider',
    () async {
      final http = _ThrowingAdapter(
        DioException(
          requestOptions: RequestOptions(path: 'api/version'),
          type: DioExceptionType.connectionError,
          message: 'connection refused',
        ),
      );
      final adapter = OllamaAdapter(
        dioFactory: (_) => _dio(http),
        closeClients: false,
      );

      final result = await adapter.probe(
        _ollamaProfile(manualModelIds: const ['manual-vision']),
      );

      expect(result.reachable, isFalse);
      expect(result.message, contains('connect'));
      expect(http.requests, hasLength(1));
    },
  );

  test('OpenAI adapter treats SSE EOF without DONE as an error', () async {
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode('data: {"choices":[{"delta":{"content":"partial"}}]}\n\n'),
      ], contentType: 'text/event-stream'),
    ]);
    final adapter = OpenAiCompatibleAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );
    final run = adapter.startCompletion(
      _openAiProfile(),
      DirectCompletionRequest(
        remoteModelId: 'model',
        messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
      ),
    );

    final events = await run.events.toList();

    expect(events.whereType<DirectContentDelta>().single.content, 'partial');
    expect(
      events.whereType<DirectStreamError>().single.message,
      contains('completion marker'),
    );
    expect(events.whereType<DirectStreamDone>(), isEmpty);
  });

  test('OpenAI adapter rejects cumulative streamed text over budget', () async {
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode(
          'data: {"choices":[{"delta":{"content":"12345"}}]}\n\n'
          'data: [DONE]\n\n',
        ),
      ], contentType: 'text/event-stream'),
    ]);
    final adapter = OpenAiCompatibleAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
      maxStreamCharacters: 4,
    );
    final run = adapter.startCompletion(
      _openAiProfile(),
      DirectCompletionRequest(
        remoteModelId: 'model',
        messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
      ),
    );

    final events = await run.events.toList();

    expect(events.whereType<DirectContentDelta>(), isEmpty);
    expect(
      events.whereType<DirectStreamError>().single.message,
      contains('size limit'),
    );
    expect(events.whereType<DirectStreamDone>(), isEmpty);
  });

  test(
    'completion settles when cancelled before the stream is listened',
    () async {
      final http = _QueuedAdapter([
        _Reply.stream([
          utf8.encode('data: [DONE]\n\n'),
        ], contentType: 'text/event-stream'),
      ]);
      final adapter = OpenAiCompatibleAdapter(
        dioFactory: (_) => _dio(http),
        closeClients: false,
      );
      final run = adapter.startCompletion(
        _openAiProfile(),
        DirectCompletionRequest(
          remoteModelId: 'model',
          messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
        ),
      );

      await run.cancel().timeout(const Duration(seconds: 1));

      expect(run.isCancelled, isTrue);
    },
  );

  test('Ollama adapter discovers and parses native NDJSON chat', () async {
    final http = _QueuedAdapter([
      _Reply.json({
        'models': [
          {
            'name': 'llava:latest',
            'size': 42,
            'details': {
              'families': ['llama', 'CLIP'],
            },
          },
        ],
      }),
      _Reply.json({
        'capabilities': ['completion', 'vision'],
      }),
      _Reply.stream([
        utf8.encode(
          '{"thinking":"duplicate","message":{"thinking":"hmm","content":"Hi"}}\n',
        ),
        utf8.encode(
          '{"message":{"content":"!"},"done":true,"prompt_eval_count":2,"eval_count":3}',
        ),
      ], contentType: 'application/x-ndjson'),
    ]);
    final adapter = OllamaAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );
    final profile = _ollamaProfile();

    final models = await adapter.listModels(profile);
    final run = adapter.startCompletion(
      profile,
      DirectCompletionRequest(
        remoteModelId: models.single.id,
        messages: [
          DirectChatMessage(
            role: 'user',
            parts: const [
              DirectTextPart('describe'),
              DirectImagePart('data:image/png;base64,aW1hZ2U='),
            ],
          ),
        ],
      ),
    );
    final events = await run.events.toList();

    expect(models.single.isMultimodal, isTrue);
    expect(
      http.requests.first.uri.toString(),
      'http://localhost:11434/api/tags',
    );
    expect(http.requests[1].uri.toString(), 'http://localhost:11434/api/show');
    expect((http.requests[1].data as Map)['model'], 'llava:latest');
    expect(
      http.requests.last.uri.toString(),
      'http://localhost:11434/api/chat',
    );
    expect(events.whereType<DirectReasoningDelta>().single.content, 'hmm');
    expect(
      events
          .whereType<DirectContentDelta>()
          .map((event) => event.content)
          .join(),
      'Hi!',
    );
    expect(
      events.whereType<DirectUsageUpdate>().single.usage['total_tokens'],
      5,
    );
    expect(events.whereType<DirectStreamDone>(), hasLength(1));
    final message =
        ((http.requests.last.data as Map)['messages'] as List).single as Map;
    expect(message['images'], ['aW1hZ2U=']);
  });

  test('Ollama uses api/show capabilities for gemma3 vision support', () async {
    final http = _QueuedAdapter([
      _Reply.json({
        'models': [
          {
            'name': 'text-only',
            'details': {
              'families': ['llama'],
            },
          },
          {
            'name': 'gemma3:latest',
            'details': {
              'families': ['gemma3'],
            },
          },
        ],
      }),
      _Reply.json({
        'capabilities': ['completion'],
      }),
      _Reply.json({
        'capabilities': ['completion', 'VISION'],
      }),
    ]);
    final adapter = OllamaAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );

    final models = await adapter.listModels(_ollamaProfile());

    expect(
      models.firstWhere((model) => model.id == 'text-only').isMultimodal,
      isFalse,
    );
    expect(
      models.firstWhere((model) => model.id == 'gemma3:latest').isMultimodal,
      isTrue,
    );
    expect(
      http.requests.where((request) => request.path == 'api/show'),
      hasLength(2),
    );
  });

  test(
    'Ollama enriches deduped models concurrently without reordering them',
    () async {
      final http = _QueuedAdapter([
        _Reply.json({
          'models': [
            {
              'name': 'slow-vision',
              'details': {
                'families': ['llama'],
              },
            },
            {
              'name': 'fallback-text',
              'details': {
                'capabilities': ['completion'],
              },
            },
            {
              'name': 'slow-vision',
              'details': {
                'families': ['clip'],
              },
            },
          ],
        }),
        _Reply.json({
          'capabilities': ['completion', 'vision'],
        }, delay: const Duration(milliseconds: 40)),
        _Reply.stream(
          [utf8.encode('[]')],
          contentType: 'application/json',
          delay: const Duration(milliseconds: 5),
        ),
      ]);
      final adapter = OllamaAdapter(
        dioFactory: (_) => _dio(http),
        closeClients: false,
      );

      final models = await adapter.listModels(_ollamaProfile());

      expect(models.map((model) => model.id), ['slow-vision', 'fallback-text']);
      expect(models.first.isMultimodal, isTrue);
      expect(models.last.isMultimodal, isFalse);
      final showRequests = http.requests
          .where((request) => request.path == 'api/show')
          .toList(growable: false);
      expect(showRequests.map((request) => (request.data as Map)['model']), [
        'slow-vision',
        'fallback-text',
      ]);
      expect(http.maxConcurrentShowRequests, 2);
    },
  );

  test('Ollama keeps catalog when one api/show response is invalid', () async {
    final http = _QueuedAdapter([
      _Reply.json({
        'models': [
          {
            'name': 'text-only',
            'details': {
              'families': ['llama'],
            },
          },
        ],
      }),
      _Reply.stream([utf8.encode('[]')], contentType: 'application/json'),
    ]);
    final adapter = OllamaAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );

    final models = await adapter.listModels(_ollamaProfile());

    expect(models.single.id, 'text-only');
    expect(models.single.isMultimodal, isFalse);
  });

  test('Ollama recognizes older show vision metadata', () async {
    final http = _QueuedAdapter([
      _Reply.json({
        'models': [
          {
            'name': 'legacy-vision',
            'details': {
              'families': ['llama'],
            },
          },
        ],
      }),
      _Reply.json({
        'model_info': {'legacy.vision.embedding_length': 1024},
      }),
    ]);
    final adapter = OllamaAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );

    final models = await adapter.listModels(_ollamaProfile());

    expect(models.single.isMultimodal, isTrue);
  });

  test('Ollama adapter treats NDJSON EOF without done as an error', () async {
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode('{"message":{"content":"partial"}}\n'),
      ], contentType: 'application/x-ndjson'),
    ]);
    final adapter = OllamaAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );
    final run = adapter.startCompletion(
      _ollamaProfile(),
      DirectCompletionRequest(
        remoteModelId: 'model',
        messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
      ),
    );

    final events = await run.events.toList();

    expect(events.whereType<DirectContentDelta>().single.content, 'partial');
    expect(
      events.whereType<DirectStreamError>().single.message,
      contains('done marker'),
    );
    expect(events.whereType<DirectStreamDone>(), isEmpty);
  });
}

DirectConnectionProfile _openAiProfile({
  List<String> manualModelIds = const [],
}) => DirectConnectionProfile(
  id: 'openai-one',
  name: 'OpenAI compatible',
  adapterKey: kOpenAiCompatibleAdapterKey,
  baseUrl: 'https://api.test/v1',
  apiKey: 'secret',
  manualModelIds: manualModelIds,
);

DirectConnectionProfile _ollamaProfile({
  List<String> manualModelIds = const [],
}) => DirectConnectionProfile(
  id: 'ollama-one',
  name: 'Ollama',
  adapterKey: kOllamaAdapterKey,
  baseUrl: 'http://localhost:11434',
  manualModelIds: manualModelIds,
);

Dio _dio(HttpClientAdapter adapter) {
  final dio = Dio();
  dio.httpClientAdapter = adapter;
  return dio;
}

final class _QueuedAdapter implements HttpClientAdapter {
  _QueuedAdapter(this._replies);

  final List<_Reply> _replies;
  final List<RequestOptions> requests = [];
  int _activeShowRequests = 0;
  int maxConcurrentShowRequests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (_replies.isEmpty) throw StateError('No fake response remains.');
    final reply = _replies.removeAt(0);
    final isShowRequest = options.path == 'api/show';
    if (isShowRequest) {
      _activeShowRequests++;
      if (_activeShowRequests > maxConcurrentShowRequests) {
        maxConcurrentShowRequests = _activeShowRequests;
      }
    }
    try {
      if (reply.delay > Duration.zero) await Future<void>.delayed(reply.delay);
      return reply.toBody();
    } finally {
      if (isShowRequest) _activeShowRequests--;
    }
  }

  @override
  void close({bool force = false}) {}
}

final class _ThrowingAdapter implements HttpClientAdapter {
  _ThrowingAdapter(this.error);

  final Object error;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    throw error;
  }

  @override
  void close({bool force = false}) {}
}

final class _Reply {
  const _Reply(this.chunks, this.contentType, this.statusCode, this.delay);

  factory _Reply.json(
    Map<String, dynamic> value, {
    int statusCode = 200,
    Duration delay = Duration.zero,
  }) => _Reply(
    [utf8.encode(jsonEncode(value))],
    'application/json; charset=utf-8',
    statusCode,
    delay,
  );

  factory _Reply.stream(
    List<List<int>> chunks, {
    required String contentType,
    int statusCode = 200,
    Duration delay = Duration.zero,
  }) => _Reply(chunks, contentType, statusCode, delay);

  final List<List<int>> chunks;
  final String contentType;
  final int statusCode;
  final Duration delay;

  ResponseBody toBody() => ResponseBody(
    Stream<Uint8List>.fromIterable([
      for (final chunk in chunks) Uint8List.fromList(chunk),
    ]),
    statusCode,
    headers: {
      'content-type': [contentType],
    },
  );
}
