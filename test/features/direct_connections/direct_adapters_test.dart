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

  test('OpenAI adapter surfaces a non-stream Chat refusal', () async {
    final http = _QueuedAdapter([
      _Reply.json({
        'choices': [
          {
            'message': {'refusal': 'I cannot help with that.'},
          },
        ],
      }),
    ]);
    final adapter = OpenAiCompatibleAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );

    final events = await adapter
        .startCompletion(
          _openAiProfile(),
          DirectCompletionRequest(
            remoteModelId: 'model',
            messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
          ),
        )
        .events
        .toList();

    expect(
      events.whereType<DirectContentDelta>().single.content,
      'I cannot help with that.',
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

  test('OpenAI adapter rejects a DONE-only Chat stream', () async {
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode(
          'data: {"usage":{"total_tokens":0}}\n\n'
          'data: [DONE]\n\n',
        ),
      ], contentType: 'text/event-stream'),
    ]);
    final adapter = OpenAiCompatibleAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );

    final events = await adapter
        .startCompletion(
          _openAiProfile(),
          DirectCompletionRequest(
            remoteModelId: 'model',
            messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
          ),
        )
        .events
        .toList();

    expect(events.whereType<DirectContentDelta>(), isEmpty);
    expect(events.whereType<DirectStreamError>(), hasLength(1));
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
    'OpenAI adapter rejects an oversized SSE line before decoding',
    () async {
      final oversized = List.filled(64, 'x').join();
      final http = _QueuedAdapter([
        _Reply.stream([
          utf8.encode('data: $oversized\n\n'),
        ], contentType: 'text/event-stream'),
      ]);
      final adapter = OpenAiCompatibleAdapter(
        dioFactory: (_) => _dio(http),
        closeClients: false,
        maxSseLineCharacters: 32,
        maxSseFrameDataCharacters: 128,
      );

      final events = await adapter
          .startCompletion(
            _openAiProfile(),
            DirectCompletionRequest(
              remoteModelId: 'model',
              messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
            ),
          )
          .events
          .toList();

      expect(events.whereType<DirectContentDelta>(), isEmpty);
      expect(events.whereType<DirectStreamError>(), hasLength(1));
      expect(events.whereType<DirectStreamDone>(), isEmpty);
    },
  );

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
        parameters: const {
          'model': 'forged-model',
          'messages': <Object>[],
          'stream': false,
          'think': 'high',
          'options': {'temperature': 0.25},
          'provider_extension': 'kept',
        },
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
    final requestBody = http.requests.last.data as Map;
    expect(requestBody['model'], 'llava:latest');
    expect(requestBody['stream'], isTrue);
    expect(requestBody['think'], 'high');
    expect(requestBody['options'], {'temperature': 0.25});
    expect(requestBody['provider_extension'], 'kept');
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

  test('Ollama adapter rejects malformed typed SDK stream events', () async {
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode('{"message":{"content":42},"done":true}\n'),
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

    expect(events.whereType<DirectContentDelta>(), isEmpty);
    expect(
      events.whereType<DirectStreamError>().single.message,
      contains('invalid response'),
    );
    expect(events.whereType<DirectStreamDone>(), isEmpty);
  });

  test('Ollama adapter preserves reasoning_content proxy alias', () async {
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode(
          '{"message":{"reasoning_content":"think","content":"answer"},"done":true}\n',
        ),
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

    expect(events.whereType<DirectReasoningDelta>().single.content, 'think');
    expect(events.whereType<DirectContentDelta>().single.content, 'answer');
    expect(events.whereType<DirectStreamDone>(), hasLength(1));
  });

  test('Ollama adapter rejects cumulative streamed text over budget', () async {
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode('{"message":{"content":"12345"},"done":true}\n'),
      ], contentType: 'application/x-ndjson'),
    ]);
    final adapter = OllamaAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
      maxStreamCharacters: 4,
    );
    final run = adapter.startCompletion(
      _ollamaProfile(),
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

  test('OpenAI adapter preserves the LM Studio thinking alias', () async {
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode(
          'data: {"choices":[{"delta":{"thinking":"think","content":"answer"}}]}\n\n'
          'data: [DONE]\n\n',
        ),
      ], contentType: 'text/event-stream'),
    ]);
    final adapter = OpenAiCompatibleAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );

    final events = await adapter
        .startCompletion(
          _openAiProfile(),
          DirectCompletionRequest(
            remoteModelId: 'model',
            messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
          ),
        )
        .events
        .toList();

    expect(events.whereType<DirectReasoningDelta>().single.content, 'think');
    expect(events.whereType<DirectContentDelta>().single.content, 'answer');
    expect(events.whereType<DirectStreamDone>(), hasLength(1));
  });

  test('OpenAI adapter surfaces a streamed Chat refusal', () async {
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode(
          'data: {"choices":[{"delta":{"refusal":"Request declined."}}]}\n\n'
          'data: [DONE]\n\n',
        ),
      ], contentType: 'text/event-stream'),
    ]);
    final adapter = OpenAiCompatibleAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );

    final events = await adapter
        .startCompletion(
          _openAiProfile(),
          DirectCompletionRequest(
            remoteModelId: 'model',
            messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
          ),
        )
        .events
        .toList();

    expect(
      events.whereType<DirectContentDelta>().single.content,
      'Request declined.',
    );
    expect(events.whereType<DirectStreamDone>(), hasLength(1));
  });

  test(
    'OpenAI adapter streams Responses API reasoning and owns routing keys',
    () async {
      final completed = {
        'type': 'response.completed',
        'response': {
          'id': 'resp_1',
          'object': 'response',
          'created_at': 1,
          'status': 'completed',
          'output': <Object>[],
          'usage': {'input_tokens': 2, 'output_tokens': 3, 'total_tokens': 5},
        },
      };
      final http = _QueuedAdapter([
        _Reply.stream([
          utf8.encode(
            'data: ${jsonEncode({'type': 'response.reasoning_summary_text.delta', 'output_index': 0, 'summary_index': 0, 'delta': 'summary '})}\n\n'
            'data: ${jsonEncode({'type': 'response.reasoning.delta', 'delta': 'detail'})}\n\n'
            'data: ${jsonEncode({'type': 'response.output_text.delta', 'output_index': 0, 'content_index': 0, 'delta': 'answer'})}\n\n'
            'data: ${jsonEncode(completed)}\n\n',
          ),
        ], contentType: 'text/event-stream'),
      ]);
      final adapter = OpenAiCompatibleAdapter(
        dioFactory: (_) => _dio(http),
        closeClients: false,
      );
      final run = adapter.startCompletion(
        _openAiProfile(
          openAiApiMode: DirectOpenAiApiMode.responses,
          apiKeyAuthMode: DirectApiKeyAuthMode.apiKeyHeader,
          apiVersion: '2025-04-01-preview',
        ),
        DirectCompletionRequest(
          remoteModelId: 'trusted-model',
          messages: [
            DirectChatMessage.text(role: 'system', text: 'be concise'),
            DirectChatMessage.text(
              role: 'observer',
              text: 'compatible-provider extension role',
            ),
            DirectChatMessage.text(role: 'assistant', text: 'previous answer'),
            DirectChatMessage(
              role: 'user',
              parts: const [
                DirectTextPart('describe'),
                DirectImagePart('data:image/png;base64,aW1hZ2U='),
              ],
            ),
          ],
          parameters: const {
            'model': 'forged-model',
            'input': 'forged-input',
            'stream': false,
            'store': false,
            'repeat_penalty': 1.1,
          },
        ),
      );

      final events = await run.events.toList();

      expect(
        events
            .whereType<DirectReasoningDelta>()
            .map((event) => event.content)
            .join(),
        'summary detail',
      );
      expect(events.whereType<DirectContentDelta>().single.content, 'answer');
      expect(
        events.whereType<DirectUsageUpdate>().single.usage['total_tokens'],
        5,
      );
      expect(events.whereType<DirectStreamDone>(), hasLength(1));

      final sent = http.requests.single;
      expect(
        sent.uri.toString(),
        'https://api.test/v1/responses?api-version=2025-04-01-preview',
      );
      expect(sent.headers['api-key'], 'secret');
      expect(sent.headers['Authorization'], isNull);
      final body = sent.data as Map;
      expect(body['model'], 'trusted-model');
      expect(body['stream'], isTrue);
      expect(body['store'], isFalse);
      expect(body['repeat_penalty'], 1.1);
      final input = body['input'] as List;
      expect(input, hasLength(4));
      expect((input.first as Map)['type'], 'message');
      expect((input.first as Map)['role'], 'system');
      expect((input[1] as Map)['role'], 'observer');
      final assistantContent = (input[2] as Map)['content'] as List;
      expect((assistantContent.single as Map)['type'], 'output_text');
      final userContent = (input.last as Map)['content'] as List;
      expect((userContent.last as Map)['type'], 'input_image');
    },
  );

  test(
    'OpenAI adapter normalizes a non-stream Responses API payload',
    () async {
      final http = _QueuedAdapter([
        _Reply.json({
          'id': 'resp_1',
          'object': 'response',
          'created_at': 1,
          'status': 'completed',
          'output': [
            {
              'type': 'reasoning',
              'id': 'reason_1',
              'summary': [
                {'type': 'summary_text', 'text': 'json-think'},
              ],
            },
            {
              'type': 'message',
              'id': 'msg_1',
              'role': 'assistant',
              'status': 'completed',
              'content': [
                {'type': 'output_text', 'text': 'json-answer'},
              ],
            },
          ],
          'usage': {'input_tokens': 2, 'output_tokens': 3, 'total_tokens': 5},
        }),
      ]);
      final adapter = OpenAiCompatibleAdapter(
        dioFactory: (_) => _dio(http),
        closeClients: false,
      );
      final run = adapter.startCompletion(
        _openAiProfile(openAiApiMode: DirectOpenAiApiMode.responses),
        DirectCompletionRequest(
          remoteModelId: 'model',
          messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
        ),
      );

      final events = await run.events.toList();

      expect(
        events.whereType<DirectReasoningDelta>().single.content,
        'json-think',
      );
      expect(
        events.whereType<DirectContentDelta>().single.content,
        'json-answer',
      );
      expect(events.whereType<DirectStreamDone>(), hasLength(1));
    },
  );

  test('OpenAI adapter surfaces a non-stream Responses refusal', () async {
    final http = _QueuedAdapter([
      _Reply.json({
        'id': 'resp_refusal',
        'object': 'response',
        'created_at': 1,
        'status': 'completed',
        'output': [
          {
            'type': 'message',
            'id': 'msg_refusal',
            'role': 'assistant',
            'status': 'completed',
            'content': [
              {'type': 'refusal', 'refusal': 'Response declined.'},
            ],
          },
        ],
      }),
    ]);
    final adapter = OpenAiCompatibleAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );

    final events = await adapter
        .startCompletion(
          _openAiProfile(openAiApiMode: DirectOpenAiApiMode.responses),
          DirectCompletionRequest(
            remoteModelId: 'model',
            messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
          ),
        )
        .events
        .toList();

    expect(
      events.whereType<DirectContentDelta>().single.content,
      'Response declined.',
    );
    expect(events.whereType<DirectStreamDone>(), hasLength(1));
  });

  test('OpenAI adapter rejects a cancelled non-stream Response', () async {
    final http = _QueuedAdapter([
      _Reply.json({
        'id': 'resp_cancelled',
        'object': 'response',
        'created_at': 1,
        'status': 'cancelled',
        'output': [
          {
            'type': 'message',
            'id': 'msg_partial',
            'role': 'assistant',
            'status': 'in_progress',
            'content': [
              {'type': 'output_text', 'text': 'partial output'},
            ],
          },
        ],
      }),
    ]);
    final adapter = OpenAiCompatibleAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );

    final events = await adapter
        .startCompletion(
          _openAiProfile(openAiApiMode: DirectOpenAiApiMode.responses),
          DirectCompletionRequest(
            remoteModelId: 'model',
            messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
          ),
        )
        .events
        .toList();

    expect(events.whereType<DirectContentDelta>(), isEmpty);
    expect(
      events.whereType<DirectStreamError>().single.message,
      contains('cancelled'),
    );
    expect(events.whereType<DirectStreamDone>(), isEmpty);
  });

  test('OpenAI adapter surfaces a streamed Responses refusal', () async {
    final completed = {
      'type': 'response.completed',
      'response': {
        'id': 'resp_refusal',
        'object': 'response',
        'created_at': 1,
        'status': 'completed',
        'output': <Object>[],
      },
    };
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode(
          'data: ${jsonEncode({'type': 'response.refusal.delta', 'output_index': 0, 'content_index': 0, 'delta': 'Request declined.'})}\n\n'
          'data: ${jsonEncode(completed)}\n\n',
        ),
      ], contentType: 'text/event-stream'),
    ]);
    final adapter = OpenAiCompatibleAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );

    final events = await adapter
        .startCompletion(
          _openAiProfile(openAiApiMode: DirectOpenAiApiMode.responses),
          DirectCompletionRequest(
            remoteModelId: 'model',
            messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
          ),
        )
        .events
        .toList();

    expect(
      events.whereType<DirectContentDelta>().single.content,
      'Request declined.',
    );
    expect(events.whereType<DirectStreamDone>(), hasLength(1));
  });

  test(
    'OpenAI adapter rejects a completed event with cancelled status',
    () async {
      final completed = {
        'type': 'response.completed',
        'response': {
          'id': 'resp_cancelled',
          'object': 'response',
          'created_at': 1,
          'status': 'cancelled',
          'output': [
            {
              'type': 'message',
              'id': 'msg_partial',
              'role': 'assistant',
              'status': 'in_progress',
              'content': [
                {'type': 'output_text', 'text': 'partial output'},
              ],
            },
          ],
        },
      };
      final http = _QueuedAdapter([
        _Reply.stream([
          utf8.encode('data: ${jsonEncode(completed)}\n\n'),
        ], contentType: 'text/event-stream'),
      ]);
      final adapter = OpenAiCompatibleAdapter(
        dioFactory: (_) => _dio(http),
        closeClients: false,
      );

      final events = await adapter
          .startCompletion(
            _openAiProfile(openAiApiMode: DirectOpenAiApiMode.responses),
            DirectCompletionRequest(
              remoteModelId: 'model',
              messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
            ),
          )
          .events
          .toList();

      expect(events.whereType<DirectContentDelta>(), isEmpty);
      expect(
        events.whereType<DirectStreamError>().single.message,
        contains('cancelled'),
      );
      expect(events.whereType<DirectStreamDone>(), isEmpty);
    },
  );

  test('Responses completion recovers text missing from delta events', () async {
    final completed = {
      'type': 'response.completed',
      'response': {
        'id': 'resp_1',
        'object': 'response',
        'created_at': 1,
        'status': 'completed',
        'output': [
          {
            'type': 'reasoning',
            'id': 'reason_1',
            'summary': [
              {'type': 'summary_text', 'text': 'complete-thought'},
            ],
          },
          {
            'type': 'message',
            'id': 'msg_1',
            'role': 'assistant',
            'status': 'completed',
            'content': [
              {'type': 'output_text', 'text': 'recovered-answer'},
            ],
          },
        ],
      },
    };
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode(
          'data: ${jsonEncode({'type': 'response.reasoning_summary_text.delta', 'output_index': 0, 'summary_index': 0, 'delta': 'streamed-thought'})}\n\n'
          'data: ${jsonEncode(completed)}\n\n',
        ),
      ], contentType: 'text/event-stream'),
    ]);
    final adapter = OpenAiCompatibleAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );

    final events = await adapter
        .startCompletion(
          _openAiProfile(openAiApiMode: DirectOpenAiApiMode.responses),
          DirectCompletionRequest(
            remoteModelId: 'model',
            messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
          ),
        )
        .events
        .toList();

    expect(
      events.whereType<DirectReasoningDelta>().single.content,
      'streamed-thought',
    );
    expect(
      events.whereType<DirectContentDelta>().single.content,
      'recovered-answer',
    );
    expect(events.whereType<DirectStreamDone>(), hasLength(1));
  });

  test('OpenAI adapter requires a Responses API terminal event', () async {
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode(
          'data: ${jsonEncode({'type': 'response.output_text.delta', 'output_index': 0, 'content_index': 0, 'delta': 'partial'})}\n\n',
        ),
      ], contentType: 'text/event-stream'),
    ]);
    final adapter = OpenAiCompatibleAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );
    final run = adapter.startCompletion(
      _openAiProfile(openAiApiMode: DirectOpenAiApiMode.responses),
      DirectCompletionRequest(
        remoteModelId: 'model',
        messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
      ),
    );

    final events = await run.events.toList();

    expect(events.whereType<DirectContentDelta>().single.content, 'partial');
    expect(
      events.whereType<DirectStreamError>().single.message,
      contains('response.completed'),
    );
    expect(events.whereType<DirectStreamDone>(), isEmpty);
  });

  test('OpenAI adapter keeps malformed Responses events strict', () async {
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode(
          'data: {"type":"response.output_text.delta","delta":42}\n\n',
        ),
      ], contentType: 'text/event-stream'),
    ]);
    final adapter = OpenAiCompatibleAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );

    final events = await adapter
        .startCompletion(
          _openAiProfile(openAiApiMode: DirectOpenAiApiMode.responses),
          DirectCompletionRequest(
            remoteModelId: 'model',
            messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
          ),
        )
        .events
        .toList();

    expect(events.whereType<DirectStreamError>(), hasLength(1));
    expect(events.whereType<DirectStreamDone>(), isEmpty);
  });
}

DirectConnectionProfile _openAiProfile({
  List<String> manualModelIds = const [],
  DirectOpenAiApiMode openAiApiMode = DirectOpenAiApiMode.chatCompletions,
  DirectApiKeyAuthMode apiKeyAuthMode = DirectApiKeyAuthMode.bearer,
  String? apiVersion,
}) => DirectConnectionProfile(
  id: 'openai-one',
  name: 'OpenAI compatible',
  adapterKey: kOpenAiCompatibleAdapterKey,
  baseUrl: 'https://api.test/v1',
  apiKey: 'secret',
  manualModelIds: manualModelIds,
  openAiApiMode: openAiApiMode,
  apiKeyAuthMode: apiKeyAuthMode,
  apiVersion: apiVersion,
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
