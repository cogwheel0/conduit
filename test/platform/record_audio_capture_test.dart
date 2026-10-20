import 'package:checks/checks.dart';
import 'package:conduit/platform/just_audio_playback.dart';
import 'package:conduit/platform/record_audio_capture.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

/// Moved here from voice_input_service_test.dart along with the mapping
/// itself. The core now asks for a capture profile and this adapter
/// decides what that means on each platform, so this is where the decision
/// is worth pinning — both of these encode routing bugs that were expensive
/// to find.
void main() {
  group('android routing', () {
    test('uses speech recognition routing outside voice calls', () {
      final config = RecordAudioCapture.androidConfigFor(
        voiceCallSession: false,
      );

      check(config.audioSource).equals(AndroidAudioSource.voiceRecognition);
      check(config.audioManagerMode).equals(AudioManagerMode.modeNormal);
      check(config.manageBluetooth).isTrue();
    });

    test('uses communication routing during voice calls', () {
      final config = RecordAudioCapture.androidConfigFor(
        voiceCallSession: true,
      );

      check(config.audioSource).equals(AndroidAudioSource.voiceCommunication);
      check(config.audioManagerMode)
          .equals(AudioManagerMode.modeInCommunication);
      // The coordinator owns SCO/communication-device routing during calls.
      // record_android's Bluetooth manager clears the communication device on
      // every recorder stop, which knocked device TTS back to the earpiece
      // (issue #716), so the plugin must not manage Bluetooth here.
      check(config.manageBluetooth).isFalse();
    });
  });

  group('profile mapping', () {
    test('a voice call profile takes the communication route', () {
      final config = RecordAudioCapture.recordConfigFor(
        const AudioCaptureConfig(profile: AudioCaptureProfile.voiceCall),
      );

      check(config.androidConfig.audioSource)
          .equals(AndroidAudioSource.voiceCommunication);
      check(config.androidConfig.manageBluetooth).isFalse();
    });

    test('a dictation profile does not', () {
      final config = RecordAudioCapture.recordConfigFor(
        const AudioCaptureConfig(profile: AudioCaptureProfile.dictation),
      );

      check(config.androidConfig.audioSource)
          .equals(AndroidAudioSource.voiceRecognition);
      check(config.androidConfig.manageBluetooth).isTrue();
    });

    test('the signal settings the recogniser needs survive the mapping', () {
      final config = RecordAudioCapture.recordConfigFor(
        const AudioCaptureConfig(
          profile: AudioCaptureProfile.dictation,
          sampleRate: 16000,
        ),
      );

      // PCM at the VAD's sample rate, mono. Echo cancellation is what stops
      // the assistant's own voice reading as the user interrupting.
      check(config.encoder).equals(AudioEncoder.pcm16bits);
      check(config.sampleRate).equals(16000);
      check(config.numChannels).equals(1);
      check(config.echoCancel).isTrue();
      check(config.noiseSuppress).isTrue();
      check(config.autoGain).isFalse();
    });

    test('iOS keeps the speaker default and allows bluetooth', () {
      final config = RecordAudioCapture.recordConfigFor(
        const AudioCaptureConfig(profile: AudioCaptureProfile.voiceCall),
      );

      check(config.iosConfig.categoryOptions).deepEquals(const [
        IosAudioCategoryOption.defaultToSpeaker,
        IosAudioCategoryOption.allowBluetooth,
      ]);
    });
  });

  group('host installation', () {
    test('the suite runs with the real audio hosts installed', () {
      // Neither audio binding is reachable from the voice tests -- they
      // inject their own fakes -- so without this the lines in
      // flutter_test_config.dart could be deleted and nothing would fail.
      // They still matter: the core's defaults report no microphone and no
      // output, which is not the code path the app takes.
      // Compares the factories rather than calling them: constructing the
      // real recorder or player asserts without a plugin behind it, and the
      // binding is what is under test, not the plugin.
      check(AudioCapturePort.hostFactory).equals(RecordAudioCapture.new);
      check(AudioPlaybackPort.hostFactory).equals(JustAudioPlayback.new);
    });
  });
}
