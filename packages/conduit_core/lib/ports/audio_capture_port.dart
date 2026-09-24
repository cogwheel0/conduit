import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Streams microphone audio as PCM frames.
///
/// Deliberately a raw PCM stream rather than "record to a file": server-side
/// voice activity detection needs the frames as they arrive, and the caller
/// owns the bridge into the VAD engine.
///
/// This interface grew out of `ServerVadRecorderClient`, which already had
/// the right shape. What moved it into the core was taking the one plugin
/// type out of its signature — see [AudioCaptureConfig].
abstract interface class AudioCapturePort {
  /// Whether the microphone permission has been granted.
  Future<bool> hasPermission();

  /// Hands iOS audio-session control to the caller, or takes it back.
  ///
  /// During a voice call something else owns the session — routing, the
  /// speaker/earpiece decision, and Bluetooth — and a recorder that also
  /// manages it will fight over the route.
  Future<void> manageIosAudioSession(bool manage);

  /// Opens the microphone and returns the PCM frames.
  Future<Stream<Uint8List>> startStream(AudioCaptureConfig config);

  Future<void> stop();

  Future<void> dispose();

  /// Creates the host's microphone.
  ///
  /// A factory, not an instance: every recognition session gets a fresh
  /// native recorder, because an audio-focus failure on one can otherwise
  /// poison the next attempt.
  ///
  /// Installed once at startup. `main.dart` and
  /// `test/flutter_test_config.dart` both install the `record` one.
  static AudioCapturePort Function() hostFactory = NullAudioCapture.new;
}

/// A microphone that is never granted and never starts.
///
/// The honest answer for a host with no capture device. It reports no
/// permission rather than returning an empty stream, so callers take their
/// existing "cannot listen" path instead of waiting for speech that will
/// never arrive.
class NullAudioCapture implements AudioCapturePort {
  const NullAudioCapture();

  @override
  Future<bool> hasPermission() async => false;

  @override
  Future<void> manageIosAudioSession(bool manage) async {}

  @override
  Future<Stream<Uint8List>> startStream(AudioCaptureConfig config) async =>
      throw StateError('This host has no microphone');

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

/// What a capture session is for, and the signal quality it needs.
///
/// Carries intent rather than platform settings on purpose. The Android audio
/// source, the audio-manager mode and who manages Bluetooth are not
/// preferences a caller should express — they are consequences of whether
/// this is a call, and getting them wrong has caused real routing bugs. So
/// the caller says which situation it is in and the host adapter decides.
@immutable
class AudioCaptureConfig {
  const AudioCaptureConfig({
    required this.profile,
    this.sampleRate = 16000,
    this.channels = 1,
    this.bitRate = 16,
    this.echoCancel = true,
    this.autoGain = false,
    this.noiseSuppress = true,
  });

  final AudioCaptureProfile profile;
  final int sampleRate;
  final int channels;
  final int bitRate;

  /// Suppresses the device's own speaker output from the captured signal.
  ///
  /// Load-bearing for barge-in: without it the assistant's own voice comes
  /// back through the microphone and reads as the user interrupting.
  final bool echoCancel;

  final bool autoGain;
  final bool noiseSuppress;
}

/// The situation a capture session is running in.
enum AudioCaptureProfile {
  /// A one-shot dictation. Nothing else is using the audio route, so the
  /// recorder may manage it.
  dictation,

  /// A live voice call, where the caller already owns routing and the
  /// recorder must not touch it.
  voiceCall,
}
