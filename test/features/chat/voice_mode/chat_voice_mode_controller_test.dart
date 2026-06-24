import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/callkit_service.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/services/text_to_speech_service.dart';
import 'package:conduit/features/chat/services/voice_input_service.dart';
import 'package:conduit/features/chat/voice_mode/chat_voice_audio_session_coordinator.dart';
import 'package:conduit/features/chat/voice_mode/chat_voice_mode_controller.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _model = Model(id: 'test-model', name: 'Test Model');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'sends transcript through chat voice mode and resumes listening',
    () async {
      final input = _FakeVoiceInputService();
      final tts = _FakeTextToSpeechService();
      final audioSession = _FakeChatVoiceAudioSessionCoordinator();
      final container = ProviderContainer(
        overrides: [
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.authenticated,
          ),
          selectedModelProvider.overrideWithValue(_model),
          appSettingsProvider.overrideWithValue(const AppSettings()),
          reviewerModeProvider.overrideWithValue(true),
          voiceInputServiceProvider.overrideWithValue(input),
          textToSpeechServiceProvider.overrideWithValue(tts),
          callKitServiceProvider.overrideWithValue(
            _UnavailableCallKitService(),
          ),
          chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
            _FakeChatVoiceBackgroundCoordinator(),
          ),
          chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
            audioSession,
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(
        chatVoiceModeControllerProvider.notifier,
      );

      await controller.start(startNewConversation: false);
      expect(input.beginCalls, 1);
      expect(audioSession.listeningCalls, 1);
      expect(
        container.read(chatVoiceModeControllerProvider).phase,
        ChatVoiceModePhase.listening,
      );

      await input.completeCurrent('hello assistant');
      await _until(() => tts.finishedTexts.isNotEmpty);

      final messages = container.read(chatMessagesProvider);
      expect(messages.first.content, 'hello assistant');
      expect(messages.first.role, 'user');
      expect(messages.last.role, 'assistant');
      expect(messages.last.isStreaming, isFalse);
      expect(tts.startedStreaming, isTrue);
      expect(tts.fedTexts.join('\n'), contains('Conduit'));

      await _until(() => input.beginCalls == 2);
      expect(
        container.read(chatVoiceModeControllerProvider).phase,
        ChatVoiceModePhase.listening,
      );
    },
  );

  test(
    'second voice turn does not replay the first assistant response',
    () async {
      final input = _FakeVoiceInputService();
      final tts = _FakeTextToSpeechService();
      final audioSession = _FakeChatVoiceAudioSessionCoordinator();
      final container = ProviderContainer(
        overrides: [
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.authenticated,
          ),
          selectedModelProvider.overrideWithValue(_model),
          appSettingsProvider.overrideWithValue(const AppSettings()),
          reviewerModeProvider.overrideWithValue(true),
          voiceInputServiceProvider.overrideWithValue(input),
          textToSpeechServiceProvider.overrideWithValue(tts),
          callKitServiceProvider.overrideWithValue(
            _UnavailableCallKitService(),
          ),
          chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
            _FakeChatVoiceBackgroundCoordinator(),
          ),
          chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
            audioSession,
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(
        chatVoiceModeControllerProvider.notifier,
      );

      await controller.start(startNewConversation: false);
      await input.completeCurrent('alpha unique voice turn');
      await _until(() => tts.finishedTexts.length == 1);
      expect(audioSession.speakingCalls, greaterThanOrEqualTo(1));
      final firstSpoken = tts.finishedTexts.single ?? '';
      expect(firstSpoken, contains('alpha unique voice turn'));

      await _until(() => input.beginCalls == 2);
      await input.completeCurrent('bravo unique voice turn');
      await _until(() => tts.finishedTexts.length == 2);
      final secondSpoken = tts.finishedTexts.last ?? '';

      expect(secondSpoken, contains('bravo unique voice turn'));
      expect(secondSpoken, isNot(contains('alpha unique voice turn')));
    },
  );

  test(
    'does not send partial-only transcript when listening completes',
    () async {
      final input = _FakeVoiceInputService();
      final tts = _FakeTextToSpeechService();
      final audioSession = _FakeChatVoiceAudioSessionCoordinator();
      final container = ProviderContainer(
        overrides: [
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.authenticated,
          ),
          selectedModelProvider.overrideWithValue(_model),
          appSettingsProvider.overrideWithValue(const AppSettings()),
          reviewerModeProvider.overrideWithValue(true),
          voiceInputServiceProvider.overrideWithValue(input),
          textToSpeechServiceProvider.overrideWithValue(tts),
          callKitServiceProvider.overrideWithValue(
            _UnavailableCallKitService(),
          ),
          chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
            _FakeChatVoiceBackgroundCoordinator(),
          ),
          chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
            audioSession,
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(
        chatVoiceModeControllerProvider.notifier,
      );

      await controller.start(startNewConversation: false);
      await input.completeCurrent('partial transcript', finalResult: false);
      await _until(() => input.beginCalls == 2);

      check(container.read(chatMessagesProvider)).isEmpty();
      check(tts.startedStreaming).isFalse();
      check(
        container.read(chatVoiceModeControllerProvider).phase,
      ).equals(ChatVoiceModePhase.listening);
    },
  );

  test(
    'native continuous STT sends finals without restarting the recognizer',
    () async {
      final input = _FakeVoiceInputService()..nativeLocalStt = true;
      final tts = _FakeTextToSpeechService();
      final audioSession = _FakeChatVoiceAudioSessionCoordinator();
      final container = ProviderContainer(
        overrides: [
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.authenticated,
          ),
          selectedModelProvider.overrideWithValue(_model),
          appSettingsProvider.overrideWithValue(const AppSettings()),
          reviewerModeProvider.overrideWithValue(true),
          voiceInputServiceProvider.overrideWithValue(input),
          textToSpeechServiceProvider.overrideWithValue(tts),
          callKitServiceProvider.overrideWithValue(
            _UnavailableCallKitService(),
          ),
          chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
            _FakeChatVoiceBackgroundCoordinator(),
          ),
          chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
            audioSession,
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(
        chatVoiceModeControllerProvider.notifier,
      );

      await controller.start(startNewConversation: false);
      input.stopCalls = 0;
      await input.completeCurrent('continuous final', close: false);
      await _until(() => tts.finishedTexts.isNotEmpty);
      await _until(
        () =>
            container.read(chatVoiceModeControllerProvider).phase ==
            ChatVoiceModePhase.listening,
      );

      check(
        container.read(chatMessagesProvider).first.content,
      ).equals('continuous final');
      check(input.beginCalls).equals(1);
      check(input.stopCalls).equals(0);
      check(input.isListening).isTrue();
      await controller.stop();
    },
  );

  test(
    'queues final transcripts that arrive while the previous final is sending',
    () async {
      final input = _FakeVoiceInputService()..nativeLocalStt = true;
      final tts = _FakeTextToSpeechService()..holdCompletion = true;
      final audioSession = _FakeChatVoiceAudioSessionCoordinator();
      var stopGenerationCalls = 0;
      final container = ProviderContainer(
        overrides: [
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.authenticated,
          ),
          selectedModelProvider.overrideWithValue(_model),
          appSettingsProvider.overrideWithValue(const AppSettings()),
          reviewerModeProvider.overrideWithValue(true),
          voiceInputServiceProvider.overrideWithValue(input),
          textToSpeechServiceProvider.overrideWithValue(tts),
          stopGenerationProvider.overrideWithValue(() {
            stopGenerationCalls += 1;
          }),
          callKitServiceProvider.overrideWithValue(
            _UnavailableCallKitService(),
          ),
          chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
            _FakeChatVoiceBackgroundCoordinator(),
          ),
          chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
            audioSession,
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(
        chatVoiceModeControllerProvider.notifier,
      );

      await controller.start(startNewConversation: false);
      await input.completeCurrent('first queued final', close: false);
      await input.completeCurrent('second queued final', close: false);
      await input.completeCurrent('third queued final', close: false);
      await _until(
        () =>
            container
                .read(chatMessagesProvider)
                .where((message) => message.role == 'user')
                .length ==
            3,
      );

      final userMessages = container
          .read(chatMessagesProvider)
          .where((message) => message.role == 'user')
          .map((message) => message.content)
          .toList();
      check(userMessages).deepEquals(<String>[
        'first queued final',
        'second queued final',
        'third queued final',
      ]);
      await _until(() => tts.finishedTexts.length == 3);
      check(stopGenerationCalls).equals(2);
      check(input.beginCalls).equals(1);
      await controller.stop();
    },
  );

  test(
    'barge-in stops assistant playback and sends the next final transcript',
    () async {
      final input = _FakeVoiceInputService()..nativeLocalStt = true;
      final tts = _FakeTextToSpeechService()..holdCompletion = true;
      final audioSession = _FakeChatVoiceAudioSessionCoordinator();
      var stopGenerationCalls = 0;
      final container = ProviderContainer(
        overrides: [
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.authenticated,
          ),
          selectedModelProvider.overrideWithValue(_model),
          appSettingsProvider.overrideWithValue(const AppSettings()),
          reviewerModeProvider.overrideWithValue(true),
          voiceInputServiceProvider.overrideWithValue(input),
          textToSpeechServiceProvider.overrideWithValue(tts),
          stopGenerationProvider.overrideWithValue(() {
            stopGenerationCalls += 1;
          }),
          callKitServiceProvider.overrideWithValue(
            _UnavailableCallKitService(),
          ),
          chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
            _FakeChatVoiceBackgroundCoordinator(),
          ),
          chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
            audioSession,
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(
        chatVoiceModeControllerProvider.notifier,
      );

      await controller.start(startNewConversation: false);
      await input.completeCurrent('first assistant turn', close: false);
      await _until(
        () =>
            container.read(chatVoiceModeControllerProvider).phase ==
            ChatVoiceModePhase.speaking,
      );

      await input.completeCurrent('second barge in turn', close: false);
      await _until(() => stopGenerationCalls == 1);
      await _until(
        () =>
            container
                .read(chatMessagesProvider)
                .where((message) => message.role == 'user')
                .length ==
            2,
      );

      final userMessages = container
          .read(chatMessagesProvider)
          .where((message) => message.role == 'user')
          .map((message) => message.content)
          .toList();
      check(
        userMessages,
      ).deepEquals(<String>['first assistant turn', 'second barge in turn']);
      await _until(() => tts.finishedTexts.length == 2);
      check(tts.stopStreamingCalls).equals(1);
      check(tts.stopCalls).equals(1);
      check(input.beginCalls).equals(1);
      await controller.stop();
    },
  );

  test('tracks the spoken assistant chunk and word progress', () async {
    final input = _FakeVoiceInputService();
    final tts = _FakeTextToSpeechService()..holdCompletion = true;
    final audioSession = _FakeChatVoiceAudioSessionCoordinator();
    final container = ProviderContainer(
      overrides: [
        authNavigationStateProvider.overrideWithValue(
          AuthNavigationState.authenticated,
        ),
        selectedModelProvider.overrideWithValue(_model),
        appSettingsProvider.overrideWithValue(const AppSettings()),
        reviewerModeProvider.overrideWithValue(true),
        voiceInputServiceProvider.overrideWithValue(input),
        textToSpeechServiceProvider.overrideWithValue(tts),
        callKitServiceProvider.overrideWithValue(_UnavailableCallKitService()),
        chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
          _FakeChatVoiceBackgroundCoordinator(),
        ),
        chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
          audioSession,
        ),
      ],
    );
    addTearDown(container.dispose);

    final controller = container.read(chatVoiceModeControllerProvider.notifier);

    await controller.start(startNewConversation: false);
    await input.completeCurrent('show karaoke progress');
    await _until(() => tts.fedTexts.isNotEmpty);

    tts.emitChunkStarted(0);
    await _until(
      () => container
          .read(chatVoiceModeControllerProvider)
          .spokenResponse
          .trim()
          .isNotEmpty,
    );

    final spoken = container
        .read(chatVoiceModeControllerProvider)
        .spokenResponse;
    final word = RegExp(r'\S+').firstMatch(spoken)!;
    tts.emitWordProgress(word.start, word.end);
    await _until(
      () =>
          container.read(chatVoiceModeControllerProvider).spokenWordStart ==
          word.start,
    );

    final snapshot = container.read(chatVoiceModeControllerProvider);
    check(snapshot.phase).equals(ChatVoiceModePhase.speaking);
    check(snapshot.spokenResponse).equals(spoken);
    check(snapshot.spokenWordEnd).equals(word.end);

    await controller.stop();
  });

  test(
    'holds a voice background lease and uses managed audio during CallKit session',
    () async {
      final input = _FakeVoiceInputService()
        ..localSttAvailable = false
        ..serverSttAvailable = true
        ..sttPreference = SttPreference.serverOnly;
      final tts = _FakeTextToSpeechService();
      final callKit = _AvailableCallKitService();
      final background = _FakeChatVoiceBackgroundCoordinator();
      final audioSession = _FakeChatVoiceAudioSessionCoordinator();
      final container = ProviderContainer(
        overrides: [
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.authenticated,
          ),
          selectedModelProvider.overrideWithValue(_model),
          appSettingsProvider.overrideWithValue(
            const AppSettings(sttPreference: SttPreference.serverOnly),
          ),
          reviewerModeProvider.overrideWithValue(true),
          voiceInputServiceProvider.overrideWithValue(input),
          textToSpeechServiceProvider.overrideWithValue(tts),
          callKitServiceProvider.overrideWithValue(callKit),
          chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
            background,
          ),
          chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
            audioSession,
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(callKit.dispose);

      final controller = container.read(
        chatVoiceModeControllerProvider.notifier,
      );

      await controller.start(startNewConversation: false);

      expect(background.started, hasLength(1));
      expect(background.started.single.leaseId, startsWith('chat-voice-mode-'));
      expect(background.started.single.requiresMicrophone, isTrue);
      expect(background.externalAudioSessionOwners, contains(false));
      expect(input.managedAudioFlags, <bool>[true]);
      expect(audioSession.listeningCalls, 1);
      await _until(() => callKit.connectedCallIds.contains('call-1'));

      await controller.stop();

      expect(background.stopped, <String>[background.started.single.leaseId]);
      expect(callKit.endedCallIds, <String>['call-1']);
      expect(background.externalAudioSessionOwners.last, isFalse);
      expect(audioSession.deactivateCalls, 1);
    },
  );

  test('pausing during sending defers assistant TTS until resume', () async {
    final input = _FakeVoiceInputService();
    final tts = _FakeTextToSpeechService();
    final audioSession = _FakeChatVoiceAudioSessionCoordinator();
    final container = ProviderContainer(
      overrides: [
        authNavigationStateProvider.overrideWithValue(
          AuthNavigationState.authenticated,
        ),
        selectedModelProvider.overrideWithValue(_model),
        appSettingsProvider.overrideWithValue(const AppSettings()),
        reviewerModeProvider.overrideWithValue(true),
        voiceInputServiceProvider.overrideWithValue(input),
        textToSpeechServiceProvider.overrideWithValue(tts),
        callKitServiceProvider.overrideWithValue(_UnavailableCallKitService()),
        chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
          _FakeChatVoiceBackgroundCoordinator(),
        ),
        chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
          audioSession,
        ),
      ],
    );
    addTearDown(container.dispose);

    final controller = container.read(chatVoiceModeControllerProvider.notifier);

    await controller.start(startNewConversation: false);
    await input.completeCurrent('pause while sending unique voice turn');
    await _until(
      () =>
          container.read(chatVoiceModeControllerProvider).phase ==
          ChatVoiceModePhase.sending,
    );

    await controller.pause();
    await Future<void>.delayed(const Duration(milliseconds: 900));

    expect(
      container.read(chatVoiceModeControllerProvider).phase,
      ChatVoiceModePhase.paused,
    );
    expect(tts.pauseCalls, 1);
    expect(tts.fedTexts, isEmpty);
    expect(tts.finishedTexts, isEmpty);

    await controller.resume();
    await _until(() => tts.finishedTexts.isNotEmpty);

    expect(tts.finishedTexts.single, isNotEmpty);
    await _until(() => input.beginCalls == 2);
    expect(
      container.read(chatVoiceModeControllerProvider).phase,
      ChatVoiceModePhase.listening,
    );

    await controller.stop();
  });
}

class _FakeVoiceInputService extends VoiceInputService {
  _FakeVoiceInputService() : super();

  int beginCalls = 0;
  bool localSttAvailable = true;
  bool serverSttAvailable = false;
  SttPreference sttPreference = SttPreference.deviceOnly;
  bool completedTranscriptSendable = false;
  bool nativeLocalStt = false;
  bool listening = false;
  int stopCalls = 0;
  final managedAudioFlags = <bool>[];
  StreamController<VoiceTranscriptEvent>? _transcriptController;
  StreamController<int>? _intensityController;

  @override
  bool get hasLocalStt => localSttAvailable;

  @override
  bool get hasServerStt => serverSttAvailable;

  @override
  SttPreference get preference => sttPreference;

  @override
  bool get prefersServerOnly => sttPreference == SttPreference.serverOnly;

  @override
  bool get prefersDeviceOnly => sttPreference == SttPreference.deviceOnly;

  @override
  bool get lastCompletedTranscriptSendable => completedTranscriptSendable;

  @override
  bool get isUsingNativeLocalStt => nativeLocalStt;

  @override
  bool get isListening => listening;

  @override
  Future<bool> initialize({bool forceLocalStt = false}) async => true;

  @override
  Future<Stream<VoiceTranscriptEvent>> beginListeningEvents({
    bool iosAudioSessionManagedExternally = false,
  }) async {
    beginCalls += 1;
    listening = true;
    completedTranscriptSendable = false;
    managedAudioFlags.add(iosAudioSessionManagedExternally);
    _transcriptController = StreamController<VoiceTranscriptEvent>.broadcast();
    _intensityController = StreamController<int>.broadcast();
    return _transcriptController!.stream;
  }

  @override
  Stream<int> get intensityStream =>
      _intensityController?.stream ?? const Stream<int>.empty();

  Future<void> completeCurrent(
    String transcript, {
    bool finalResult = true,
    bool close = true,
  }) async {
    final controller = _transcriptController;
    if (controller == null) return;
    controller.add(
      VoiceTranscriptEvent(text: transcript, isFinal: finalResult),
    );
    completedTranscriptSendable = finalResult;
    if (close) {
      listening = false;
      await controller.close();
    }
  }

  @override
  Future<void> stopListening() async {
    stopCalls += 1;
    listening = false;
    final controller = _transcriptController;
    _transcriptController = null;
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
  }
}

class _FakeTextToSpeechService extends TextToSpeechService {
  _FakeTextToSpeechService() : super();

  final _events = StreamController<TtsEvent>.broadcast();
  final fedTexts = <String>[];
  final finishedTexts = <String?>[];
  bool startedStreaming = false;
  bool holdCompletion = false;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int stopStreamingCalls = 0;
  int stopCalls = 0;
  bool _didStart = false;

  @override
  Stream<TtsEvent> get events => _events.stream;

  @override
  List<String> splitTextForSpeech(String text) {
    return text
        .split(RegExp(r'(?<=[.!?])\s+|\n+'))
        .map((chunk) => chunk.trim())
        .where((chunk) => chunk.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<bool> initialize({
    String? deviceVoice,
    String? serverVoice,
    double speechRate = 0.5,
    double pitch = 1.0,
    double volume = 1.0,
    TtsEngine engine = TtsEngine.device,
  }) async {
    return true;
  }

  @override
  Future<void> startStreamingTts() async {
    startedStreaming = true;
    _didStart = false;
  }

  @override
  Future<void> feedStreamingText(String accumulatedText) async {
    fedTexts.add(accumulatedText);
    if (!_didStart && accumulatedText.trim().isNotEmpty) {
      _didStart = true;
      _events.add(const TtsStarted());
    }
  }

  @override
  Future<void> finishStreamingTts({String? finalText}) async {
    finishedTexts.add(finalText);
    if (holdCompletion) {
      return;
    }
    _events.add(const TtsCompleted());
  }

  @override
  Future<void> stopStreamingTts() async {
    stopStreamingCalls += 1;
  }

  @override
  Future<void> pause() async {
    pauseCalls += 1;
    _events.add(const TtsPaused());
  }

  @override
  Future<void> resume() async {
    resumeCalls += 1;
    _events.add(const TtsResumed());
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
  }

  void emitChunkStarted(int index) {
    _events.add(TtsChunkStarted(index));
  }

  void emitWordProgress(int start, int end) {
    _events.add(TtsWordProgress(start, end));
  }
}

class _UnavailableCallKitService extends CallKitService {
  @override
  bool get isAvailable => false;

  @override
  Stream<CallEvent> get events => const Stream<CallEvent>.empty();
}

class _AvailableCallKitService extends CallKitService {
  final _events = StreamController<CallEvent>.broadcast();
  final connectedCallIds = <String>[];
  final endedCallIds = <String>[];

  @override
  bool get isAvailable => true;

  @override
  Stream<CallEvent> get events => _events.stream;

  @override
  Future<void> checkAndCleanActiveCalls() async {}

  @override
  Future<void> requestPermissions() async {}

  @override
  Future<String?> startOutgoingVoiceCall({
    required String calleeName,
    required String handle,
    String? avatar,
    int? durationMs,
  }) async {
    return 'call-1';
  }

  @override
  Future<void> markCallConnected(String id) async {
    connectedCallIds.add(id);
  }

  @override
  Future<void> endCall(String id) async {
    endedCallIds.add(id);
  }

  Future<void> dispose() => _events.close();
}

class _FakeChatVoiceBackgroundCoordinator
    extends ChatVoiceModeBackgroundCoordinator {
  final started = <({String leaseId, bool requiresMicrophone})>[];
  final stopped = <String>[];
  final externalAudioSessionOwners = <bool>[];
  int keepAliveCalls = 0;

  @override
  Future<void> startVoiceLease({
    required String leaseId,
    required bool requiresMicrophone,
  }) async {
    started.add((leaseId: leaseId, requiresMicrophone: requiresMicrophone));
  }

  @override
  Future<void> stopVoiceLease(String leaseId) async {
    stopped.add(leaseId);
  }

  @override
  Future<bool> keepAlive() async {
    keepAliveCalls += 1;
    return true;
  }

  @override
  Future<void> setExternalAudioSessionOwner(bool isExternal) async {
    externalAudioSessionOwners.add(isExternal);
  }
}

class _FakeChatVoiceAudioSessionCoordinator
    extends ChatVoiceAudioSessionCoordinator {
  int listeningCalls = 0;
  int speakingCalls = 0;
  int deactivateCalls = 0;

  @override
  Future<void> configureForListening() async {
    listeningCalls += 1;
  }

  @override
  Future<void> configureForSpeaking() async {
    speakingCalls += 1;
  }

  @override
  Future<void> deactivate() async {
    deactivateCalls += 1;
  }
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 300; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('Condition was not met.');
}
