/// The host capabilities a voice call drives, as the voice-mode controller
/// sees them.
///
/// The controller (`chat_voice_mode_controller.dart`) owns the call's turn
/// taking: when to listen, when to send, when the assistant's speech ends and
/// the microphone comes back, barge-in, pause and mute, and the order in which
/// everything is torn down. The things it drives are host capabilities: a
/// speech recognizer, a speech synthesizer, the system call UI (CallKit, or an
/// Android call notification), the audio session and its routes, a background
/// lease, and platform permissions. Each is a port here, bound by the app in
/// `lib/main.dart`.
///
/// Every port has an inert default, so a host that binds nothing (the daemon,
/// a unit test) gets a controller that refuses to start rather than one that
/// throws on first read.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/services/settings_service.dart' show TtsEngine;
import 'package:conduit_core/voice/voice_events.dart';

export 'package:conduit_core/voice/voice_events.dart';

/// The recognizer a voice call listens through.
///
/// The Flutter app's `VoiceInputService` is the reference implementation:
/// on-device recognition, or server transcription of what voice activity
/// detection cut out of the microphone stream.
abstract interface class VoiceModeInput {
  /// Whether on-device recognition is available (after [initialize]).
  bool get hasLocalStt;

  /// Whether a server transcription endpoint is configured.
  bool get hasServerStt;

  /// Whether the user asked for server transcription only.
  bool get prefersServerOnly;

  /// Whether the next listen will run the native on-device recognizer, which
  /// can hand its capture over to the response wait instead of stopping it.
  bool get willUseNativeLocalStt;

  /// Whether the current listen runs the native on-device recognizer.
  bool get isUsingNativeLocalStt;

  bool get isListening;

  /// Whether a server recorder finished an utterance and is being held
  /// (discarding audio) through the assistant's turn.
  bool get isHoldingServerRecorderForResponse;

  /// Whether the transcript of the listen that just ended may be sent: a
  /// final recognizer result, or a completed server transcription.
  bool get lastCompletedTranscriptSendable;

  /// Loudness of the current listen, 0 to 10.
  Stream<int> get intensityStream;

  /// Failures of a capture held through the assistant's turn, reported after
  /// the listen that owned it ended.
  Stream<Object> get responseCaptureFailures;

  Future<bool> initialize({bool forceLocalStt = false});

  /// Asks for the microphone; false when it is denied.
  Future<bool> checkPermissions();

  /// Starts a listen for a voice call and returns its transcript events. The
  /// stream closes when the listen ends.
  Future<Stream<VoiceTranscriptEvent>> beginListeningEvents({
    bool iosAudioSessionManagedExternally = false,
  });

  /// Ends the listen so the assistant can answer. Returns true when the input
  /// keeps its own capture running through the response wait (a held server
  /// recorder), so the audio session need not start one.
  Future<bool> prepareResponseWaitHandoff();

  Future<void> stopListening();
}

/// The speech engine a voice call speaks through: device or server TTS,
/// fed incrementally while the assistant's reply streams in.
abstract interface class VoiceModeSpeech {
  Stream<TtsEvent> get events;

  /// Moves device speech onto the call's audio route (and back to the media
  /// route when false).
  void setVoiceCallActive(bool active);

  Future<bool> initialize({
    String? deviceVoice,
    String? serverVoice,
    double speechRate = 0.5,
    double pitch = 1.0,
    double volume = 1.0,
    TtsEngine engine = TtsEngine.device,
  });

  Future<void> startStreamingTts();

  /// Feeds the accumulated reply; complete sentences start speaking.
  Future<void> feedStreamingText(String accumulatedText);

  /// Flushes the rest of the reply; [TtsCompleted] follows once spoken.
  Future<void> finishStreamingTts({String? finalText});

  Future<void> stopStreamingTts();
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();

  /// How [feedStreamingText] splits text into spoken chunks, so the caller
  /// can show the chunk being spoken.
  List<String> splitTextForSpeech(String text);
}

/// Something the system call UI did to a call.
sealed class VoiceCallKitEvent {
  const VoiceCallKitEvent(this.callId);

  final String callId;
}

/// The call was ended, declined or timed out from the system UI.
final class VoiceCallKitEnded extends VoiceCallKitEvent {
  const VoiceCallKitEnded(super.callId);
}

/// The call's mute was toggled from the system UI.
final class VoiceCallKitMuteToggled extends VoiceCallKitEvent {
  const VoiceCallKitMuteToggled(super.callId, {required this.isMuted});

  final bool isMuted;
}

/// The system call UI: CallKit on iOS, a call notification on Android.
abstract interface class VoiceCallKitPort {
  /// False where the system call UI must not be used (CallKit on iPhones set
  /// to mainland China) or does not exist.
  bool get isAvailable;

  Stream<VoiceCallKitEvent> get events;

  /// Ends calls a previous run left behind.
  Future<void> checkAndCleanActiveCalls();

  Future<void> requestPermissions();

  /// Reports an outgoing call to the system and returns its id, or null when
  /// the system refused it (the call then runs without the system UI).
  Future<String?> startOutgoingVoiceCall({
    required String calleeName,
    required String handle,
  });

  /// Starts the call timer in the system UI.
  Future<void> markCallConnected(String id);

  Future<void> endCall(String id);
}

/// The audio session a voice call runs in: its category and mode per phase,
/// the loudspeaker/earpiece/headset route, and the capture that keeps the
/// microphone (and so the app) alive while the assistant answers.
abstract interface class VoiceAudioSessionPort {
  /// Whether the call is on the loudspeaker, whenever the host can say: after
  /// every configure pass (mostly unchanged), after a reroute the host made on
  /// its own (a headset plugged in or pulled out), and when the platform moves
  /// the route itself. Manual toggles are answered by [setSpeakerphoneEnabled]
  /// instead.
  Stream<bool> get speakerphoneRouteChanges;

  /// Failures of the response-wait capture after it started.
  Stream<Object> get responseCaptureFailures;

  /// Picks the loudspeaker for a call with no accessory attached; the next
  /// `configureFor*` pass applies it.
  Future<void> applyDefaultSpeakerphoneRoute();

  /// Moves the call on the user's instruction; false when the platform
  /// refused.
  Future<bool> setSpeakerphoneEnabled(bool enabled);

  Future<void> configureForListening();
  Future<void> configureForSpeaking();

  /// Speaking while the recognizer keeps listening (iOS barge-in).
  Future<void> configureForBargeInSpeaking();

  /// Ties audio ownership to the system call [callId].
  Future<void> setActiveCallKitCallId(String callId);

  /// Keeps a discard-only microphone capture running through the assistant's
  /// turn (iOS keeps a call with an active recording alive in the
  /// background).
  Future<void> beginResponseWaitCapture({String? callKitCallId});

  Future<void> endResponseWaitCapture();

  /// Hands the route back to whatever had it before the call.
  Future<void> deactivate();
}

/// The background lease that keeps a voice call running while the app is
/// not in the foreground.
abstract interface class VoiceBackgroundPort {
  Future<void> startVoiceLease({
    required String leaseId,
    required bool requiresMicrophone,
  });

  Future<void> stopVoiceLease(String leaseId);

  /// Renews the lease; false when there is nothing to renew.
  Future<bool> keepAlive();

  /// Tells the host's own background audio keeper that the call owns the
  /// audio session.
  Future<void> setExternalAudioSessionOwner(bool isExternal);
}

/// Platform facts and permissions the call flow branches on.
abstract interface class VoiceModePlatformPort {
  bool get isIOS;
  bool get isAndroid;

  /// Asks for what the call needs to route audio to headsets (Android 12+
  /// `BLUETOOTH_CONNECT`). A denial is logged, not fatal.
  Future<void> requestCallRoutingPermission();
}

/// A recognizer that never initializes: the controller reports "voice input
/// initialization failed" instead of listening.
class UnavailableVoiceModeInput implements VoiceModeInput {
  const UnavailableVoiceModeInput();

  @override
  bool get hasLocalStt => false;
  @override
  bool get hasServerStt => false;
  @override
  bool get prefersServerOnly => false;
  @override
  bool get willUseNativeLocalStt => false;
  @override
  bool get isUsingNativeLocalStt => false;
  @override
  bool get isListening => false;
  @override
  bool get isHoldingServerRecorderForResponse => false;
  @override
  bool get lastCompletedTranscriptSendable => false;
  @override
  Stream<int> get intensityStream => const Stream<int>.empty();
  @override
  Stream<Object> get responseCaptureFailures => const Stream<Object>.empty();
  @override
  Future<bool> initialize({bool forceLocalStt = false}) async => false;
  @override
  Future<bool> checkPermissions() async => false;
  @override
  Future<Stream<VoiceTranscriptEvent>> beginListeningEvents({
    bool iosAudioSessionManagedExternally = false,
  }) async => throw StateError('This host has no speech recognizer');
  @override
  Future<bool> prepareResponseWaitHandoff() async => false;
  @override
  Future<void> stopListening() async {}
}

/// A speech engine that says nothing and finishes at once.
class SilentVoiceModeSpeech implements VoiceModeSpeech {
  const SilentVoiceModeSpeech();

  @override
  Stream<TtsEvent> get events => const Stream<TtsEvent>.empty();
  @override
  void setVoiceCallActive(bool active) {}
  @override
  Future<bool> initialize({
    String? deviceVoice,
    String? serverVoice,
    double speechRate = 0.5,
    double pitch = 1.0,
    double volume = 1.0,
    TtsEngine engine = TtsEngine.device,
  }) async => false;
  @override
  Future<void> startStreamingTts() async {}
  @override
  Future<void> feedStreamingText(String accumulatedText) async {}
  @override
  Future<void> finishStreamingTts({String? finalText}) async {}
  @override
  Future<void> stopStreamingTts() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> stop() async {}
  @override
  List<String> splitTextForSpeech(String text) =>
      text.trim().isEmpty ? const <String>[] : <String>[text.trim()];
}

/// No system call UI: calls run in the app only.
class UnavailableVoiceCallKit implements VoiceCallKitPort {
  const UnavailableVoiceCallKit();

  @override
  bool get isAvailable => false;
  @override
  Stream<VoiceCallKitEvent> get events =>
      const Stream<VoiceCallKitEvent>.empty();
  @override
  Future<void> checkAndCleanActiveCalls() async {}
  @override
  Future<void> requestPermissions() async {}
  @override
  Future<String?> startOutgoingVoiceCall({
    required String calleeName,
    required String handle,
  }) async => null;
  @override
  Future<void> markCallConnected(String id) async {}
  @override
  Future<void> endCall(String id) async {}
}

/// No audio session to configure: every route change is taken as applied.
class NoVoiceAudioSession implements VoiceAudioSessionPort {
  const NoVoiceAudioSession();

  @override
  Stream<bool> get speakerphoneRouteChanges => const Stream<bool>.empty();
  @override
  Stream<Object> get responseCaptureFailures => const Stream<Object>.empty();
  @override
  Future<void> applyDefaultSpeakerphoneRoute() async {}
  @override
  Future<bool> setSpeakerphoneEnabled(bool enabled) async => true;
  @override
  Future<void> configureForListening() async {}
  @override
  Future<void> configureForSpeaking() async {}
  @override
  Future<void> configureForBargeInSpeaking() async {}
  @override
  Future<void> setActiveCallKitCallId(String callId) async {}
  @override
  Future<void> beginResponseWaitCapture({String? callKitCallId}) async {}
  @override
  Future<void> endResponseWaitCapture() async {}
  @override
  Future<void> deactivate() async {}
}

/// No background to survive in.
class NoVoiceBackground implements VoiceBackgroundPort {
  const NoVoiceBackground();

  @override
  Future<void> startVoiceLease({
    required String leaseId,
    required bool requiresMicrophone,
  }) async {}
  @override
  Future<void> stopVoiceLease(String leaseId) async {}
  @override
  Future<bool> keepAlive() async => false;
  @override
  Future<void> setExternalAudioSessionOwner(bool isExternal) async {}
}

/// `dart:io`'s platform, with no permission prompts. On a test host neither
/// flag is set, which is what the controller's tests expect.
class HostVoiceModePlatform implements VoiceModePlatformPort {
  const HostVoiceModePlatform();

  @override
  bool get isIOS => Platform.isIOS;
  @override
  bool get isAndroid => Platform.isAndroid;
  @override
  Future<void> requestCallRoutingPermission() async {}
}

/// The recognizer. Hosts bind their voice input service.
final voiceModeInputProvider = Provider<VoiceModeInput>(
  (ref) => const UnavailableVoiceModeInput(),
);

/// The speech engine. Hosts bind their text-to-speech service.
final voiceModeSpeechProvider = Provider<VoiceModeSpeech>(
  (ref) => const SilentVoiceModeSpeech(),
);

/// The system call UI.
final voiceCallKitProvider = Provider<VoiceCallKitPort>(
  (ref) => const UnavailableVoiceCallKit(),
);

/// The call's audio session.
final voiceAudioSessionProvider = Provider<VoiceAudioSessionPort>(
  (ref) => const NoVoiceAudioSession(),
);

/// The call's background lease.
final chatVoiceModeBackgroundCoordinatorProvider =
    Provider<VoiceBackgroundPort>((ref) => const NoVoiceBackground());

/// Platform facts and permissions.
final voiceModePlatformProvider = Provider<VoiceModePlatformPort>(
  (ref) => const HostVoiceModePlatform(),
);
