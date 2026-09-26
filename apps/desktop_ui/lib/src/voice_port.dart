import 'dart:async';

/// A recording the browser holds, ready to be transcribed.
class CapturedAudio {
  const CapturedAudio({
    required this.handle,
    required this.contentType,
    required this.size,
  });

  final String handle;
  final String contentType;
  final int size;
}

/// One of the system's voices, as Web Speech Synthesis lists it.
class DeviceVoice {
  const DeviceVoice({
    required this.name,
    this.language = '',
    this.isDefault = false,
  });

  final String name;
  final String language;
  final bool isDefault;
}

/// Hears how loud the microphone is, [elapsed] into a capture. [level] is
/// the signal's RMS, from 0 to 1.
typedef LevelListener = void Function(double level, Duration elapsed);

/// The window's audio: the microphone, the system's voices, and an audio
/// element for the server's. Everything else about voice is logic,
/// and lives outside this port so it can be tested.
abstract interface class VoicePort {
  /// Starts recording from the microphone. False when there is none or it
  /// was refused -- the user's answer, not an error.
  Future<bool> startCapture(LevelListener onLevel);

  /// Stops recording. Null when nothing was captured.
  Future<CapturedAudio?> stopCapture();

  /// Stops recording and throws it away.
  void cancelCapture();

  /// The transcription of [audio], through the daemon. With [wav], the
  /// recording is sent as 16 kHz mono WAV, which transcribing on this
  /// computer needs.
  Future<String> transcribe(CapturedAudio audio, {bool wav = false});

  /// The system's voices; empty when it has none.
  Future<List<DeviceVoice>> deviceVoices();

  /// Says [text] with a system voice. Completes when it has been said, or
  /// when [stopSpeech] cuts it short. [rate] is Web Speech's: 1 is normal.
  Future<void> speakDevice(
    String text, {
    String? voice,
    double rate = 1,
    double pitch = 1,
    double volume = 1,
  });

  /// Plays a `voice.speak` job's audio. Completes when it ends or is
  /// stopped.
  Future<void> play(String jobId, {double volume = 1});

  /// Silences whatever is being said.
  void stopSpeech();
}

/// Records what it was asked to do. The default outside a browser.
final class RecordingVoice implements VoicePort {
  /// Whether [startCapture] finds a microphone.
  bool microphone = true;

  /// What [transcribe] answers.
  String transcript = 'Hello from the microphone';

  /// Fails the next transcription with this, if set.
  Object? failWith;

  List<DeviceVoice> voices = const <DeviceVoice>[
    DeviceVoice(name: 'Alex', language: 'en-US', isDefault: true),
    DeviceVoice(name: 'Amelie', language: 'fr-FR'),
  ];

  /// Whether a capture is running, and who hears its levels.
  LevelListener? listening;
  final List<String> transcribed = <String>[];

  /// Whether each transcription asked for WAV.
  final List<bool> transcribedAsWav = <bool>[];
  int cancelled = 0;

  /// Everything said, as `device:<text>` or `server:<jobId>`, in order.
  final List<String> spoken = <String>[];

  /// The settings each device utterance was said with.
  final List<({String? voice, double rate, double pitch, double volume})>
  deviceSettings =
      <({String? voice, double rate, double pitch, double volume})>[];

  /// Whether speech finishes at once. When false, each utterance waits
  /// for [finishSpeech] -- so a test can look while something is said.
  bool instantSpeech = true;
  Completer<void>? _speaking;
  int stops = 0;

  @override
  Future<bool> startCapture(LevelListener onLevel) async {
    if (!microphone) return false;
    listening = onLevel;
    return true;
  }

  /// Plays [level] to the capture, as the microphone would.
  void level(double level, Duration elapsed) => listening?.call(level, elapsed);

  @override
  Future<CapturedAudio?> stopCapture() async {
    if (listening == null) return null;
    listening = null;
    return const CapturedAudio(
      handle: 'v0',
      contentType: 'audio/webm',
      size: 2048,
    );
  }

  @override
  void cancelCapture() {
    if (listening != null) cancelled++;
    listening = null;
  }

  @override
  Future<String> transcribe(CapturedAudio audio, {bool wav = false}) async {
    if (failWith case final error?) {
      failWith = null;
      throw error;
    }
    transcribed.add(audio.handle);
    transcribedAsWav.add(wav);
    return transcript;
  }

  @override
  Future<List<DeviceVoice>> deviceVoices() async => voices;

  @override
  Future<void> speakDevice(
    String text, {
    String? voice,
    double rate = 1,
    double pitch = 1,
    double volume = 1,
  }) {
    spoken.add('device:$text');
    deviceSettings.add((
      voice: voice,
      rate: rate,
      pitch: pitch,
      volume: volume,
    ));
    return _say();
  }

  @override
  Future<void> play(String jobId, {double volume = 1}) {
    spoken.add('server:$jobId');
    return _say();
  }

  Future<void> _say() {
    if (instantSpeech) return Future<void>.value();
    return (_speaking = Completer<void>()).future;
  }

  /// Ends the utterance being said, when [instantSpeech] is off.
  void finishSpeech() {
    final speaking = _speaking;
    _speaking = null;
    if (speaking != null && !speaking.isCompleted) speaking.complete();
  }

  @override
  void stopSpeech() {
    stops++;
    finishSpeech();
  }
}
