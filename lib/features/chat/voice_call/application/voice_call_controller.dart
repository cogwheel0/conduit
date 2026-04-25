import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../core/models/chat_message.dart';
import '../../../../core/providers/app_providers.dart';
import '../../../../core/services/settings_service.dart';
import '../../../../shared/widgets/markdown/markdown_preprocessor.dart';
import '../../../tools/providers/tools_providers.dart';
import '../../providers/chat_providers.dart';
import '../domain/call_state_machine.dart';
import '../domain/voice_call_interfaces.dart';
import '../domain/voice_call_models.dart';
import 'assistant_turn_tracker.dart';
import '../infrastructure/assistant_transport_socket.dart';
import '../infrastructure/background_policy_default.dart';
import '../infrastructure/call_audio_session_coordinator.dart';
import '../infrastructure/call_permission_orchestrator_permission_handler.dart';
import '../infrastructure/native_call_surface_callkit.dart';
import '../infrastructure/voice_input_engine_speech.dart';
import '../infrastructure/voice_output_engine_tts.dart';

part 'voice_call_controller.g.dart';

/// Deterministic call-session controller for voice calls.
@Riverpod(keepAlive: true)
class VoiceCallController extends _$VoiceCallController {
  static const int _maxEmptyTranscriptRestarts = 4;
  static const int _maxNonSpeakableFinalizationAttempts = 2;
  static const int _emptyTranscriptBaseDelayMs = 250;
  static const int _emptyTranscriptMaxDelayMs = 2000;
  static const Duration _responseInactivityTimeout = Duration(seconds: 4);
  static const Duration _responseWatchdogPatience = Duration(seconds: 24);

  Future<void> _serial = Future<void>.value();

  int _sessionToken = 0;
  String? _nativeCallId;
  String? _transportSessionId;
  String? _boundConversationId;

  StreamSubscription<NativeCallEvent>? _nativeCallSub;
  VoiceAssistantSubscription? _assistantSub;
  StreamSubscription<void>? _reconnectSub;
  StreamSubscription<String>? _transcriptSub;
  StreamSubscription<int>? _intensitySub;

  Timer? _keepAliveTimer;
  Timer? _elapsedTimer;
  Timer? _responseWatchdog;

  String _accumulatedTranscript = '';
  String _accumulatedResponse = '';
  String? _activeAssistantMessageId;
  String? _activeUserMessageId;
  String? _localAssistantMessageId;
  String? _boundRemoteAssistantMessageId;
  bool _assistantResponseFinalized = false;
  bool _isSpeaking = false;
  bool _speechStartInFlight = false;
  Completer<void>? _activeSpeechCompleter;
  Object? _activeSpeechError;
  bool _listeningSuspendedForSpeech = false;
  int _enqueuedSentenceCount = 0;
  int _emptyTranscriptRestartAttempts = 0;
  int _nonSpeakableFinalizationAttempts = 0;
  DateTime? _listeningStartedAt;
  DateTime? _assistantTurnStartedAt;
  DateTime? _lastAssistantActivityAt;

  final ListQueue<String> _speechQueue = ListQueue<String>();
  final Set<CallPauseReason> _pauseReasons = <CallPauseReason>{};
  final Set<String> _ignoredAssistantMessageIds = <String>{};

  late final VoiceInputEngine _input;
  late final VoiceOutputEngine _output;
  late final NativeCallSurface _callSurface;
  late final CallBackgroundPolicy _background;
  late final CallAudioSessionCoordinator _audioSession;
  late final CallPermissionOrchestrator _permissions;

  @override
  VoiceCallSnapshot build() {
    _input = ref.read(voiceInputEngineProvider);
    _output = ref.read(voiceOutputEngineProvider);
    _callSurface = ref.read(nativeCallSurfaceProvider);
    _background = ref.read(callBackgroundPolicyProvider);
    _audioSession = ref.read(callAudioSessionCoordinatorProvider);
    _permissions = ref.read(callPermissionOrchestratorProvider);

    ref.listen<AppSettings>(appSettingsProvider, (_, next) {
      unawaited(_output.updateSettings(next));
    });

    ref.listen(activeConversationProvider, (previous, next) {
      final nextId = next?.id;
      if (nextId == null || nextId == _boundConversationId) {
        return;
      }
      _boundConversationId = nextId;
      final sessionId = _transportSessionId;
      if (sessionId != null) {
        ref
            .read(voiceAssistantTransportProvider)
            ?.updateSessionIdForConversation(nextId, sessionId);
      }
      if (state.isActive) {
        unawaited(_rebindTransportSubscription(_sessionToken));
      }
    });

    ref.onDispose(() {
      unawaited(_disposeResources());
    });

    return const VoiceCallSnapshot();
  }

  Future<void> start({required bool startNewConversation}) {
    return _enqueue(() async {
      if (state.isActive && state.phase != CallPhase.failed) {
        return;
      }

      final token = ++_sessionToken;
      _resetRuntimeOnly();

      try {
        if (startNewConversation) {
          startNewChat(ref);
        }

        _setPhase(CallPhase.starting);
        await _background.initialize();
        await _background.requestNotificationPermissionIfNeeded();

        await _permissions.ensureCallPermissions(_input);

        final initialized = await _input.initialize();
        if (!initialized) {
          throw _failure(
            CallFailureCategory.speechInput,
            'Voice input initialization failed.',
            recoverable: true,
          );
        }

        final hasLocalStt = _input.hasLocalStt;
        final hasServerStt = _input.hasServerStt;
        final ready = switch (_input.preference) {
          SttPreference.deviceOnly => hasLocalStt || hasServerStt,
          SttPreference.serverOnly => hasServerStt,
        };
        if (!ready) {
          throw _failure(
            CallFailureCategory.speechInput,
            'Preferred speech recognition engine is unavailable.',
            recoverable: true,
          );
        }

        final settings = ref.read(appSettingsProvider);
        await _output.initializeWithSettings(settings);
        _output.bindHandlers(
          onStart: _handleOutputStart,
          onComplete: _handleOutputComplete,
          onError: _handleOutputError,
        );

        if (_callSurface.isAvailable) {
          await _callSurface.checkAndCleanActiveCalls();
          await _callSurface.requestPermissions();
          final modelName =
              ref.read(selectedModelProvider)?.name ?? 'Assistant';
          _nativeCallId = await _callSurface.startOutgoingCall(
            callerName: modelName,
            handle: 'Conduit AI',
          );
          _listenForNativeCallEvents(token);
        }

        _setPhase(CallPhase.connecting);

        final transport = ref.read(voiceAssistantTransportProvider);
        if (transport == null) {
          throw _failure(
            CallFailureCategory.transport,
            'Socket transport is unavailable.',
            recoverable: true,
          );
        }

        final connected = await transport.ensureConnected(
          timeout: const Duration(seconds: 10),
        );
        _transportSessionId = transport.sessionId;
        _boundConversationId = ref.read(activeConversationProvider)?.id;

        if (!connected || _transportSessionId == null) {
          throw _failure(
            CallFailureCategory.network,
            'Failed to establish socket connection.',
            recoverable: true,
          );
        }

        await _rebindTransportSubscription(token);

        _reconnectSub?.cancel();
        _reconnectSub = transport.onReconnect.listen((_) {
          if (token != _sessionToken || !state.isActive) {
            return;
          }
          final newSessionId = transport.sessionId;
          if (newSessionId != null) {
            _transportSessionId = newSessionId;
            final conversationId = _boundConversationId;
            if (conversationId != null && conversationId.isNotEmpty) {
              transport.updateSessionIdForConversation(
                conversationId,
                newSessionId,
              );
            }
            unawaited(_rebindTransportSubscription(token));
          }
        });

        final requiresMicrophone =
            Platform.isAndroid ||
            (_input.prefersServerOnly && _input.hasServerStt) ||
            (!_input.hasLocalStt && _input.hasServerStt);

        await _background.startBackgroundExecution(
          requiresMicrophone: requiresMicrophone,
        );
        await _background.setScreenAwake(true);

        _keepAliveTimer?.cancel();
        _keepAliveTimer = Timer.periodic(const Duration(minutes: 5), (_) {
          unawaited(_background.keepAlive());
        });

        state = state.copyWith(
          callStartedAt: DateTime.now(),
          elapsed: Duration.zero,
        );
        _elapsedTimer?.cancel();
        _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          final startedAt = state.callStartedAt;
          if (startedAt == null) {
            return;
          }
          state = state.copyWith(elapsed: DateTime.now().difference(startedAt));
        });

        await _startListening(token);

        final callId = _nativeCallId;
        if (callId != null) {
          await _callSurface.markConnected(callId);
        }
      } catch (error, stackTrace) {
        developer.log(
          'Voice call start failed: $error',
          name: 'voice_call_controller',
          error: error,
          stackTrace: stackTrace,
        );
        await _teardown(
          CallEndReason.fatalError,
          targetPhase: CallPhase.failed,
        );
        if (error is _ControllerFailure) {
          _setFailure(error.failure);
        } else {
          _setFailure(
            CallFailure(
              category: CallFailureCategory.unknown,
              message: error.toString(),
              recoverable: true,
              cause: error,
            ),
          );
        }
      }
    });
  }

  Future<void> pause({CallPauseReason reason = CallPauseReason.user}) {
    return _enqueue(() async {
      _pauseReasons.add(reason);
      await _input.stopListening();
      await _transcriptSub?.cancel();
      _transcriptSub = null;
      await _intensitySub?.cancel();
      _intensitySub = null;

      state = state.copyWith(
        pauseReasons: Set<CallPauseReason>.from(_pauseReasons),
        phase: state.isMuted ? CallPhase.muted : CallPhase.paused,
      );
      await _updateNotification();
    });
  }

  Future<void> resume({CallPauseReason reason = CallPauseReason.user}) {
    return _enqueue(() async {
      _pauseReasons.remove(reason);
      state = state.copyWith(
        pauseReasons: Set<CallPauseReason>.from(_pauseReasons),
      );

      if (_pauseReasons.isNotEmpty || state.phase == CallPhase.ending) {
        await _updateNotification();
        return;
      }

      if (state.isMuted) {
        state = state.copyWith(isMuted: false);
      }

      await _startListening(_sessionToken);
      await _updateNotification();
    });
  }

  Future<void> toggleMute() {
    return _enqueue(() async {
      final nextMuted = !state.isMuted;
      state = state.copyWith(isMuted: nextMuted);

      if (nextMuted) {
        _pauseReasons.add(CallPauseReason.mute);
        _speechQueue.clear();
        _enqueuedSentenceCount = 0;
        _assistantResponseFinalized = false;
        _isSpeaking = false;
        _signalActiveSpeechCompletion(error: StateError('Muted'));
        await _output.stop();
        await _input.stopListening();
        await _transcriptSub?.cancel();
        _transcriptSub = null;
        await _intensitySub?.cancel();
        _intensitySub = null;
        state = state.copyWith(
          pauseReasons: Set<CallPauseReason>.from(_pauseReasons),
          phase: CallPhase.muted,
        );
      } else {
        _pauseReasons.remove(CallPauseReason.mute);
        state = state.copyWith(
          pauseReasons: Set<CallPauseReason>.from(_pauseReasons),
        );
        if (_pauseReasons.isEmpty) {
          await _startListening(_sessionToken);
        }
      }

      await _updateNotification();
    });
  }

  Future<void> stop({CallEndReason reason = CallEndReason.user}) {
    return _enqueue(() async {
      if (!state.isActive && state.phase != CallPhase.failed) {
        state = state.copyWith(phase: CallPhase.ended, failure: null);
        return;
      }
      ++_sessionToken;
      await _teardown(reason, targetPhase: CallPhase.ended);
    });
  }

  Future<void> cancelAssistantSpeech() {
    return _enqueue(() async {
      _speechQueue.clear();
      _enqueuedSentenceCount = 0;
      _assistantResponseFinalized = false;
      _isSpeaking = false;
      _listeningSuspendedForSpeech = false;
      _signalActiveSpeechCompletion(error: StateError('Cancelled'));
      await _output.stop();
      await _startListening(_sessionToken);
    });
  }

  Future<void> _startListening(int token) async {
    if (token != _sessionToken) {
      return;
    }

    if (_pauseReasons.isNotEmpty) {
      state = state.copyWith(
        phase: state.isMuted ? CallPhase.muted : CallPhase.paused,
        pauseReasons: Set<CallPauseReason>.from(_pauseReasons),
      );
      return;
    }

    await _audioSession.configureForListening();

    _speechQueue.clear();
    _enqueuedSentenceCount = 0;
    _assistantResponseFinalized = false;
    _listeningSuspendedForSpeech = false;
    _accumulatedTranscript = '';

    final stream = await _input.beginListening();
    if (token != _sessionToken) {
      return;
    }

    _emptyTranscriptRestartAttempts = 0;
    _listeningStartedAt = DateTime.now();
    _setPhase(CallPhase.listening);

    await _transcriptSub?.cancel();
    _transcriptSub = stream.listen(
      (text) {
        if (token != _sessionToken) {
          return;
        }
        _accumulatedTranscript = text;
        state = state.copyWith(transcript: text, intensity: state.intensity);
      },
      onError: (error) {
        if (token != _sessionToken) {
          return;
        }
        _setFailure(
          CallFailure(
            category: CallFailureCategory.speechInput,
            message: error.toString(),
            recoverable: true,
            cause: error,
          ),
        );
        _setPhase(CallPhase.failed);
      },
      onDone: () {
        unawaited(_handleListeningDone(token));
      },
    );

    await _intensitySub?.cancel();
    _intensitySub = _input.intensityStream.listen((intensity) {
      if (token != _sessionToken) {
        return;
      }
      state = state.copyWith(intensity: intensity);
    });

    await _updateNotification();
  }

  Future<void> _handleListeningDone(int token) async {
    if (token != _sessionToken || state.phase != CallPhase.listening) {
      return;
    }

    final trimmed = _accumulatedTranscript.trim();
    if (trimmed.isEmpty) {
      final startedAt = _listeningStartedAt;
      final listenDuration = startedAt == null
          ? Duration.zero
          : DateTime.now().difference(startedAt);
      final shouldCountAttempt = listenDuration < const Duration(seconds: 3);
      await _restartListeningAfterEmptyTranscript(
        token,
        countAttempt: shouldCountAttempt,
      );
      return;
    }

    _emptyTranscriptRestartAttempts = 0;
    await _sendMessageToAssistant(trimmed, token);
  }

  Future<void> _restartListeningAfterEmptyTranscript(
    int token, {
    required bool countAttempt,
  }) async {
    int delayMs = _emptyTranscriptBaseDelayMs;
    if (countAttempt) {
      _emptyTranscriptRestartAttempts++;
      if (_emptyTranscriptRestartAttempts > _maxEmptyTranscriptRestarts) {
        _pauseReasons.add(CallPauseReason.system);
        state = state.copyWith(
          phase: CallPhase.paused,
          pauseReasons: Set<CallPauseReason>.from(_pauseReasons),
        );
        await _updateNotification();
        return;
      }

      final exponent = _emptyTranscriptRestartAttempts - 1;
      delayMs = (_emptyTranscriptBaseDelayMs << exponent).clamp(
        _emptyTranscriptBaseDelayMs,
        _emptyTranscriptMaxDelayMs,
      );
    } else {
      _emptyTranscriptRestartAttempts = 0;
    }

    await Future<void>.delayed(Duration(milliseconds: delayMs));

    if (token != _sessionToken ||
        _pauseReasons.isNotEmpty ||
        state.phase != CallPhase.listening) {
      return;
    }

    await _startListening(token);
  }

  Future<void> _sendMessageToAssistant(String text, int token) async {
    if (token != _sessionToken) {
      return;
    }

    _setPhase(CallPhase.thinking);
    state = state.copyWith(
      transcript: text,
      response: '',
      intensity: 0,
      failure: null,
    );

    _accumulatedResponse = '';
    _activeAssistantMessageId = null;
    _activeUserMessageId = null;
    _localAssistantMessageId = null;
    _boundRemoteAssistantMessageId = null;
    _assistantResponseFinalized = false;
    _enqueuedSentenceCount = 0;
    _speechQueue.clear();
    _nonSpeakableFinalizationAttempts = 0;
    _assistantTurnStartedAt = DateTime.now();
    _lastAssistantActivityAt = null;

    final selectedToolIds = ref.read(selectedToolIdsProvider);
    final sendFuture = sendMessageFromService(
      ref,
      text,
      null,
      selectedToolIds,
      true,
    );
    _seedActiveTurnMessageIds();
    unawaited(sendFuture);

    _armResponseWatchdog(token);

    await _updateNotification();
  }

  Future<void> _pollLatestAssistantReply(int token) async {
    if (token != _sessionToken || !state.isActive) {
      return;
    }

    Iterable<ChatMessage>? remoteMessages;
    final conversationId = ref.read(activeConversationProvider)?.id;
    final api = ref.read(apiServiceProvider);
    if (conversationId != null && conversationId.isNotEmpty && api != null) {
      try {
        final conversation = await api.getConversation(conversationId);
        if (token != _sessionToken) {
          return;
        }
        remoteMessages = conversation.messages;
      } catch (error) {
        developer.log(
          'Response watchdog poll failed: $error',
          name: 'voice_call_controller',
        );
      }
    }

    final recovery = resolveAssistantRecoveryCandidate(
      localMessages: ref.read(chatMessagesProvider),
      remoteMessages: remoteMessages,
      activeAssistantMessageId: _activeAssistantMessageId,
      activeUserMessageId: _activeUserMessageId,
      assistantTurnStartedAt: _assistantTurnStartedAt,
    );
    if (_applyPolledAssistantReply(
      recovery.message,
      token,
      authoritative: recovery.authoritative,
    )) {
      return;
    }

    _handlePendingAssistantWatchdog(token);
  }

  void _handleTransportEvent(
    Map<String, dynamic> event,
    void Function(dynamic)? ack,
  ) {
    if (!state.isActive) {
      return;
    }

    final outerData = event['data'];
    if (outerData is! Map<String, dynamic>) {
      return;
    }
    final eventType = outerData['type']?.toString();
    final innerData = outerData['data'];
    if (eventType != 'chat:completion' || innerData is! Map<String, dynamic>) {
      return;
    }
    final messageId = event['message_id']?.toString();
    if (!_shouldProcessAssistantMessage(messageId)) {
      return;
    }

    _markAssistantTurnActivity();
    _armResponseWatchdog(_sessionToken);

    final doneFlag = innerData['done'] == true;

    if (innerData.containsKey('content')) {
      final content = innerData['content']?.toString() ?? '';
      if (content.isNotEmpty) {
        _accumulatedResponse = content;
        state = state.copyWith(response: content);
        _processSpeakableSegments(isFinalChunk: doneFlag);
      }
      if (doneFlag) {
        _maybeFinalizeAssistantResponse(_sessionToken);
      }
    }

    if (innerData.containsKey('choices')) {
      final choices = innerData['choices'] as List?;
      if (choices != null && choices.isNotEmpty) {
        final firstChoice = choices.first as Map<String, dynamic>?;
        final delta = firstChoice?['delta'];
        final finishReason = firstChoice?['finish_reason'];

        if (delta is Map<String, dynamic>) {
          final deltaContent = delta['content']?.toString() ?? '';
          if (deltaContent.isNotEmpty) {
            _accumulatedResponse += deltaContent;
            state = state.copyWith(response: _accumulatedResponse);
            _processSpeakableSegments(isFinalChunk: false);
          }
        }

        if (finishReason == 'stop' || finishReason == 'length') {
          _maybeFinalizeAssistantResponse(_sessionToken);
        }
      }
    }

    if (doneFlag && !_assistantResponseFinalized) {
      _maybeFinalizeAssistantResponse(_sessionToken);
    }
  }

  void _armResponseWatchdog(int token) {
    if (token != _sessionToken ||
        !state.isActive ||
        _assistantResponseFinalized) {
      return;
    }

    _responseWatchdog?.cancel();
    _responseWatchdog = Timer(_responseInactivityTimeout, () {
      if (token != _sessionToken ||
          !state.isActive ||
          _assistantResponseFinalized) {
        return;
      }

      // Flush whatever we have if stream completion markers were missed.
      if (_hasSpeakableAssistantResponse) {
        _assistantResponseFinalized = true;
        _retireActiveAssistantMessage();
        _processSpeakableSegments(isFinalChunk: true);
        _maybeResumeListeningAfterSpeech(token);
        return;
      }

      // Also attempt one server sync for authoritative final content.
      unawaited(_pollLatestAssistantReply(token));
    });
  }

  void _processSpeakableSegments({required bool isFinalChunk}) {
    final speakableText = ConduitMarkdownPreprocessor.removeAllDetails(
      _accumulatedResponse,
    ).trim();
    if (speakableText.isEmpty) {
      return;
    }

    final segments = _output.splitTextForSpeech(speakableText);
    if (segments.isEmpty) {
      return;
    }

    var availableCount = segments.length;
    if (!isFinalChunk && availableCount > 0) {
      availableCount -= 1;
    }

    if (_enqueuedSentenceCount > availableCount) {
      _enqueuedSentenceCount = availableCount;
    }

    if (availableCount > _enqueuedSentenceCount) {
      final newChunks = segments.sublist(
        _enqueuedSentenceCount,
        availableCount,
      );
      _enqueuedSentenceCount = availableCount;
      for (final chunk in newChunks) {
        _enqueueSpeechChunk(chunk);
      }
    }

    if (isFinalChunk && _enqueuedSentenceCount < segments.length) {
      _enqueuedSentenceCount = segments.length;
      _enqueueSpeechChunk(segments.last);
    }
  }

  bool _shouldProcessAssistantMessage(String? messageId) {
    final decision = resolveAssistantTransportDecision(
      incomingMessageId: messageId,
      activeAssistantMessageId: _activeAssistantMessageId,
      localAssistantMessageId: _localAssistantMessageId,
      boundRemoteAssistantMessageId: _boundRemoteAssistantMessageId,
      assistantResponseFinalized: _assistantResponseFinalized,
      ignoredAssistantMessageIds: _ignoredAssistantMessageIds,
    );

    if (!decision.shouldProcess) {
      final activeId = _activeAssistantMessageId;
      final normalizedId = messageId?.trim();
      if (activeId != null &&
          activeId.isNotEmpty &&
          normalizedId != null &&
          normalizedId.isNotEmpty &&
          activeId != normalizedId) {
        developer.log(
          'Ignoring assistant message_id switch $activeId -> $normalizedId '
          'within active turn',
          name: 'voice_call_controller',
          level: 800,
        );
      }
      return false;
    }

    if (decision.boundRemoteAssistantMessage) {
      developer.log(
        'Binding remote assistant message ${decision.boundRemoteAssistantMessageId} '
        'to local placeholder ${_localAssistantMessageId ?? "<none>"}',
        name: 'voice_call_controller',
      );
    }

    _activeAssistantMessageId = decision.activeAssistantMessageId;
    _boundRemoteAssistantMessageId = decision.boundRemoteAssistantMessageId;
    return true;
  }

  void _seedActiveTurnMessageIds() {
    final messages = ref.read(chatMessagesProvider);
    for (var i = messages.length - 1; i >= 0; i--) {
      final message = messages[i];
      if (message.role == 'assistant') {
        _activeAssistantMessageId = message.id;
        _localAssistantMessageId = message.id;
        _activeUserMessageId = _resolveActiveUserMessageId(
          messages: messages,
          assistantIndex: i,
        );
        return;
      }
    }
  }

  bool get _hasSpeakableAssistantResponse =>
      ConduitMarkdownPreprocessor.cleanText(
        ConduitMarkdownPreprocessor.removeAllDetails(_accumulatedResponse),
      ).trim().isNotEmpty;

  void _retireActiveAssistantMessage() {
    _ignoreAssistantMessageId(_activeAssistantMessageId);
    _ignoreAssistantMessageId(_localAssistantMessageId);
    _ignoreAssistantMessageId(_boundRemoteAssistantMessageId);
  }

  void _maybeFinalizeAssistantResponse(int token) {
    if (_hasSpeakableAssistantResponse) {
      _nonSpeakableFinalizationAttempts = 0;
      _responseWatchdog?.cancel();
      _responseWatchdog = null;
      _assistantResponseFinalized = true;
      _retireActiveAssistantMessage();
      _processSpeakableSegments(isFinalChunk: true);
      _maybeResumeListeningAfterSpeech(token);
      return;
    }

    if (_accumulatedResponse.trim().isEmpty &&
        !_hasExceededAssistantWaitBudget) {
      _assistantResponseFinalized = false;
      if (state.phase != CallPhase.thinking) {
        _setPhase(CallPhase.thinking);
      }
      _armResponseWatchdog(token);
      return;
    }

    _nonSpeakableFinalizationAttempts++;
    _assistantResponseFinalized = false;
    if (_nonSpeakableFinalizationAttempts >
        _maxNonSpeakableFinalizationAttempts) {
      _abandonAssistantTurn(token);
      return;
    }

    if (state.phase != CallPhase.thinking) {
      _setPhase(CallPhase.thinking);
    }
    _armResponseWatchdog(token);
  }

  bool get _hasExceededAssistantWaitBudget {
    return hasExceededAssistantWaitBudget(
      assistantTurnStartedAt: _assistantTurnStartedAt,
      lastAssistantActivityAt: _lastAssistantActivityAt,
      now: DateTime.now(),
      patience: _responseWatchdogPatience,
    );
  }

  bool _applyPolledAssistantReply(
    ChatMessage? assistant,
    int token, {
    required bool authoritative,
  }) {
    if (assistant == null) {
      return false;
    }

    final content = assistant.content;
    if (content.trim().isEmpty) {
      return false;
    }

    final candidateAssistantId = assistant.id.trim();
    final activeAssistantId = _activeAssistantMessageId?.trim();
    final localAssistantId = _localAssistantMessageId?.trim();
    final boundRemoteAssistantId = _boundRemoteAssistantMessageId?.trim();
    final matchesTrackedAssistant =
        candidateAssistantId == activeAssistantId ||
        candidateAssistantId == localAssistantId ||
        candidateAssistantId == boundRemoteAssistantId;

    if (authoritative &&
        localAssistantId != null &&
        localAssistantId.isNotEmpty &&
        candidateAssistantId != localAssistantId &&
        (boundRemoteAssistantId == null || boundRemoteAssistantId.isEmpty)) {
      _boundRemoteAssistantMessageId = assistant.id;
    }
    if (authoritative || matchesTrackedAssistant) {
      _activeAssistantMessageId = assistant.id;
    }
    if (candidateAssistantId != activeAssistantId ||
        content != _accumulatedResponse) {
      _markAssistantTurnActivity();
    }

    _accumulatedResponse = content;
    state = state.copyWith(response: content);
    _maybeFinalizeAssistantResponse(token);
    return true;
  }

  void _handlePendingAssistantWatchdog(int token) {
    if (token != _sessionToken ||
        !state.isActive ||
        _assistantResponseFinalized) {
      return;
    }
    if (_hasExceededAssistantWaitBudget) {
      _abandonAssistantTurn(token);
      return;
    }
    _armResponseWatchdog(token);
  }

  void _abandonAssistantTurn(int token) {
    _responseWatchdog?.cancel();
    _responseWatchdog = null;
    _assistantResponseFinalized = true;
    _retireActiveAssistantMessage();
    _nonSpeakableFinalizationAttempts = 0;
    _maybeResumeListeningAfterSpeech(token);
  }

  void _markAssistantTurnActivity() {
    final now = DateTime.now();
    _assistantTurnStartedAt ??= now;
    _lastAssistantActivityAt = now;
  }

  String? _resolveActiveUserMessageId({
    required List<ChatMessage> messages,
    required int assistantIndex,
  }) {
    final metadataParentId = messages[assistantIndex].metadata?['parentId']
        ?.toString()
        .trim();
    if (metadataParentId != null && metadataParentId.isNotEmpty) {
      return metadataParentId;
    }
    for (var i = assistantIndex - 1; i >= 0; i--) {
      final message = messages[i];
      if (message.role == 'user') {
        return message.id;
      }
    }
    return null;
  }

  void _ignoreAssistantMessageId(String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) {
      return;
    }
    _ignoredAssistantMessageIds.add(normalized);
  }

  void _enqueueSpeechChunk(String chunk) {
    final trimmed = chunk.trim();
    if (trimmed.isEmpty || state.isMuted) {
      return;
    }
    _speechQueue.add(trimmed);
    if (!_isSpeaking) {
      unawaited(_startNextSpeechChunk(_sessionToken));
    }
  }

  Future<void> _startNextSpeechChunk(int token) async {
    if (token != _sessionToken ||
        _isSpeaking ||
        _speechStartInFlight ||
        _speechQueue.isEmpty ||
        state.isMuted) {
      return;
    }

    _speechStartInFlight = true;
    final next = _speechQueue.removeFirst();
    _isSpeaking = true;
    var shouldScheduleNext = false;

    try {
      await _prepareForSpeechPlayback();
      _setPhase(CallPhase.speaking);

      final completer = Completer<void>();
      _activeSpeechCompleter = completer;
      _activeSpeechError = null;

      await _output.speak(next);
      await _updateNotification();

      await completer.future.timeout(const Duration(seconds: 90));
      if (_activeSpeechError != null) {
        throw _activeSpeechError!;
      }

      _isSpeaking = false;
      if (_speechQueue.isNotEmpty) {
        shouldScheduleNext = true;
      } else {
        _listeningSuspendedForSpeech = false;
        _maybeResumeListeningAfterSpeech(_sessionToken);
      }
    } catch (error) {
      _isSpeaking = false;
      _speechQueue.clear();
      _listeningSuspendedForSpeech = false;
      _setFailure(
        CallFailure(
          category: CallFailureCategory.speechOutput,
          message: error.toString(),
          recoverable: true,
          cause: error,
        ),
      );
      _setPhase(CallPhase.failed);
    } finally {
      _activeSpeechCompleter = null;
      _activeSpeechError = null;
      _speechStartInFlight = false;
    }

    if (shouldScheduleNext) {
      unawaited(_startNextSpeechChunk(_sessionToken));
    }
  }

  Future<void> _prepareForSpeechPlayback() async {
    if (_listeningSuspendedForSpeech) {
      return;
    }
    _listeningSuspendedForSpeech = true;
    await _audioSession.configureForSpeaking();
    await _input.stopListening();
    await _transcriptSub?.cancel();
    _transcriptSub = null;
    await _intensitySub?.cancel();
    _intensitySub = null;
  }

  void _handleOutputStart() {
    if (!state.isActive) {
      return;
    }
    _setPhase(CallPhase.speaking);
  }

  void _handleOutputComplete() {
    if (!state.isActive) {
      return;
    }
    _signalActiveSpeechCompletion();
  }

  void _handleOutputError(String error) {
    if (!state.isActive) {
      return;
    }
    _activeSpeechError = error;
    _signalActiveSpeechCompletion();
    if (_activeSpeechCompleter == null) {
      _isSpeaking = false;
      _speechQueue.clear();
      _listeningSuspendedForSpeech = false;
      _setFailure(
        CallFailure(
          category: CallFailureCategory.speechOutput,
          message: error,
          recoverable: true,
        ),
      );
      _setPhase(CallPhase.failed);
    }
  }

  void _signalActiveSpeechCompletion({Object? error}) {
    if (error != null) {
      _activeSpeechError ??= error;
    }
    final completer = _activeSpeechCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void _maybeResumeListeningAfterSpeech(int token) {
    if (token != _sessionToken || !_assistantResponseFinalized) {
      return;
    }

    if (_isSpeaking || _speechQueue.isNotEmpty) {
      return;
    }

    if (_pauseReasons.isNotEmpty) {
      state = state.copyWith(
        phase: state.isMuted ? CallPhase.muted : CallPhase.paused,
        pauseReasons: Set<CallPauseReason>.from(_pauseReasons),
      );
      unawaited(_updateNotification());
      return;
    }

    _listeningSuspendedForSpeech = false;
    unawaited(_startListening(token));
  }

  void _listenForNativeCallEvents(int token) {
    _nativeCallSub?.cancel();
    _nativeCallSub = _callSurface.events.listen((event) {
      if (token != _sessionToken) {
        return;
      }
      if (_nativeCallId != null &&
          event.callId != null &&
          event.callId != _nativeCallId) {
        return;
      }

      switch (event.type) {
        case NativeCallEventType.ended:
        case NativeCallEventType.declined:
        case NativeCallEventType.timeout:
          unawaited(stop(reason: CallEndReason.nativeSurface));
          break;
        case NativeCallEventType.muteToggled:
          final nextMuted = event.isMuted;
          if (nextMuted != null && state.isMuted != nextMuted) {
            unawaited(toggleMute());
          }
          break;
        case NativeCallEventType.holdToggled:
          final onHold = event.isOnHold;
          if (onHold == true) {
            unawaited(pause(reason: CallPauseReason.system));
          } else if (onHold == false) {
            unawaited(resume(reason: CallPauseReason.system));
          }
          break;
        case NativeCallEventType.connected:
          break;
      }
    });
  }

  Future<void> _rebindTransportSubscription(int token) async {
    final transport = ref.read(voiceAssistantTransportProvider);
    if (transport == null) {
      return;
    }

    await _assistantSub?.dispose();
    if (token != _sessionToken) {
      return;
    }

    _assistantSub = transport.registerAssistantEvents(
      conversationId: _boundConversationId,
      sessionId: _transportSessionId,
      requireFocus: false,
      handler: _handleTransportEvent,
    );
  }

  Future<void> _teardown(
    CallEndReason reason, {
    required CallPhase targetPhase,
  }) async {
    _setPhase(CallPhase.ending);

    _responseWatchdog?.cancel();
    _responseWatchdog = null;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;

    await _transcriptSub?.cancel();
    _transcriptSub = null;
    await _intensitySub?.cancel();
    _intensitySub = null;
    await _nativeCallSub?.cancel();
    _nativeCallSub = null;
    await _reconnectSub?.cancel();
    _reconnectSub = null;
    await _assistantSub?.dispose();
    _assistantSub = null;

    await _input.stopListening();
    _signalActiveSpeechCompletion(error: StateError('Teardown'));
    await _output.stop();

    await _background.stopBackgroundExecution();
    await _background.cancelCallNotification();
    await _background.setScreenAwake(false);
    await _audioSession.deactivate();

    final callId = _nativeCallId;
    _nativeCallId = null;
    if (callId != null) {
      await _callSurface.endCall(callId);
    } else {
      await _callSurface.endAllCalls();
    }

    _resetRuntimeOnly();
    state = VoiceCallSnapshot(
      phase: targetPhase,
      failure: targetPhase == CallPhase.failed ? state.failure : null,
    );
  }

  Future<void> _updateNotification() async {
    final modelName = ref.read(selectedModelProvider)?.name ?? 'Assistant';
    final show = _nativeCallId == null && state.isActive;
    await _background.updateOngoingCallNotification(
      modelName: modelName,
      isMuted: state.isMuted,
      isSpeaking: state.phase == CallPhase.speaking,
      isPaused:
          state.phase == CallPhase.paused || state.phase == CallPhase.muted,
      show: show,
    );
  }

  void _setPhase(CallPhase phase) {
    final current = state.phase;
    if (current == phase) {
      return;
    }
    if (!CallStateMachine.canTransition(current, phase)) {
      developer.log(
        'Ignoring invalid transition $current -> $phase',
        name: 'voice_call_controller',
        level: 900,
      );
      return;
    }
    state = state.copyWith(phase: phase);
    unawaited(_updateNotification());
  }

  void _setFailure(CallFailure failure) {
    state = state.copyWith(failure: failure);
  }

  _ControllerFailure _failure(
    CallFailureCategory category,
    String message, {
    required bool recoverable,
  }) {
    return _ControllerFailure(
      CallFailure(
        category: category,
        message: message,
        recoverable: recoverable,
      ),
    );
  }

  void _resetRuntimeOnly() {
    _accumulatedTranscript = '';
    _accumulatedResponse = '';
    _activeAssistantMessageId = null;
    _activeUserMessageId = null;
    _localAssistantMessageId = null;
    _boundRemoteAssistantMessageId = null;
    _assistantResponseFinalized = false;
    _isSpeaking = false;
    _speechStartInFlight = false;
    _activeSpeechCompleter = null;
    _activeSpeechError = null;
    _listeningSuspendedForSpeech = false;
    _enqueuedSentenceCount = 0;
    _emptyTranscriptRestartAttempts = 0;
    _nonSpeakableFinalizationAttempts = 0;
    _listeningStartedAt = null;
    _assistantTurnStartedAt = null;
    _lastAssistantActivityAt = null;
    _speechQueue.clear();
    _pauseReasons.clear();
    _ignoredAssistantMessageIds.clear();
    _transportSessionId = null;
    _boundConversationId = null;
  }

  Future<void> _disposeResources() async {
    _sessionToken++;

    _responseWatchdog?.cancel();
    _responseWatchdog = null;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;

    await _transcriptSub?.cancel();
    _transcriptSub = null;
    await _intensitySub?.cancel();
    _intensitySub = null;
    await _nativeCallSub?.cancel();
    _nativeCallSub = null;
    await _reconnectSub?.cancel();
    _reconnectSub = null;
    await _assistantSub?.dispose();
    _assistantSub = null;

    await _input.stopListening();
    _signalActiveSpeechCompletion(error: StateError('Disposed'));
    await _output.stop();
    await _background.stopBackgroundExecution();
    await _background.cancelCallNotification();
    await _background.setScreenAwake(false);
    await _audioSession.deactivate();

    final callId = _nativeCallId;
    _nativeCallId = null;
    if (callId != null) {
      await _callSurface.endCall(callId);
    } else {
      await _callSurface.endAllCalls();
    }

    await _input.dispose();
    await _output.dispose();
  }

  Future<void> _enqueue(Future<void> Function() action) {
    _serial = _serial.then((_) => action());
    return _serial;
  }
}

class _ControllerFailure implements Exception {
  const _ControllerFailure(this.failure);

  final CallFailure failure;
}
