/// The voice-call ("voice mode") controller: the turn-taking state machine
/// behind the voice-call surface.
///
/// Moved from the app's `lib/features/chat/voice_mode/` so the call logic is
/// tested without Flutter. Everything it touches that belongs to a host (the recognizer, the speech engine, the system call UI,
/// the audio session, the background lease, platform permissions) is a port
/// in `voice_mode_ports.dart`, bound by the app's composition root.
library;

import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/voice/voice_session.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/model.dart';

import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show
        activeConversationProvider,
        isActiveConversationInPlaceRemap,
        selectedModelProvider,
        socketServiceProvider;

import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/socket_service.dart'
    show SocketBackgroundActivityLease, SocketService;

import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/realtime_call/bridge_call_engine.dart';
import 'package:conduit_core/features/chat/realtime_call/bridge_call_host.dart';
import 'package:conduit_core/features/chat/realtime_call/gpt_live_call_engine.dart';
import 'package:conduit_core/features/chat/realtime_call/chat_bridge_call_host.dart';
import 'package:conduit_core/features/chat/realtime_call/realtime_bridge_transport.dart';
import 'package:conduit_core/features/chat/realtime_call/realtime_call_availability.dart';
import 'package:conduit_core/features/chat/realtime_call/realtime_call_state.dart';
import 'package:conduit_core/features/chat/voice_call/voice_call_eligibility.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_mode_ports.dart';

import 'package:conduit_core/features/tools/providers/tools_providers.dart';

export 'package:conduit_core/voice/voice_session.dart';
export 'package:conduit_core/features/chat/voice_mode/voice_mode_ports.dart';

final class _ChatVoiceModeStartCancelled implements Exception {
  const _ChatVoiceModeStartCancelled();
}

/// A start failure with a known [kind], so the panel can say why in the
/// user's language. [toString] stays the log text.
final class _ChatVoiceModeFailure implements Exception {
  const _ChatVoiceModeFailure(this.kind, this.message);

  final ChatVoiceModeError kind;
  final String message;

  @override
  String toString() => message;
}

ChatVoiceModeError _errorKindOf(Object error) =>
    error is _ChatVoiceModeFailure ? error.kind : ChatVoiceModeError.other;

/// Where a realtime call in [callChatId] stands once [nextChatId] is open.
/// It follows only its own chat: the one its first send created
/// ([createdByCall]), and that chat's server id given in place ([remapped]).
/// Any other chat, or none, ends it.
@visibleForTesting
({bool ends, String? chatId}) realtimeCallChatAfter(
  String? callChatId,
  String? nextChatId, {
  bool createdByCall = false,
  bool remapped = false,
}) {
  if (nextChatId == callChatId) return (ends: false, chatId: callChatId);
  if (nextChatId != null &&
      ((callChatId == null && createdByCall) || remapped)) {
    return (ends: false, chatId: nextChatId);
  }
  return (ends: true, chatId: callChatId);
}

final chatVoiceModeControllerProvider =
    NotifierProvider<ChatVoiceModeController, ChatVoiceModeSnapshot>(
      ChatVoiceModeController.new,
    );

@visibleForTesting
final chatVoiceModeServiceLifecycleTimeoutProvider = Provider<Duration>((ref) {
  return const Duration(seconds: 30);
});

final _chatVoiceModeServiceLifecycleGateProvider =
    Provider<_ChatVoiceModeServiceLifecycleGate>((ref) {
      return _ChatVoiceModeServiceLifecycleGate(
        timeout: ref.watch(chatVoiceModeServiceLifecycleTimeoutProvider),
      );
    });

class _ChatVoiceModeServiceLifecycleGate {
  _ChatVoiceModeServiceLifecycleGate({required Duration timeout})
    : _timeout = timeout;

  final Duration _timeout;
  Future<void> _tail = Future<void>.value();

  Future<T> runExclusive<T>(Future<T> Function() operation) =>
      _runExclusive(operation, keepQueuedAfterTimeout: false);

  Future<void> runCleanupExclusive(Future<void> Function() operation) =>
      _runExclusive(operation, keepQueuedAfterTimeout: true);

  Future<T> _runExclusive<T>(
    Future<T> Function() operation, {
    required bool keepQueuedAfterTimeout,
  }) {
    var started = false;
    var cancelledBeforeStart = false;
    final rawResult = _tail.then<T>((_) {
      if (cancelledBeforeStart) {
        throw TimeoutException(
          'Voice service lifecycle operation expired while queued',
          _timeout,
        );
      }
      started = true;
      return operation();
    });

    // Preserve the raw operation as the serialization tail. A Future timeout
    // does not cancel its source, so advancing the tail to the bounded wrapper
    // would let stale teardown overlap a replacement using the same services.
    _tail = rawResult.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return rawResult.timeout(
      _timeout,
      onTimeout: () {
        // An expired user operation must not start later merely because the
        // operation ahead of it settles. Mandatory cleanup is different: its
        // caller may stop waiting, but the raw cleanup must remain in the tail
        // so captured platform resources are eventually released in order.
        if (!started && !keepQueuedAfterTimeout) {
          cancelledBeforeStart = true;
        }
        throw TimeoutException(
          started
              ? 'Voice service lifecycle operation timed out'
              : 'Timed out waiting for voice service lifecycle ownership',
          _timeout,
        );
      },
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
  int _stopRequestGeneration = 0;
  int _emptyTranscriptRestarts = 0;
  bool _disposed = false;
  Completer<void>? _pendingStartReadinessCancellation;

  StreamSubscription<VoiceTranscriptEvent>? _transcriptSub;
  StreamSubscription<int>? _intensitySub;
  StreamSubscription<Object>? _responseCaptureFailureSub;
  StreamSubscription<Object>? _audioResponseCaptureFailureSub;
  StreamSubscription<TtsEvent>? _ttsSub;
  StreamSubscription<VoiceCallKitEvent>? _callKitSub;
  StreamSubscription<bool>? _speakerphoneRouteSub;
  ProviderSubscription<SocketService?>? _socketServiceSub;
  ProviderSubscription<Model?>? _selectedModelSub;
  Timer? _elapsedTimer;
  Timer? _backgroundKeepAliveTimer;

  String _currentTranscript = '';
  String _lastFedAssistantText = '';
  String? _backgroundLeaseId;
  String? _activeCallId;
  String? _activeAssistantMessageId;
  SocketBackgroundActivityLease? _socketBackgroundLease;
  VoiceBackgroundPort? _backgroundCoordinator;
  VoiceAudioSessionPort? _audioSessionCoordinator;
  VoiceModePlatformPort _platform = const HostVoiceModePlatform();
  late _ChatVoiceModeServiceLifecycleGate _serviceLifecycleGate;
  VoiceModeInput? _voiceInput;
  VoiceModeSpeech? _textToSpeech;
  VoiceCallKitPort? _callKit;
  Set<String> _assistantMessageIdsBeforeTurn = <String>{};
  bool _awaitingAssistant = false;
  bool _assistantFinalized = false;
  bool _streamingTtsStarted = false;
  bool _iosAudioSessionManagedExternally = false;
  bool _markedCallConnected = false;

  /// The realtime voice of a call that has one; the turn-by-turn input and
  /// speech are then unused.
  RealtimeCallEngine? _realtime;
  ChatBridgeCallHost? _realtimeHost;
  StreamSubscription<RealtimeCallState>? _realtimeSub;
  ProviderSubscription<Conversation?>? _realtimeChatSub;
  bool _pausedDuringSpeech = false;
  bool _pausedDuringAssistantTurn = false;
  bool _mutedDuringSpeech = false;
  bool _assistantFinalizationDeferred = false;
  String? _pendingPausedAssistantText;
  String? _pendingPausedAssistantFinalText;
  final Queue<String> _pendingFinalTranscripts = Queue<String>();
  String? _lastSubmittedTranscript;
  bool _stoppingFromCallKit = false;
  bool _sendingTranscript = false;
  bool _usesOpenWebUiTransport = false;
  List<String> _assistantSpeechChunks = const <String>[];
  int _activeAssistantSpeechChunkIndex = -1;

  @override
  ChatVoiceModeSnapshot build() {
    _disposed = false;
    _backgroundCoordinator = ref.read(
      chatVoiceModeBackgroundCoordinatorProvider,
    );
    _audioSessionCoordinator = ref.read(voiceAudioSessionProvider);
    _platform = ref.read(voiceModePlatformProvider);
    _serviceLifecycleGate = ref.read(
      _chatVoiceModeServiceLifecycleGateProvider,
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
      // Invalidate every detached transcript/TTS continuation before tearing
      // down its subscriptions. Async work must use only dependencies captured
      // while the provider was alive; reading Ref from this point is invalid.
      _disposed = true;
      ++_stopRequestGeneration;
      _cancelPendingStartReadiness();
      ++_token;
      _elapsedTimer?.cancel();
      _backgroundKeepAliveTimer?.cancel();
      final transcriptSub = _transcriptSub;
      final intensitySub = _intensitySub;
      final responseCaptureFailureSub = _responseCaptureFailureSub;
      final audioResponseCaptureFailureSub = _audioResponseCaptureFailureSub;
      final ttsSub = _ttsSub;
      final callKitSub = _callKitSub;
      final speakerphoneRouteSub = _speakerphoneRouteSub;
      final socketServiceSub = _socketServiceSub;
      final selectedModelSub = _selectedModelSub;
      _speakerphoneRouteSub = null;
      _socketServiceSub = null;
      _selectedModelSub = null;
      final input = _voiceInput;
      final tts = _textToSpeech;
      final backgroundCoordinator = _backgroundCoordinator;
      final audioSessionCoordinator = _audioSessionCoordinator;
      final callKit = _callKit;
      final callId = _activeCallId;
      final socketBackgroundLease = _socketBackgroundLease;
      final realtime = _realtime;
      final realtimeSub = _realtimeSub;
      final realtimeChatSub = _realtimeChatSub;
      _realtime = null;
      _realtimeHost = null;
      _realtimeSub = null;
      _realtimeChatSub = null;
      realtimeChatSub?.close();
      // The voice's microphone and connection end with the provider; the
      // host skips the chat writes a disposed provider can no longer make.
      unawaited(realtimeSub?.cancel());
      unawaited(realtime?.end());
      _activeCallId = null;
      _usesOpenWebUiTransport = false;
      selectedModelSub?.close();
      socketServiceSub?.close();
      _socketBackgroundLease = null;
      socketBackgroundLease?.dispose();
      unawaited(
        _serviceLifecycleGate
            .runCleanupExclusive(() async {
              await _cancelSubscriptionAfterDispose(transcriptSub);
              await _cancelSubscriptionAfterDispose(intensitySub);
              await _cancelSubscriptionAfterDispose(responseCaptureFailureSub);
              await _cancelSubscriptionAfterDispose(
                audioResponseCaptureFailureSub,
              );
              await _stopVoiceInputAfterDispose(input);
              await _endResponseWaitCaptureAfterDispose(
                audioSessionCoordinator,
              );
              await _cancelSubscriptionAfterDispose(ttsSub);
              await _stopTtsAfterDispose(tts);
              // The engine is shared with read-aloud, which belongs on the
              // media stream. Nothing survives provider disposal to hand it
              // back, so it happens here.
              tts?.setVoiceCallActive(false);
              await _stopBackgroundVoiceLeaseAfterDispose(
                backgroundCoordinator,
              );
              await _deactivateAudioSessionAfterDispose(
                audioSessionCoordinator,
              );
              await _cancelSubscriptionAfterDispose(callKitSub);
              await _cancelSubscriptionAfterDispose(speakerphoneRouteSub);
              if (callId != null) {
                await _endCallAfterDispose(callKit, callId);
              }
            })
            .catchError((Object error, StackTrace stackTrace) {
              DebugLogger.error(
                'dispose-lifecycle-timeout',
                scope: 'chat/voice_mode',
                error: error,
                stackTrace: stackTrace,
              );
            }),
      );
    });

    return const ChatVoiceModeSnapshot();
  }

  Future<ChatVoiceModeStartResult> start({
    required bool startNewConversation,
    bool Function()? shouldStart,
    Model? admittedModel,
  }) async {
    final stopGenerationAtRequest = _stopRequestGeneration;
    bool cancellationRequested() =>
        _disposed || stopGenerationAtRequest != _stopRequestGeneration;

    var result = ChatVoiceModeStartResult.failed;
    await _enqueue(() async {
      if (cancellationRequested()) {
        result = ChatVoiceModeStartResult.cancelled;
        return;
      }

      int? token;
      final readinessCancellation = admittedModel == null
          ? Completer<void>()
          : null;

      try {
        await _serviceLifecycleGate.runExclusive(() async {
          if (cancellationRequested()) {
            result = ChatVoiceModeStartResult.cancelled;
            return;
          }
          if (state.isActive) {
            result = ChatVoiceModeStartResult.alreadyActive;
            return;
          }

          final VoiceCallEligibility eligibility;
          if (admittedModel != null) {
            eligibility = VoiceCallEligibility.eligible(admittedModel);
          } else {
            _pendingStartReadinessCancellation = readinessCancellation;
            eligibility = await resolveVoiceCallEligibility(
              ref,
              cancellationSignal: readinessCancellation!.future,
              cancellationRequested: cancellationRequested,
            );
          }
          if (cancellationRequested()) {
            result = ChatVoiceModeStartResult.cancelled;
            return;
          }
          if (!eligibility.canStart) {
            _setError(eligibility.errorMessage!, ChatVoiceModeError.message);
            return;
          }
          if (shouldStart != null && !shouldStart()) {
            result = ChatVoiceModeStartResult.cancelled;
            return;
          }

          final model = eligibility.model!;

          final startToken = ++_token;
          token = startToken;
          _resetRuntime();

          void cancelIfRequested() {
            if (cancellationRequested() ||
                (shouldStart != null && !shouldStart())) {
              throw const _ChatVoiceModeStartCancelled();
            }
          }

          bool lostOwnership() {
            if (_isCurrent(startToken)) return false;
            result = ChatVoiceModeStartResult.cancelled;
            return true;
          }

          // Keep the inactive overlay lightweight. These services can reach
          // authenticated storage and platform channels, so capture them only
          // when a voice session actually starts. The retained references also
          // let disposal finish without reading Ref after invalidation.
          final VoiceModeInput input =
              _voiceInput ?? ref.read(voiceModeInputProvider);
          _voiceInput = input;
          final VoiceModeSpeech tts =
              _textToSpeech ?? ref.read(voiceModeSpeechProvider);
          _textToSpeech = tts;
          _callKit ??= ref.read(voiceCallKitProvider);
          final settings = ref.read(appSettingsProvider);

          state = state.copyWith(
            phase: ChatVoiceModePhase.starting,
            startedAt: DateTime.now(),
            elapsed: Duration.zero,
            clearErrorMessage: true,
            isCollapsed: false,
            isMuted: false,
            isSpeakerphoneEnabled: false,
          );

          _socketServiceSub = ref.listen<SocketService?>(
            socketServiceProvider,
            (_, next) => _replaceSocketBackgroundLease(next),
          );
          _selectedModelSub = ref.listen<Model?>(
            selectedModelProvider,
            (_, next) => _updateVoiceTransport(next),
          );
          _updateVoiceTransport(ref.read(selectedModelProvider) ?? model);

          final inputReady = await input.initialize();
          if (lostOwnership()) return;
          cancelIfRequested();
          if (!inputReady) {
            throw const _ChatVoiceModeFailure(
              ChatVoiceModeError.inputUnavailable,
              'Voice input initialization failed.',
            );
          }
          if (!await input.checkPermissions()) {
            throw const _ChatVoiceModeFailure(
              ChatVoiceModeError.microphoneDenied,
              'Microphone permission denied.',
            );
          }
          if (lostOwnership()) return;
          cancelIfRequested();

          await _requestAndroidVoiceRoutingPermission();
          if (lostOwnership()) return;
          cancelIfRequested();
          await _applyDefaultSpeakerphoneRoute();
          if (lostOwnership()) return;
          cancelIfRequested();

          final realtime = await _resolveRealtime(
            model,
            newChat: startNewConversation,
          );
          if (lostOwnership()) return;
          cancelIfRequested();
          if (realtime != null) {
            await _startCallKit(model.name, startToken);
            if (lostOwnership()) return;
            cancelIfRequested();
            await _startBackgroundVoiceLease(input, startToken);
            if (lostOwnership()) return;
            cancelIfRequested();
            _startElapsedTimer(startToken);
            if (startNewConversation) {
              startNewChat(ref, modelForNewConversation: model);
            }
            // Both directions at once, on the voice-chat route that cancels
            // echo.
            await _audioSessionCoordinator?.configureForBargeInSpeaking();
            if (lostOwnership()) return;
            cancelIfRequested();
            await _startRealtime(realtime, startToken);
            if (lostOwnership()) return;
            if (_isCurrent(startToken) && state.isActive) {
              result = ChatVoiceModeStartResult.started;
            }
            return;
          }

          await _initializeTts(tts, settings);
          if (lostOwnership()) return;
          cancelIfRequested();
          _listenForTtsEvents(tts, startToken);
          await _listenForResponseCaptureFailures(
            input,
            _audioSessionCoordinator,
            startToken,
          );
          await _startCallKit(model.name, startToken);
          if (lostOwnership()) return;
          cancelIfRequested();
          await _startBackgroundVoiceLease(input, startToken);
          if (lostOwnership()) return;
          cancelIfRequested();
          _startElapsedTimer(startToken);
          await _startListening(
            startToken,
            beforeAcceptingTranscripts: startNewConversation
                ? () {
                    cancelIfRequested();
                    startNewChat(ref, modelForNewConversation: model);
                  }
                : null,
          );
          if (lostOwnership()) return;
          cancelIfRequested();
          if (_isCurrent(startToken) && state.isActive) {
            result = ChatVoiceModeStartResult.started;
          }
        });
      } catch (error, stackTrace) {
        final startToken = token;
        if (_disposed || (startToken != null && !_isCurrent(startToken))) {
          result = ChatVoiceModeStartResult.cancelled;
          return;
        }
        if (error is _ChatVoiceModeStartCancelled ||
            error is VoiceCallEligibilityResolutionCancelled) {
          result = ChatVoiceModeStartResult.cancelled;
          if (startToken != null) {
            await _stopInternal(endCallKit: true);
          }
          return;
        }
        DebugLogger.error(
          'start-failed',
          scope: 'chat/voice_mode',
          error: error,
          stackTrace: stackTrace,
        );
        if (error is TimeoutException) {
          if (startToken != null) {
            final cleanupToken = ++_token;
            unawaited(
              _disposeResources(endCallKit: true, ownershipToken: cleanupToken),
            );
          }
          _setError(
            'Voice services timed out. Try again.',
            ChatVoiceModeError.timeout,
          );
          return;
        }
        if (startToken == null) {
          _setError(error.toString(), _errorKindOf(error));
          return;
        }
        await _fail(error.toString(), startToken, _errorKindOf(error));
      } finally {
        if (identical(
          _pendingStartReadinessCancellation,
          readinessCancellation,
        )) {
          _pendingStartReadinessCancellation = null;
        }
      }
    });
    return result;
  }

  /// How to build the realtime voice for a call with [model], or null when
  /// the call is a Standard one: the user chose Standard, the device cannot
  /// run the voice's audio, or the model's backend offers no realtime voice.
  Future<RealtimeCallEngine Function(BridgeCallHost host)?> _resolveRealtime(
    Model model, {
    required bool newChat,
  }) async {
    final route = await ref.read(realtimeCallRouteResolverProvider)(
      model,
      newChat: newChat,
    );
    final bridge = route.bridge;
    if (bridge != null) {
      final audio = ref.read(realtimePcmAudioFactoryProvider)();
      if (audio != null) {
        return (host) =>
            BridgeCallEngine(transport: bridge, audio: audio, host: host);
      }
      await bridge.close();
    }
    final hermes = route.hermes;
    if (hermes != null) {
      final media = ref.read(realtimeWebRtcMediaFactoryProvider)();
      if (media != null) {
        // Built after a new chat has started, so the voice never hears the
        // chat the call left.
        return (host) => GptLiveCallEngine(
          media: media,
          host: host,
          history: gptLiveHistory(ref.read(chatMessagesProvider)),
          open: (offer, history) async => (await hermes.createVoiceLiveSession(
            sdp: offer,
            history: history,
          )).answerSdp,
        );
      }
    }
    DebugLogger.log(
      'realtime-unavailable',
      scope: 'chat/voice_mode',
      data: {'reason': route.block?.name ?? 'no-device-audio'},
    );
    return null;
  }

  Future<void> _startRealtime(
    RealtimeCallEngine Function(BridgeCallHost host) build,
    int token,
  ) async {
    final host = ChatBridgeCallHost(
      ref,
      onNotice: (notice) {
        if (!_isCurrent(token) || _disposed) return;
        state = state.copyWith(
          notice: notice,
          noticeCount: state.noticeCount + 1,
        );
      },
    );
    final engine = build(host);
    _realtime = engine;
    _realtimeHost = host;
    // Followed from before it connects: a chat opened while it connects
    // ends it too.
    _followRealtimeChat(host, token);
    try {
      await engine.connect();
    } on RealtimeBridgeException catch (error) {
      // The start fails with this; the engine's own ending is not a second
      // failure.
      throw _ChatVoiceModeFailure(ChatVoiceModeError.message, error.message);
    }
    _realtimeSub = engine.states.listen(
      (realtime) => _onRealtimeState(realtime, token),
    );
    _onRealtimeState(engine.state, token);
    final callId = state.activeCallId;
    if (_isCurrent(token) && !_markedCallConnected && callId != null) {
      _markedCallConnected = true;
      unawaited(_callKit!.markCallConnected(callId));
    }
  }

  /// Ends a realtime call when the user leaves its chat: the voice talks
  /// about that chat, and a request it handed over is answered there. The
  /// chat the call's own send creates, and that chat's server id, stay the
  /// call's.
  void _followRealtimeChat(ChatBridgeCallHost host, int token) {
    _realtimeChatSub = ref.listen<Conversation?>(activeConversationProvider, (
      _,
      next,
    ) {
      if (!_isCurrent(token)) return;
      final callChatId = host.chatId;
      final followed = realtimeCallChatAfter(
        callChatId,
        next?.id,
        createdByCall: host.createdChat(next),
        remapped: isActiveConversationInPlaceRemap(ref, callChatId, next?.id),
      );
      if (followed.ends) {
        unawaited(stop());
      } else {
        host.followChat(next);
      }
    });
  }

  /// Shows the realtime call in the same snapshot a Standard call uses.
  void _onRealtimeState(RealtimeCallState realtime, int token) {
    if (!_isCurrent(token) || _disposed) return;
    if (realtime.phase == RealtimeCallPhase.ended) {
      final error = realtime.error;
      if (error != null) {
        unawaited(_fail(error, token, ChatVoiceModeError.message));
      } else {
        unawaited(stop());
      }
      return;
    }
    final level = realtime.assistantSpeaking
        ? realtime.outputLevel
        : realtime.inputLevel;
    state = state.copyWith(
      phase: switch (realtime) {
        RealtimeCallState(phase: RealtimeCallPhase.connecting) =>
          ChatVoiceModePhase.starting,
        RealtimeCallState(muted: true) => ChatVoiceModePhase.muted,
        RealtimeCallState(assistantSpeaking: true) =>
          ChatVoiceModePhase.speaking,
        RealtimeCallState(working: true) => ChatVoiceModePhase.sending,
        _ => ChatVoiceModePhase.listening,
      },
      transcript: realtime.userCaption,
      assistantPreview: realtime.assistantCaption,
      intensity: (level * 40).round().clamp(0, 10),
      isMuted: realtime.muted,
    );
  }

  /// Starts accessory-free calls on the loudspeaker, and follows the route the
  /// coordinator reads back for the rest of the call.
  ///
  /// The snapshot only ever moves on a route the coordinator confirms, so the
  /// overlay's speaker button never lights up for a move the platform refused,
  /// and goes back down when the platform moves the call off the loudspeaker.
  Future<void> _applyDefaultSpeakerphoneRoute() async {
    final coordinator = _audioSessionCoordinator;
    if (coordinator == null) {
      return;
    }
    unawaited(_speakerphoneRouteSub?.cancel());
    _speakerphoneRouteSub = coordinator.speakerphoneRouteChanges.listen((
      enabled,
    ) {
      if (_disposed || !state.isActive) return;
      // Every configure pass reports the route, mostly unchanged.
      if (state.isSpeakerphoneEnabled == enabled) return;
      state = state.copyWith(isSpeakerphoneEnabled: enabled);
    });
    await coordinator.applyDefaultSpeakerphoneRoute();
  }

  Future<void> _requestAndroidVoiceRoutingPermission() async {
    if (!_platform.isAndroid) {
      return;
    }

    try {
      await _platform.requestCallRoutingPermission();
    } catch (error, stackTrace) {
      DebugLogger.error(
        'bluetooth-connect-request-failed',
        scope: 'chat/voice_mode',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @visibleForTesting
  bool get isWaitingForStartReadiness =>
      _pendingStartReadinessCancellation != null;

  Future<void> stop() {
    ++_stopRequestGeneration;
    _cancelPendingStartReadiness();
    return _enqueue(() => _stopInternal(endCallKit: true));
  }

  Future<void> pause() {
    return _enqueue(() async {
      if (!state.canPause) return;
      final realtime = _realtime;
      if (realtime != null) {
        // A realtime voice has no pause: it stops talking and stops listening.
        realtime
          ..interrupt()
          ..setMuted(true);
        return;
      }

      final wasAwaitingAssistant = _awaitingAssistant;
      _pausedDuringSpeech = state.phase == ChatVoiceModePhase.speaking;
      _pausedDuringAssistantTurn = wasAwaitingAssistant;
      await _cancelListening();
      await _audioSessionCoordinator?.endResponseWaitCapture();
      if (_disposed) return;
      if (wasAwaitingAssistant) {
        await _textToSpeech!.pause();
      }

      if (_disposed) return;

      state = state.copyWith(phase: ChatVoiceModePhase.paused);
    });
  }

  Future<void> resume() {
    return _enqueue(() async {
      if (!state.canResume) return;
      final realtime = _realtime;
      if (realtime != null) {
        realtime.setMuted(false);
        return;
      }

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
        await _textToSpeech!.resume();
        if (_disposed) return;
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
      final realtime = _realtime;
      if (realtime != null) {
        realtime.setMuted(!realtime.state.muted);
        return;
      }

      if (!state.isMuted) {
        final token = _token;
        final phaseBeforeMute = state.phase;
        try {
          final keepAssistantAlive =
              _awaitingAssistant && state.phase != ChatVoiceModePhase.paused;
          if (keepAssistantAlive) {
            await _serviceLifecycleGate.runExclusive(() async {
              if (!_isCurrent(token)) return;
              await _detachListeningSubscriptions();
              if (!_isCurrent(token)) return;
              final inputOwnsCapture =
                  await _voiceInput?.prepareResponseWaitHandoff() ?? false;
              if (!_isCurrent(token)) return;
              if (!inputOwnsCapture) {
                await _audioSessionCoordinator?.beginResponseWaitCapture(
                  callKitCallId: _activeCallId,
                );
              }
            });
          } else {
            await _cancelListening();
            await _audioSessionCoordinator?.endResponseWaitCapture();
          }
          if (!_isCurrent(token)) return;
          _mutedDuringSpeech =
              phaseBeforeMute == ChatVoiceModePhase.speaking ||
              state.phase == ChatVoiceModePhase.speaking;
          state = state.copyWith(
            phase: ChatVoiceModePhase.muted,
            isMuted: true,
            intensity: 0,
          );
        } catch (error, stackTrace) {
          if (!_isCurrent(token)) return;
          DebugLogger.error(
            'mute-background-audio-failed',
            scope: 'chat/voice_mode',
            error: error,
            stackTrace: stackTrace,
          );
          await _fail(error.toString(), token, _errorKindOf(error));
        }
        return;
      }

      final resumeBargeIn =
          _awaitingAssistant &&
          ref.read(appSettingsProvider).voiceBargeInEnabled &&
          (_voiceInput?.willUseNativeLocalStt ?? false);
      if (_pausedDuringAssistantTurn) {
        _mutedDuringSpeech = false;
        state = state.copyWith(
          phase: ChatVoiceModePhase.starting,
          isMuted: false,
          clearErrorMessage: true,
        );
        await _resumePausedAssistantTurn(_token);
        return;
      }
      if (_awaitingAssistant && !resumeBargeIn) {
        final resumeSpeaking =
            _mutedDuringSpeech || state.phase == ChatVoiceModePhase.speaking;
        _mutedDuringSpeech = false;
        state = state.copyWith(
          phase: resumeSpeaking
              ? ChatVoiceModePhase.speaking
              : ChatVoiceModePhase.sending,
          isMuted: false,
          clearErrorMessage: true,
        );
        return;
      }

      _mutedDuringSpeech = false;
      state = state.copyWith(
        phase: ChatVoiceModePhase.starting,
        isMuted: false,
        clearErrorMessage: true,
      );
      await _startListening(_token);
    });
  }

  Future<void> toggleSpeakerphone() {
    return _enqueue(() async {
      if (!state.isActive) return;
      final coordinator = _audioSessionCoordinator;
      if (coordinator == null) return;
      final enabled = !state.isSpeakerphoneEnabled;
      final applied = await coordinator.setSpeakerphoneEnabled(enabled);
      if (_disposed) return;
      // A route the platform refused leaves audio where it was, so the button
      // stays where it was too rather than promising a route nobody is hearing.
      // That holds both ways: the coordinator reads the route back on and off
      // the loudspeaker, and reports the route it finds on every configure
      // pass, so the button shows the real route and the next press always
      // asks for the other one.
      if (!applied) return;
      state = state.copyWith(isSpeakerphoneEnabled: enabled);
    });
  }

  Future<void> cancelSpeaking() {
    return _enqueue(() async {
      final realtime = _realtime;
      if (realtime != null) {
        realtime.interrupt();
        return;
      }
      final tts = _textToSpeech;
      if (tts == null) return;
      await tts.stopStreamingTts();
      await tts.stop();
      if (_disposed) return;
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

  Future<void> _initializeTts(VoiceModeSpeech tts, AppSettings settings) {
    tts.setVoiceCallActive(true);
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
    final callKit = _callKit!;
    if (!callKit.isAvailable) {
      return;
    }

    await callKit.checkAndCleanActiveCalls();
    if (!_isCurrent(token)) return;

    await callKit.requestPermissions();
    if (!_isCurrent(token)) return;

    final callId = await callKit.startOutgoingVoiceCall(
      calleeName: modelName,
      handle: 'Conduit AI',
    );
    if (callId == null) {
      return;
    }
    if (!_isCurrent(token)) {
      await _endCallAfterDispose(callKit, callId);
      return;
    }

    _activeCallId = callId;
    state = state.copyWith(activeCallId: callId);
    await _audioSessionCoordinator?.setActiveCallKitCallId(callId);
    if (!_isCurrent(token)) return;
    await _callKitSub?.cancel();
    _callKitSub = callKit.events.listen((event) {
      _handleCallKitEvent(event);
    });
  }

  void _handleCallKitEvent(VoiceCallKitEvent event) {
    if (_disposed) return;
    final callId = _activeCallId;
    if (callId == null) return;

    switch (event) {
      case VoiceCallKitEnded(callId: final endedCallId):
        if (endedCallId == callId) {
          _stoppingFromCallKit = true;
          unawaited(_enqueue(() => _stopInternal(endCallKit: false)));
        }
      case VoiceCallKitMuteToggled(callId: final mutedCallId, :final isMuted):
        if (mutedCallId == callId && isMuted != state.isMuted) {
          unawaited(toggleMute());
        }
    }
  }

  void _listenForTtsEvents(VoiceModeSpeech tts, int token) {
    unawaited(_ttsSub?.cancel());
    _ttsSub = tts.events.listen((event) {
      if (!_isCurrent(token)) return;

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
          state = state.copyWith(
            errorMessage: message,
            errorKind: ChatVoiceModeError.other,
          );
          // Failed speech still ends the assistant turn. Without this the
          // recognizer stopped for playback is never restarted, leaving voice
          // mode active with no way to accept the next utterance.
          if (_awaitingAssistant) {
            _assistantFinalized = true;
            unawaited(_resumeAfterAssistantSpeech(token));
          }
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

  Future<void> _listenForResponseCaptureFailures(
    VoiceModeInput input,
    VoiceAudioSessionPort? audioSessionCoordinator,
    int token,
  ) async {
    await _responseCaptureFailureSub?.cancel();
    await _audioResponseCaptureFailureSub?.cancel();

    void handleFailure(Object error) {
      if (!_isCurrent(token)) return;
      DebugLogger.error(
        'response-capture-failed',
        scope: 'chat/voice_mode',
        error: error,
      );
      unawaited(_fail(error.toString(), token, _errorKindOf(error)));
    }

    _responseCaptureFailureSub = input.responseCaptureFailures.listen(
      handleFailure,
      onError: handleFailure,
    );
    _audioResponseCaptureFailureSub = audioSessionCoordinator
        ?.responseCaptureFailures
        .listen(handleFailure, onError: handleFailure);
  }

  Future<void> _startBackgroundVoiceLease(
    VoiceModeInput input,
    int token,
  ) async {
    await _stopBackgroundVoiceLease();
    if (!_isCurrent(token)) return;

    final leaseId = 'chat-voice-mode-$token';
    final requiresMicrophone = _requiresNativeBackgroundMicrophone(input);
    final background = _backgroundCoordinator!;

    _backgroundLeaseId = leaseId;
    _iosAudioSessionManagedExternally = true;

    await background.setExternalAudioSessionOwner(!requiresMicrophone);
    if (!_isCurrent(token)) {
      if (_backgroundLeaseId == leaseId) {
        _backgroundLeaseId = null;
      }
      await background.setExternalAudioSessionOwner(false);
      return;
    }

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
    if (!_isCurrent(token)) {
      if (_backgroundLeaseId == leaseId) {
        _backgroundLeaseId = null;
      }
      try {
        await background.stopVoiceLease(leaseId);
      } catch (_) {}
      await background.setExternalAudioSessionOwner(false);
      return;
    }

    _startBackgroundKeepAliveTimer(token, background);
  }

  bool _requiresNativeBackgroundMicrophone(VoiceModeInput input) {
    return _platform.isAndroid ||
        input.hasServerStt && (input.prefersServerOnly || !input.hasLocalStt);
  }

  void _startBackgroundKeepAliveTimer(
    int token,
    VoiceBackgroundPort background,
  ) {
    _backgroundKeepAliveTimer?.cancel();
    _backgroundKeepAliveTimer = Timer.periodic(_backgroundKeepAliveInterval, (
      _,
    ) {
      if (!_isCurrent(token) || !state.isActive) {
        _backgroundKeepAliveTimer?.cancel();
        _backgroundKeepAliveTimer = null;
        return;
      }
      unawaited(background.keepAlive());
    });
  }

  Future<void> _stopBackgroundVoiceLease([
    VoiceBackgroundPort? coordinator,
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

  Future<void> _startListening(
    int token, {
    void Function()? beforeAcceptingTranscripts,
  }) async {
    if (!_isCurrent(token) || state.isMuted) {
      return;
    }

    final input = _voiceInput!;
    final transferResponseCaptureToLocalStt = input.willUseNativeLocalStt;
    if (!transferResponseCaptureToLocalStt) {
      await _audioSessionCoordinator?.endResponseWaitCapture();
      if (!_isCurrent(token) || state.isMuted) return;
    }

    final bufferedEvents = <VoiceTranscriptEvent>[];
    Object? bufferedError;
    StackTrace? bufferedErrorStackTrace;
    var bufferedDone = false;
    var acceptingTranscripts = beforeAcceptingTranscripts == null;

    void onTranscriptEvent(VoiceTranscriptEvent event) {
      if (!acceptingTranscripts) {
        bufferedEvents.add(event);
        return;
      }
      _handleTranscriptEvent(event, token);
    }

    void onTranscriptError(Object error, StackTrace stackTrace) {
      if (!acceptingTranscripts) {
        bufferedError ??= error;
        bufferedErrorStackTrace ??= stackTrace;
        return;
      }
      if (!_isCurrent(token)) return;
      DebugLogger.error(
        'listen-failed',
        scope: 'chat/voice_mode',
        error: error,
        stackTrace: stackTrace,
      );
      unawaited(_fail(error.toString(), token, _errorKindOf(error)));
    }

    void onTranscriptDone() {
      if (!acceptingTranscripts) {
        bufferedDone = true;
        return;
      }
      _transcriptSub = null;
      unawaited(_handleListeningDone(token));
    }

    if (_transcriptSub == null || !input.isListening) {
      await _detachListeningSubscriptions();
      if (!input.isHoldingServerRecorderForResponse) {
        try {
          await input.stopListening();
        } catch (_) {}
      }
    }
    if (!_isCurrent(token)) return;
    await _audioSessionCoordinator?.configureForListening();
    if (!_isCurrent(token)) return;

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
      unawaited(_callKit!.markCallConnected(callId));
    }

    if (_transcriptSub == null || !input.isListening) {
      final stream = await input.beginListeningEvents(
        iosAudioSessionManagedExternally: _iosAudioSessionManagedExternally,
      );
      if (!_isCurrent(token)) {
        await _stopVoiceInputAfterDispose(input);
        return;
      }

      await _transcriptSub?.cancel();
      _transcriptSub = stream.listen(
        onTranscriptEvent,
        onError: onTranscriptError,
        onDone: onTranscriptDone,
      );
    }
    if (transferResponseCaptureToLocalStt) {
      await _audioSessionCoordinator?.endResponseWaitCapture();
      if (!_isCurrent(token) || state.isMuted) return;
    }

    await _intensitySub?.cancel();
    if (!_isCurrent(token)) return;
    _intensitySub = input.intensityStream.listen((intensity) {
      if (_isCurrent(token) && state.phase == ChatVoiceModePhase.listening) {
        state = state.copyWith(intensity: intensity);
      }
    });

    final startupError = bufferedError;
    if (startupError != null) {
      final stackTrace = bufferedErrorStackTrace ?? StackTrace.current;
      DebugLogger.error(
        'listen-failed',
        scope: 'chat/voice_mode',
        error: startupError,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(startupError, stackTrace);
    }

    beforeAcceptingTranscripts?.call();
    if (!_isCurrent(token)) return;
    acceptingTranscripts = true;
    for (final event in bufferedEvents) {
      if (!_isCurrent(token)) return;
      _handleTranscriptEvent(event, token);
    }
    bufferedEvents.clear();
    if (bufferedDone && _isCurrent(token)) {
      _transcriptSub = null;
      unawaited(_handleListeningDone(token));
    }
  }

  void _handleTranscriptEvent(VoiceTranscriptEvent event, int token) {
    if (!_isCurrent(token) || state.isMuted) return;

    _currentTranscript = event.text;
    if (state.isActive && state.phase != ChatVoiceModePhase.paused) {
      state = state.copyWith(transcript: event.text);
    }

    if (event.isFinal) {
      unawaited(_handleFinalTranscript(event.text, token));
    }
  }

  Future<void> _handleFinalTranscript(String text, int token) async {
    if (!_isCurrent(token) ||
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
    if (!_isCurrent(token) || state.phase != ChatVoiceModePhase.listening) {
      return;
    }

    final input = _voiceInput!;
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
      if (!_isCurrent(token) ||
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
        final assistantActive =
            _awaitingAssistant ||
            state.phase == ChatVoiceModePhase.sending ||
            state.phase == ChatVoiceModePhase.speaking;
        if (assistantActive &&
            !ref.read(appSettingsProvider).voiceBargeInEnabled) {
          _pendingFinalTranscripts.clear();
          return;
        }
        if (assistantActive) {
          await _interruptAssistantForBargeIn(token);
        }
        if (!_isCurrent(token) || state.isMuted) return;
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
        errorKind: ChatVoiceModeError.noSpeech,
      );
      return;
    }

    final exponent = _emptyTranscriptRestarts - 1;
    final delayMs = (_emptyTranscriptBaseDelayMs << exponent).clamp(
      _emptyTranscriptBaseDelayMs,
      _emptyTranscriptMaxDelayMs,
    );
    await Future<void>.delayed(Duration(milliseconds: delayMs));
    if (_isCurrent(token) && state.phase == ChatVoiceModePhase.listening) {
      await _startListening(token);
    }
  }

  Future<void> _sendTranscript(String transcript, int token) async {
    if (!_isCurrent(token)) return;

    try {
      final input = _voiceInput!;
      final keepListening =
          ref.read(appSettingsProvider).voiceBargeInEnabled &&
          input.isUsingNativeLocalStt;
      await _serviceLifecycleGate.runExclusive(() async {
        if (!_isCurrent(token)) return;
        var inputOwnsResponseCapture = false;
        if (!keepListening) {
          await _detachListeningSubscriptions();
          if (!_isCurrent(token)) return;
          inputOwnsResponseCapture = await input.prepareResponseWaitHandoff();
          if (!_isCurrent(token)) return;
        }
        if (_platform.isIOS) {
          await _audioSessionCoordinator?.configureForBargeInSpeaking();
        } else {
          await _audioSessionCoordinator?.configureForSpeaking();
        }
        if (!_isCurrent(token)) return;
        if (!keepListening && !inputOwnsResponseCapture) {
          await _audioSessionCoordinator?.beginResponseWaitCapture(
            callKitCallId: _activeCallId,
          );
        }
      });
      if (!_isCurrent(token)) return;
      final tts = _textToSpeech!;
      _assistantMessageIdsBeforeTurn = _currentAssistantMessageIds();
      ref.read(streamingContentProvider.notifier).set(null);
      await tts.startStreamingTts();
      if (!_isCurrent(token)) {
        await _stopTtsAfterDispose(tts);
        return;
      }

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

      await _backgroundCoordinator?.keepAlive();
      if (!_isCurrent(token)) return;
      final selectedToolIds = ref.read(selectedToolIdsProvider);
      await durableSend(
        ref,
        transcript,
        null,
        toolIds: selectedToolIds,
        isVoiceMode: true,
      );
      if (!_isCurrent(token)) return;

      _activeAssistantMessageId ??= _activeAssistantMessage()?.id;
      _handleAssistantContentChanged();
      _handleChatMessagesChanged(ref.read(chatMessagesProvider));
    } catch (error, stackTrace) {
      if (!_isCurrent(token)) return;
      DebugLogger.error(
        'send-failed',
        scope: 'chat/voice_mode',
        error: error,
        stackTrace: stackTrace,
      );
      await _fail(error.toString(), token, _errorKindOf(error));
    }
  }

  Future<void> _interruptAssistantForBargeIn(int token) async {
    if (!_isCurrent(token)) return;

    DebugLogger.info('barge-in', scope: 'chat/voice_mode');
    final tts = _textToSpeech!;
    await tts.stopStreamingTts();
    await tts.stop();
    if (!_isCurrent(token)) return;

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
    if (_disposed ||
        !_awaitingAssistant ||
        !_streamingTtsStarted ||
        _assistantFinalized) {
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
    unawaited(_textToSpeech!.feedStreamingText(text));
  }

  void _handleChatMessagesChanged(List<ChatMessage> messages) {
    if (_disposed ||
        !_awaitingAssistant ||
        !_streamingTtsStarted ||
        _assistantFinalized) {
      return;
    }

    final active = _activeAssistantMessage(messages);
    if (active == null) {
      return;
    }
    _activeAssistantMessageId ??= active.id;
    final error = active.error;
    if (error != null) {
      _assistantFinalized = true;
      unawaited(
        _fail(
          error.content ?? 'The assistant response failed.',
          _token,
          error.content == null
              ? ChatVoiceModeError.other
              : ChatVoiceModeError.message,
        ),
      );
      return;
    }
    _handleAssistantContentChanged(messages);
    // The transport marks `responseDone` on a terminal finish reason while
    // `isStreaming` can stay true until a later done event. Finalize on either
    // signal so the trailing TTS chunk is not held until transport close.
    if (!assistantMessageResponseCompleted(active)) {
      return;
    }

    unawaited(_finishAssistantResponse(_token));
  }

  Future<void> _finishAssistantResponse(int token) async {
    if (!_isCurrent(token) || _assistantFinalized) {
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
    await _textToSpeech!.finishStreamingTts(finalText: finalText);
  }

  Future<void> _resumePausedAssistantTurn(int token) async {
    final shouldResumePlayback = _pausedDuringSpeech;
    _pausedDuringSpeech = false;
    _pausedDuringAssistantTurn = false;

    if (!_awaitingAssistant) {
      await _startListening(token);
      return;
    }

    try {
      await _audioSessionCoordinator?.beginResponseWaitCapture(
        callKitCallId: _activeCallId,
      );
    } catch (error, stackTrace) {
      if (!_isCurrent(token)) return;
      DebugLogger.error(
        'resume-background-audio-failed',
        scope: 'chat/voice_mode',
        error: error,
        stackTrace: stackTrace,
      );
      await _fail(error.toString(), token, _errorKindOf(error));
      return;
    }
    if (!_isCurrent(token)) return;

    state = state.copyWith(
      phase: shouldResumePlayback
          ? ChatVoiceModePhase.speaking
          : ChatVoiceModePhase.sending,
      clearErrorMessage: true,
    );

    await _flushPausedAssistantTts(token);
    if (!_isCurrent(token) || !state.isActive) {
      return;
    }

    if (shouldResumePlayback) {
      await _textToSpeech!.resume();
      if (_isCurrent(token) && state.isActive) {
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
    final tts = _textToSpeech!;
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

    if (!_isCurrent(token) ||
        pendingText == null ||
        pendingText == _lastFedAssistantText) {
      return;
    }

    _lastFedAssistantText = pendingText;
    await tts.feedStreamingText(pendingText);
  }

  Future<void> _resumeAfterAssistantSpeech(int token) async {
    if (!_isCurrent(token) || !_awaitingAssistant) {
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
    // Once the transport marks the response done it has flushed the buffered
    // text into the message, while `streamingContentProvider` may still hold
    // an earlier frame. The message is authoritative from that point.
    final settled =
        message.isStreaming &&
        assistantMessageResponseCompleted(message) &&
        message.content.isNotEmpty;
    if (!settled &&
        message.isStreaming &&
        _isLastStreamingAssistant(message, messages)) {
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
    final input = _voiceInput;
    await _detachListeningSubscriptions();
    try {
      await input?.stopListening();
    } catch (_) {}
  }

  Future<void> _detachListeningSubscriptions() async {
    await _transcriptSub?.cancel();
    _transcriptSub = null;
    await _intensitySub?.cancel();
    _intensitySub = null;
  }

  Future<void> _fail(
    String message,
    int token, [
    ChatVoiceModeError kind = ChatVoiceModeError.other,
  ]) async {
    if (!_isCurrent(token)) return;
    // Invalidate transcript/TTS callbacks before resources are detached. The
    // lifecycle gate may delay subscription cancellation, and a recognizer is
    // allowed to deliver buffered data or onDone after onError.
    final failureToken = ++_token;
    await _disposeResources(endCallKit: true, ownershipToken: failureToken);
    if (!_isCurrent(failureToken)) return;
    state = state.copyWith(
      phase: ChatVoiceModePhase.error,
      errorMessage: message,
      errorKind: kind,
      clearActiveCallId: true,
      clearSpokenResponse: true,
      intensity: 0,
    );
  }

  void _setError(
    String message, [
    ChatVoiceModeError kind = ChatVoiceModeError.other,
  ]) {
    state = state.copyWith(
      phase: ChatVoiceModePhase.error,
      errorMessage: message,
      errorKind: kind,
      clearActiveCallId: true,
      clearSpokenResponse: true,
      intensity: 0,
    );
  }

  Future<void> _stopInternal({required bool endCallKit}) async {
    if (!state.isActive && state.phase != ChatVoiceModePhase.error) {
      return;
    }

    ++_token;
    final stopToken = _token;
    state = state.copyWith(phase: ChatVoiceModePhase.ending);
    await _disposeResources(
      endCallKit: endCallKit && !_stoppingFromCallKit,
      ownershipToken: stopToken,
    );
    if (!_isCurrent(stopToken)) return;
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
      isSpeakerphoneEnabled: false,
    );
  }

  Future<void> _disposeResources({
    required bool endCallKit,
    required int ownershipToken,
  }) async {
    final input = _voiceInput;
    final tts = _textToSpeech;
    final callKit = _callKit;
    final callId = _activeCallId;
    final transcriptSub = _transcriptSub;
    final intensitySub = _intensitySub;
    final responseCaptureFailureSub = _responseCaptureFailureSub;
    final audioResponseCaptureFailureSub = _audioResponseCaptureFailureSub;
    final ttsSub = _ttsSub;
    final callKitSub = _callKitSub;
    final speakerphoneRouteSub = _speakerphoneRouteSub;
    final socketServiceSub = _socketServiceSub;
    final selectedModelSub = _selectedModelSub;
    final elapsedTimer = _elapsedTimer;
    final backgroundKeepAliveTimer = _backgroundKeepAliveTimer;
    final backgroundLeaseId = _backgroundLeaseId;
    final socketBackgroundLease = _socketBackgroundLease;
    final backgroundCoordinator = _backgroundCoordinator;
    final audioSessionCoordinator = _audioSessionCoordinator;
    final realtime = _realtime;
    final realtimeHost = _realtimeHost;
    final realtimeSub = _realtimeSub;
    final realtimeChatSub = _realtimeChatSub;

    // Detach this session's instance state before the first await. A stale
    // teardown can then finish its captured resources without a later finally
    // block nulling services or resetting flags installed by a replacement
    // start.
    _activeCallId = null;
    _elapsedTimer = null;
    _transcriptSub = null;
    _intensitySub = null;
    _responseCaptureFailureSub = null;
    _audioResponseCaptureFailureSub = null;
    _ttsSub = null;
    _callKitSub = null;
    _speakerphoneRouteSub = null;
    _socketServiceSub = null;
    _selectedModelSub = null;
    _backgroundKeepAliveTimer = null;
    _backgroundLeaseId = null;
    _socketBackgroundLease = null;
    _voiceInput = null;
    _textToSpeech = null;
    _callKit = null;
    _iosAudioSessionManagedExternally = false;
    _usesOpenWebUiTransport = false;
    _realtime = null;
    _realtimeHost = null;
    _realtimeSub = null;
    _realtimeChatSub = null;
    realtimeChatSub?.close();
    // Its ending is this teardown's own; nothing listens for it any more.
    unawaited(realtimeSub?.cancel());
    // Ends the realtime voice and saves what it had not saved yet.
    final realtimeEnded = realtime?.end();
    elapsedTimer?.cancel();
    backgroundKeepAliveTimer?.cancel();
    selectedModelSub?.close();
    socketServiceSub?.close();
    socketBackgroundLease?.dispose();
    _resetRuntime();

    try {
      await _serviceLifecycleGate.runCleanupExclusive(() async {
        bool replacementOwnsInput() =>
            !_isCurrent(ownershipToken) && _voiceInput != null;
        bool replacementOwnsTts() =>
            !_isCurrent(ownershipToken) && _textToSpeech != null;
        bool replacementOwnsSharedAudio() =>
            !_isCurrent(ownershipToken) &&
            (_voiceInput != null ||
                _textToSpeech != null ||
                _backgroundLeaseId != null);

        // Before the audio session goes, so the call's audio stops first.
        await _runTeardownStep('realtime-end', () async {
          try {
            await realtimeEnded;
          } finally {
            // Answers still running go on in the chat, unfollowed.
            realtimeHost?.close();
          }
        });
        await _runTeardownStep('transcript-subscription-cancel', () async {
          await transcriptSub?.cancel();
        });
        await _runTeardownStep('intensity-subscription-cancel', () async {
          await intensitySub?.cancel();
        });
        await _runTeardownStep('input-capture-failure-cancel', () async {
          await responseCaptureFailureSub?.cancel();
        });
        await _runTeardownStep('audio-capture-failure-cancel', () async {
          await audioResponseCaptureFailureSub?.cancel();
        });
        await _runTeardownStep('voice-input-stop', () async {
          if (!replacementOwnsInput()) {
            await input?.stopListening();
          }
        });
        await _runTeardownStep('response-wait-capture-stop', () async {
          if (!replacementOwnsSharedAudio()) {
            await audioSessionCoordinator?.endResponseWaitCapture();
          }
        });
        await _runTeardownStep('tts-subscription-cancel', () async {
          await ttsSub?.cancel();
        });
        await _runTeardownStep('streaming-tts-stop', () async {
          if (!replacementOwnsTts()) {
            await tts?.stopStreamingTts();
          }
        });
        await _runTeardownStep('tts-stop', () async {
          if (!replacementOwnsTts()) {
            await tts?.stop();
          }
        });
        // Its own step: a stop that throws must not leave the shared engine on
        // the call route, where read-aloud does not belong.
        await _runTeardownStep('tts-call-route-release', () async {
          if (!replacementOwnsTts()) {
            tts?.setVoiceCallActive(false);
          }
        });
        await _runTeardownStep('background-lease-stop', () async {
          if (backgroundLeaseId != null) {
            await backgroundCoordinator?.stopVoiceLease(backgroundLeaseId);
          }
        });
        await _runTeardownStep('background-audio-owner-release', () async {
          if (!replacementOwnsSharedAudio()) {
            await backgroundCoordinator?.setExternalAudioSessionOwner(false);
          }
        });
        await _runTeardownStep('audio-session-deactivate', () async {
          if (!replacementOwnsSharedAudio()) {
            await audioSessionCoordinator?.deactivate();
          }
        });
        await _runTeardownStep('callkit-subscription-cancel', () async {
          await callKitSub?.cancel();
        });
        await _runTeardownStep(
          'speakerphone-route-subscription-cancel',
          () async {
            await speakerphoneRouteSub?.cancel();
          },
        );
        if (endCallKit && callId != null) {
          await _runTeardownStep('callkit-end', () async {
            await callKit?.endCall(callId);
          });
        }
      });
    } on TimeoutException catch (error, stackTrace) {
      DebugLogger.error(
        'teardown-lifecycle-timeout',
        scope: 'chat/voice_mode',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _runTeardownStep(
    String step,
    Future<void> Function() teardown,
  ) async {
    try {
      await teardown();
    } catch (error, stackTrace) {
      DebugLogger.error(
        'teardown-step-failed',
        scope: 'chat/voice_mode',
        error: error,
        stackTrace: stackTrace,
        data: {'step': step},
      );
    }
  }

  void _resetRuntime() {
    _selectedModelSub?.close();
    _selectedModelSub = null;
    _socketServiceSub?.close();
    _socketServiceSub = null;
    _socketBackgroundLease?.dispose();
    _socketBackgroundLease = null;
    _usesOpenWebUiTransport = false;
    _emptyTranscriptRestarts = 0;
    _currentTranscript = '';
    _lastFedAssistantText = '';
    _activeCallId = null;
    _activeAssistantMessageId = null;
    _assistantMessageIdsBeforeTurn = <String>{};
    _awaitingAssistant = false;
    _assistantFinalized = false;
    _streamingTtsStarted = false;
    _iosAudioSessionManagedExternally = false;
    _markedCallConnected = false;
    _pausedDuringSpeech = false;
    _pausedDuringAssistantTurn = false;
    _mutedDuringSpeech = false;
    _assistantFinalizationDeferred = false;
    _pendingPausedAssistantText = null;
    _pendingPausedAssistantFinalText = null;
    _pendingFinalTranscripts.clear();
    _lastSubmittedTranscript = null;
    _sendingTranscript = false;
    _assistantSpeechChunks = const <String>[];
    _activeAssistantSpeechChunkIndex = -1;
  }

  void _replaceSocketBackgroundLease(SocketService? socket) {
    final replacement = !_disposed && _usesOpenWebUiTransport && state.isActive
        ? socket?.acquireBackgroundActivityLease()
        : null;
    final previous = _socketBackgroundLease;
    _socketBackgroundLease = replacement;
    previous?.dispose();
  }

  void _updateVoiceTransport(Model? model) {
    if (_usesOpenWebUiTransport ||
        model == null ||
        !voiceCallUsesOpenWebUiTransport(ref, model)) {
      return;
    }
    _usesOpenWebUiTransport = true;
    _replaceSocketBackgroundLease(ref.read(socketServiceProvider));
  }

  void _syncAssistantSpeechChunks(String text) {
    _assistantSpeechChunks = _textToSpeech!.splitTextForSpeech(text);

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
      if (!_isCurrent(token)) {
        _elapsedTimer?.cancel();
        return;
      }
      final startedAt = state.startedAt;
      if (startedAt == null) return;
      state = state.copyWith(elapsed: DateTime.now().difference(startedAt));
    });
  }

  Future<void> _enqueue(Future<void> Function() action) {
    if (_disposed) return Future<void>.value();
    final next = _serial.then((_) async {
      if (_disposed) return;
      await action();
    });
    _serial = next.catchError((_) {});
    return next;
  }

  void _cancelPendingStartReadiness() {
    final cancellation = _pendingStartReadinessCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
  }

  bool _isCurrent(int token) => !_disposed && token == _token;

  Future<void> _cancelSubscriptionAfterDispose(
    StreamSubscription<dynamic>? subscription,
  ) async {
    try {
      await subscription?.cancel();
    } catch (_) {}
  }

  Future<void> _stopVoiceInputAfterDispose(VoiceModeInput? input) async {
    try {
      await input?.stopListening();
    } catch (_) {}
  }

  Future<void> _stopTtsAfterDispose(VoiceModeSpeech? tts) async {
    try {
      await tts?.stopStreamingTts();
    } catch (_) {}
    try {
      await tts?.stop();
    } catch (_) {}
  }

  Future<void> _stopBackgroundVoiceLeaseAfterDispose(
    VoiceBackgroundPort? coordinator,
  ) async {
    try {
      await _stopBackgroundVoiceLease(coordinator);
    } catch (_) {}
  }

  Future<void> _deactivateAudioSessionAfterDispose(
    VoiceAudioSessionPort? coordinator,
  ) async {
    try {
      await coordinator?.deactivate();
    } catch (_) {}
  }

  Future<void> _endResponseWaitCaptureAfterDispose(
    VoiceAudioSessionPort? coordinator,
  ) async {
    try {
      await coordinator?.endResponseWaitCapture();
    } catch (_) {}
  }

  Future<void> _endCallAfterDispose(
    VoiceCallKitPort? callKit,
    String callId,
  ) async {
    try {
      await callKit?.endCall(callId);
    } catch (_) {}
  }
}
