import 'dart:async';
import 'dart:convert';

import 'package:conduit/core/platform/conduit_platform_apis.g.dart';
import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/services/direct_adapter_helpers.dart';
import 'package:conduit/features/direct_connections/services/apple_pcc_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'PCC profile is app-owned and exposes one model when available',
    () async {
      final host = _FakePccHost();
      final adapter = ApplePccAdapter(hostApi: host);
      final profile = DirectConnectionProfile.applePrivateCloudCompute();

      expect(profile.validateOrNull(), isNull);
      expect(profile.isApplePrivateCloudCompute, isTrue);
      final models = await adapter.listModels(profile);
      expect(models, hasLength(1));
      expect(models.single.isMultimodal, isTrue);
      expect(models.single.capabilities['context_length'], 32768);
    },
  );

  test('on-device profile routes through the iOS 26 system model', () async {
    final host = _FakePccHost();
    final adapter = ApplePccAdapter(hostApi: host);
    final profile = DirectConnectionProfile.appleOnDevice();

    expect(profile.validateOrNull(), isNull);
    expect(profile.isAppleOnDevice, isTrue);
    final models = await adapter.listModels(profile);
    expect(models.single.id, kAppleOnDeviceRemoteModelId);
    expect(models.single.isMultimodal, isFalse);
    expect(models.single.capabilities['context_length'], 4096);

    final run = adapter.startCompletion(
      profile,
      DirectCompletionRequest(
        remoteModelId: kAppleOnDeviceRemoteModelId,
        messages: <DirectChatMessage>[
          DirectChatMessage.text(role: 'user', text: 'Hello'),
        ],
      ),
    );
    final events = run.events.toList();
    await host.started.future;
    expect(host.request?.model, PlatformAppleModel.onDevice);
    expect(host.request?.allowOnDeviceFallback, isFalse);
    await run.cancel();
    expect(await events, isEmpty);
  });

  test('PCC adapter maps keyed native events into a Direct run', () async {
    final host = _FakePccHost();
    final adapter = ApplePccAdapter(
      hostApi: host,
      allowOnDeviceFallback: () => true,
    );
    final run = adapter.startCompletion(
      DirectConnectionProfile.applePrivateCloudCompute(),
      DirectCompletionRequest(
        remoteModelId: kApplePccRemoteModelId,
        messages: <DirectChatMessage>[
          DirectChatMessage(
            role: 'user',
            parts: const <DirectContentPart>[
              DirectTextPart('Hello'),
              DirectImagePart('data:image/png;base64,AQID'),
            ],
          ),
        ],
        parameters: const <String, dynamic>{
          'reasoning_effort': 'moderate',
          'temperature': 0.4,
          'max_tokens': 123,
          'top_p': 0.9,
          'seed': 42,
          'response_format': <String, dynamic>{
            'type': 'json_schema',
            'json_schema': <String, dynamic>{
              'name': 'Answer',
              'schema': <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{
                  'answer': <String, dynamic>{'type': 'string'},
                },
                'required': <String>['answer'],
              },
            },
          },
        },
      ),
    );
    final events = run.events.toList();
    await host.started.future;

    adapter.onEvent(
      PlatformPccStreamEvent(
        runId: run.id,
        kind: PlatformPccEventKind.fallback,
      ),
    );
    adapter.onEvent(
      PlatformPccStreamEvent(
        runId: run.id,
        kind: PlatformPccEventKind.content,
        content: 'Hi',
      ),
    );
    adapter.onEvent(
      PlatformPccStreamEvent(
        runId: run.id,
        kind: PlatformPccEventKind.usage,
        inputTokenCount: 3,
        outputTokenCount: 2,
        reasoningTokenCount: 1,
        totalTokenCount: 5,
      ),
    );
    adapter.onEvent(
      PlatformPccStreamEvent(runId: run.id, kind: PlatformPccEventKind.done),
    );

    final received = await events;
    expect(received[0], isA<DirectProviderMetadataUpdate>());
    expect((received[1] as DirectContentDelta).content, 'Hi');
    expect((received[2] as DirectUsageUpdate).usage['reasoning_tokens'], 1);
    expect(received[3], isA<DirectStreamDone>());
    expect(host.request?.model, PlatformAppleModel.privateCloudCompute);
    expect(host.request?.reasoningLevel, 'moderate');
    expect(host.request?.allowOnDeviceFallback, isTrue);
    expect(host.request?.messages.single.images.single.bytes, <int>[1, 2, 3]);
    expect(host.request?.temperature, 0.4);
    expect(host.request?.maximumResponseTokens, 123);
    expect(host.request?.topP, 0.9);
    expect(host.request?.seed, 42);
    expect(host.request?.responseSchemaName, 'Answer');
    expect(host.request?.responseSchemaJson, contains('"answer"'));
  });

  test('PCC rejects conflicting sampling controls', () {
    final adapter = ApplePccAdapter(hostApi: _FakePccHost());
    expect(
      () => adapter.startCompletion(
        DirectConnectionProfile.applePrivateCloudCompute(),
        DirectCompletionRequest(
          remoteModelId: kApplePccRemoteModelId,
          messages: <DirectChatMessage>[
            DirectChatMessage.text(role: 'user', text: 'Hello'),
          ],
          parameters: const <String, dynamic>{'top_p': 0.9, 'top_k': 40},
        ),
      ),
      throwsA(isA<DirectProviderException>()),
    );
  });

  test(
    'PCC bridges approved local MCP tools through the native session',
    () async {
      final host = _FakePccHost();
      final approval = Completer<DirectToolApprovalDecision>();
      final approvalRequested = Completer<void>();
      Map<String, dynamic>? executedArguments;
      final adapter = ApplePccAdapter(hostApi: host);
      final run = adapter.startCompletion(
        DirectConnectionProfile.applePrivateCloudCompute(),
        DirectCompletionRequest(
          remoteModelId: kApplePccRemoteModelId,
          messages: <DirectChatMessage>[
            DirectChatMessage.text(role: 'user', text: 'Hello'),
          ],
          tools: DirectToolRuntime(
            definitions: [_toolDefinition],
            requestApproval: (callId, definition, arguments) {
              approvalRequested.complete();
              return DirectToolApprovalHandle(
                request: DirectToolApprovalRequest(
                  id: 'approval',
                  serverName: definition.serverName,
                  toolName: definition.displayName,
                  callId: callId,
                  argumentsJson: jsonEncode(arguments),
                ),
                decision: approval.future,
              );
            },
            execute: (name, arguments) async {
              executedArguments = arguments;
              return const DirectToolResult(text: 'Tool result');
            },
          ),
        ),
      );
      final events = run.events.toList();
      await host.started.future;
      expect(host.request?.tools.single.name, _toolDefinition.name);
      expect(host.request?.tools.single.inputSchemaJson, contains('query'));

      final resultFuture = adapter.onToolCall(
        PlatformPccToolCall(
          runId: run.id,
          callId: 'native-call',
          name: _toolDefinition.name,
          argumentsJson: '{"query":"weather"}',
        ),
      );
      await approvalRequested.future;
      approval.complete(DirectToolApprovalDecision.allowOnce);
      final result = await resultFuture;
      expect(result.cancelled, isFalse);
      expect(result.content, 'Tool result');
      expect(executedArguments, {'query': 'weather'});

      adapter.onEvent(
        PlatformPccStreamEvent(runId: run.id, kind: PlatformPccEventKind.done),
      );
      final received = await events;
      expect(received.whereType<DirectMcpApprovalRequested>(), hasLength(1));
      expect(received.whereType<DirectMcpApprovalResolved>(), hasLength(1));
      expect(received.whereType<DirectToolCallStarted>(), hasLength(1));
      expect(received.whereType<DirectToolCallCompleted>(), hasLength(1));
      expect(received.last, isA<DirectStreamDone>());
    },
  );

  test('PCC returns denied MCP calls without executing them', () async {
    final host = _FakePccHost();
    var executions = 0;
    final adapter = ApplePccAdapter(hostApi: host);
    final run = adapter.startCompletion(
      DirectConnectionProfile.applePrivateCloudCompute(),
      DirectCompletionRequest(
        remoteModelId: kApplePccRemoteModelId,
        messages: <DirectChatMessage>[
          DirectChatMessage.text(role: 'user', text: 'Hello'),
        ],
        tools: DirectToolRuntime(
          definitions: [_toolDefinition],
          requestApproval: (callId, definition, arguments) =>
              DirectToolApprovalHandle(
                request: DirectToolApprovalRequest(
                  id: 'approval',
                  serverName: definition.serverName,
                  toolName: definition.displayName,
                  callId: callId,
                  argumentsJson: jsonEncode(arguments),
                ),
                decision: Future.value(DirectToolApprovalDecision.deny),
              ),
          execute: (_, _) async {
            executions++;
            return const DirectToolResult(text: 'not reached');
          },
        ),
      ),
    );
    final events = run.events.toList();
    await host.started.future;

    final result = await adapter.onToolCall(
      PlatformPccToolCall(
        runId: run.id,
        callId: 'denied-call',
        name: _toolDefinition.name,
        argumentsJson: '{}',
      ),
    );
    expect(result.cancelled, isFalse);
    expect(result.content, contains('denied'));
    expect(executions, 0);
    adapter.onEvent(
      PlatformPccStreamEvent(runId: run.id, kind: PlatformPccEventKind.done),
    );
    final received = await events;
    expect(received.whereType<DirectToolCallStarted>(), isEmpty);
    expect(
      received.whereType<DirectToolCallCompleted>().single.isError,
      isTrue,
    );
  });

  test(
    'cancelling PCC while MCP approval is pending settles native call',
    () async {
      final host = _FakePccHost();
      final approval = Completer<DirectToolApprovalDecision>();
      final approvalRequested = Completer<void>();
      var executions = 0;
      final adapter = ApplePccAdapter(hostApi: host);
      final run = adapter.startCompletion(
        DirectConnectionProfile.applePrivateCloudCompute(),
        DirectCompletionRequest(
          remoteModelId: kApplePccRemoteModelId,
          messages: <DirectChatMessage>[
            DirectChatMessage.text(role: 'user', text: 'Hello'),
          ],
          tools: DirectToolRuntime(
            definitions: [_toolDefinition],
            requestApproval: (callId, definition, arguments) {
              approvalRequested.complete();
              return DirectToolApprovalHandle(
                request: DirectToolApprovalRequest(
                  id: 'approval',
                  serverName: definition.serverName,
                  toolName: definition.displayName,
                  callId: callId,
                  argumentsJson: jsonEncode(arguments),
                ),
                decision: approval.future,
              );
            },
            execute: (_, _) async {
              executions++;
              return const DirectToolResult(text: 'not reached');
            },
          ),
        ),
      );
      final events = run.events.toList();
      await host.started.future;
      final resultFuture = adapter.onToolCall(
        PlatformPccToolCall(
          runId: run.id,
          callId: 'cancelled-call',
          name: _toolDefinition.name,
          argumentsJson: '{}',
        ),
      );
      await approvalRequested.future;

      await run.cancel();
      final result = await resultFuture;
      expect(result.cancelled, isTrue);
      expect(executions, 0);
      expect(host.cancelledRunId, run.id);
      expect(await events, hasLength(1));
    },
  );

  test('PCC bounds native MCP callbacks', () async {
    final host = _FakePccHost();
    final adapter = ApplePccAdapter(hostApi: host);
    final run = adapter.startCompletion(
      DirectConnectionProfile.applePrivateCloudCompute(),
      DirectCompletionRequest(
        remoteModelId: kApplePccRemoteModelId,
        messages: <DirectChatMessage>[
          DirectChatMessage.text(role: 'user', text: 'Hello'),
        ],
        tools: DirectToolRuntime(
          definitions: [_toolDefinition],
          requestApproval: (callId, definition, arguments) =>
              DirectToolApprovalHandle(
                request: DirectToolApprovalRequest(
                  id: 'approval-$callId',
                  serverName: definition.serverName,
                  toolName: definition.displayName,
                  callId: callId,
                  argumentsJson: '{}',
                ),
                decision: Future.value(DirectToolApprovalDecision.allowOnce),
                requiresUserDecision: false,
              ),
          execute: (_, _) async => const DirectToolResult(text: 'ok'),
        ),
      ),
    );
    final events = run.events.toList();
    await host.started.future;

    for (var index = 0; index < kDirectMaxToolRounds; index++) {
      final result = await adapter.onToolCall(
        PlatformPccToolCall(
          runId: run.id,
          callId: 'call-$index',
          name: _toolDefinition.name,
          argumentsJson: '{}',
        ),
      );
      expect(result.cancelled, isFalse);
    }
    final overflow = await adapter.onToolCall(
      PlatformPccToolCall(
        runId: run.id,
        callId: 'overflow',
        name: _toolDefinition.name,
        argumentsJson: '{}',
      ),
    );

    expect(overflow.cancelled, isTrue);
    final received = await events;
    expect(
      (received.last as DirectStreamError).message,
      contains('tool-call limit'),
    );
    await pumpEventQueue();
    expect(host.cancelledRunId, run.id);
  });

  test('PCC rejects invalid native MCP arguments', () async {
    final cases = <({String arguments, String message})>[
      (arguments: '[]', message: 'invalid tool arguments'),
      (
        arguments: jsonEncode({
          'value': List<String>.filled(
            kDirectMaxToolArgumentBytes + 1,
            'x',
          ).join(),
        }),
        message: 'oversized tool arguments',
      ),
    ];

    for (final testCase in cases) {
      final host = _FakePccHost();
      final adapter = ApplePccAdapter(hostApi: host);
      final run = adapter.startCompletion(
        DirectConnectionProfile.applePrivateCloudCompute(),
        DirectCompletionRequest(
          remoteModelId: kApplePccRemoteModelId,
          messages: <DirectChatMessage>[
            DirectChatMessage.text(role: 'user', text: 'Hello'),
          ],
          tools: DirectToolRuntime(
            definitions: [_toolDefinition],
            requestApproval: (_, _, _) => throw StateError('not reached'),
            execute: (_, _) => throw StateError('not reached'),
          ),
        ),
      );
      final events = run.events.toList();
      await host.started.future;

      final result = await adapter.onToolCall(
        PlatformPccToolCall(
          runId: run.id,
          callId: 'invalid',
          name: _toolDefinition.name,
          argumentsJson: testCase.arguments,
        ),
      );

      expect(result.cancelled, isTrue);
      final received = await events;
      expect(
        (received.last as DirectStreamError).message,
        contains(testCase.message),
      );
    }
  });

  test('PCC reports a non-positive top_p accurately', () {
    final adapter = ApplePccAdapter(hostApi: _FakePccHost());
    expect(
      () => adapter.startCompletion(
        DirectConnectionProfile.applePrivateCloudCompute(),
        DirectCompletionRequest(
          remoteModelId: kApplePccRemoteModelId,
          messages: <DirectChatMessage>[
            DirectChatMessage.text(role: 'user', text: 'Hello'),
          ],
          parameters: const <String, dynamic>{'top_p': 0},
        ),
      ),
      throwsA(
        isA<DirectProviderException>().having(
          (error) => error.message,
          'message',
          contains('greater than zero'),
        ),
      ),
    );
  });

  test('cancelling a PCC run closes only that run', () async {
    final host = _FakePccHost();
    final adapter = ApplePccAdapter(hostApi: host);
    final run = adapter.startCompletion(
      DirectConnectionProfile.applePrivateCloudCompute(),
      DirectCompletionRequest(
        remoteModelId: kApplePccRemoteModelId,
        messages: <DirectChatMessage>[
          DirectChatMessage.text(role: 'user', text: 'Stop'),
        ],
      ),
    );
    final events = run.events.toList();
    await host.started.future;

    await run.cancel();

    expect(await events, isEmpty);
    expect(host.cancelledRunId, run.id);
  });
}

final DirectToolDefinition _toolDefinition = DirectToolDefinition(
  name: 'mcp_12345678_weather',
  serverId: 'server',
  serverName: 'Weather server',
  remoteName: 'weather',
  displayName: 'Weather',
  description: 'Look up the weather.',
  approvalFingerprint: 'fingerprint',
  inputSchema: const <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'query': <String, dynamic>{'type': 'string'},
    },
  },
);

final class _FakePccHost extends PccHostApi {
  final Completer<void> started = Completer<void>();
  PlatformPccCompletionRequest? request;
  String? cancelledRunId;

  @override
  Future<PlatformPccStatus> getStatus(PlatformAppleModel model) async =>
      PlatformPccStatus(
        availability: PlatformPccAvailability.available,
        quotaStatus: PlatformPccQuotaStatus.belowLimit,
        quotaLimitReached: false,
        canIncreaseQuota: false,
        contextSize: model == PlatformAppleModel.onDevice ? 4096 : 32768,
      );

  @override
  Future<bool> showQuotaIncreaseSuggestion() async => false;

  @override
  Future<void> start(PlatformPccCompletionRequest request) async {
    this.request = request;
    if (!started.isCompleted) started.complete();
  }

  @override
  Future<void> cancel(String runId) async {
    cancelledRunId = runId;
  }
}
