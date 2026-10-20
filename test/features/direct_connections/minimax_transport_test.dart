import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/services/openai_compatible_adapter.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final baseUrl in [kMiniMaxApiBaseUrl, kMiniMaxCnApiBaseUrl]) {
    test(
      '$baseUrl discovers Flash first and preserves manual legacy IDs',
      () async {
        final transport = _Transport([]);
        final adapter = _adapter(transport);
        final models = await adapter.listModels(_profile(baseUrl));
        expect(models.map((model) => model.id), kMiniMaxModelIds);
        final saved = await adapter.listModels(
          _profile(baseUrl)
              .copyWith(manualModelIds: ['MiniMax-M2.7', 'custom']),
        );
        expect(saved.map((model) => model.id), ['MiniMax-M2.7', 'custom']);
        expect(transport.requests, isEmpty);
      },
    );

    test('$baseUrl sends images and assistant reasoning unchanged', () async {
      final transport = _Transport([_completion]);
      final events = await _run(
        transport,
        _profile(baseUrl),
        parameters: const {'reasoning_effort': 'max'},
      );
      expect(events.whereType<DirectStreamError>(), isEmpty);
      final request = transport.requests.single;
      expect(request.uri.toString(), '$baseUrl/chat/completions');
      final body = _body(request);
      expect(body['model'], 'MiniMax-M3.1-Flash');
      expect(body['reasoning_effort'], 'max');
      expect(body.containsKey('service_tier'), isFalse);
      final messages = body['messages'] as List;
      expect(messages[0]['reasoning_content'], 'Keep this reasoning');
      expect(messages[1]['content'][1]['image_url']['url'], _image);
    });

    for (final effort in ['low', 'medium', 'high', 'xhigh', 'max']) {
      test('$baseUrl permits Flash effort $effort', () async {
        final transport = _Transport([_completion]);
        final events = await _run(
          transport,
          _profile(baseUrl),
          parameters: {
            'reasoning_effort': effort,
            'thinking': {'type': 'adaptive'},
          },
        );
        expect(events.whereType<DirectStreamError>(), isEmpty);
        expect(_body(transport.requests.single)['reasoning_effort'], effort);
      });
    }

    for (final parameters in [
      {'reasoning_effort': 'none'},
      {
        'thinking': {'type': 'disabled'},
      },
      {'reasoning_split': false},
      {'service_tier': 'priority'},
    ]) {
      test(
        '$baseUrl rejects unsupported Flash controls $parameters before HTTP',
        () async {
          final transport = _Transport([]);
          final events = await _run(
            transport,
            _profile(baseUrl),
            parameters: parameters,
          );
          expect(events.whereType<DirectStreamError>().isNotEmpty, isTrue);
          expect(transport.requests, isEmpty);
        },
      );
    }
  }

  test(
    'international Responses sends full reasoning and image history',
    () async {
      final transport = _Transport([
        {
          'id': 'resp_1',
          'object': 'response',
          'status': 'completed',
          'output': [
            {
              'id': 'msg-1',
              'type': 'message',
              'role': 'assistant',
              'status': 'completed',
              'content': [
                {'type': 'output_text', 'text': 'Done'},
              ],
            },
          ],
        },
      ]);
      final events = await _run(
        transport,
        _profile(kMiniMaxApiBaseUrl, mode: DirectOpenAiApiMode.responses),
        parameters: const {
          'reasoning_effort': 'high',
          'store': true,
          'previous_response_id': 'old-response',
          'conversation': 'old-conversation',
        },
      );
      expect(events.whereType<DirectStreamError>(), isEmpty);
      final request = transport.requests.single;
      expect(request.uri.toString(), '$kMiniMaxApiBaseUrl/responses');
      final body = _body(request);
      expect(body['reasoning'], {'effort': 'high'});
      expect(body['store'], isFalse);
      expect(body.containsKey('previous_response_id'), isFalse);
      expect(body.containsKey('conversation'), isFalse);
      final input = body['input'] as List;
      expect(input.any((dynamic item) => item['type'] == 'reasoning'), isTrue);
      expect(jsonEncode(input), contains(_image));
    },
  );

  for (final mode in DirectOpenAiApiMode.values) {
    test(
      'MiniMax $mode replays tool result and reasoning on the next HTTP round',
      () async {
        final responses = mode == DirectOpenAiApiMode.responses;
        final transport = _Transport([
          if (responses)
            {
              'id': 'resp-tool',
              'status': 'completed',
              'output': [
                {
                  'type': 'reasoning',
                  'id': 'reason-1',
                  'summary': [
                    {'type': 'summary_text', 'text': 'Need lookup'},
                  ],
                },
                {
                  'type': 'function_call',
                  'id': 'fc-1',
                  'call_id': 'call-1',
                  'name': 'lookup',
                  'arguments': '{}',
                  'status': 'completed',
                },
              ],
            }
          else
            {
              'id': 'chat-tool',
              'choices': [
                {
                  'index': 0,
                  'finish_reason': 'tool_calls',
                  'message': {
                    'role': 'assistant',
                    'reasoning_content': 'Need lookup',
                    'tool_calls': [
                      {
                        'id': 'call-1',
                        'type': 'function',
                        'function': {'name': 'lookup', 'arguments': '{}'},
                      },
                    ],
                  },
                },
              ],
            },
          if (responses)
            {
              'id': 'resp-final',
              'status': 'completed',
              'output': [
                {
                  'id': 'msg-final',
                  'type': 'message',
                  'role': 'assistant',
                  'status': 'completed',
                  'content': [
                    {'type': 'output_text', 'text': 'Done'},
                  ],
                },
              ],
            }
          else
            _completion,
        ]);
        final run = _adapter(transport).startCompletion(
          _profile(kMiniMaxApiBaseUrl, mode: mode),
          DirectCompletionRequest(
            remoteModelId: 'MiniMax-M3.1-Flash',
            messages: [
              DirectChatMessage(
                role: 'user',
                parts: const [
                  DirectTextPart('Look up this image'),
                  DirectImagePart(_image),
                ],
              ),
            ],
            tools: _tools(),
          ),
        );
        final events = await run.events.toList();
        await run.done;
        expect(events.whereType<DirectStreamError>(), isEmpty);
        expect(transport.requests, hasLength(2));
        final first = _body(transport.requests.first);
        final second = _body(transport.requests.last);
        expect(first['tools'], isNotEmpty);
        expect(jsonEncode(second), contains(_image));
        if (responses) {
          final input = second['input'] as List;
          expect(
            input.any((dynamic item) => item['type'] == 'reasoning'),
            isTrue,
          );
          expect(
            input.any(
              (dynamic item) =>
                  item['type'] == 'function_call' &&
                  item['call_id'] == 'call-1',
            ),
            isTrue,
          );
          expect(
            input.any(
              (dynamic item) =>
                  item['type'] == 'function_call_output' &&
                  item['call_id'] == 'call-1' &&
                  item['output'] == 'lookup result',
            ),
            isTrue,
          );
          expect(second.containsKey('previous_response_id'), isFalse);
        } else {
          final messages = second['messages'] as List;
          expect(messages[1]['reasoning_content'], 'Need lookup');
          expect(messages[1]['tool_calls'][0]['id'], 'call-1');
          expect(messages[2]['tool_call_id'], 'call-1');
          expect(messages[2]['content'], 'lookup result');
        }
      },
    );
  }

  test('Responses rejects none effort before HTTP', () async {
    final transport = _Transport([]);
    final events = await _run(
      transport,
      _profile(kMiniMaxApiBaseUrl, mode: DirectOpenAiApiMode.responses),
      parameters: const {
        'reasoning': {'effort': 'none'},
      },
    );
    expect(events.whereType<DirectStreamError>().isNotEmpty, isTrue);
    expect(transport.requests, isEmpty);
  });

  test(
    'M3 disabled thinking and explicit legacy/custom requests remain intact',
    () async {
      for (final model in ['MiniMax-M3', 'MiniMax-M2.7', 'my-custom-model']) {
        final transport = _Transport([_completion]);
        final events = await _run(
          transport,
          _profile(kMiniMaxApiBaseUrl),
          model: model,
          parameters: const {
            'thinking': {'type': 'disabled'},
            'service_tier': 'priority',
          },
        );
        expect(events.whereType<DirectStreamError>(), isEmpty);
        expect(_body(transport.requests.single)['model'], model);
        expect(_body(transport.requests.single)['thinking'], {
          'type': 'disabled',
        });
        expect(_body(transport.requests.single)['service_tier'], 'priority');
      }
    },
  );

  test(
    'gateway picker limits only MiniMax text and retains gateway metadata',
    () async {
      final transport = _Transport([
        {
          'data': [
            {'id': 'other/provider'},
            {'id': 'minimax/minimax-m3', 'context_length': 524288},
            {'id': 'minimax/minimax-m2.7'},
            {
              'id': 'minimax/image-model',
              'architecture': {
                'output_modalities': ['image'],
              },
            },
            {'id': 'minimax/minimax-m3.1-flash:free', 'context_length': 262144},
          ],
        },
      ]);
      final models = await _adapter(transport)
          .listModels(_profile(kOpenRouterApiBaseUrl));
      expect(models.map((model) => model.id), [
        'other/provider',
        'minimax/minimax-m3.1-flash:free',
        'minimax/image-model',
        'minimax/minimax-m3',
      ]);
      expect(models[1].capabilities['context_length'], 262144);
      expect(models[3].capabilities['context_length'], 524288);
    },
  );

  test(
    'gateway Flash serializes its verified route and gateway reasoning',
    () async {
      final transport = _Transport([_completion]);
      final events = await _run(
        transport,
        _profile(kOpenRouterApiBaseUrl),
        model: 'minimax/minimax-m3.1-flash:free',
        parameters: const {'reasoning_effort': 'high'},
      );
      expect(events.whereType<DirectStreamError>(), isEmpty);
      final body = _body(transport.requests.single);
      expect(body['model'], 'minimax/minimax-m3.1-flash:free');
      expect(body['reasoning'], {'effort': 'high'});
      expect(body.containsKey('reasoning_effort'), isFalse);
      expect(
        (body['messages'] as List).first['reasoning_content'],
        'Keep this reasoning',
      );
    },
  );

  test('gateway Flash rejects disabled reasoning before HTTP', () async {
    final transport = _Transport([]);
    final events = await _run(
      transport,
      _profile(kOpenRouterApiBaseUrl),
      model: 'minimax/minimax-m3.1-flash:free',
      parameters: const {'reasoning_effort': 'none'},
    );
    expect(events.whereType<DirectStreamError>().isNotEmpty, isTrue);
    expect(transport.requests, isEmpty);
  });

  test(
    'unrelated providers and lookalike URLs retain their controls',
    () async {
      for (final url in [
        'https://example.com/v1',
        'https://api.minimax.io.example.com/v1',
      ]) {
        final transport = _Transport([_completion]);
        final events = await _run(
          transport,
          _profile(url),
          parameters: const {
            'reasoning_effort': 'none',
            'service_tier': 'priority',
          },
        );
        expect(events.whereType<DirectStreamError>(), isEmpty);
        final body = _body(transport.requests.single);
        expect(body['reasoning_effort'], 'none');
        expect(body['service_tier'], 'priority');
        expect(
          (body['messages'] as List).first.containsKey('reasoning_content'),
          isFalse,
        );
      }
    },
  );
}

const _image = 'data:image/png;base64,aGVsbG8=';
const _completion = {
  'id': 'completion-1',
  'choices': [
    {
      'index': 0,
      'message': {'role': 'assistant', 'content': 'Done'},
      'finish_reason': 'stop',
    },
  ],
};

DirectConnectionProfile _profile(
  String url, {
  DirectOpenAiApiMode mode = DirectOpenAiApiMode.chatCompletions,
}) => DirectConnectionProfile(
  id: 'offline-fixture',
  name: 'Offline fixture',
  adapterKey: kOpenAiCompatibleAdapterKey,
  baseUrl: url,
  openAiApiMode: mode,
);

OpenAiCompatibleAdapter _adapter(_Transport transport) =>
    OpenAiCompatibleAdapter(
      dioFactory: (_) => Dio()..httpClientAdapter = transport,
    );

Future<List<DirectStreamEvent>> _run(
  _Transport transport,
  DirectConnectionProfile profile, {
  String model = 'MiniMax-M3.1-Flash',
  Map<String, dynamic> parameters = const {},
}) async {
  final run = _adapter(transport).startCompletion(
    profile,
    DirectCompletionRequest(
      remoteModelId: model,
      parameters: parameters,
      messages: [
        DirectChatMessage(
          role: 'assistant',
          parts: const [DirectTextPart('Previous answer')],
          reasoning: 'Keep this reasoning',
        ),
        DirectChatMessage(
          role: 'user',
          parts: const [
            DirectTextPart('Describe this image'),
            DirectImagePart(_image),
          ],
        ),
      ],
    ),
  );
  final events = await run.events.toList();
  await run.done;
  return events;
}

DirectToolRuntime _tools() => DirectToolRuntime(
  definitions: [
    DirectToolDefinition(
      name: 'lookup',
      serverId: 'fixture',
      serverName: 'Fixture',
      remoteName: 'lookup',
      displayName: 'Lookup',
      description: 'Offline lookup',
      approvalFingerprint: 'a' * 64,
      inputSchema: const {'type': 'object'},
    ),
  ],
  requestApproval: (callId, definition, arguments) => DirectToolApprovalHandle(
    request: DirectToolApprovalRequest(
      id: 'approval',
      serverName: definition.serverName,
      toolName: definition.displayName,
      callId: callId,
      argumentsJson: jsonEncode(arguments),
    ),
    decision: Future.value(DirectToolApprovalDecision.allowOnce),
    requiresUserDecision: false,
  ),
  execute: (_, _) async => const DirectToolResult(text: 'lookup result'),
);

Map<String, dynamic> _body(RequestOptions request) =>
    request.extra['serializedBody'] as Map<String, dynamic>;

final class _Transport implements HttpClientAdapter {
  _Transport(this.replies);
  final List<Map<String, dynamic>> replies;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requestStream != null) {
      options.extra['serializedBody'] = jsonDecode(
        await utf8.decoder.bind(requestStream).join(),
      );
    }
    return ResponseBody.fromString(
      jsonEncode({
        if (options.path == 'responses') 'object': 'response',
        if (options.path == 'responses') 'created_at': 1,
        ...replies.removeAt(0),
      }),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
