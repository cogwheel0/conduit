import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../voice_mode/chat_voice_mode_controller.dart';

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

/// Backward-compatible facade over chat-layered voice mode.
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

  Future<void> initialize() async {}

  Future<void> startCall(String? conversationId) {
    return _ref
        .read(chatVoiceModeControllerProvider.notifier)
        .start(startNewConversation: false);
  }

  Future<void> pauseListening({
    VoiceCallPauseReason reason = VoiceCallPauseReason.user,
  }) {
    if (reason == VoiceCallPauseReason.mute) {
      return _ref.read(chatVoiceModeControllerProvider.notifier).toggleMute();
    }
    return _ref.read(chatVoiceModeControllerProvider.notifier).pause();
  }

  Future<void> resumeListening({
    VoiceCallPauseReason reason = VoiceCallPauseReason.user,
  }) {
    return _ref.read(chatVoiceModeControllerProvider.notifier).resume();
  }

  Future<void> cancelSpeaking() {
    return _ref.read(chatVoiceModeControllerProvider.notifier).cancelSpeaking();
  }

  Future<void> stopCall() {
    return _ref.read(chatVoiceModeControllerProvider.notifier).stop();
  }

  Future<void> dispose() async {
    await _stateController.close();
    await _transcriptController.close();
    await _responseController.close();
    await _intensityController.close();
  }

  void syncFromSnapshot(ChatVoiceModeSnapshot snapshot) {
    final mappedState = _mapState(snapshot.phase);
    if (_state != mappedState) {
      _state = mappedState;
      _stateController.add(mappedState);
    }

    _transcriptController.add(snapshot.transcript);
    _responseController.add(snapshot.assistantPreview);
    _intensityController.add(snapshot.intensity);
  }

  VoiceCallState _mapState(ChatVoiceModePhase phase) {
    return switch (phase) {
      ChatVoiceModePhase.idle => VoiceCallState.idle,
      ChatVoiceModePhase.starting => VoiceCallState.connecting,
      ChatVoiceModePhase.listening => VoiceCallState.listening,
      ChatVoiceModePhase.paused ||
      ChatVoiceModePhase.muted => VoiceCallState.paused,
      ChatVoiceModePhase.sending => VoiceCallState.processing,
      ChatVoiceModePhase.speaking => VoiceCallState.speaking,
      ChatVoiceModePhase.ending ||
      ChatVoiceModePhase.ended => VoiceCallState.disconnected,
      ChatVoiceModePhase.error => VoiceCallState.error,
    };
  }
}

final voiceCallServiceProvider = Provider<VoiceCallService>((ref) {
  final service = VoiceCallService(ref: ref);

  ref.listen<ChatVoiceModeSnapshot>(chatVoiceModeControllerProvider, (_, next) {
    service.syncFromSnapshot(next);
  });

  ref.onDispose(() {
    unawaited(service.dispose());
  });

  return service;
});
