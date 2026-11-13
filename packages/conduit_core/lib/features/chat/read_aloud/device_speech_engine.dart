import 'dart:async';

/// What the device's speech engine reports: `start`, `progress` (the word
/// being spoken, as [start]..[end] offsets in the text handed to
/// [DeviceSpeechEngine.speak]), `complete`, `cancel`, `pause`, `continue`
/// and `error`.
///
/// Moved here from the Flutter app's `native_tts_service.dart`, which
/// re-exports it under the same name.
class NativeTtsEvent {
  const NativeTtsEvent({
    required this.type,
    this.message,
    this.start,
    this.end,
  });

  final String type;
  final String? message;
  final int? start;
  final int? end;

  factory NativeTtsEvent.fromMap(Map<Object?, Object?> map) {
    return NativeTtsEvent(
      type: (map['type'] as String?) ?? 'unknown',
      message: map['message'] as String?,
      start: (map['start'] as num?)?.toInt(),
      end: (map['end'] as num?)?.toInt(),
    );
  }
}

/// Device speech rendered to a file, with its length.
class NativeTtsAudio {
  const NativeTtsAudio(this.path, this.duration);
  final String path;
  final Duration duration;
}

/// The device's own text-to-speech: AVSpeechSynthesizer on Apple systems,
/// Android's TextToSpeech.
///
/// A port so the read-aloud manager can live in the core: the phone
/// reaches its engine over platform channels, the desktop over the
/// daemon's `speech.*` protocol.
abstract interface class DeviceSpeechEngine {
  /// What the engine reports while it speaks.
  Stream<NativeTtsEvent> get events;

  /// The engine's name for the voices it lists (`AVSpeech`, `AndroidTTS`).
  String get engineName;

  /// Whether [speak] replaces what the engine is saying without reporting
  /// a `cancel` for it, so a reading can move to another sentence, or say
  /// the rest of one again at a new speed, without ending.
  ///
  /// Such an engine is paused and resumed by the reading alone: its
  /// [pause] and [resume] answering is what counts, and its own `pause` and
  /// `continue` events are not waited for.
  bool get replacesOnSpeak;

  Future<bool> isAvailable();

  Future<List<Map<String, dynamic>>> getVoices();

  /// Speaks [text]. [voiceCall] keeps playback on the active call route.
  Future<bool> speak({
    required String text,
    String? voiceIdentifier,
    required double rate,
    required double pitch,
    required double volume,
    bool voiceCall = false,
  });

  /// Renders [text] to a local file so a reading can seek by time.
  Future<NativeTtsAudio> synthesize({
    required String text,
    String? voiceIdentifier,
    required double rate,
    required double pitch,
    required double volume,
  });

  Future<bool> cancelSynthesis();

  Future<bool> stop();

  Future<bool> pause();

  Future<bool> resume();

  /// Creates the host's engine. Installed once at startup, as
  /// `AudioPlaybackPort.hostFactory` is; the core's default speaks nothing.
  static DeviceSpeechEngine Function() hostFactory = NoDeviceSpeech.new;
}

/// An engine that is never available: the host has no device speech.
class NoDeviceSpeech implements DeviceSpeechEngine {
  NoDeviceSpeech();

  @override
  Stream<NativeTtsEvent> get events => const Stream<NativeTtsEvent>.empty();

  @override
  String get engineName => 'none';

  @override
  bool get replacesOnSpeak => false;

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<List<Map<String, dynamic>>> getVoices() async =>
      const <Map<String, dynamic>>[];

  @override
  Future<bool> speak({
    required String text,
    String? voiceIdentifier,
    required double rate,
    required double pitch,
    required double volume,
    bool voiceCall = false,
  }) async => false;

  @override
  Future<NativeTtsAudio> synthesize({
    required String text,
    String? voiceIdentifier,
    required double rate,
    required double pitch,
    required double volume,
  }) async => throw StateError('Device speech did not produce audio');

  @override
  Future<bool> cancelSynthesis() async => false;

  @override
  Future<bool> stop() async => false;

  @override
  Future<bool> pause() async => false;

  @override
  Future<bool> resume() async => false;
}
