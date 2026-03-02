import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../voice_call/application/voice_call_controller.dart';
import '../voice_call/domain/voice_call_models.dart';

part 'voice_call_service.g.dart';

enum VoiceCallState {
  idle,
  connecting,
  listening,
  paused,
  processing,
  speaking,
  error,
  disconnected,
}

enum VoiceCallPauseReason { user, mute, system }

/// Backward-compatible facade delegating to [VoiceCallController].
class VoiceCallService {
  VoiceCallService({required Ref ref}) : _ref = ref;

  final Ref _ref;

  final StreamController<VoiceCallState> _stateController =
      StreamController<VoiceCallState>.broadcast();
  final StreamController<String> _transcriptController =
      StreamController<String>.broadcast();
  final StreamController<String> _responseController =
      StreamController<String>.broadcast();
  final StreamController<int> _intensityController =
      StreamController<int>.broadcast();

  VoiceCallState _state = VoiceCallState.idle;

  VoiceCallState get state => _state;
  Stream<VoiceCallState> get stateStream => _stateController.stream;
  Stream<String> get transcriptStream => _transcriptController.stream;
  Stream<String> get responseStream => _responseController.stream;
  Stream<int> get intensityStream => _intensityController.stream;

  Future<void> initialize() async {
    // Initialization is owned by VoiceCallController.start().
  }

  Future<void> startCall(String? conversationId) {
    return _ref
        .read(voiceCallControllerProvider.notifier)
        .start(startNewConversation: false);
  }

  Future<void> pauseListening({
    VoiceCallPauseReason reason = VoiceCallPauseReason.user,
  }) {
    return _ref
        .read(voiceCallControllerProvider.notifier)
        .pause(reason: _mapLegacyPauseReason(reason));
  }

  Future<void> resumeListening({
    VoiceCallPauseReason reason = VoiceCallPauseReason.user,
  }) {
    return _ref
        .read(voiceCallControllerProvider.notifier)
        .resume(reason: _mapLegacyPauseReason(reason));
  }

  Future<void> cancelSpeaking() {
    return _ref
        .read(voiceCallControllerProvider.notifier)
        .cancelAssistantSpeech();
  }

  Future<void> stopCall() {
    return _ref.read(voiceCallControllerProvider.notifier).stop();
  }

  Future<void> dispose() async {
    await _stateController.close();
    await _transcriptController.close();
    await _responseController.close();
    await _intensityController.close();
  }

  void syncFromSnapshot(VoiceCallSnapshot snapshot) {
    final mappedState = _mapState(snapshot.phase);
    if (_state != mappedState) {
      _state = mappedState;
      _stateController.add(mappedState);
    }

    _transcriptController.add(snapshot.transcript);
    _responseController.add(snapshot.response);
    _intensityController.add(snapshot.intensity);
  }

  CallPauseReason _mapLegacyPauseReason(VoiceCallPauseReason reason) {
    switch (reason) {
      case VoiceCallPauseReason.user:
        return CallPauseReason.user;
      case VoiceCallPauseReason.mute:
        return CallPauseReason.mute;
      case VoiceCallPauseReason.system:
        return CallPauseReason.system;
    }
  }

  VoiceCallState _mapState(CallPhase phase) {
    switch (phase) {
      case CallPhase.idle:
        return VoiceCallState.idle;
      case CallPhase.starting:
      case CallPhase.connecting:
        return VoiceCallState.connecting;
      case CallPhase.listening:
        return VoiceCallState.listening;
      case CallPhase.paused:
      case CallPhase.muted:
        return VoiceCallState.paused;
      case CallPhase.thinking:
        return VoiceCallState.processing;
      case CallPhase.speaking:
        return VoiceCallState.speaking;
      case CallPhase.ending:
      case CallPhase.ended:
        return VoiceCallState.disconnected;
      case CallPhase.failed:
        return VoiceCallState.error;
    }
  }
}

@riverpod
VoiceCallService voiceCallService(Ref ref) {
  final service = VoiceCallService(ref: ref);

  ref.listen<VoiceCallSnapshot>(voiceCallControllerProvider, (_, next) {
    service.syncFromSnapshot(next);
  });

  ref.onDispose(() {
    service.dispose();
  });

  return service;
}
