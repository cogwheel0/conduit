import 'dart:typed_data';

/// What the audio engine reports a few times a second.
final class RealtimePlaybackReport {
  const RealtimePlaybackReport({
    required this.clearId,
    required this.playbackActive,
    required this.queuedSamples,
    required this.receivedSamples,
    this.inputLevel = 0,
    this.outputLevel = 0,
  });

  /// The latest clear the report follows; older reports are stale.
  final int clearId;

  /// Whether speech played since the last report.
  final bool playbackActive;

  /// Samples waiting to be played.
  final int queuedSamples;

  /// Samples received for playback since the engine started.
  final int receivedSamples;

  /// Loudness of the microphone and of the voice, 0 to 1.
  final double inputLevel;
  final double outputLevel;
}

/// How much of one spoken item the user heard before playback was cleared.
typedef RealtimeRenderedItem = ({
  String responseId,
  String itemId,
  int contentIndex,
  int samples,
});

/// The microphone and speaker of a bridge call, on one 24 kHz audio clock
/// with echo cancellation, so the voice does not hear itself.
///
/// Mirrors Open WebUI's `realtime-audio.js` worklet: capture in 960-sample
/// frames (40 ms), playback that starts once 1920 samples are queued or the
/// response has ended, and a clear that reports what was heard of each item.
abstract interface class RealtimePcmAudioPort {
  /// Starts capture and playback. Throws when the microphone is unavailable.
  Future<void> start();

  /// PCM16 little-endian mono frames, while capture is enabled.
  Stream<Uint8List> get captureFrames;

  Stream<RealtimePlaybackReport> get reports;

  /// Why the audio stopped working mid-call, such as a lost microphone.
  Stream<String> get failures;

  void setCaptureEnabled(bool enabled);

  /// Queues PCM16 speech of one item for playback.
  void enqueue({
    required String responseId,
    required String itemId,
    required int contentIndex,
    required Uint8List pcm,
  });

  /// No more speech will come for [responseId]; play what is queued.
  void endResponse(String responseId);

  /// Drops queued speech and returns how much of each item was played.
  Future<List<RealtimeRenderedItem>> clear(int clearId);

  /// How long played audio takes to reach the speaker.
  Duration get outputLatency;

  Future<void> stop();
}

/// Where a WebRTC call's connection stands.
enum RealtimeMediaState { connecting, connected, failed, closed }

/// A WebRTC call to a realtime voice: the microphone and the voice on the
/// platform's echo-cancelled call audio, and a data channel for the voice's
/// events.
abstract interface class RealtimeWebRtcMediaPort {
  /// Opens the microphone and returns the SDP offer with every ICE candidate
  /// gathered, exactly as it must be sent, with a data channel named
  /// [dataChannel].
  Future<String> createOffer({String dataChannel = 'oai-events'});

  Future<void> acceptAnswer(String sdp);

  /// Text messages arriving on the data channel.
  Stream<String> get messages;

  Stream<RealtimeMediaState> get states;

  /// Sends a text message on the data channel.
  void send(String message);

  void setMicrophoneEnabled(bool enabled);

  Future<void> close();
}
