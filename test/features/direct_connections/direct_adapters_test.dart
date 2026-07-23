import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/models/ollama_keep_alive.dart';
import 'package:conduit/features/direct_connections/services/direct_adapter_helpers.dart';
import 'package:conduit/features/direct_connections/services/direct_http_client.dart';
import 'package:conduit/features/direct_connections/services/ollama_adapter.dart';
import 'package:conduit/features/direct_connections/services/openai_compatible_adapter.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'successful pooled completions reuse one keep-alive connection',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final remotePorts = <int>{};
      final serverErrors = <Object>[];
      var requestCount = 0;
      final handledBoth = Completer<void>();
      final subscription = server.listen((request) async {
        try {
          remotePorts.add(request.connectionInfo!.remotePort);
          await request.drain<void>();
          request.response
            ..statusCode = HttpStatus.ok
            ..persistentConnection = true;
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.write(
            'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n',
          );
          request.response.write('data: [DONE]\n\n');
          await request.response.close();
        } catch (error) {
          serverErrors.add(error);
        } finally {
          requestCount++;
          if (requestCount == 2 && !handledBoth.isCompleted) {
            handledBoth.complete();
          }
        }
      });
      final pool = DirectHttpClientPool();
      final adapter = OpenAiCompatibleAdapter(clientPool: pool);
      addTearDown(() async {
        adapter.dispose();
        pool.dispose();
        await subscription.cancel();
        await server.close(force: true);
      });
      final profile = DirectConnectionProfile(
        id: 'keep-alive-profile',
        name: 'Keep alive',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'http://${server.address.address}:${server.port}/v1',
      );
      final request = DirectCompletionRequest(
        remoteModelId: 'model',
        messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
      );

      for (var index = 0; index < 2; index++) {
        final run = adapter.startCompletion(profile, request);
        final events = await run.events.toList().timeout(
          const Duration(seconds: 5),
        );
        await run.done.timeout(const Duration(seconds: 5));
        expect(events.whereType<DirectContentDelta>().single.content, 'ok');
        expect(events.whereType<DirectStreamDone>(), hasLength(1));
        expect(events.whereType<DirectStreamError>(), isEmpty);
      }
      await handledBoth.future.timeout(const Duration(seconds: 5));

      expect(serverErrors, isEmpty, reason: 'responses must not be aborted');
      expect(requestCount, 2);
      expect(
        remotePorts,
        hasLength(1),
        reason: 'both completions should share one accepted TCP connection',
      );
    },
  );

  test(
    'adapters reject invalid completion limits before creating a client or run',
    () {
      var clientCreations = 0;
      Dio factory(DirectConnectionProfile _) {
        clientCreations++;
        return Dio();
      }

      final request = DirectCompletionRequest(
        remoteModelId: 'model',
        messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
      );
      final invalidStarts = <void Function()>[
        () => OpenAiCompatibleAdapter(
          dioFactory: factory,
          streamIdleTimeout: Duration.zero,
        ).startCompletion(_openAiProfile(), request),
        () => OpenAiCompatibleAdapter(
          dioFactory: factory,
          streamMaxDuration: Duration.zero,
        ).startCompletion(_openAiProfile(), request),
        () => OpenAiCompatibleAdapter(
          dioFactory: factory,
          maxStreamBytes: 0,
        ).startCompletion(_openAiProfile(), request),
        () => OpenAiCompatibleAdapter(
          dioFactory: factory,
          maxStreamCharacters: 0,
        ).startCompletion(_openAiProfile(), request),
        () => OpenAiCompatibleAdapter(
          dioFactory: factory,
          maxStreamEvents: 0,
        ).startCompletion(_openAiProfile(), request),
        () => OpenAiCompatibleAdapter(
          dioFactory: factory,
          maxSseLineCharacters: 0,
        ).startCompletion(_openAiProfile(), request),
        () => OpenAiCompatibleAdapter(
          dioFactory: factory,
          maxSseFrameDataCharacters: 0,
        ).startCompletion(_openAiProfile(), request),
        () => OllamaAdapter(
          dioFactory: factory,
          streamIdleTimeout: Duration.zero,
        ).startCompletion(_ollamaProfile(), request),
        () => OllamaAdapter(
          dioFactory: factory,
          streamMaxDuration: Duration.zero,
        ).startCompletion(_ollamaProfile(), request),
        () => OllamaAdapter(
          dioFactory: factory,
          maxStreamBytes: 0,
        ).startCompletion(_ollamaProfile(), request),
        () => OllamaAdapter(
          dioFactory: factory,
          maxStreamCharacters: 0,
        ).startCompletion(_ollamaProfile(), request),
        () => OllamaAdapter(
          dioFactory: factory,
          maxStreamEvents: 0,
        ).startCompletion(_ollamaProfile(), request),
      ];

      for (final start in invalidStarts) {
        expect(start, throwsA(isA<ArgumentError>()));
      }
      expect(clientCreations, 0);
    },
  );

  for (final protocol in const ['OpenAI Chat', 'OpenAI Responses', 'Ollama']) {
    test(
      '$protocol rejects requests emptied by non-user image suppression',
      () async {
        final http = _QueuedAdapter(const <_Reply>[]);
        final request = DirectCompletionRequest(
          remoteModelId: 'model',
          messages: [
            DirectChatMessage(
              role: 'system',
              parts: const [DirectImagePart('data:image/png;base64,c3lzdGVt')],
            ),
            DirectChatMessage(
              role: 'assistant',
              parts: const [
                DirectImagePart('data:image/png;base64,YXNzaXN0YW50'),
              ],
            ),
          ],
        );

        late final DirectCompletionRun run;
        if (protocol == 'Ollama') {
          run = OllamaAdapter(
            dioFactory: (_) => _dio(http),
            closeClients: false,
          ).startCompletion(_ollamaProfile(), request);
        } else {
          run =
              OpenAiCompatibleAdapter(
                dioFactory: (_) => _dio(http),
                closeClients: false,
              ).startCompletion(
                _openAiProfile(
                  openAiApiMode: protocol == 'OpenAI Responses'
                      ? DirectOpenAiApiMode.responses
                      : DirectOpenAiApiMode.chatCompletions,
                ),
                request,
              );
        }

        final events = await run.events.toList();
        await run.done;

        expect(http.requests, isEmpty);
        expect(events.whereType<DirectStreamDone>(), isEmpty);
        expect(
          events.whereType<DirectStreamError>().single.message,
          'The direct request has no serializable messages.',
        );
      },
    );
  }

  for (final protocol in const ['OpenAI Chat', 'OpenAI Responses', 'Ollama']) {
    test('$protocol rejects tool parameters before network dispatch', () async {
      final http = _QueuedAdapter(const <_Reply>[]);
      final request = DirectCompletionRequest(
        remoteModelId: 'model',
        messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
        parameters: const {
          'tools': [
            {
              'type': 'function',
              'function': {'name': 'dangerous_tool'},
            },
          ],
          'tool_choice': 'auto',
        },
      );

      final run = protocol == 'Ollama'
          ? OllamaAdapter(
              dioFactory: (_) => _dio(http),
              closeClients: false,
            ).startCompletion(_ollamaProfile(), request)
          : OpenAiCompatibleAdapter(
              dioFactory: (_) => _dio(http),
              closeClients: false,
            ).startCompletion(
              _openAiProfile(
                openAiApiMode: protocol == 'OpenAI Responses'
                    ? DirectOpenAiApiMode.responses
                    : DirectOpenAiApiMode.chatCompletions,
              ),
              request,
            );

      final events = await run.events.toList();
      await run.done;

      expect(http.requests, isEmpty);
      expect(events.whereType<DirectStreamDone>(), isEmpty);
      expect(
        events.whereType<DirectStreamError>().single.message,
        kDirectToolCallingUnsupportedMessage,
      );
    });
  }

  test('built-in adapters reject unsolicited provider tool calls', () async {
    final openAiHttp = _QueuedAdapter([
      _Reply.stream([
        utf8.encode(
          'data: {"choices":[{"delta":{"tool_calls":[{"id":"call-1"}]}}]}\n\n',
        ),
      ], contentType: 'text/event-stream'),
    ]);
    final ollamaHttp = _QueuedAdapter([
      _Reply.stream([
        utf8.encode(
          '{"message":{"tool_calls":[{"function":{"name":"tool"}}]},"done":true}\n',
        ),
      ], contentType: 'application/x-ndjson'),
    ]);
    final responsesHttp = _QueuedAdapter([
      _Reply.json({
        'id': 'resp-tool',
        'object': 'response',
        'created_at': 1,
        'status': 'completed',
        'output': [
          {
            'type': 'function_call',
            'call_id': 'call-1',
            'name': 'tool',
            'arguments': '{}',
          },
        ],
      }),
    ]);
    final request = DirectCompletionRequest(
      remoteModelId: 'model',
      messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
    );

    final openAiEvents = await OpenAiCompatibleAdapter(
      dioFactory: (_) => _dio(openAiHttp),
      closeClients: false,
    ).startCompletion(_openAiProfile(), request).events.toList();
    final ollamaEvents = await OllamaAdapter(
      dioFactory: (_) => _dio(ollamaHttp),
      closeClients: false,
    ).startCompletion(_ollamaProfile(), request).events.toList();
    final responsesEvents =
        await OpenAiCompatibleAdapter(
              dioFactory: (_) => _dio(responsesHttp),
              closeClients: false,
            )
            .startCompletion(
              _openAiProfile(openAiApiMode: DirectOpenAiApiMode.responses),
              request,
            )
            .events
            .toList();

    expect(
      openAiEvents.whereType<DirectStreamError>().single.message,
      kDirectToolCallingUnsupportedMessage,
    );
    expect(
      ollamaEvents.whereType<DirectStreamError>().single.message,
      kDirectToolCallingUnsupportedMessage,
    );
    expect(
      responsesEvents.whereType<DirectStreamError>().single.message,
      kDirectToolCallingUnsupportedMessage,
    );
  });

  test(
    'OpenAI Responses rejects every SDK tool output item even beside text',
    () async {
      const toolOutputTypes = <String>[
        'function_call',
        'web_search_call',
        'file_search_call',
        'code_interpreter_call',
        'image_generation_call',
        'local_shell_call',
        'local_shell_call_output',
        'shell_call',
        'shell_call_output',
        'mcp_call',
        'tool_search_call',
        'tool_search_output',
        'computer_call',
        'custom_tool_call',
        'custom_tool_call_output',
        'additional_tools',
      ];
      final request = DirectCompletionRequest(
        remoteModelId: 'model',
        messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
      );

      for (final toolType in toolOutputTypes) {
        final http = _QueuedAdapter([
          _Reply.json({
            'id': 'resp-$toolType',
            'object': 'response',
            'created_at': 1,
            'status': 'completed',
            'output': [
              {
                'type': 'message',
                'id': 'msg-$toolType',
                'role': 'assistant',
                'status': 'completed',
                'content': [
                  {'type': 'output_text', 'text': 'must not be accepted'},
                ],
              },
              {'type': toolType},
            ],
          }),
        ]);

        final events =
            await OpenAiCompatibleAdapter(
                  dioFactory: (_) => _dio(http),
                  closeClients: false,
                )
                .startCompletion(
                  _openAiProfile(openAiApiMode: DirectOpenAiApiMode.responses),
                  request,
                )
                .events
                .toList();

        expect(
          events.whereType<DirectStreamError>().single.message,
          kDirectToolCallingUnsupportedMessage,
          reason: toolType,
        );
        expect(
          events.whereType<DirectContentDelta>(),
          isEmpty,
          reason: toolType,
        );
        expect(events.whereType<DirectStreamDone>(), isEmpty, reason: toolType);
      }
    },
  );

  test(
    'OpenAI Responses settles immediately when terminal SSE has no EOF',
    () async {
      final completed = {
        'type': 'response.completed',
        'response': {
          'id': 'resp_terminal_open_stream',
          'object': 'response',
          'created_at': 1,
          'status': 'completed',
          'output': [
            {
              'type': 'message',
              'id': 'msg_terminal_open_stream',
              'role': 'assistant',
              'status': 'completed',
              'content': [
                {'type': 'output_text', 'text': 'terminal answer'},
              ],
            },
          ],
        },
      };
      final http = _NeverEndingStreamAdapter(
        utf8.encode('data: ${jsonEncode(completed)}\n\n'),
        contentType: 'text/event-stream',
      );
      final run =
          OpenAiCompatibleAdapter(
            dioFactory: (_) => _dio(http),
            closeClients: false,
            streamIdleTimeout: const Duration(seconds: 30),
            streamMaxDuration: const Duration(minutes: 1),
          ).startCompletion(
            _openAiProfile(openAiApiMode: DirectOpenAiApiMode.responses),
            DirectCompletionRequest(
              remoteModelId: 'model',
              messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
            ),
          );

      final events = await run.events.toList().timeout(
        const Duration(seconds: 1),
      );
      await run.done.timeout(const Duration(seconds: 1));
      await http.sourceCancelled.future.timeout(const Duration(seconds: 1));

      expect(
        events.whereType<DirectContentDelta>().single.content,
        'terminal answer',
      );
      expect(events.whereType<DirectStreamError>(), isEmpty);
      expect(events.whereType<DirectStreamDone>(), hasLength(1));
    },
  );

  test(
    'successful terminal drain is time-bounded despite heartbeats',
    () async {
      final http = _HeartbeatAdapter(
        utf8.encode(
          'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n'
          'data: [DONE]\n\n',
        ),
        contentType: 'text/event-stream',
      );
      final run =
          OpenAiCompatibleAdapter(
            dioFactory: (_) => _dio(http),
            closeClients: false,
            streamIdleTimeout: const Duration(seconds: 30),
            streamMaxDuration: const Duration(minutes: 1),
            successDrainTimeout: const Duration(milliseconds: 25),
            maxSuccessDrainBytes: 64 * 1024 * 1024,
          ).startCompletion(
            _openAiProfile(),
            DirectCompletionRequest(
              remoteModelId: 'model',
              messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
            ),
          );

      final events = await run.events.toList().timeout(
        const Duration(seconds: 1),
      );
      await run.done.timeout(const Duration(seconds: 1));

      expect(events.whereType<DirectContentDelta>().single.content, 'ok');
      expect(events.whereType<DirectStreamDone>(), hasLength(1));
      expect(events.whereType<DirectStreamError>(), isEmpty);
      expect(http.sourceCancelled, isTrue);
    },
  );

  for (final adapterName in const ['OpenAI', 'Ollama']) {
    test('$adapterName model discovery never logs a foreign stack', () async {
      const apiKey = 'direct-log-api-secret';
      const headerSecret = 'direct-log-header-secret';
      const stackSecret = 'direct-log-foreign-stack-secret';
      final http = _ForeignStackAdapter(
        error: 'foreign model error $apiKey $headerSecret',
        stackTrace: StackTrace.fromString('$stackSecret $apiKey $headerSecret'),
      );
      final logs = <String>[];
      final previousDebugPrint = debugPrint;
      debugPrint = (value, {wrapWidth}) {
        if (value != null) logs.add(value);
      };

      try {
        if (adapterName == 'OpenAI') {
          await expectLater(
            OpenAiCompatibleAdapter(
              dioFactory: (_) => _dio(http),
              closeClients: false,
            ).listModels(
              _openAiProfile(
                apiKey: apiKey,
                customHeaders: const {'X-Private': headerSecret},
              ),
            ),
            throwsA(isA<DirectProviderException>()),
          );
        } else {
          await expectLater(
            OllamaAdapter(
              dioFactory: (_) => _dio(http),
              closeClients: false,
            ).listModels(
              _ollamaProfile(
                apiKey: apiKey,
                customHeaders: const {'X-Private': headerSecret},
              ),
            ),
            throwsA(isA<DirectProviderException>()),
          );
        }
      } finally {
        debugPrint = previousDebugPrint;
      }

      final combined = logs.join('\n');
      expect(combined, contains('models-failed'));
      expect(combined, isNot(contains(apiKey)));
      expect(combined, isNot(contains(headerSecret)));
      expect(combined, isNot(contains(stackSecret)));
      expect(combined, isNot(contains('foreign model error')));
    });

    test('$adapterName completion never logs a foreign stack', () async {
      const apiKey = 'direct-completion-log-api-secret';
      const headerSecret = 'direct-completion-log-header-secret';
      const stackSecret = 'direct-completion-foreign-stack-secret';
      final http = _ForeignStackAdapter(
        error: 'foreign completion error $apiKey $headerSecret',
        stackTrace: StackTrace.fromString('$stackSecret $apiKey $headerSecret'),
      );
      final logs = <String>[];
      final previousDebugPrint = debugPrint;
      debugPrint = (value, {wrapWidth}) {
        if (value != null) logs.add(value);
      };

      try {
        final request = DirectCompletionRequest(
          remoteModelId: 'model',
          messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
        );
        final run = adapterName == 'OpenAI'
            ? OpenAiCompatibleAdapter(
                dioFactory: (_) => _dio(http),
                closeClients: false,
              ).startCompletion(
                _openAiProfile(
                  apiKey: apiKey,
                  customHeaders: const {'X-Private': headerSecret},
                ),
                request,
              )
            : OllamaAdapter(
                dioFactory: (_) => _dio(http),
                closeClients: false,
              ).startCompletion(
                _ollamaProfile(
                  apiKey: apiKey,
                  customHeaders: const {'X-Private': headerSecret},
                ),
                request,
              );
        final events = await run.events.toList();
        await run.done;
        expect(events.whereType<DirectStreamError>(), hasLength(1));
      } finally {
        debugPrint = previousDebugPrint;
      }

      final combined = logs.join('\n');
      expect(combined, contains('completion-failed'));
      expect(combined, isNot(contains(apiKey)));
      expect(combined, isNot(contains(headerSecret)));
      expect(combined, isNot(contains(stackSecret)));
      expect(combined, isNot(contains('foreign completion error')));
    });
  }

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

  test(
    'OpenAI discovery honors advertised image modalities with absent fallback',
    () async {
      final http = _QueuedAdapter([
        _Reply.json({
          'data': [
            {
              'id': 'text-only',
              'architecture': {
                'input_modalities': ['text'],
              },
            },
            {
              'id': 'vision',
              'architecture': {
                'input_modalities': ['text', 'IMAGE'],
              },
            },
            {'id': 'explicit-text', 'is_multimodal': false},
            {
              'id': 'metadata-without-modalities',
              'architecture': {'tokenizer': 'example'},
            },
            {'id': 'metadata-absent'},
          ],
        }),
      ]);
      final adapter = OpenAiCompatibleAdapter(
        dioFactory: (_) => _dio(http),
        closeClients: false,
      );

      final models = await adapter.listModels(_openAiProfile());
      DirectRemoteModel model(String id) =>
          models.firstWhere((candidate) => candidate.id == id);

      expect(model('text-only').isMultimodal, isFalse);
      expect(model('vision').isMultimodal, isTrue);
      expect(model('explicit-text').isMultimodal, isFalse);
      expect(model('metadata-without-modalities').isMultimodal, isTrue);
      expect(model('metadata-absent').isMultimodal, isTrue);
      expect(model('text-only').capabilities['advertised_multimodal'], isFalse);
      expect(
        model('metadata-absent').capabilities,
        isNot(contains('advertised_multimodal')),
      );
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

  test(
    'OpenAI Chat drops image-only non-user history and sends user images',
    () async {
      final http = _QueuedAdapter([
        _Reply.json({
          'choices': [
            {
              'message': {'content': 'ok'},
            },
          ],
        }),
      ]);
      final adapter = OpenAiCompatibleAdapter(
        dioFactory: (_) => _dio(http),
        closeClients: false,
      );

      await adapter
          .startCompletion(
            _openAiProfile(),
            DirectCompletionRequest(
              remoteModelId: 'model',
              messages: [
                DirectChatMessage(
                  role: 'system',
                  parts: const [
                    DirectImagePart('data:image/png;base64,c3lzdGVtLW9ubHk='),
                  ],
                ),
                DirectChatMessage(
                  role: 'assistant',
                  parts: const [
                    DirectImagePart(
                      'data:image/png;base64,YXNzaXN0YW50LW9ubHk=',
                    ),
                  ],
                ),
                DirectChatMessage(
                  role: 'system',
                  parts: const [
                    DirectTextPart('instructions'),
                    DirectImagePart('data:image/png;base64,c3lzdGVt'),
                  ],
                ),
                DirectChatMessage(
                  role: 'assistant',
                  parts: const [
                    DirectTextPart('previous answer'),
                    DirectImagePart('data:image/png;base64,YXNzaXN0YW50'),
                  ],
                ),
                DirectChatMessage(
                  role: 'user',
                  parts: const [
                    DirectTextPart('describe'),
                    DirectImagePart('data:image/png;base64,dXNlcg=='),
                  ],
                ),
              ],
            ),
          )
          .events
          .toList();

      final body = http.requests.single.data as Map;
      final messages = body['messages'] as List;
      expect(messages, hasLength(3));
      expect((messages[0] as Map)['content'], 'instructions');
      expect((messages[1] as Map)['content'], 'previous answer');
      final userContent = (messages[2] as Map)['content'] as List;
      expect(
        userContent.whereType<Map>().map((part) => part['type']),
        contains('image_url'),
      );
    },
  );

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

  test('OpenAI adapter rejects whitespace-only completion content', () async {
    final http = _QueuedAdapter([
      _Reply.json({
        'choices': [
          {
            'message': {'content': ' \n\t '},
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

    expect(events.whereType<DirectContentDelta>().single.content, ' \n\t ');
    expect(events.whereType<DirectStreamError>(), hasLength(1));
    expect(events.whereType<DirectStreamDone>(), isEmpty);
  });

  test(
    'OpenAI adapter preserves whitespace before real streamed text',
    () async {
      final http = _QueuedAdapter([
        _Reply.stream([
          utf8.encode(
            'data: {"choices":[{"delta":{"content":"  "}}]}\n\n'
            'data: {"choices":[{"delta":{"content":"answer"}}]}\n\n'
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
        events.whereType<DirectContentDelta>().map((event) => event.content),
        ['  ', 'answer'],
      );
      expect(events.whereType<DirectStreamDone>(), hasLength(1));
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

  test('manual Ollama Cloud probe uses documented api/tags endpoint', () async {
    final http = _QueuedAdapter([
      _Reply.json({
        'models': [
          {'name': 'gpt-oss:120b-cloud'},
        ],
      }),
    ]);
    final adapter = OllamaAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );

    final result = await adapter.probe(
      _ollamaProfile(
        baseUrl: 'https://ollama.com',
        apiKey: 'cloud-key',
        manualModelIds: const ['gpt-oss:120b-cloud'],
      ),
    );

    expect(result.reachable, isTrue);
    expect(result.modelCount, 1);
    expect(http.requests, hasLength(1));
    expect(http.requests.single.method, 'GET');
    expect(http.requests.single.uri.toString(), 'https://ollama.com/api/tags');
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

  test('OpenAI adapter redacts credentials from provider errors', () async {
    const apiKey = 'live-api-key-value';
    const headerSecret = 'private-header-value';
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode(
          'data: ${jsonEncode({
            'error': {'message': 'Authorization: Bearer $apiKey; X-Service-Token: '
                '$headerSecret\u0000\nprovider detail'},
          })}\n\n',
        ),
      ], contentType: 'text/event-stream'),
    ]);
    final adapter = OpenAiCompatibleAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );
    final profile = _openAiProfile(
      apiKey: apiKey,
      customHeaders: const {'X-Service-Token': headerSecret},
    );

    final events = await adapter
        .startCompletion(
          profile,
          DirectCompletionRequest(
            remoteModelId: 'model',
            messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
          ),
        )
        .events
        .toList();

    final message = events.whereType<DirectStreamError>().single.message;
    expect(message, isNot(contains(apiKey)));
    expect(message, isNot(contains(headerSecret)));
    expect(message, isNot(contains('\u0000')));
    expect(message, contains('provider detail'));
    expect(events.whereType<DirectStreamDone>(), isEmpty);
  });

  test('OpenAI adapter redacts credentials from transport errors', () async {
    const apiKey = 'transport-api-key-value';
    const headerSecret = 'transport-header-value';
    final http = _ThrowingAdapter(
      StateError(
        'Authorization: Bearer $apiKey; '
        'X-Service-Token: $headerSecret',
      ),
    );
    final adapter = OpenAiCompatibleAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );
    final run = adapter.startCompletion(
      _openAiProfile(
        apiKey: apiKey,
        customHeaders: const {'X-Service-Token': headerSecret},
      ),
      DirectCompletionRequest(
        remoteModelId: 'model',
        messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
      ),
    );

    final events = await run.events.toList();
    await run.done;

    final message = events.whereType<DirectStreamError>().single.message;
    expect(message, isNot(contains(apiKey)));
    expect(message, isNot(contains(headerSecret)));
    expect(events.whereType<DirectStreamDone>(), isEmpty);
  });

  test(
    'OpenAI adapter redacts secrets before truncating provider errors',
    () async {
      const apiKey = 'LEAKME-secret-crossing-the-boundary';
      final reflected = '${List.filled(507, 'x').join()}$apiKey';
      final http = _QueuedAdapter([
        _Reply.stream([
          utf8.encode(
            'data: ${jsonEncode({
              'error': {'message': reflected},
            })}\n\n',
          ),
        ], contentType: 'text/event-stream'),
      ]);
      final adapter = OpenAiCompatibleAdapter(
        dioFactory: (_) => _dio(http),
        closeClients: false,
      );

      final events = await adapter
          .startCompletion(
            _openAiProfile(apiKey: apiKey),
            DirectCompletionRequest(
              remoteModelId: 'model',
              messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
            ),
          )
          .events
          .toList();

      final message = events.whereType<DirectStreamError>().single.message;
      expect(message, isNot(contains('LEAK')));
      expect(message.runes.length, kMaxDirectProviderErrorCharacters);
    },
  );

  test('provider error sanitizer fails closed for oversized secrets', () {
    final oversizedSecret = '${List.filled(8192, 'x').join()}LEAKING_TAIL';

    final message = sanitizeDirectProviderErrorMessage(
      'provider reflected LEAKING_TAIL',
      sensitiveValues: <String>[oversizedSecret],
    );

    expect(message, 'The provider reported an error.');
    expect(message, isNot(contains('LEAKING_TAIL')));
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

  test('OpenAI adapter bounds decoded frames that emit no text', () async {
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode(
          'data: {"choices":[{"delta":{}}]}\n\n'
          'data: {"choices":[{"delta":{"content":"late"}}]}\n\n'
          'data: [DONE]\n\n',
        ),
      ], contentType: 'text/event-stream'),
    ]);
    final adapter = OpenAiCompatibleAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
      maxStreamEvents: 1,
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
    expect(
      events.whereType<DirectStreamError>().single.message,
      contains('resource limit'),
    );
    expect(events.whereType<DirectStreamDone>(), isEmpty);
  });

  test(
    'OpenAI adapter enforces raw transfer and absolute time limits',
    () async {
      final oversizedHttp = _QueuedAdapter([
        _Reply.stream([
          utf8.encode(
            'data: {"choices":[{"delta":{"content":"answer"}}]}\n\n'
            'data: [DONE]\n\n',
          ),
        ], contentType: 'text/event-stream'),
      ]);
      final oversizedAdapter = OpenAiCompatibleAdapter(
        dioFactory: (_) => _dio(oversizedHttp),
        closeClients: false,
        maxStreamBytes: 16,
      );

      final oversizedEvents = await oversizedAdapter
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
        oversizedEvents.whereType<DirectStreamError>().single.message,
        contains('transfer limit'),
      );

      final heartbeatHttp = _HeartbeatAdapter(
        utf8.encode(': heartbeat\n\n'),
        contentType: 'text/event-stream',
      );
      final heartbeatAdapter = OpenAiCompatibleAdapter(
        dioFactory: (_) => _dio(heartbeatHttp),
        closeClients: false,
        streamIdleTimeout: const Duration(milliseconds: 100),
        streamMaxDuration: const Duration(milliseconds: 15),
      );

      final heartbeatEvents = await heartbeatAdapter
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
        heartbeatEvents.whereType<DirectStreamError>().single.message,
        contains('time limit'),
      );
      expect(heartbeatHttp.sourceCancelled, isTrue);

      final jsonHeartbeatHttp = _HeartbeatAdapter(
        utf8.encode(' '),
        contentType: 'application/json',
      );
      final jsonHeartbeatAdapter = OpenAiCompatibleAdapter(
        dioFactory: (_) => _dio(jsonHeartbeatHttp),
        closeClients: false,
        streamIdleTimeout: const Duration(milliseconds: 100),
        streamMaxDuration: const Duration(milliseconds: 15),
      );

      final jsonHeartbeatEvents = await jsonHeartbeatAdapter
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
        jsonHeartbeatEvents.whereType<DirectStreamError>().single.message,
        contains('time limit'),
      );
      expect(jsonHeartbeatHttp.sourceCancelled, isTrue);
    },
  );

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
    'OpenAI adapter settles when source cancellation never completes',
    () async {
      final http = _NeverCompletingCancelAdapter(
        utf8.encode(': heartbeat\n\n'),
        contentType: 'text/event-stream',
      );
      final adapter = OpenAiCompatibleAdapter(
        dioFactory: (_) => _dio(http),
        closeClients: false,
        streamIdleTimeout: const Duration(milliseconds: 100),
        streamMaxDuration: const Duration(milliseconds: 15),
      );
      final run = adapter.startCompletion(
        _openAiProfile(),
        DirectCompletionRequest(
          remoteModelId: 'model',
          messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
        ),
      );

      final events = await run.events.toList().timeout(
        const Duration(seconds: 1),
      );
      await run.done.timeout(const Duration(seconds: 1));

      expect(
        events.whereType<DirectStreamError>().single.message,
        contains('time limit'),
      );
      expect(events.whereType<DirectStreamDone>(), isEmpty);
      await http.cancellationStarted.future.timeout(const Duration(seconds: 1));
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

  test('Ollama adapter reports models currently loaded by api/ps', () async {
    final http = _QueuedAdapter([
      _Reply.json({
        'models': [
          {'name': 'llama3.2:latest', 'model': 'llama3.2:latest'},
          {'name': 'vision:latest'},
        ],
      }),
    ]);
    final adapter = OllamaAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );

    final loaded = await adapter.listRunningModelIds(_ollamaProfile());

    expect(loaded, {'llama3.2:latest', 'vision:latest'});
    expect(http.requests.single.method, 'GET');
    expect(
      http.requests.single.uri.toString(),
      'http://localhost:11434/api/ps',
    );
  });

  test('Ollama adapter warms and unloads models with empty chats', () async {
    final http = _QueuedAdapter([
      _Reply.json({'done': true, 'done_reason': 'load'}),
      _Reply.json({'done': true, 'done_reason': 'unload'}),
    ]);
    final adapter = OllamaAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );
    final profile = _ollamaProfile();

    await adapter.loadModel(profile, 'llama3.2:latest', keepAlive: '30m');
    await adapter.unloadModel(profile, 'llama3.2:latest');

    expect(http.requests, hasLength(2));
    final loadBody = http.requests.first.data as Map;
    expect(loadBody['model'], 'llama3.2:latest');
    expect(loadBody['messages'], isEmpty);
    expect(loadBody['stream'], isFalse);
    expect(loadBody['keep_alive'], '30m');
    final unloadBody = http.requests.last.data as Map;
    expect(unloadBody['model'], 'llama3.2:latest');
    expect(unloadBody['messages'], isEmpty);
    expect(unloadBody['stream'], isFalse);
    expect(unloadBody['keep_alive'], 0);
  });

  test(
    'Ollama Cloud rejects local lifecycle calls before network I/O',
    () async {
      final http = _QueuedAdapter(<_Reply>[]);
      final adapter = OllamaAdapter(
        dioFactory: (_) => _dio(http),
        closeClients: false,
      );
      final profile = _ollamaProfile(baseUrl: 'https://ollama.com');

      await expectLater(
        adapter.listRunningModelIds(profile),
        throwsA(
          isA<DirectProviderException>().having(
            (error) => error.message,
            'message',
            contains('unavailable for Ollama Cloud'),
          ),
        ),
      );
      await expectLater(
        adapter.loadModel(profile, 'gpt-oss:120b-cloud'),
        throwsA(isA<DirectProviderException>()),
      );
      await expectLater(
        adapter.unloadModel(profile, 'gpt-oss:120b-cloud'),
        throwsA(isA<DirectProviderException>()),
      );
      expect(http.requests, isEmpty);
    },
  );

  test('Ollama completion applies its per-model keep-alive override', () async {
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode(
          '{"message":{"content":"ok"},"done":true,"eval_count":1}\n',
        ),
      ], contentType: 'application/x-ndjson'),
    ]);
    final adapter = OllamaAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );
    final profile = _ollamaProfile(
      ollamaKeepAliveByModel: const {'llama3.2:latest': '-1'},
    );

    final events = await adapter
        .startCompletion(
          profile,
          DirectCompletionRequest(
            remoteModelId: 'llama3.2:latest',
            messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
          ),
        )
        .events
        .toList();

    expect(events.whereType<DirectStreamDone>(), hasLength(1));
    expect((http.requests.single.data as Map)['keep_alive'], -1);
  });

  test('Ollama Cloud completion omits local keep-alive controls', () async {
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode(
          '{"message":{"content":"ok"},"done":true,"eval_count":1}\n',
        ),
      ], contentType: 'application/x-ndjson'),
    ]);
    final adapter = OllamaAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );
    final profile = _ollamaProfile(
      baseUrl: 'https://ollama.com',
      ollamaKeepAliveByModel: const {'llama3.2:latest': '-1'},
    );

    final events = await adapter
        .startCompletion(
          profile,
          DirectCompletionRequest(
            remoteModelId: 'llama3.2:latest',
            messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
          ),
        )
        .events
        .toList();

    expect(events.whereType<DirectStreamDone>(), hasLength(1));
    expect((http.requests.single.data as Map), isNot(contains('keep_alive')));
    expect(profile.supportsOllamaModelLifecycle, isFalse);
  });

  test('Ollama keep-alive accepts documented values and rejects junk', () {
    expect(normalizeOllamaKeepAlive(' 10M '), '10m');
    expect(normalizeOllamaKeepAlive('1h30m'), '1h30m');
    expect(ollamaKeepAliveApiValue('3600'), 3600);
    expect(ollamaKeepAliveApiValue('-1'), -1);
    expect(() => normalizeOllamaKeepAlive('tomorrow'), throwsFormatException);
  });

  test(
    'Ollama drops image-only non-user history and sends user images',
    () async {
      final http = _QueuedAdapter([
        _Reply.stream([
          utf8.encode('{"message":{"content":"ok"},"done":true}\n'),
        ], contentType: 'application/x-ndjson'),
      ]);
      final adapter = OllamaAdapter(
        dioFactory: (_) => _dio(http),
        closeClients: false,
      );

      await adapter
          .startCompletion(
            _ollamaProfile(),
            DirectCompletionRequest(
              remoteModelId: 'vision-model',
              messages: [
                DirectChatMessage(
                  role: 'system',
                  parts: const [
                    DirectImagePart('https://example.test/system-only.png'),
                  ],
                ),
                DirectChatMessage(
                  role: 'assistant',
                  parts: const [
                    DirectImagePart('https://example.test/assistant-only.png'),
                  ],
                ),
                DirectChatMessage(
                  role: 'system',
                  parts: const [
                    DirectTextPart('instructions'),
                    DirectImagePart('https://example.test/system.png'),
                  ],
                ),
                DirectChatMessage(
                  role: 'assistant',
                  parts: const [
                    DirectTextPart('previous answer'),
                    DirectImagePart('https://example.test/assistant.png'),
                  ],
                ),
                DirectChatMessage(
                  role: 'user',
                  parts: const [
                    DirectTextPart('describe'),
                    DirectImagePart('data:image/png;base64,dXNlcg=='),
                  ],
                ),
              ],
            ),
          )
          .events
          .toList();

      final body = http.requests.single.data as Map;
      final messages = body['messages'] as List;
      expect(messages, hasLength(3));
      expect((messages[0] as Map)['content'], 'instructions');
      expect((messages[0] as Map)['images'], isNull);
      expect((messages[1] as Map)['content'], 'previous answer');
      expect((messages[1] as Map)['images'], isNull);
      expect((messages[2] as Map)['images'], ['dXNlcg==']);
    },
  );

  test(
    'Ollama adapter settles when source cancellation never completes',
    () async {
      final http = _NeverCompletingCancelAdapter(
        utf8.encode('{"message":{"content":""},"done":false}\n'),
        contentType: 'application/x-ndjson',
      );
      final adapter = OllamaAdapter(
        dioFactory: (_) => _dio(http),
        closeClients: false,
        streamIdleTimeout: const Duration(milliseconds: 100),
        streamMaxDuration: const Duration(milliseconds: 15),
      );
      final run = adapter.startCompletion(
        _ollamaProfile(),
        DirectCompletionRequest(
          remoteModelId: 'model',
          messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
        ),
      );

      final events = await run.events.toList().timeout(
        const Duration(seconds: 1),
      );
      await run.done.timeout(const Duration(seconds: 1));

      expect(
        events.whereType<DirectStreamError>().single.message,
        contains('time limit'),
      );
      expect(events.whereType<DirectStreamDone>(), isEmpty);
      await http.cancellationStarted.future.timeout(const Duration(seconds: 1));
    },
  );

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

  test('Ollama merges catalog and api/show capabilities', () async {
    final http = _QueuedAdapter([
      _Reply.json({
        'models': [
          {
            'name': 'catalog-vision',
            'details': {
              'families': ['llama'],
              'capabilities': ['VISION'],
            },
          },
        ],
      }),
      _Reply.json({
        'capabilities': ['completion'],
      }),
    ]);
    final adapter = OllamaAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );

    final model = (await adapter.listModels(_ollamaProfile())).single;

    expect(model.isMultimodal, isTrue);
    expect(model.capabilities['capabilities'], ['vision', 'completion']);
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

  test('Ollama adapter rejects a done-only stream', () async {
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode('{"message":{"content":""},"done":true}\n'),
      ], contentType: 'application/x-ndjson'),
    ]);
    final adapter = OllamaAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );

    final events = await adapter
        .startCompletion(
          _ollamaProfile(),
          DirectCompletionRequest(
            remoteModelId: 'model',
            messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
          ),
        )
        .events
        .toList();

    expect(events.whereType<DirectContentDelta>(), isEmpty);
    expect(events.whereType<DirectReasoningDelta>(), isEmpty);
    expect(events.whereType<DirectStreamError>(), hasLength(1));
    expect(events.whereType<DirectStreamDone>(), isEmpty);
  });

  test('Ollama adapter rejects whitespace-only completion content', () async {
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode('{"message":{"content":"  \\n  "},"done":true}\n'),
      ], contentType: 'application/x-ndjson'),
    ]);
    final adapter = OllamaAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );

    final events = await adapter
        .startCompletion(
          _ollamaProfile(),
          DirectCompletionRequest(
            remoteModelId: 'model',
            messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
          ),
        )
        .events
        .toList();

    expect(events.whereType<DirectContentDelta>(), hasLength(1));
    expect(events.whereType<DirectStreamError>(), hasLength(1));
    expect(events.whereType<DirectStreamDone>(), isEmpty);
  });

  test(
    'Ollama adapter preserves whitespace before real streamed text',
    () async {
      final http = _QueuedAdapter([
        _Reply.stream([
          utf8.encode(
            '{"message":{"content":"  "},"done":false}\n'
            '{"message":{"content":"answer"},"done":true}\n',
          ),
        ], contentType: 'application/x-ndjson'),
      ]);
      final adapter = OllamaAdapter(
        dioFactory: (_) => _dio(http),
        closeClients: false,
      );

      final events = await adapter
          .startCompletion(
            _ollamaProfile(),
            DirectCompletionRequest(
              remoteModelId: 'model',
              messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
            ),
          )
          .events
          .toList();

      expect(
        events.whereType<DirectContentDelta>().map((event) => event.content),
        ['  ', 'answer'],
      );
      expect(events.whereType<DirectStreamDone>(), hasLength(1));
    },
  );

  test('Ollama adapter redacts credentials from provider errors', () async {
    const apiKey = 'ollama-api-key-value';
    const headerSecret = 'ollama-header-value';
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode(
          '${jsonEncode({'error': 'Bearer $apiKey and $headerSecret\u0000\nprovider detail'})}\n',
        ),
      ], contentType: 'application/x-ndjson'),
    ]);
    final adapter = OllamaAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );

    final events = await adapter
        .startCompletion(
          _ollamaProfile(
            apiKey: apiKey,
            customHeaders: const {'X-Service-Token': headerSecret},
          ),
          DirectCompletionRequest(
            remoteModelId: 'model',
            messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
          ),
        )
        .events
        .toList();

    final message = events.whereType<DirectStreamError>().single.message;
    expect(message, isNot(contains(apiKey)));
    expect(message, isNot(contains(headerSecret)));
    expect(message, isNot(contains('\u0000')));
    expect(message, contains('provider detail'));
    expect(events.whereType<DirectStreamDone>(), isEmpty);
  });

  test(
    'Ollama adapter redacts secrets before truncating provider errors',
    () async {
      const apiKey = 'LEAKME-ollama-secret-crossing-the-boundary';
      final reflected = '${List.filled(507, 'x').join()}$apiKey';
      final http = _QueuedAdapter([
        _Reply.stream([
          utf8.encode('${jsonEncode({'error': reflected})}\n'),
        ], contentType: 'application/x-ndjson'),
      ]);
      final adapter = OllamaAdapter(
        dioFactory: (_) => _dio(http),
        closeClients: false,
      );

      final events = await adapter
          .startCompletion(
            _ollamaProfile(apiKey: apiKey),
            DirectCompletionRequest(
              remoteModelId: 'model',
              messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
            ),
          )
          .events
          .toList();

      final message = events.whereType<DirectStreamError>().single.message;
      expect(message, isNot(contains('LEAK')));
      expect(message.runes.length, kMaxDirectProviderErrorCharacters);
    },
  );

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

  test('Ollama adapter bounds decoded frames that emit no text', () async {
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode(
          '{"message":{"content":""},"done":false}\n'
          '{"message":{"content":"late"},"done":true}\n',
        ),
      ], contentType: 'application/x-ndjson'),
    ]);
    final adapter = OllamaAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
      maxStreamEvents: 1,
    );

    final events = await adapter
        .startCompletion(
          _ollamaProfile(),
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
      contains('resource limit'),
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
            DirectChatMessage(
              role: 'system',
              parts: const [
                DirectImagePart('data:image/png;base64,c3lzdGVtLW9ubHk='),
              ],
            ),
            DirectChatMessage(
              role: 'assistant',
              parts: const [
                DirectImagePart('data:image/png;base64,YXNzaXN0YW50LW9ubHk='),
              ],
            ),
            DirectChatMessage.text(role: 'system', text: 'be concise'),
            DirectChatMessage.text(
              role: 'observer',
              text: 'compatible-provider extension role',
            ),
            DirectChatMessage(
              role: 'assistant',
              parts: const [
                DirectTextPart('previous answer'),
                DirectImagePart('data:image/png;base64,YXNzaXN0YW50'),
              ],
            ),
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

  test(
    'OpenAI adapter rejects whitespace-only Responses JSON output',
    () async {
      final http = _QueuedAdapter([
        _Reply.json({
          'id': 'resp_whitespace',
          'object': 'response',
          'created_at': 1,
          'status': 'completed',
          'output': [
            {
              'type': 'message',
              'id': 'msg_whitespace',
              'role': 'assistant',
              'status': 'completed',
              'content': [
                {'type': 'output_text', 'text': ' \n\t '},
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

      expect(events.whereType<DirectContentDelta>().single.content, ' \n\t ');
      expect(events.whereType<DirectStreamError>(), hasLength(1));
      expect(events.whereType<DirectStreamDone>(), isEmpty);
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

  test(
    'Responses completion appends missing text and reasoning suffixes',
    () async {
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
            'data: ${jsonEncode({'type': 'response.reasoning_summary_text.delta', 'output_index': 0, 'summary_index': 0, 'delta': 'complete-'})}\n\n'
            'data: ${jsonEncode({'type': 'response.output_text.delta', 'output_index': 1, 'content_index': 0, 'delta': 'recovered-'})}\n\n'
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
        events
            .whereType<DirectReasoningDelta>()
            .map((event) => event.content)
            .join(),
        'complete-thought',
      );
      expect(
        events
            .whereType<DirectContentDelta>()
            .map((event) => event.content)
            .join(),
        'recovered-answer',
      );
      expect(events.whereType<DirectStreamDone>(), hasLength(1));
    },
  );

  test(
    'Responses completion keeps reasoning text and summary channels distinct',
    () async {
      final completed = {
        'type': 'response.completed',
        'response': {
          'id': 'resp_reasoning_channels',
          'object': 'response',
          'created_at': 1,
          'status': 'completed',
          'output': [
            {
              'type': 'reasoning',
              'id': 'reason_channels',
              'content': [
                {'type': 'reasoning_text', 'text': 'detail-full'},
              ],
              'summary': [
                {'type': 'summary_text', 'text': 'summary-full'},
              ],
            },
            {
              'type': 'message',
              'id': 'msg_channels',
              'role': 'assistant',
              'status': 'completed',
              'content': [
                {'type': 'output_text', 'text': 'answer'},
              ],
            },
          ],
        },
      };
      final http = _QueuedAdapter([
        _Reply.stream([
          utf8.encode(
            'data: ${jsonEncode({'type': 'response.reasoning_text.delta', 'output_index': 0, 'content_index': 0, 'delta': 'detail-full'})}\n\n'
            'data: ${jsonEncode({'type': 'response.reasoning_summary_text.delta', 'output_index': 0, 'summary_index': 0, 'delta': 'summary-full'})}\n\n'
            'data: ${jsonEncode({'type': 'response.output_text.delta', 'output_index': 1, 'content_index': 0, 'delta': 'answer'})}\n\n'
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
        events
            .whereType<DirectReasoningDelta>()
            .map((event) => event.content)
            .toList(),
        ['detail-full', 'summary-full'],
      );
      expect(events.whereType<DirectContentDelta>().single.content, 'answer');
      expect(events.whereType<DirectStreamError>(), isEmpty);
      expect(events.whereType<DirectStreamDone>(), hasLength(1));
    },
  );

  test('Responses completion preserves streamed reasoning item boundaries', () async {
    final completed = {
      'type': 'response.completed',
      'response': {
        'id': 'resp_reasoning_items',
        'object': 'response',
        'created_at': 1,
        'status': 'completed',
        'output': [
          {
            'type': 'reasoning',
            'id': 'reason_1',
            'content': [
              {'type': 'reasoning_text', 'text': 'detail one'},
            ],
            'summary': [
              {'type': 'summary_text', 'text': 'summary one'},
            ],
          },
          {
            'type': 'reasoning',
            'id': 'reason_2',
            'content': [
              {'type': 'reasoning_text', 'text': 'detail two'},
            ],
            'summary': [
              {'type': 'summary_text', 'text': 'summary two'},
            ],
          },
          {
            'type': 'message',
            'id': 'msg_reasoning_items',
            'role': 'assistant',
            'status': 'completed',
            'content': [
              {'type': 'output_text', 'text': 'answer'},
            ],
          },
        ],
      },
    };
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode(
          'data: ${jsonEncode({'type': 'response.reasoning_text.delta', 'output_index': 0, 'content_index': 0, 'delta': 'detail one'})}\n\n'
          'data: ${jsonEncode({'type': 'response.reasoning_text.delta', 'output_index': 1, 'content_index': 0, 'delta': 'detail two'})}\n\n'
          'data: ${jsonEncode({'type': 'response.reasoning_summary_text.delta', 'output_index': 0, 'summary_index': 0, 'delta': 'summary one'})}\n\n'
          'data: ${jsonEncode({'type': 'response.reasoning_summary_text.delta', 'output_index': 1, 'summary_index': 0, 'delta': 'summary two'})}\n\n'
          'data: ${jsonEncode({'type': 'response.output_text.delta', 'output_index': 2, 'content_index': 0, 'delta': 'answer'})}\n\n'
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
      events
          .whereType<DirectReasoningDelta>()
          .map((event) => event.content)
          .join(),
      'detail one\ndetail twosummary one\nsummary two',
    );
    expect(events.whereType<DirectContentDelta>().single.content, 'answer');
    expect(events.whereType<DirectStreamError>(), isEmpty);
    expect(events.whereType<DirectStreamDone>(), hasLength(1));
  });

  test('Responses completion rejects divergent streamed output', () async {
    final completed = {
      'type': 'response.completed',
      'response': {
        'id': 'resp_divergent',
        'object': 'response',
        'created_at': 1,
        'status': 'completed',
        'output': [
          {
            'type': 'message',
            'id': 'msg_divergent',
            'role': 'assistant',
            'status': 'completed',
            'content': [
              {'type': 'output_text', 'text': 'Goodbye'},
            ],
          },
        ],
      },
    };
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode(
          'data: ${jsonEncode({'type': 'response.output_text.delta', 'output_index': 0, 'content_index': 0, 'delta': 'Hello'})}\n\n'
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

    expect(events.whereType<DirectContentDelta>().single.content, 'Hello');
    expect(
      events.whereType<DirectStreamError>().single.message,
      contains('do not match'),
    );
    expect(events.whereType<DirectStreamDone>(), isEmpty);
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

  test('Ollama Cloud runs a bounded native web-search agent loop', () async {
    final http = _QueuedAdapter([
      _Reply.stream([
        utf8.encode(
          '${jsonEncode({
            'model': 'gpt-oss:120b',
            'message': {
              'role': 'assistant',
              'thinking': 'I should search.',
              'content': '',
              'tool_calls': [
                {
                  'function': {
                    'name': 'web_search',
                    'arguments': {'query': 'Ollama Cloud documentation', 'max_results': 2},
                  },
                },
              ],
            },
            'done': true,
          })}\n',
        ),
      ], contentType: 'application/x-ndjson'),
      _Reply.json({
        'results': [
          {
            'title': 'Ollama Cloud',
            'url': 'https://docs.ollama.com/cloud',
            'content': 'Cloud models run remotely.',
          },
        ],
      }),
      _Reply.stream([
        utf8.encode(
          '${jsonEncode({
            'model': 'gpt-oss:120b',
            'message': {'role': 'assistant', 'content': 'Cloud models run remotely.'},
            'done': true,
            'prompt_eval_count': 12,
            'eval_count': 5,
          })}\n',
        ),
      ], contentType: 'application/x-ndjson'),
    ]);
    final adapter = OllamaAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );
    final run = adapter.startCompletion(
      _ollamaProfile(
        baseUrl: 'https://ollama.com',
        ollamaThinkingByModel: const {'gpt-oss:120b': 'medium'},
      ),
      DirectCompletionRequest(
        remoteModelId: 'gpt-oss:120b',
        messages: [DirectChatMessage.text(role: 'user', text: 'Research this')],
        enableWebSearch: true,
      ),
    );

    final events = await run.events.toList();
    await run.done;

    expect(http.requests.map((request) => request.path), [
      'api/chat',
      'api/web_search',
      'api/chat',
    ]);
    final firstChat = http.requests.first.data as Map<String, dynamic>;
    expect(firstChat['think'], 'medium');
    expect(firstChat['tools'], isA<List>());
    final secondChat = http.requests.last.data as Map<String, dynamic>;
    final replayMessages = secondChat['messages'] as List;
    expect(
      replayMessages.whereType<Map>().map((message) => message['role']),
      containsAllInOrder(['user', 'assistant', 'tool']),
    );
    expect(events.whereType<DirectToolCallStarted>(), hasLength(1));
    final completed = events.whereType<DirectToolCallCompleted>().single;
    expect(completed.name, 'web_search');
    expect(completed.isError, isFalse);
    expect(
      events.whereType<DirectContentDelta>().last.content,
      'Cloud models run remotely.',
    );
    expect(events.whereType<DirectStreamError>(), isEmpty);
    expect(events.whereType<DirectStreamDone>(), hasLength(1));
  });

  test('self-hosted Ollama rejects the Cloud web-search capability', () async {
    final http = _QueuedAdapter(const []);
    final adapter = OllamaAdapter(
      dioFactory: (_) => _dio(http),
      closeClients: false,
    );
    final run = adapter.startCompletion(
      _ollamaProfile(),
      DirectCompletionRequest(
        remoteModelId: 'model',
        messages: [DirectChatMessage.text(role: 'user', text: 'hello')],
        enableWebSearch: true,
      ),
    );

    final events = await run.events.toList();

    expect(http.requests, isEmpty);
    expect(
      events.whereType<DirectStreamError>().single.message,
      'Ollama web search requires an Ollama Cloud connection.',
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
  String apiKey = 'secret',
  Map<String, String> customHeaders = const {},
}) => DirectConnectionProfile(
  id: 'openai-one',
  name: 'OpenAI compatible',
  adapterKey: kOpenAiCompatibleAdapterKey,
  baseUrl: 'https://api.test/v1',
  apiKey: apiKey,
  customHeaders: customHeaders,
  manualModelIds: manualModelIds,
  openAiApiMode: openAiApiMode,
  apiKeyAuthMode: apiKeyAuthMode,
  apiVersion: apiVersion,
);

DirectConnectionProfile _ollamaProfile({
  String baseUrl = 'http://localhost:11434',
  List<String> manualModelIds = const [],
  String? apiKey,
  Map<String, String> customHeaders = const {},
  Map<String, String> ollamaKeepAliveByModel = const {},
  Map<String, String> ollamaThinkingByModel = const {},
}) => DirectConnectionProfile(
  id: 'ollama-one',
  name: 'Ollama',
  adapterKey: kOllamaAdapterKey,
  baseUrl: baseUrl,
  apiKey: apiKey,
  customHeaders: customHeaders,
  manualModelIds: manualModelIds,
  ollamaKeepAliveByModel: ollamaKeepAliveByModel,
  ollamaThinkingByModel: ollamaThinkingByModel,
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

final class _NeverEndingStreamAdapter implements HttpClientAdapter {
  _NeverEndingStreamAdapter(this.chunk, {required this.contentType});

  final List<int> chunk;
  final String contentType;
  final Completer<void> sourceCancelled = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    late final StreamController<Uint8List> controller;
    controller = StreamController<Uint8List>(
      onListen: () => controller.add(Uint8List.fromList(chunk)),
      onCancel: () {
        if (!sourceCancelled.isCompleted) sourceCancelled.complete();
      },
    );
    return ResponseBody(
      controller.stream,
      200,
      headers: {
        'content-type': [contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _HeartbeatAdapter implements HttpClientAdapter {
  _HeartbeatAdapter(this.chunk, {required this.contentType});

  final List<int> chunk;
  final String contentType;
  bool sourceCancelled = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    late Timer timer;
    late final StreamController<Uint8List> controller;
    controller = StreamController<Uint8List>(
      onListen: () {
        timer = Timer.periodic(
          const Duration(milliseconds: 2),
          (_) => controller.add(Uint8List.fromList(chunk)),
        );
      },
      onCancel: () {
        sourceCancelled = true;
        timer.cancel();
      },
    );
    return ResponseBody(
      controller.stream,
      200,
      headers: {
        'content-type': [contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _NeverCompletingCancelAdapter implements HttpClientAdapter {
  _NeverCompletingCancelAdapter(this.chunk, {required this.contentType});

  final List<int> chunk;
  final String contentType;
  final Completer<void> cancellationStarted = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    late Timer timer;
    late final StreamController<Uint8List> controller;
    controller = StreamController<Uint8List>(
      onListen: () {
        timer = Timer.periodic(
          const Duration(milliseconds: 2),
          (_) => controller.add(Uint8List.fromList(chunk)),
        );
      },
      onCancel: () {
        timer.cancel();
        if (!cancellationStarted.isCompleted) cancellationStarted.complete();
        return Completer<void>().future;
      },
    );
    return ResponseBody(
      controller.stream,
      200,
      headers: {
        'content-type': [contentType],
      },
    );
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

final class _ForeignStackAdapter implements HttpClientAdapter {
  _ForeignStackAdapter({required this.error, required this.stackTrace});

  final Object error;
  final StackTrace stackTrace;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody(
      Stream<Uint8List>.error(error, stackTrace),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
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
