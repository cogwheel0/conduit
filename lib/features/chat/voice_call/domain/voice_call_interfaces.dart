import 'dart:async';

import '../../services/text_to_speech_service.dart';
import '../../../../core/services/settings_service.dart';

/// Native outgoing call events normalized for platform-agnostic handling.
enum NativeCallEventType {
  ended,
  declined,
  timeout,
  muteToggled,
  holdToggled,
  connected,
}

class NativeCallEvent {
  const NativeCallEvent({
    required this.type,
    this.callId,
    this.isMuted,
    this.isOnHold,
  });

  final NativeCallEventType type;
  final String? callId;
  final bool? isMuted;
  final bool? isOnHold;
}

/// Disposable subscription abstraction for transport handlers.
class VoiceAssistantSubscription {
  const VoiceAssistantSubscription({required this.dispose, this.handlerId});

  final FutureOr<void> Function() dispose;
  final String? handlerId;
}

typedef VoiceAssistantEventHandler =
    void Function(Map<String, dynamic> event, void Function(dynamic)? ack);

/// Native call-surface abstraction.
abstract class NativeCallSurface {
  bool get isAvailable;
  Stream<NativeCallEvent> get events;

  Future<void> requestPermissions();
  Future<void> checkAndCleanActiveCalls();
  Future<String?> startOutgoingCall({
    required String callerName,
    required String handle,
  });
  Future<void> markConnected(String callId);
  Future<void> endCall(String callId);
  Future<void> endAllCalls();
}

/// Speech input abstraction for device/server STT.
abstract class VoiceInputEngine {
  bool get hasLocalStt;
  bool get hasServerStt;
  bool get prefersServerOnly;
  bool get prefersDeviceOnly;
  SttPreference get preference;

  Stream<int> get intensityStream;

  Future<bool> initialize();
  Future<bool> checkPermissions();
  Future<bool> requestMicrophonePermission();
  Future<Stream<String>> beginListening();
  Future<void> stopListening();
  Future<void> dispose();
}

/// Speech output abstraction for device/server TTS.
abstract class VoiceOutputEngine {
  bool get prefersServerEngine;

  void bindHandlers({
    void Function()? onStart,
    void Function()? onComplete,
    void Function(String error)? onError,
  });

  Future<void> initializeWithSettings(AppSettings settings);
  Future<void> updateSettings(AppSettings settings);
  Future<void> reloadBackendConfig();
  List<String> splitTextForSpeech(String text);
  Future<void> speak(String text);
  Future<SpeechAudioChunk> synthesizeServerSpeechChunk(String text);
  Future<void> stop();
  Future<void> dispose();
}

/// Assistant transport abstraction for connection and streaming events.
abstract class VoiceAssistantTransport {
  String? get sessionId;
  bool get isConnected;
  Stream<void> get onReconnect;

  Future<bool> ensureConnected({
    Duration timeout = const Duration(seconds: 10),
  });
  VoiceAssistantSubscription registerAssistantEvents({
    required VoiceAssistantEventHandler handler,
    String? conversationId,
    String? sessionId,
    bool requireFocus,
  });
  void updateSessionIdForConversation(String conversationId, String sessionId);
}

/// Background lifecycle and notifications abstraction.
abstract class CallBackgroundPolicy {
  Future<void> initialize();
  Future<void> requestNotificationPermissionIfNeeded();
  Future<void> startBackgroundExecution({required bool requiresMicrophone});
  Future<void> stopBackgroundExecution();
  Future<bool> keepAlive();
  Future<void> setScreenAwake(bool enabled);
  Future<void> updateOngoingCallNotification({
    required String modelName,
    required bool isMuted,
    required bool isSpeaking,
    required bool isPaused,
    required bool show,
  });
  Future<void> cancelCallNotification();
}

/// Audio session coordinator to reduce STT/TTS focus conflicts.
abstract class CallAudioSessionCoordinator {
  Future<void> configureForListening();
  Future<void> configureForSpeaking();
  Future<void> deactivate();
}

/// Handles permission preflight for call sessions.
abstract class CallPermissionOrchestrator {
  Future<void> ensureCallPermissions(VoiceInputEngine input);
}
