import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/chatgpt/chatgpt_account_adapter.dart';
import 'package:conduit/features/chatgpt/chatgpt_runtime_client.dart';
import 'package:conduit/features/chatgpt/native_generated/api/contract.dart'
    as native;
import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
import 'package:checks/checks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hides protocol items from visible ChatGPT results', () async {
    final runtime = _FakeRuntime();
    final adapter = ChatGptAccountAdapter(runtime: runtime);
    final profile = chatGptAccountProfile();

    final models = await adapter.listModels(profile);
    check(models.single.capabilities['audio_input']).equals(true);
    check(models.single.capabilities['vision']).equals(true);
    check(models.single.capabilities['web_search']).equals(true);
    check(models.single.capabilities['image_generation']).equals(true);

    final registry = DirectModelRegistry();
    final selectedModel = registry.replaceProfileModels(profile, models).single;
    final container = ProviderContainer(
      overrides: [
        selectedModelProvider.overrideWithValue(selectedModel),
        directModelRegistryProvider.overrideWithValue(registry),
      ],
    );
    addTearDown(container.dispose);
    check(container.read(webSearchAvailableProvider)).isTrue();
    check(container.read(imageGenerationAvailableProvider)).isTrue();

    final run = adapter.startCompletion(
      profile,
      DirectCompletionRequest(
        remoteModelId: 'gpt-test',
        localChatId: 'local-chat',
        localAssistantMessageId: 'assistant-1',
        enableWebSearch: true,
        enableImageGeneration: true,
        messages: <DirectChatMessage>[
          DirectChatMessage(
            role: 'user',
            localMessageId: 'message-1',
            parts: <DirectContentPart>[
              const DirectTextPart('hello'),
              DirectAudioPart(
                dataUrl: 'data:audio/wav;base64,${base64Encode(<int>[1, 2])}',
                mimeType: 'audio/wav',
              ),
              DirectFilePart(
                filename: 'notes.txt',
                mimeType: 'text/plain',
                dataUrl:
                    'data:text/plain;base64,${base64Encode(utf8.encode('notes'))}',
              ),
            ],
          ),
        ],
      ),
    );

    final events = await run.events.toList().timeout(
      const Duration(seconds: 2),
    );
    await run.done;
    check(
      runtime.lastRequest!.messages.single.parts.map((input) => input.kind),
    ).deepEquals(<String>['text', 'audio', 'document']);
    check(runtime.lastRequest?.enableWebSearch).equals(true);
    check(
      events.whereType<DirectContentDelta>().single.content,
    ).equals('answer');
    check(
      events.whereType<DirectReasoningDelta>().single.content,
    ).equals('I should look this up.');
    check(
      events.whereType<DirectSourceFound>().single.url,
    ).equals('https://example.com');
    check(
      events.whereType<DirectGeneratedImage>().single.mediaType,
    ).equals('image/webp');
    check(events.whereType<DirectToolCallStarted>()).isEmpty();
    check(events.whereType<DirectToolCallCompleted>()).isEmpty();
    check(events.last).isA<DirectStreamDone>();
  });

  test('cancelling a direct run interrupts the native run', () async {
    final runtime = _FakeRuntime(autoComplete: false);
    final adapter = ChatGptAccountAdapter(runtime: runtime);
    final run = adapter.startCompletion(
      chatGptAccountProfile(),
      DirectCompletionRequest(
        remoteModelId: 'gpt-test',
        messages: <DirectChatMessage>[
          DirectChatMessage.text(role: 'user', text: 'stop'),
        ],
      ),
    );
    final events = run.events.toList();
    await runtime.turnStarted.future.timeout(const Duration(seconds: 2));
    await run.cancel().timeout(const Duration(seconds: 2));
    check(runtime.interruptedRunId).equals('run-1');
    check((await events).last).isA<DirectStreamDone>();
  });

  test('cancellation settles without a native terminal event', () async {
    final runtime = _FakeRuntime(
      autoComplete: false,
      emitCancellationEvent: false,
    );
    final adapter = ChatGptAccountAdapter(runtime: runtime);
    final run = adapter.startCompletion(
      chatGptAccountProfile(),
      DirectCompletionRequest(
        remoteModelId: 'gpt-test',
        messages: <DirectChatMessage>[
          DirectChatMessage.text(role: 'user', text: 'stop'),
        ],
      ),
    );

    await runtime.turnStarted.future.timeout(const Duration(seconds: 2));
    await run.cancel().timeout(const Duration(seconds: 2));

    check(runtime.interruptedRunId).equals('run-1');
  });

  test('cancelling the event subscription interrupts the native run', () async {
    final runtime = _FakeRuntime(
      autoComplete: false,
      emitCancellationEvent: false,
    );
    final adapter = ChatGptAccountAdapter(runtime: runtime);
    final run = adapter.startCompletion(
      chatGptAccountProfile(),
      DirectCompletionRequest(
        remoteModelId: 'gpt-test',
        messages: <DirectChatMessage>[
          DirectChatMessage.text(role: 'user', text: 'stop'),
        ],
      ),
    );
    final subscription = run.events.listen((_) {});
    await runtime.turnStarted.future.timeout(const Duration(seconds: 2));

    await subscription.cancel();
    await run.done.timeout(const Duration(seconds: 2));

    check(runtime.interruptedRunId).equals('run-1');
  });

  test('reports an error when the native event stream closes early', () async {
    final runtime = _FakeRuntime(autoComplete: false);
    final adapter = ChatGptAccountAdapter(runtime: runtime);
    final run = adapter.startCompletion(
      chatGptAccountProfile(),
      DirectCompletionRequest(
        remoteModelId: 'gpt-test',
        messages: <DirectChatMessage>[
          DirectChatMessage.text(role: 'user', text: 'hello'),
        ],
      ),
    );
    final events = run.events.toList();
    await runtime.turnStarted.future.timeout(const Duration(seconds: 2));
    await runtime.closeEvents();

    check((await events).last).isA<DirectStreamError>();
    await run.done.timeout(const Duration(seconds: 2));
  });

  test(
    'reuses the latest session and isolates an older local branch',
    () async {
      final runtime = _FakeRuntime();
      final adapter = ChatGptAccountAdapter(runtime: runtime);
      final profile = chatGptAccountProfile();

      Future<void> complete({
        required String assistantId,
        String? branchHead,
      }) async {
        final run = adapter.startCompletion(
          profile,
          DirectCompletionRequest(
            remoteModelId: 'gpt-test',
            localChatId: 'branch-chat',
            headMessageId: branchHead,
            localAssistantMessageId: assistantId,
            messages: <DirectChatMessage>[
              DirectChatMessage(
                role: 'user',
                localMessageId: 'user-$assistantId',
                parentMessageId: branchHead,
                parts: const <DirectContentPart>[DirectTextPart('next')],
              ),
            ],
          ),
        );
        await run.events.toList().timeout(const Duration(seconds: 2));
        await run.done;
      }

      await complete(assistantId: 'assistant-1');
      await complete(assistantId: 'assistant-2', branchHead: 'assistant-1');
      await complete(
        assistantId: 'assistant-branch',
        branchHead: 'assistant-1',
      );

      check(runtime.startedSessionIds).length.equals(3);
      check(runtime.startedSessionIds[1]).equals(runtime.startedSessionIds[0]);
      check(
        runtime.startedSessionIds[2],
      ).not((it) => it.equals(runtime.startedSessionIds[0]));
    },
  );

  test(
    'starts a replacement session and fully replays on policy change',
    () async {
      final runtime = _FakeRuntime();
      final adapter = ChatGptAccountAdapter(runtime: runtime);
      final profile = chatGptAccountProfile();

      final first = adapter.startCompletion(
        profile,
        DirectCompletionRequest(
          remoteModelId: 'gpt-test',
          localChatId: 'policy-chat',
          localAssistantMessageId: 'assistant-1',
          messages: <DirectChatMessage>[
            DirectChatMessage.text(role: 'user', text: 'first'),
          ],
        ),
      );
      await first.events.toList();

      final second = adapter.startCompletion(
        profile,
        DirectCompletionRequest(
          remoteModelId: 'gpt-test',
          localChatId: 'policy-chat',
          headMessageId: 'assistant-1',
          localAssistantMessageId: 'assistant-2',
          enableWebSearch: true,
          messages: <DirectChatMessage>[
            DirectChatMessage.text(role: 'user', text: 'first'),
            DirectChatMessage.text(role: 'user', text: 'search now'),
            DirectChatMessage.text(role: 'assistant', text: 'trailing answer'),
          ],
        ),
      );
      await second.events.toList();

      check(runtime.startedSessionIds).length.equals(2);
      check(
        runtime.startedSessionIds[1],
      ).not((it) => it.equals(runtime.startedSessionIds[0]));
      check(runtime.lastRequest!.enableWebSearch).isTrue();
      check(
        runtime.lastRequest!.messages
            .expand((message) => message.parts)
            .map((part) => part.text),
      ).deepEquals(<String?>['first', 'search now', 'trailing answer']);
    },
  );

  test('reuses a checkpoint and persists its input-token count', () async {
    final runtime = _FakeRuntime();
    final adapter = ChatGptAccountAdapter(runtime: runtime);
    final profile = chatGptAccountProfile();

    await _completePersistentTurn(
      adapter: adapter,
      profile: profile,
      chatId: 'checkpoint-chat',
    );

    final second = adapter.startCompletion(
      profile,
      DirectCompletionRequest(
        remoteModelId: 'gpt-test',
        localChatId: 'checkpoint-chat',
        headMessageId: 'assistant-1',
        localAssistantMessageId: 'assistant-2',
        messages: _followUpMessages,
      ),
    );
    await second.events.toList();

    check(runtime.lastRequest!.checkpoint!.toList()).deepEquals(<int>[7, 8, 9]);
    check(runtime.lastRequest!.previousInputTokens).equals(BigInt.from(900));
    check(
      runtime.lastRequest!.messages
          .expand((message) => message.parts)
          .map((part) => part.text),
    ).deepEquals(<String?>['answer', 'follow up']);
  });

  test('invalid checkpoint retries once with the full local branch', () async {
    final runtime = _FakeRuntime(rejectCheckpointOnce: true);
    final adapter = ChatGptAccountAdapter(runtime: runtime);
    final profile = chatGptAccountProfile();

    await _completePersistentTurn(
      adapter: adapter,
      profile: profile,
      chatId: 'retry-chat',
    );

    final second = adapter.startCompletion(
      profile,
      DirectCompletionRequest(
        remoteModelId: 'gpt-test',
        localChatId: 'retry-chat',
        headMessageId: 'assistant-1',
        localAssistantMessageId: 'assistant-2',
        messages: _followUpMessages,
      ),
    );
    await second.events.toList();

    check(runtime.checkpointRejections).equals(1);
    check(runtime.lastRequest!.checkpoint).isNull();
    check(runtime.lastRequest!.messages).length.equals(3);
  });
}

Future<void> _completePersistentTurn({
  required ChatGptAccountAdapter adapter,
  required DirectConnectionProfile profile,
  required String chatId,
}) async {
  final run = adapter.startCompletion(
    profile,
    DirectCompletionRequest(
      remoteModelId: 'gpt-test',
      localChatId: chatId,
      localAssistantMessageId: 'assistant-1',
      messages: <DirectChatMessage>[
        DirectChatMessage(
          role: 'user',
          localMessageId: 'user-1',
          parts: const <DirectContentPart>[DirectTextPart('first')],
        ),
      ],
    ),
  );
  await run.events.toList();
}

final _followUpMessages = <DirectChatMessage>[
  DirectChatMessage(
    role: 'user',
    localMessageId: 'user-1',
    parts: const <DirectContentPart>[DirectTextPart('first')],
  ),
  DirectChatMessage(
    role: 'assistant',
    localMessageId: 'assistant-1',
    parts: const <DirectContentPart>[DirectTextPart('answer')],
  ),
  DirectChatMessage(
    role: 'user',
    localMessageId: 'user-2',
    parentMessageId: 'assistant-1',
    parts: const <DirectContentPart>[DirectTextPart('follow up')],
  ),
];

final class _FakeRuntime implements ChatGptRuntimeClient {
  _FakeRuntime({
    this.autoComplete = true,
    this.emitCancellationEvent = true,
    this.rejectCheckpointOnce = false,
  });

  final bool autoComplete;
  final bool emitCancellationEvent;
  bool rejectCheckpointOnce;
  final StreamController<native.RuntimeEvent> _events =
      StreamController<native.RuntimeEvent>.broadcast();
  native.TurnRequest? lastRequest;
  String? interruptedRunId;
  int _runCount = 0;
  int checkpointRejections = 0;
  final Completer<void> turnStarted = Completer<void>();
  final List<String> startedSessionIds = <String>[];

  @override
  Stream<native.RuntimeEvent> get events => _events.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<native.AuthStateInfo> authState() async => const native.AuthStateInfo(
    authenticated: true,
    accountFingerprint: 'fingerprint',
  );

  @override
  Future<List<native.ModelInfo>> listModels() async => const <native.ModelInfo>[
    native.ModelInfo(
      id: 'gpt-test',
      displayName: 'GPT Test',
      description: 'Test model',
      supportsImages: true,
      supportsAudio: true,
      supportedReasoningEfforts: <String>['medium'],
    ),
  ];

  @override
  Future<native.RunInfo> startTurn(native.TurnRequest request) async {
    lastRequest = request;
    if (request.checkpoint != null && rejectCheckpointOnce) {
      rejectCheckpointOnce = false;
      checkpointRejections += 1;
      throw const native.BridgeError(
        kind: native.BridgeErrorKind.protocolMismatch,
        message: 'invalid checkpoint',
      );
    }
    startedSessionIds.add(request.sessionId);
    if (!turnStarted.isCompleted) turnStarted.complete();
    _runCount += 1;
    final runId = 'run-$_runCount';
    if (autoComplete) {
      Timer.run(
        () => _emitCompletion(runId: runId, sessionId: request.sessionId),
      );
    }
    return native.RunInfo(runId: runId, sessionId: request.sessionId);
  }

  void _emitCompletion({required String runId, required String sessionId}) {
    _events
      ..add(
        _event(
          native.RuntimeEventKind.checkpointUpdated,
          runId: runId,
          sessionId: sessionId,
          jsonData: '{"throughMessageId":"user-1"}',
          binaryData: Uint8List.fromList(<int>[7, 8, 9]),
        ),
      )
      ..add(
        _event(
          native.RuntimeEventKind.usage,
          runId: runId,
          sessionId: sessionId,
          jsonData: '{"input_tokens":900}',
        ),
      )
      ..add(
        _event(
          native.RuntimeEventKind.reasoningDelta,
          runId: runId,
          sessionId: sessionId,
          text: 'I should look this up.',
        ),
      )
      ..add(
        _event(
          native.RuntimeEventKind.textDelta,
          runId: runId,
          sessionId: sessionId,
          text: 'answer',
        ),
      )
      ..add(
        _event(
          native.RuntimeEventKind.source,
          runId: runId,
          sessionId: sessionId,
          jsonData: '{"url":"https://example.com","title":"Example"}',
        ),
      )
      ..add(
        _event(
          native.RuntimeEventKind.generatedImage,
          runId: runId,
          sessionId: sessionId,
          jsonData: '{"mediaType":"image/webp"}',
          binaryData: Uint8List.fromList(<int>[1, 2, 3]),
        ),
      )
      ..add(
        _event(
          native.RuntimeEventKind.completed,
          runId: runId,
          sessionId: sessionId,
        ),
      );
  }

  native.RuntimeEvent _event(
    native.RuntimeEventKind kind, {
    required String runId,
    required String sessionId,
    String? text,
    String? jsonData,
    Uint8List? binaryData,
  }) => native.RuntimeEvent(
    clientEpoch: BigInt.one,
    sequence: BigInt.one,
    kind: kind,
    runId: runId,
    sessionId: sessionId,
    text: text,
    jsonData: jsonData,
    binaryData: binaryData,
  );

  @override
  Future<void> interruptTurn(String runId) async {
    interruptedRunId = runId;
    if (!emitCancellationEvent) return;
    final request = lastRequest!;
    _events.add(
      _event(
        native.RuntimeEventKind.cancelled,
        runId: runId,
        sessionId: request.sessionId,
      ),
    );
  }

  @override
  Future<native.DeviceCodeChallenge> beginDeviceCodeLogin() =>
      throw UnimplementedError();

  @override
  Future<void> cancelDeviceCodeLogin() async {}

  @override
  Future<void> disconnectAccount() async {}

  @override
  Future<void> shutdown() => _events.close();

  Future<void> closeEvents() => _events.close();
}
