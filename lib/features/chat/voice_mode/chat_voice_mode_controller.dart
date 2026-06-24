import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/background_streaming_handler.dart';
import '../../../core/services/callkit_service.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../auth/providers/unified_auth_providers.dart';
import '../providers/chat_providers.dart';
import '../providers/text_to_speech_provider.dart';
import '../services/text_to_speech_service.dart';
import '../services/voice_input_service.dart';
import 'chat_voice_audio_session_coordinator.dart';
import '../../tools/providers/tools_providers.dart';

enum ChatVoiceModePhase {
  idle,
  starting,
  listening,
  sending,
  speaking,
  paused,
  muted,
  ending,
  ended,
  error,
}

@immutable
class ChatVoiceModeSnapshot {
  const ChatVoiceModeSnapshot({
    this.phase = ChatVoiceModePhase.idle,
    this.transcript = '',
    this.assistantPreview = '',
    this.spokenResponse = '',
    this.spokenWordStart,
    this.spokenWordEnd,
    this.intensity = 0,
    this.elapsed = Duration.zero,
    this.startedAt,
    this.activeCallId,
    this.errorMessage,
    this.isCollapsed = false,
    this.isMuted = false,
  });

  final ChatVoiceModePhase phase;
  final String transcript;
  final String assistantPreview;
  final String spokenResponse;
  final int? spokenWordStart;
  final int? spokenWordEnd;
  final int intensity;
  final Duration elapsed;
  final DateTime? startedAt;
  final String? activeCallId;
  final String? errorMessage;
  final bool isCollapsed;
  final bool isMuted;

  bool get isActive {
    return switch (phase) {
      ChatVoiceModePhase.idle ||
      ChatVoiceModePhase.ended ||
      ChatVoiceModePhase.error => false,
      _ => true,
    };
  }

  bool get canPause {
    return phase == ChatVoiceModePhase.listening ||
        phase == ChatVoiceModePhase.sending ||
        phase == ChatVoiceModePhase.speaking;
  }

  bool get canResume {
    return phase == ChatVoiceModePhase.paused ||
        phase == ChatVoiceModePhase.muted;
  }

  ChatVoiceModeSnapshot copyWith({
    ChatVoiceModePhase? phase,
    String? transcript,
    String? assistantPreview,
    String? spokenResponse,
    bool clearSpokenResponse = false,
    int? spokenWordStart,
    int? spokenWordEnd,
    bool clearSpokenProgress = false,
    int? intensity,
    Duration? elapsed,
    DateTime? startedAt,
    bool clearStartedAt = false,
    String? activeCallId,
    bool clearActiveCallId = false,
    String? errorMessage,
    bool clearErrorMessage = false,
    bool? isCollapsed,
    bool? isMuted,
  }) {
    return ChatVoiceModeSnapshot(
      phase: phase ?? this.phase,
      transcript: transcript ?? this.transcript,
      assistantPreview: assistantPreview ?? this.assistantPreview,
      spokenResponse: clearSpokenResponse
          ? ''
          : spokenResponse ?? this.spokenResponse,
      spokenWordStart: clearSpokenResponse || clearSpokenProgress
          ? null
          : spokenWordStart ?? this.spokenWordStart,
      spokenWordEnd: clearSpokenResponse || clearSpokenProgress
          ? null
          : spokenWordEnd ?? this.spokenWordEnd,
      intensity: intensity ?? this.intensity,
      elapsed: elapsed ?? this.elapsed,
      startedAt: clearStartedAt ? null : startedAt ?? this.startedAt,
      activeCallId: clearActiveCallId
          ? null
          : activeCallId ?? this.activeCallId,
      errorMessage: clearErrorMessage
          ? null
          : errorMessage ?? this.errorMessage,
      isCollapsed: isCollapsed ?? this.isCollapsed,
      isMuted: isMuted ?? this.isMuted,
    );
  }
}

final chatVoiceModeControllerProvider =
    NotifierProvider<ChatVoiceModeController, ChatVoiceModeSnapshot>(
      ChatVoiceModeController.new,
    );

final chatVoiceModeBackgroundCoordinatorProvider =
    Provider<ChatVoiceModeBackgroundCoordinator>((ref) {
      return ChatVoiceModeBackgroundCoordinator();
    });

class ChatVoiceModeBackgroundCoordinator {
  Future<void> startVoiceLease({
    required String leaseId,
    required bool requiresMicrophone,
  }) {
    return BackgroundStreamingHandler.instance.startBackgroundExecution(
      [leaseId],
      requiresMicrophone: requiresMicrophone,
      kind: BackgroundStreamKind.voice,
    );
  }

  Future<void> stopVoiceLease(String leaseId) {
    return BackgroundStreamingHandler.instance.stopBackgroundExecution([
      leaseId,
    ]);
  }

  Future<bool> keepAlive() {
    return BackgroundStreamingHandler.instance.keepAlive();
  }

  Future<void> setExternalAudioSessionOwner(bool isExternal) {
    return BackgroundStreamingHandler.instance.setExternalAudioSessionOwner(
      isExternal,
    );
  }
}

class ChatVoiceModeController extends Notifier<ChatVoiceModeSnapshot> {
  static const int _maxEmptyTranscriptRestarts = 4;
  static const int _emptyTranscriptBaseDelayMs = 250;
  static const int _emptyTranscriptMaxDelayMs = 2000;
  static const Duration _backgroundKeepAliveInterval = Duration(minutes: 5);

  Future<void> _serial = Future<void>.value();
  int _token = 0;
  int _emptyTranscriptRestarts = 0;

  StreamSubscription<VoiceTranscriptEvent>? _transcriptSub;
  StreamSubscription<int>? _intensitySub;
  StreamSubscription<TtsEvent>? _ttsSub;
  StreamSubscription<CallEvent>? _callKitSub;
  Timer? _elapsedTimer;
  Timer? _backgroundKeepAliveTimer;

  String _currentTranscript = '';
  String _lastFedAssistantText = '';
  String? _backgroundLeaseId;
  String? _activeAssistantMessageId;
  ChatVoiceModeBackgroundCoordinator? _backgroundCoordinator;
  ChatVoiceAudioSessionCoordinator? _audioSessionCoordinator;
  Set<String> _assistantMessageIdsBeforeTurn = <String>{};
  bool _awaitingAssistant = false;
  bool _assistantFinalized = false;
  bool _streamingTtsStarted = false;
  bool _iosAudioSessionManagedExternally = false;
  bool _markedCallConnected = false;
  bool _pausedDuringSpeech = false;
  bool _pausedDuringAssistantTurn = false;
  bool _assistantFinalizationDeferred = false;
  String? _pendingPausedAssistantText;
  String? _pendingPausedAssistantFinalText;
  final Queue<String> _pendingFinalTranscripts = Queue<String>();
  String? _lastSubmittedTranscript;
  bool _stoppingFromCallKit = false;
  bool _sendingTranscript = false;
  List<String> _assistantSpeechChunks = const <String>[];
  int _activeAssistantSpeechChunkIndex = -1;

  @override
  ChatVoiceModeSnapshot build() {
    _backgroundCoordinator = ref.read(
      chatVoiceModeBackgroundCoordinatorProvider,
    );
    _audioSessionCoordinator = ref.read(
      chatVoiceAudioSessionCoordinatorProvider,
    );

    ref.listen<String?>(streamingContentProvider, (_, next) {
      if (next != null) {
        _handleAssistantContentChanged();
      }
    });

    ref.listen<List<ChatMessage>>(chatMessagesProvider, (_, next) {
      _handleChatMessagesChanged(next);
    });

    ref.onDispose(() {
      _elapsedTimer?.cancel();
      unawaited(_transcriptSub?.cancel());
      unawaited(_intensitySub?.cancel());
      unawaited(_ttsSub?.cancel());
      unawaited(_callKitSub?.cancel());
      _backgroundKeepAliveTimer?.cancel();
      unawaited(_stopBackgroundVoiceLease(_backgroundCoordinator));
    });

    return const ChatVoiceModeSnapshot();
  }

  Future<void> start({required bool startNewConversation}) {
    return _enqueue(() async {
      if (state.isActive) {
        return;
      }

      final authState = ref.read(authNavigationStateProvider);
      if (authState != AuthNavigationState.authenticated) {
        _setError('Sign in to start a voice call.');
        return;
      }

      final model = ref.read(selectedModelProvider);
      if (model == null) {
        _setError('Choose a model before starting a voice call.');
        return;
      }

      final token = ++_token;
      _resetRuntime();

      state = state.copyWith(
        phase: ChatVoiceModePhase.starting,
        startedAt: DateTime.now(),
        elapsed: Duration.zero,
        clearErrorMessage: true,
        isCollapsed: false,
        isMuted: false,
      );

      if (startNewConversation) {
        startNewChat(ref);
      }

      try {
        final input = ref.read(voiceInputServiceProvider);
        final tts = ref.read(textToSpeechServiceProvider);
        final settings = ref.read(appSettingsProvider);

        final inputReady = await input.initialize();
        if (!inputReady) {
          throw StateError('Voice input initialization failed.');
        }

        await _requestAndroidVoiceRoutingPermission();
        await _initializeTts(tts, settings);
        _listenForTtsEvents(tts, token);
        await _startCallKit(model.name, token);
        await _startBackgroundVoiceLease(input, token);
        _startElapsedTimer(token);
        await _startListening(token);
      } catch (error, stackTrace) {
        DebugLogger.error(
          'start-failed',
          scope: 'chat/voice_mode',
          error: error,
          stackTrace: stackTrace,
        );
        await _fail(error.toString(), token);
      }
    });
  }

  Future<void> _requestAndroidVoiceRoutingPermission() async {
    if (!Platform.isAndroid) {
      return;
    }

    try {
      final status = await Permission.bluetoothConnect.status;
      if (status.isGranted) {
        return;
      }

      final requested = await Permission.bluetoothConnect.request();
      if (!requested.isGranted) {
        DebugLogger.warning(
          'bluetooth-connect-denied',
          scope: 'chat/voice_mode',
          data: {'status': requested.name},
        );
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'bluetooth-connect-request-failed',
        scope: 'chat/voice_mode',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> stop() {
    return _enqueue(() => _stopInternal(endCallKit: true));
  }

  Future<void> pause() {
    return _enqueue(() async {
      if (!state.canPause) return;

      final wasAwaitingAssistant = _awaitingAssistant;
      _pausedDuringSpeech = state.phase == ChatVoiceModePhase.speaking;
      _pausedDuringAssistantTurn = wasAwaitingAssistant;
      await _cancelListening();
      if (wasAwaitingAssistant) {
        await ref.read(textToSpeechServiceProvider).pause();
      }

      state = state.copyWith(phase: ChatVoiceModePhase.paused);
    });
  }

  Future<void> resume() {
    return _enqueue(() async {
      if (!state.canResume) return;

      final token = _token;
      state = state.copyWith(
        phase: ChatVoiceModePhase.starting,
        isMuted: false,
        clearErrorMessage: true,
      );

      if (_pausedDuringAssistantTurn) {
        await _resumePausedAssistantTurn(token);
        return;
      }

      if (_pausedDuringSpeech) {
        _pausedDuringSpeech = false;
        await ref.read(textToSpeechServiceProvider).resume();
        state = state.copyWith(phase: ChatVoiceModePhase.speaking);
        return;
      }

      await _startListening(token);
    });
  }

  Future<void> toggleMute() {
    return _enqueue(() async {
      if (!state.isActive && state.phase != ChatVoiceModePhase.paused) {
        return;
      }

      if (!state.isMuted) {
        await _cancelListening();
        state = state.copyWith(
          phase: ChatVoiceModePhase.muted,
          isMuted: true,
          intensity: 0,
        );
        return;
      }

      state = state.copyWith(
        phase: ChatVoiceModePhase.starting,
        isMuted: false,
        clearErrorMessage: true,
      );
      await _startListening(_token);
    });
  }

  Future<void> cancelSpeaking() {
    return _enqueue(() async {
      await ref.read(textToSpeechServiceProvider).stopStreamingTts();
      await ref.read(textToSpeechServiceProvider).stop();
      _streamingTtsStarted = false;
      _assistantFinalized = true;
      if (state.isActive && !state.isMuted) {
        await _startListening(_token);
      }
    });
  }

  void collapse() {
    if (state.isActive) {
      state = state.copyWith(isCollapsed: true);
    }
  }

  void expand() {
    if (state.isActive) {
      state = state.copyWith(isCollapsed: false);
    }
  }

  void toggleCollapsed() {
    if (state.isActive) {
      state = state.copyWith(isCollapsed: !state.isCollapsed);
    }
  }

  Future<void> _initializeTts(TextToSpeechService tts, AppSettings settings) {
    return tts.initialize(
      deviceVoice: settings.ttsVoice,
      serverVoice: settings.ttsServerVoiceId,
      speechRate: settings.ttsSpeechRate,
      pitch: settings.ttsPitch,
      volume: settings.ttsVolume,
      engine: settings.ttsEngine,
    );
  }

  Future<void> _startCallKit(String modelName, int token) async {
    final callKit = ref.read(callKitServiceProvider);
    if (!callKit.isAvailable) {
      return;
    }

    await callKit.checkAndCleanActiveCalls();
    if (token != _token) return;

    await callKit.requestPermissions();
    if (token != _token) return;

    final callId = await callKit.startOutgoingVoiceCall(
      calleeName: modelName,
      handle: 'Conduit AI',
    );
    if (token != _token || callId == null) {
      return;
    }

    state = state.copyWith(activeCallId: callId);
    await _callKitSub?.cancel();
    _callKitSub = callKit.events.listen((event) {
      _handleCallKitEvent(event);
    });
  }

  void _handleCallKitEvent(CallEvent event) {
    final callId = state.activeCallId;
    if (callId == null) return;

    final endedCallId = switch (event) {
      CallEventActionCallEnded(:final id) => id,
      CallEventActionCallDecline(:final id) => id,
      CallEventActionCallTimeout(:final id) => id,
      _ => null,
    };
    if (endedCallId != null) {
      if (endedCallId == callId) {
        _stoppingFromCallKit = true;
        unawaited(_enqueue(() => _stopInternal(endCallKit: false)));
      }
      return;
    }

    if (event is CallEventActionCallToggleMute && event.id == callId) {
      final shouldMute = event.isMuted;
      if (shouldMute != state.isMuted) {
        unawaited(toggleMute());
      }
    }
  }

  void _listenForTtsEvents(TextToSpeechService tts, int token) {
    unawaited(_ttsSub?.cancel());
    _ttsSub = tts.events.listen((event) {
      if (token != _token) return;

      switch (event) {
        case TtsStarted():
          if (_awaitingAssistant && state.phase != ChatVoiceModePhase.paused) {
            if (_activeAssistantSpeechChunkIndex < 0 &&
                _assistantSpeechChunks.isNotEmpty) {
              _handleTtsChunkStarted(0);
            }
            state = state.copyWith(phase: ChatVoiceModePhase.speaking);
          }
        case TtsCompleted():
          if (_assistantFinalized && _awaitingAssistant) {
            unawaited(_resumeAfterAssistantSpeech(token));
          }
        case TtsCancelled():
          break;
        case TtsError(:final message):
          state = state.copyWith(errorMessage: message);
        case TtsPaused():
        case TtsResumed():
          break;
        case TtsChunkStarted(:final chunkIndex):
          _handleTtsChunkStarted(chunkIndex);
        case TtsWordProgress(:final start, :final end):
          _handleTtsWordProgress(start, end);
      }
    });
  }

  Future<void> _startBackgroundVoiceLease(
    VoiceInputService input,
    int token,
  ) async {
    await _stopBackgroundVoiceLease();
    if (token != _token) return;

    final leaseId = 'chat-voice-mode-$token';
    final requiresMicrophone = _requiresNativeBackgroundMicrophone(input);
    final background = _backgroundCoordinator!;

    _backgroundLeaseId = leaseId;
    _iosAudioSessionManagedExternally = true;

    await background.setExternalAudioSessionOwner(!requiresMicrophone);

    try {
      await background.startVoiceLease(
        leaseId: leaseId,
        requiresMicrophone: requiresMicrophone,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'background-start-failed',
        scope: 'chat/voice_mode',
        error: error,
        stackTrace: stackTrace,
        data: {'requiresMicrophone': requiresMicrophone},
      );
    }

    _startBackgroundKeepAliveTimer(token, background);
  }

  bool _requiresNativeBackgroundMicrophone(VoiceInputService input) {
    return Platform.isAndroid ||
        input.hasServerStt && (input.prefersServerOnly || !input.hasLocalStt);
  }

  void _startBackgroundKeepAliveTimer(
    int token,
    ChatVoiceModeBackgroundCoordinator background,
  ) {
    _backgroundKeepAliveTimer?.cancel();
    _backgroundKeepAliveTimer = Timer.periodic(_backgroundKeepAliveInterval, (
      _,
    ) {
      if (token != _token || !state.isActive) {
        _backgroundKeepAliveTimer?.cancel();
        _backgroundKeepAliveTimer = null;
        return;
      }
      unawaited(background.keepAlive());
    });
  }

  Future<void> _stopBackgroundVoiceLease([
    ChatVoiceModeBackgroundCoordinator? coordinator,
  ]) async {
    _backgroundKeepAliveTimer?.cancel();
    _backgroundKeepAliveTimer = null;
    _iosAudioSessionManagedExternally = false;

    final leaseId = _backgroundLeaseId;
    _backgroundLeaseId = null;
    final background = coordinator ?? _backgroundCoordinator;
    if (background == null) return;

    if (leaseId != null) {
      try {
        await background.stopVoiceLease(leaseId);
      } catch (error, stackTrace) {
        DebugLogger.error(
          'background-stop-failed',
          scope: 'chat/voice_mode',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    await background.setExternalAudioSessionOwner(false);
  }

  Future<void> _startListening(int token) async {
    if (token != _token || state.isMuted) {
      return;
    }

    final input = ref.read(voiceInputServiceProvider);
    if (_transcriptSub == null || !input.isListening) {
      await _cancelListening();
    }
    await _audioSessionCoordinator?.configureForListening();

    _currentTranscript = '';
    state = state.copyWith(
      phase: ChatVoiceModePhase.listening,
      transcript: '',
      assistantPreview: '',
      clearSpokenResponse: true,
      intensity: 0,
      clearErrorMessage: true,
    );

    final callId = state.activeCallId;
    if (!_markedCallConnected && callId != null) {
      _markedCallConnected = true;
      unawaited(ref.read(callKitServiceProvider).markCallConnected(callId));
    }

    if (_transcriptSub == null || !input.isListening) {
      final stream = await input.beginListeningEvents(
        iosAudioSessionManagedExternally: _iosAudioSessionManagedExternally,
      );
      if (token != _token) return;

      await _transcriptSub?.cancel();
      _transcriptSub = stream.listen(
        (event) {
          _handleTranscriptEvent(event, token);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (token != _token) return;
          DebugLogger.error(
            'listen-failed',
            scope: 'chat/voice_mode',
            error: error,
            stackTrace: stackTrace,
          );
          unawaited(_fail(error.toString(), token));
        },
        onDone: () {
          _transcriptSub = null;
          unawaited(_handleListeningDone(token));
        },
      );
    }

    await _intensitySub?.cancel();
    _intensitySub = input.intensityStream.listen((intensity) {
      if (token == _token && state.phase == ChatVoiceModePhase.listening) {
        state = state.copyWith(intensity: intensity);
      }
    });
  }

  void _handleTranscriptEvent(VoiceTranscriptEvent event, int token) {
    if (token != _token || state.isMuted) return;

    _currentTranscript = event.text;
    if (state.isActive && state.phase != ChatVoiceModePhase.paused) {
      state = state.copyWith(transcript: event.text);
    }

    if (event.isFinal) {
      unawaited(_handleFinalTranscript(event.text, token));
    }
  }

  Future<void> _handleFinalTranscript(String text, int token) async {
    if (token != _token ||
        state.isMuted ||
        state.phase == ChatVoiceModePhase.paused) {
      return;
    }

    final transcript = text.trim();
    if (transcript.isEmpty) {
      return;
    }

    if (_sendingTranscript) {
      _enqueuePendingFinalTranscript(transcript);
      return;
    }

    await _drainFinalTranscripts(transcript, token);
  }

  Future<void> _handleListeningDone(int token) async {
    if (token != _token || state.phase != ChatVoiceModePhase.listening) {
      return;
    }

    final input = ref.read(voiceInputServiceProvider);
    final transcript = input.lastCompletedTranscriptSendable
        ? _currentTranscript.trim()
        : '';
    if (transcript.isEmpty) {
      await _restartAfterEmptyTranscript(token);
      return;
    }

    _emptyTranscriptRestarts = 0;
    await _handleFinalTranscript(transcript, token);
  }

  Future<void> _drainFinalTranscripts(
    String initialTranscript,
    int token,
  ) async {
    var transcript = initialTranscript;

    while (true) {
      if (token != _token ||
          state.isMuted ||
          state.phase == ChatVoiceModePhase.paused) {
        return;
      }

      if (transcript == _lastSubmittedTranscript) {
        final pending = _takePendingFinalTranscript();
        if (pending == null) {
          return;
        }
        transcript = pending;
        continue;
      }

      _sendingTranscript = true;
      try {
        _emptyTranscriptRestarts = 0;
        if (_awaitingAssistant ||
            state.phase == ChatVoiceModePhase.sending ||
            state.phase == ChatVoiceModePhase.speaking) {
          await _interruptAssistantForBargeIn(token);
        }
        if (token != _token || state.isMuted) return;
        _lastSubmittedTranscript = transcript;
        await _sendTranscript(transcript, token);
      } finally {
        _sendingTranscript = false;
      }

      final pending = _takePendingFinalTranscript();
      if (pending == null || pending == transcript) {
        return;
      }
      transcript = pending;
    }
  }

  void _enqueuePendingFinalTranscript(String transcript) {
    final pending = transcript.trim();
    if (pending.isEmpty || pending == _lastSubmittedTranscript) {
      return;
    }
    if (_pendingFinalTranscripts.isNotEmpty &&
        _pendingFinalTranscripts.last == pending) {
      return;
    }
    _pendingFinalTranscripts.addLast(pending);
  }

  String? _takePendingFinalTranscript() {
    while (_pendingFinalTranscripts.isNotEmpty) {
      final pending = _pendingFinalTranscripts.removeFirst().trim();
      if (pending.isNotEmpty && pending != _lastSubmittedTranscript) {
        return pending;
      }
    }
    return null;
  }

  Future<void> _restartAfterEmptyTranscript(int token) async {
    _emptyTranscriptRestarts++;
    if (_emptyTranscriptRestarts > _maxEmptyTranscriptRestarts) {
      state = state.copyWith(
        phase: ChatVoiceModePhase.paused,
        errorMessage: 'No speech detected.',
      );
      return;
    }

    final exponent = _emptyTranscriptRestarts - 1;
    final delayMs = (_emptyTranscriptBaseDelayMs << exponent).clamp(
      _emptyTranscriptBaseDelayMs,
      _emptyTranscriptMaxDelayMs,
    );
    await Future<void>.delayed(Duration(milliseconds: delayMs));
    if (token == _token && state.phase == ChatVoiceModePhase.listening) {
      await _startListening(token);
    }
  }

  Future<void> _sendTranscript(String transcript, int token) async {
    if (token != _token) return;

    final input = ref.read(voiceInputServiceProvider);
    final keepListening = input.isUsingNativeLocalStt;
    if (!keepListening) {
      await _cancelListening();
    }
    if (keepListening && Platform.isIOS) {
      await _audioSessionCoordinator?.configureForBargeInSpeaking();
    } else {
      await _audioSessionCoordinator?.configureForSpeaking();
    }
    final tts = ref.read(textToSpeechServiceProvider);
    _assistantMessageIdsBeforeTurn = _currentAssistantMessageIds();
    ref.read(streamingContentProvider.notifier).set(null);
    await tts.startStreamingTts();

    _streamingTtsStarted = true;
    _assistantFinalized = false;
    _awaitingAssistant = true;
    _lastFedAssistantText = '';
    _activeAssistantMessageId = null;
    _assistantSpeechChunks = const <String>[];
    _activeAssistantSpeechChunkIndex = -1;

    state = state.copyWith(
      phase: ChatVoiceModePhase.sending,
      transcript: transcript,
      assistantPreview: '',
      clearSpokenResponse: true,
      intensity: 0,
      clearErrorMessage: true,
    );

    try {
      final selectedToolIds = ref.read(selectedToolIdsProvider);
      await sendMessageFromService(
        ref,
        transcript,
        null,
        selectedToolIds,
        true,
      );
      if (token != _token) return;

      _activeAssistantMessageId ??= _activeAssistantMessage()?.id;
      _handleAssistantContentChanged();
      _handleChatMessagesChanged(ref.read(chatMessagesProvider));
    } catch (error, stackTrace) {
      DebugLogger.error(
        'send-failed',
        scope: 'chat/voice_mode',
        error: error,
        stackTrace: stackTrace,
      );
      await _fail(error.toString(), token);
    }
  }

  Future<void> _interruptAssistantForBargeIn(int token) async {
    if (token != _token) return;

    DebugLogger.info('barge-in', scope: 'chat/voice_mode');
    final tts = ref.read(textToSpeechServiceProvider);
    await tts.stopStreamingTts();
    await tts.stop();

    try {
      ref.read(stopGenerationProvider)();
    } catch (error, stackTrace) {
      DebugLogger.warning(
        'barge-in-stop-generation-failed',
        scope: 'chat/voice_mode',
        data: {'error': error, 'stackTrace': stackTrace},
      );
    }

    _awaitingAssistant = false;
    _assistantFinalized = true;
    _streamingTtsStarted = false;
    _activeAssistantMessageId = null;
    _lastFedAssistantText = '';
    _assistantSpeechChunks = const <String>[];
    _activeAssistantSpeechChunkIndex = -1;
    _assistantMessageIdsBeforeTurn = <String>{};
    state = state.copyWith(clearSpokenResponse: true);
  }

  void _handleAssistantContentChanged([List<ChatMessage>? messages]) {
    if (!_awaitingAssistant || !_streamingTtsStarted || _assistantFinalized) {
      return;
    }

    final text = _visibleAssistantText(messages);
    if (text == null) {
      return;
    }

    _syncAssistantSpeechChunks(text);
    state = state.copyWith(assistantPreview: text);
    if (state.phase == ChatVoiceModePhase.paused) {
      _pendingPausedAssistantText = text;
      return;
    }

    if (text == _lastFedAssistantText) {
      return;
    }

    _lastFedAssistantText = text;
    unawaited(ref.read(textToSpeechServiceProvider).feedStreamingText(text));
  }

  void _handleChatMessagesChanged(List<ChatMessage> messages) {
    if (!_awaitingAssistant || !_streamingTtsStarted || _assistantFinalized) {
      return;
    }

    final active = _activeAssistantMessage(messages);
    if (active == null) {
      return;
    }
    _activeAssistantMessageId ??= active.id;
    _handleAssistantContentChanged(messages);
    if (active.isStreaming) {
      return;
    }

    unawaited(_finishAssistantResponse(_token));
  }

  Future<void> _finishAssistantResponse(int token) async {
    if (token != _token || _assistantFinalized) {
      return;
    }

    final finalText = _visibleAssistantText() ?? '';
    _syncAssistantSpeechChunks(finalText);
    state = state.copyWith(assistantPreview: finalText);

    if (state.phase == ChatVoiceModePhase.paused) {
      _assistantFinalized = true;
      _assistantFinalizationDeferred = true;
      _pendingPausedAssistantText = finalText;
      _pendingPausedAssistantFinalText = finalText;
      return;
    }

    _assistantFinalized = true;
    await ref
        .read(textToSpeechServiceProvider)
        .finishStreamingTts(finalText: finalText);
  }

  Future<void> _resumePausedAssistantTurn(int token) async {
    final shouldResumePlayback = _pausedDuringSpeech;
    _pausedDuringSpeech = false;
    _pausedDuringAssistantTurn = false;

    if (!_awaitingAssistant) {
      await _startListening(token);
      return;
    }

    state = state.copyWith(
      phase: shouldResumePlayback
          ? ChatVoiceModePhase.speaking
          : ChatVoiceModePhase.sending,
      clearErrorMessage: true,
    );

    await _flushPausedAssistantTts(token);
    if (token != _token || !state.isActive) {
      return;
    }

    if (shouldResumePlayback) {
      await ref.read(textToSpeechServiceProvider).resume();
      if (token == _token && state.isActive) {
        state = state.copyWith(phase: ChatVoiceModePhase.speaking);
      }
      return;
    }

    if (!_assistantFinalized) {
      _handleAssistantContentChanged();
      _handleChatMessagesChanged(ref.read(chatMessagesProvider));
    }
  }

  Future<void> _flushPausedAssistantTts(int token) async {
    final tts = ref.read(textToSpeechServiceProvider);
    final deferredFinalText = _pendingPausedAssistantFinalText;
    final pendingText = _pendingPausedAssistantText;
    _pendingPausedAssistantText = null;
    _pendingPausedAssistantFinalText = null;

    if (_assistantFinalizationDeferred) {
      _assistantFinalizationDeferred = false;
      final finalText = deferredFinalText ?? pendingText ?? '';
      _lastFedAssistantText = finalText;
      await tts.finishStreamingTts(finalText: finalText);
      return;
    }

    if (token != _token ||
        pendingText == null ||
        pendingText == _lastFedAssistantText) {
      return;
    }

    _lastFedAssistantText = pendingText;
    await tts.feedStreamingText(pendingText);
  }

  Future<void> _resumeAfterAssistantSpeech(int token) async {
    if (token != _token || !_awaitingAssistant) {
      return;
    }

    _awaitingAssistant = false;
    _streamingTtsStarted = false;
    _pendingFinalTranscripts.clear();
    _lastSubmittedTranscript = null;
    _activeAssistantMessageId = null;
    _lastFedAssistantText = '';
    _assistantSpeechChunks = const <String>[];
    _activeAssistantSpeechChunkIndex = -1;
    _assistantMessageIdsBeforeTurn = <String>{};

    if (!state.isActive ||
        state.isMuted ||
        state.phase == ChatVoiceModePhase.paused) {
      return;
    }

    await _startListening(token);
  }

  Set<String> _currentAssistantMessageIds() {
    final List<ChatMessage> messages = ref.read(chatMessagesProvider);
    return {
      for (final message in messages)
        if (message.role == 'assistant') message.id,
    };
  }

  ChatMessage? _activeAssistantMessage([List<ChatMessage>? messages]) {
    final List<ChatMessage> all = messages ?? ref.read(chatMessagesProvider);
    final id = _activeAssistantMessageId;
    if (id != null) {
      for (final message in all.reversed) {
        if (message.id == id && message.role == 'assistant') {
          return message;
        }
      }
    }
    for (final message in all.reversed) {
      if (message.role == 'assistant' &&
          !_assistantMessageIdsBeforeTurn.contains(message.id)) {
        return message;
      }
    }
    return null;
  }

  String? _visibleAssistantText([List<ChatMessage>? messages]) {
    final message = _activeAssistantMessage(messages);
    if (message == null) return null;
    if (message.isStreaming && _isLastStreamingAssistant(message, messages)) {
      final visible = ref.read(streamingContentProvider);
      if (visible != null && visible.isNotEmpty) {
        return visible;
      }
    }
    return message.content;
  }

  bool _isLastStreamingAssistant(
    ChatMessage message, [
    List<ChatMessage>? messages,
  ]) {
    final List<ChatMessage> all = messages ?? ref.read(chatMessagesProvider);
    if (all.isEmpty) return false;
    final last = all.last;
    return last.id == message.id &&
        last.role == 'assistant' &&
        last.isStreaming;
  }

  Future<void> _cancelListening() async {
    await _transcriptSub?.cancel();
    _transcriptSub = null;
    await _intensitySub?.cancel();
    _intensitySub = null;
    try {
      await ref.read(voiceInputServiceProvider).stopListening();
    } catch (_) {}
  }

  Future<void> _fail(String message, int token) async {
    if (token != _token) return;
    await _disposeResources(endCallKit: true);
    state = state.copyWith(
      phase: ChatVoiceModePhase.error,
      errorMessage: message,
      clearActiveCallId: true,
      clearSpokenResponse: true,
      intensity: 0,
    );
  }

  void _setError(String message) {
    state = state.copyWith(
      phase: ChatVoiceModePhase.error,
      errorMessage: message,
      clearSpokenResponse: true,
      intensity: 0,
    );
  }

  Future<void> _stopInternal({required bool endCallKit}) async {
    if (!state.isActive && state.phase != ChatVoiceModePhase.error) {
      return;
    }

    ++_token;
    state = state.copyWith(phase: ChatVoiceModePhase.ending);
    await _disposeResources(endCallKit: endCallKit && !_stoppingFromCallKit);
    _stoppingFromCallKit = false;
    state = state.copyWith(
      phase: ChatVoiceModePhase.ended,
      transcript: '',
      assistantPreview: '',
      clearSpokenResponse: true,
      intensity: 0,
      elapsed: Duration.zero,
      clearStartedAt: true,
      clearActiveCallId: true,
      isMuted: false,
    );
  }

  Future<void> _disposeResources({required bool endCallKit}) async {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    await _cancelListening();
    await _ttsSub?.cancel();
    _ttsSub = null;
    await ref.read(textToSpeechServiceProvider).stopStreamingTts();
    await ref.read(textToSpeechServiceProvider).stop();
    await _stopBackgroundVoiceLease();
    await _audioSessionCoordinator?.deactivate();

    final callId = state.activeCallId;
    await _callKitSub?.cancel();
    _callKitSub = null;
    if (endCallKit && callId != null) {
      await ref.read(callKitServiceProvider).endCall(callId);
    }

    _resetRuntime();
  }

  void _resetRuntime() {
    _emptyTranscriptRestarts = 0;
    _currentTranscript = '';
    _lastFedAssistantText = '';
    _activeAssistantMessageId = null;
    _assistantMessageIdsBeforeTurn = <String>{};
    _awaitingAssistant = false;
    _assistantFinalized = false;
    _streamingTtsStarted = false;
    _iosAudioSessionManagedExternally = false;
    _markedCallConnected = false;
    _pausedDuringSpeech = false;
    _pausedDuringAssistantTurn = false;
    _assistantFinalizationDeferred = false;
    _pendingPausedAssistantText = null;
    _pendingPausedAssistantFinalText = null;
    _pendingFinalTranscripts.clear();
    _lastSubmittedTranscript = null;
    _sendingTranscript = false;
    _assistantSpeechChunks = const <String>[];
    _activeAssistantSpeechChunkIndex = -1;
  }

  void _syncAssistantSpeechChunks(String text) {
    _assistantSpeechChunks = ref
        .read(textToSpeechServiceProvider)
        .splitTextForSpeech(text);

    final index = _activeAssistantSpeechChunkIndex;
    if (index >= 0 && index < _assistantSpeechChunks.length) {
      final chunk = _assistantSpeechChunks[index];
      if (chunk != state.spokenResponse) {
        state = state.copyWith(
          spokenResponse: chunk,
          clearSpokenProgress: true,
        );
      }
    }
  }

  void _handleTtsChunkStarted(int chunkIndex) {
    if (!_awaitingAssistant || !_streamingTtsStarted) {
      return;
    }

    _activeAssistantSpeechChunkIndex = chunkIndex;
    if (chunkIndex < 0) {
      state = state.copyWith(clearSpokenResponse: true);
      return;
    }

    if (chunkIndex >= _assistantSpeechChunks.length) {
      _syncAssistantSpeechChunks(state.assistantPreview);
    }

    if (chunkIndex >= _assistantSpeechChunks.length) {
      state = state.copyWith(clearSpokenResponse: true);
      return;
    }

    state = state.copyWith(
      spokenResponse: _assistantSpeechChunks[chunkIndex],
      clearSpokenProgress: true,
    );
  }

  void _handleTtsWordProgress(int start, int end) {
    if (!_awaitingAssistant ||
        !_streamingTtsStarted ||
        state.spokenResponse.trim().isEmpty) {
      return;
    }

    state = state.copyWith(spokenWordStart: start, spokenWordEnd: end);
  }

  void _startElapsedTimer(int token) {
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (token != _token) {
        _elapsedTimer?.cancel();
        return;
      }
      final startedAt = state.startedAt;
      if (startedAt == null) return;
      state = state.copyWith(elapsed: DateTime.now().difference(startedAt));
    });
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _serial.then((_) => action());
    _serial = next.catchError((_) {});
    return next;
  }
}
