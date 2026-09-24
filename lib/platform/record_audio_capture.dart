import 'dart:typed_data';

import 'package:conduit_core/conduit_core.dart';
import 'package:meta/meta.dart';
import 'package:record/record.dart';

/// The mobile app's [AudioCapturePort], backed by `record`.
///
/// This is where the platform routing decisions live. The core asks for a
/// profile — dictation or a live call — and everything below is the
/// consequence of that choice on each platform. None of it is a preference a
/// caller should be expressing.
class RecordAudioCapture implements AudioCapturePort {
  RecordAudioCapture([AudioRecorder? recorder])
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<void> manageIosAudioSession(bool manage) async {
    await _recorder.ios?.manageAudioSession(manage);
  }

  @override
  Future<Stream<Uint8List>> startStream(AudioCaptureConfig config) =>
      _recorder.startStream(recordConfigFor(config));

  @override
  Future<void> stop() async {
    await _recorder.stop();
  }

  @override
  Future<void> dispose() => _recorder.dispose();

  /// Maps a capture profile onto `record`'s platform configuration.
  ///
  /// Exposed because the mapping is the part worth pinning: it encodes two
  /// routing bugs that were expensive to find.
  @visibleForTesting
  static RecordConfig recordConfigFor(AudioCaptureConfig config) {
    final voiceCall = config.profile == AudioCaptureProfile.voiceCall;
    return RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: config.sampleRate,
      numChannels: config.channels,
      bitRate: config.bitRate,
      echoCancel: config.echoCancel,
      autoGain: config.autoGain,
      noiseSuppress: config.noiseSuppress,
      androidConfig: androidConfigFor(voiceCallSession: voiceCall),
      iosConfig: const IosRecordConfig(categoryOptions: _iosCategoryOptions),
    );
  }

  @visibleForTesting
  static AndroidRecordConfig androidConfigFor({
    required bool voiceCallSession,
  }) => AndroidRecordConfig(
    audioSource: voiceCallSession
        ? AndroidAudioSource.voiceCommunication
        : AndroidAudioSource.voiceRecognition,
    audioManagerMode: voiceCallSession
        ? AudioManagerMode.modeInCommunication
        : AudioManagerMode.modeNormal,
    speakerphone: false,
    // During voice calls the audio session coordinator owns SCO and
    // communication-device selection. Letting the record plugin manage
    // Bluetooth makes every recorder stop clear the communication device
    // (issue #716: the loudspeaker route is wiped right before TTS speaks).
    manageBluetooth: !voiceCallSession,
    useLegacy: false,
  );

  // A2DP is output-only on iOS and can break duplex mic capture when the
  // recorder is trying to open a microphone stream.
  static const List<IosAudioCategoryOption> _iosCategoryOptions =
      <IosAudioCategoryOption>[
        IosAudioCategoryOption.defaultToSpeaker,
        IosAudioCategoryOption.allowBluetooth,
      ];
}
