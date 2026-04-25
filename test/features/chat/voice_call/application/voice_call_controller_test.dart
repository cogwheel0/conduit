import 'dart:async';

import 'package:conduit/features/chat/voice_call/application/voice_call_controller.dart';
import 'package:conduit/features/chat/voice_call/domain/voice_call_interfaces.dart';
import 'package:conduit/features/chat/voice_call/domain/voice_call_models.dart';
import 'package:conduit/features/chat/voice_call/infrastructure/assistant_transport_socket.dart';
import 'package:conduit/features/chat/voice_call/infrastructure/background_policy_default.dart';
import 'package:conduit/features/chat/voice_call/infrastructure/call_audio_session_coordinator.dart';
import 'package:conduit/features/chat/voice_call/infrastructure/call_permission_orchestrator_permission_handler.dart';
import 'package:conduit/features/chat/voice_call/infrastructure/native_call_surface_callkit.dart';
import 'package:conduit/features/chat/voice_call/infrastructure/voice_input_engine_speech.dart';
import 'package:conduit/features/chat/voice_call/infrastructure/voice_output_engine_tts.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/chat/services/text_to_speech_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VoiceCallController', () {
    test('start/stop are idempotent and serialized', () async {
      final fakeInput = _FakeInput();
      final fakeOutput = _FakeOutput();
      final fakeTransport = _FakeTransport();
      final fakeCallSurface = _FakeCallSurface();
      final fakeBackground = _FakeBackgroundPolicy();
      final fakeAudio = _FakeAudioSession();
      final fakePermissions = _FakePermissionOrchestrator();

      final container = ProviderContainer(
        overrides: [
          voiceInputEngineProvider.overrideWithValue(fakeInput),
          voiceOutputEngineProvider.overrideWithValue(fakeOutput),
          voiceAssistantTransportProvider.overrideWithValue(fakeTransport),
          nativeCallSurfaceProvider.overrideWithValue(fakeCallSurface),
          callBackgroundPolicyProvider.overrideWithValue(fakeBackground),
          callAudioSessionCoordinatorProvider.overrideWithValue(fakeAudio),
          callPermissionOrchestratorProvider.overrideWithValue(fakePermissions),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(voiceCallControllerProvider.notifier);

      await notifier.start(startNewConversation: false);
      expect(
        container.read(voiceCallControllerProvider).phase,
        CallPhase.listening,
      );
      expect(fakeInput.beginListeningCalls, 1);

      await notifier.start(startNewConversation: false);
      expect(fakeInput.beginListeningCalls, 1);

      await notifier.stop();
      expect(
        container.read(voiceCallControllerProvider).phase,
        CallPhase.ended,
      );

      await notifier.stop();
      expect(
        container.read(voiceCallControllerProvider).phase,
        CallPhase.ended,
      );
      expect(fakeBackground.stopCalls, 1);
    });

    test('pause reasons stack and require full resume', () async {
      final fakeInput = _FakeInput();
      final container = _buildContainer(fakeInput: fakeInput);
      addTearDown(container.dispose);

      final notifier = container.read(voiceCallControllerProvider.notifier);
      await notifier.start(startNewConversation: false);
      expect(
        container.read(voiceCallControllerProvider).phase,
        CallPhase.listening,
      );

      await notifier.pause(reason: CallPauseReason.user);
      await notifier.pause(reason: CallPauseReason.system);
      final paused = container.read(voiceCallControllerProvider);
      expect(paused.phase, CallPhase.paused);
      expect(paused.pauseReasons.length, 2);

      await notifier.resume(reason: CallPauseReason.user);
      expect(
        container.read(voiceCallControllerProvider).phase,
        CallPhase.paused,
      );

      await notifier.resume(reason: CallPauseReason.system);
      expect(
        container.read(voiceCallControllerProvider).phase,
        CallPhase.listening,
      );
    });

    test('reconnect updates transport session binding', () async {
      final fakeTransport = _FakeTransport();
      final container = _buildContainer(fakeTransport: fakeTransport);
      addTearDown(container.dispose);

      final notifier = container.read(voiceCallControllerProvider.notifier);
      await notifier.start(startNewConversation: false);

      fakeTransport.sessionIdValue = 'sid-2';
      fakeTransport.emitReconnect();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        fakeTransport.registeredSessionIds.length,
        greaterThanOrEqualTo(2),
      );
      expect(fakeTransport.registeredSessionIds.last, 'sid-2');
    });

    test('start does not reload backend config for local output', () async {
      final fakeOutput = _FakeOutput();
      final container = _buildContainer(fakeOutput: fakeOutput);
      addTearDown(container.dispose);

      final notifier = container.read(voiceCallControllerProvider.notifier);
      await notifier.start(startNewConversation: false);

      expect(fakeOutput.reloadBackendConfigCalls, 0);
    });

    test('start reloads backend config for server output', () async {
      final fakeOutput = _FakeOutput(prefersServerEngineValue: true);
      final container = _buildContainer(fakeOutput: fakeOutput);
      addTearDown(container.dispose);

      final notifier = container.read(voiceCallControllerProvider.notifier);
      await notifier.start(startNewConversation: false);

      expect(fakeOutput.reloadBackendConfigCalls, 1);
    });

    test(
      'non-completion events with message_id do not reset assistant response',
      () async {
        final fakeTransport = _FakeTransport();
        final container = _buildContainer(fakeTransport: fakeTransport);
        addTearDown(container.dispose);

        final notifier = container.read(voiceCallControllerProvider.notifier);
        await notifier.start(startNewConversation: false);

        fakeTransport.emitChatEvent({
          'message_id': 'assistant-msg-1',
          'data': {
            'type': 'chat:completion',
            'data': {'content': 'Hello there.', 'done': true},
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 5));

        expect(
          container.read(voiceCallControllerProvider).response,
          'Hello there.',
        );

        fakeTransport.emitChatEvent({
          'message_id': 'assistant-msg-2',
          'data': {
            'type': 'chat:message:follow_ups',
            'data': {'follow_ups': []},
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 5));

        expect(
          container.read(voiceCallControllerProvider).response,
          'Hello there.',
        );
      },
    );

    test(
      'ignores completion events for a different assistant message id',
      () async {
        final fakeTransport = _FakeTransport();
        final container = _buildContainer(fakeTransport: fakeTransport);
        addTearDown(container.dispose);

        final notifier = container.read(voiceCallControllerProvider.notifier);
        await notifier.start(startNewConversation: false);

        fakeTransport.emitChatEvent({
          'message_id': 'assistant-msg-1',
          'data': {
            'type': 'chat:completion',
            'data': {'content': 'Current reply', 'done': false},
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 5));

        fakeTransport.emitChatEvent({
          'message_id': 'assistant-msg-2',
          'data': {
            'type': 'chat:completion',
            'data': {'content': 'Old reply', 'done': true},
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          container.read(voiceCallControllerProvider).response,
          'Current reply',
        );
      },
    );

    test(
      'tool-only completions stay in thinking until a speakable reply arrives',
      () async {
        final fakeOutput = _FakeOutput();
        final fakeTransport = _FakeTransport();
        final container = _buildContainer(
          fakeOutput: fakeOutput,
          fakeTransport: fakeTransport,
        );
        addTearDown(container.dispose);

        final notifier = container.read(voiceCallControllerProvider.notifier);
        await notifier.start(startNewConversation: false);

        notifier.state = container
            .read(voiceCallControllerProvider)
            .copyWith(phase: CallPhase.thinking);

        fakeTransport.emitChatEvent({
          'message_id': 'assistant-msg-1',
          'data': {
            'type': 'chat:completion',
            'data': {
              'content':
                  '<details type="tool_calls" done="true" '
                  'name="search"><summary>Tool Executed</summary></details>',
              'done': true,
            },
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          container.read(voiceCallControllerProvider).phase,
          CallPhase.thinking,
        );
        expect(fakeOutput.spokenTexts, isEmpty);
      },
    );

    test('watchdog poll prefers the active assistant message id', () async {
      final fakeTransport = _FakeTransport();
      final fakeApi = _FakeApiService(
        conversation: _conversationWithMessages([
          _assistantMessage(id: 'assistant-msg-1', content: 'Fresh reply'),
          _assistantMessage(id: 'assistant-msg-2', content: 'Older reply'),
        ]),
      );
      final container = _buildContainer(
        fakeTransport: fakeTransport,
        apiService: fakeApi,
        activeConversation: _conversationWithMessages(const []),
      );
      addTearDown(container.dispose);

      final notifier = container.read(voiceCallControllerProvider.notifier);
      await notifier.start(startNewConversation: false);

      fakeTransport.emitChatEvent({
        'message_id': 'assistant-msg-1',
        'data': {
          'type': 'chat:completion',
          'data': {'content': '', 'done': true},
        },
      });

      await Future<void>.delayed(const Duration(seconds: 5));

      expect(
        container.read(voiceCallControllerProvider).response,
        'Fresh reply',
      );
    });

    test(
      'fresh assistant activity extends the empty-response wait budget',
      () async {
        final fakeTransport = _FakeTransport();
        final fakeOutput = _FakeOutput();
        final container = _buildContainer(
          fakeTransport: fakeTransport,
          fakeOutput: fakeOutput,
        );
        addTearDown(container.dispose);

        final notifier = container.read(voiceCallControllerProvider.notifier);
        await notifier.start(startNewConversation: false);

        fakeTransport.emitChatEvent({
          'message_id': 'assistant-msg-1',
          'data': {
            'type': 'chat:completion',
            'data': {'content': '', 'done': true},
          },
        });

        await Future<void>.delayed(const Duration(seconds: 5));

        fakeTransport.emitChatEvent({
          'message_id': 'assistant-msg-1',
          'data': {
            'type': 'chat:completion',
            'data': {'content': '', 'done': true},
          },
        });

        await Future<void>.delayed(const Duration(seconds: 21));

        fakeTransport.emitChatEvent({
          'message_id': 'assistant-msg-1',
          'data': {
            'type': 'chat:completion',
            'data': {'content': 'Fresh reply.', 'done': true},
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(
          container.read(voiceCallControllerProvider).response,
          'Fresh reply.',
        );
        expect(fakeOutput.spokenTexts, ['Fresh reply.']);
        expect(
          container.read(voiceCallControllerProvider).phase,
          CallPhase.listening,
        );
      },
    );

    test(
      'watchdog resumes listening after repeated non-speakable completions',
      () async {
        final fakeTransport = _FakeTransport();
        final fakeApi = _FakeApiService(
          conversation: _conversationWithMessages([
            _assistantMessage(
              id: 'assistant-msg-1',
              content:
                  '<details type="tool_calls" done="true" '
                  'name="search"><summary>Tool Executed</summary></details>',
            ),
          ]),
        );
        final fakeInput = _FakeInput();
        final container = _buildContainer(
          fakeInput: fakeInput,
          fakeTransport: fakeTransport,
          apiService: fakeApi,
          activeConversation: _conversationWithMessages(const []),
        );
        addTearDown(container.dispose);

        final notifier = container.read(voiceCallControllerProvider.notifier);
        await notifier.start(startNewConversation: false);

        fakeTransport.emitChatEvent({
          'message_id': 'assistant-msg-1',
          'data': {
            'type': 'chat:completion',
            'data': {'content': '', 'done': true},
          },
        });

        await Future<void>.delayed(const Duration(seconds: 13));

        expect(
          container.read(voiceCallControllerProvider).phase,
          CallPhase.listening,
        );
        expect(fakeInput.beginListeningCalls, greaterThanOrEqualTo(2));
      },
    );

    test(
      'late events from an abandoned non-speakable turn are ignored',
      () async {
        final fakeTransport = _FakeTransport();
        final fakeApi = _FakeApiService(
          conversation: _conversationWithMessages([
            _assistantMessage(
              id: 'assistant-msg-1',
              content:
                  '<details type="tool_calls" done="true" '
                  'name="search"><summary>Tool Executed</summary></details>',
            ),
          ]),
        );
        final fakeOutput = _FakeOutput();
        final container = _buildContainer(
          fakeTransport: fakeTransport,
          fakeOutput: fakeOutput,
          apiService: fakeApi,
          activeConversation: _conversationWithMessages(const []),
        );
        addTearDown(container.dispose);

        final notifier = container.read(voiceCallControllerProvider.notifier);
        await notifier.start(startNewConversation: false);

        fakeTransport.emitChatEvent({
          'message_id': 'assistant-msg-1',
          'data': {
            'type': 'chat:completion',
            'data': {'content': '', 'done': true},
          },
        });

        await Future<void>.delayed(const Duration(seconds: 13));

        fakeTransport.emitChatEvent({
          'message_id': 'assistant-msg-1',
          'data': {
            'type': 'chat:completion',
            'data': {'content': 'Delayed stale reply.', 'done': true},
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(
          container.read(voiceCallControllerProvider).response,
          isNot('Delayed stale reply.'),
        );
        expect(fakeOutput.spokenTexts, isEmpty);
        expect(
          container.read(voiceCallControllerProvider).phase,
          CallPhase.listening,
        );
      },
    );

    test('late events after a spoken reply are ignored', () async {
      final fakeTransport = _FakeTransport();
      final fakeOutput = _FakeOutput();
      final container = _buildContainer(
        fakeTransport: fakeTransport,
        fakeOutput: fakeOutput,
      );
      addTearDown(container.dispose);

      final notifier = container.read(voiceCallControllerProvider.notifier);
      await notifier.start(startNewConversation: false);

      fakeTransport.emitChatEvent({
        'message_id': 'assistant-msg-1',
        'data': {
          'type': 'chat:completion',
          'data': {'content': 'Fresh reply.', 'done': true},
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));

      fakeTransport.emitChatEvent({
        'message_id': 'assistant-msg-1',
        'data': {
          'type': 'chat:completion',
          'data': {'content': 'Delayed stale reply.', 'done': true},
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(
        container.read(voiceCallControllerProvider).response,
        'Fresh reply.',
      );
      expect(fakeOutput.spokenTexts, ['Fresh reply.']);
      expect(
        container.read(voiceCallControllerProvider).phase,
        CallPhase.listening,
      );
    });

    test(
      'late id-less completion events after a spoken reply are ignored',
      () async {
        final fakeTransport = _FakeTransport();
        final fakeOutput = _FakeOutput();
        final container = _buildContainer(
          fakeTransport: fakeTransport,
          fakeOutput: fakeOutput,
        );
        addTearDown(container.dispose);

        final notifier = container.read(voiceCallControllerProvider.notifier);
        await notifier.start(startNewConversation: false);

        fakeTransport.emitChatEvent({
          'message_id': 'assistant-msg-1',
          'data': {
            'type': 'chat:completion',
            'data': {'content': 'Fresh reply.', 'done': true},
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));

        fakeTransport.emitChatEvent({
          'data': {
            'type': 'chat:completion',
            'data': {'content': 'Delayed stale reply.', 'done': true},
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(
          container.read(voiceCallControllerProvider).response,
          'Fresh reply.',
        );
        expect(fakeOutput.spokenTexts, ['Fresh reply.']);
        expect(
          container.read(voiceCallControllerProvider).phase,
          CallPhase.listening,
        );
      },
    );

    test('speaks all queued chunks sequentially', () async {
      final fakeOutput = _FakeOutput();
      final fakeTransport = _FakeTransport();
      final container = _buildContainer(
        fakeOutput: fakeOutput,
        fakeTransport: fakeTransport,
      );
      addTearDown(container.dispose);

      final notifier = container.read(voiceCallControllerProvider.notifier);
      await notifier.start(startNewConversation: false);

      fakeTransport.emitChatEvent({
        'message_id': 'assistant-msg-1',
        'data': {
          'type': 'chat:completion',
          'data': {'content': 'One. Two. Three.', 'done': true},
        },
      });

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(fakeOutput.spokenTexts, ['One.', 'Two.', 'Three.']);
    });
  });
}

ProviderContainer _buildContainer({
  _FakeInput? fakeInput,
  _FakeOutput? fakeOutput,
  _FakeTransport? fakeTransport,
  _FakeCallSurface? fakeCallSurface,
  _FakeBackgroundPolicy? fakeBackground,
  _FakeAudioSession? fakeAudio,
  _FakePermissionOrchestrator? fakePermissions,
  ApiService? apiService,
  Conversation? activeConversation,
}) {
  return ProviderContainer(
    overrides: [
      voiceInputEngineProvider.overrideWithValue(fakeInput ?? _FakeInput()),
      voiceOutputEngineProvider.overrideWithValue(fakeOutput ?? _FakeOutput()),
      voiceAssistantTransportProvider.overrideWithValue(
        fakeTransport ?? _FakeTransport(),
      ),
      nativeCallSurfaceProvider.overrideWithValue(
        fakeCallSurface ?? _FakeCallSurface(),
      ),
      callBackgroundPolicyProvider.overrideWithValue(
        fakeBackground ?? _FakeBackgroundPolicy(),
      ),
      callAudioSessionCoordinatorProvider.overrideWithValue(
        fakeAudio ?? _FakeAudioSession(),
      ),
      callPermissionOrchestratorProvider.overrideWithValue(
        fakePermissions ?? _FakePermissionOrchestrator(),
      ),
      apiServiceProvider.overrideWithValue(apiService),
      activeConversationProvider.overrideWith(
        () => _TestActiveConversationNotifier(activeConversation),
      ),
    ],
  );
}

class _TestActiveConversationNotifier extends ActiveConversationNotifier {
  _TestActiveConversationNotifier(this._conversation);

  final Conversation? _conversation;

  @override
  Conversation? build() => _conversation;
}

class _FakeInput implements VoiceInputEngine {
  final StreamController<int> _intensity = StreamController<int>.broadcast();
  final StreamController<String> _transcript =
      StreamController<String>.broadcast();

  int beginListeningCalls = 0;

  @override
  bool get hasLocalStt => true;

  @override
  bool get hasServerStt => true;

  @override
  bool get prefersServerOnly => false;

  @override
  bool get prefersDeviceOnly => true;

  @override
  SttPreference get preference => SttPreference.deviceOnly;

  @override
  Stream<int> get intensityStream => _intensity.stream;

  @override
  Future<Stream<String>> beginListening() async {
    beginListeningCalls += 1;
    return _transcript.stream;
  }

  @override
  Future<bool> checkPermissions() async => true;

  @override
  Future<bool> initialize() async => true;

  @override
  Future<bool> requestMicrophonePermission() async => true;

  @override
  Future<void> stopListening() async {}

  @override
  Future<void> dispose() async {
    await _intensity.close();
    await _transcript.close();
  }
}

class _FakeOutput implements VoiceOutputEngine {
  _FakeOutput({this.prefersServerEngineValue = false});

  void Function()? _onStart;
  void Function()? _onComplete;
  final List<String> spokenTexts = <String>[];
  final bool prefersServerEngineValue;
  int reloadBackendConfigCalls = 0;

  @override
  bool get prefersServerEngine => prefersServerEngineValue;

  @override
  void bindHandlers({
    void Function()? onStart,
    void Function()? onComplete,
    void Function(String error)? onError,
  }) {
    _onStart = onStart;
    _onComplete = onComplete;
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<void> initializeWithSettings(AppSettings settings) async {
    if (prefersServerEngineValue) {
      await reloadBackendConfig();
    }
  }

  @override
  Future<void> reloadBackendConfig() async {
    reloadBackendConfigCalls++;
  }

  @override
  Future<void> speak(String text) async {
    spokenTexts.add(text);
    _onStart?.call();
    await Future<void>.delayed(const Duration(milliseconds: 1));
    _onComplete?.call();
  }

  @override
  List<String> splitTextForSpeech(String text) {
    return text
        .split(RegExp(r'(?<=[.!?])\s+'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
  }

  @override
  Future<void> stop() async {}

  @override
  Future<SpeechAudioChunk> synthesizeServerSpeechChunk(String text) {
    throw UnimplementedError();
  }

  @override
  Future<void> updateSettings(AppSettings settings) async {}
}

class _FakeTransport implements VoiceAssistantTransport {
  final StreamController<void> _reconnect = StreamController<void>.broadcast();
  final List<String?> registeredSessionIds = [];
  VoiceAssistantEventHandler? _handler;

  String sessionIdValue = 'sid-1';

  @override
  bool get isConnected => true;

  @override
  Stream<void> get onReconnect => _reconnect.stream;

  @override
  String? get sessionId => sessionIdValue;

  @override
  Future<bool> ensureConnected({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    return true;
  }

  @override
  VoiceAssistantSubscription registerAssistantEvents({
    required VoiceAssistantEventHandler handler,
    String? conversationId,
    String? sessionId,
    bool requireFocus = false,
  }) {
    registeredSessionIds.add(sessionId);
    _handler = handler;
    return const VoiceAssistantSubscription(dispose: _noopDispose);
  }

  @override
  void updateSessionIdForConversation(String conversationId, String sessionId) {
    // Not needed in this test fake.
  }

  void emitReconnect() {
    _reconnect.add(null);
  }

  void emitChatEvent(Map<String, dynamic> event) {
    _handler?.call(event, null);
  }
}

class _FakeApiService extends ApiService {
  _FakeApiService({required this.conversation})
    : super(
        serverConfig: const ServerConfig(
          id: 'test',
          name: 'Test',
          url: 'http://localhost:0',
        ),
        workerManager: WorkerManager(),
      );

  final Conversation conversation;

  @override
  Future<Conversation> getConversation(String conversationId) async {
    return conversation;
  }
}

class _FakeCallSurface implements NativeCallSurface {
  @override
  bool get isAvailable => false;

  @override
  Stream<NativeCallEvent> get events => const Stream<NativeCallEvent>.empty();

  @override
  Future<void> checkAndCleanActiveCalls() async {}

  @override
  Future<void> endAllCalls() async {}

  @override
  Future<void> endCall(String callId) async {}

  @override
  Future<void> markConnected(String callId) async {}

  @override
  Future<void> requestPermissions() async {}

  @override
  Future<String?> startOutgoingCall({
    required String callerName,
    required String handle,
  }) async {
    return null;
  }
}

class _FakeBackgroundPolicy implements CallBackgroundPolicy {
  int stopCalls = 0;

  @override
  Future<void> cancelCallNotification() async {}

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> keepAlive() async => true;

  @override
  Future<void> requestNotificationPermissionIfNeeded() async {}

  @override
  Future<void> setScreenAwake(bool enabled) async {}

  @override
  Future<void> startBackgroundExecution({
    required bool requiresMicrophone,
  }) async {}

  @override
  Future<void> stopBackgroundExecution() async {
    stopCalls += 1;
  }

  @override
  Future<void> updateOngoingCallNotification({
    required String modelName,
    required bool isMuted,
    required bool isSpeaking,
    required bool isPaused,
    required bool show,
  }) async {}
}

class _FakeAudioSession implements CallAudioSessionCoordinator {
  @override
  Future<void> configureForListening() async {}

  @override
  Future<void> configureForSpeaking() async {}

  @override
  Future<void> deactivate() async {}
}

class _FakePermissionOrchestrator implements CallPermissionOrchestrator {
  @override
  Future<void> ensureCallPermissions(VoiceInputEngine input) async {}
}

Future<void> _noopDispose() async {}

Conversation _conversationWithMessages(List<ChatMessage> messages) {
  return Conversation(
    id: 'conv-1',
    title: 'Voice call test',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    messages: messages,
  );
}

ChatMessage _assistantMessage({required String id, required String content}) {
  return ChatMessage(
    id: id,
    role: 'assistant',
    content: content,
    timestamp: DateTime(2026),
  );
}
