import 'package:checks/checks.dart';
import 'package:conduit/features/chat/services/voice_input_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:vad/vad.dart';

void main() {
  group('VoiceInputService.silenceDurationToVadFrames', () {
    test('does not shorten the requested pause window', () {
      check(VoiceInputService.silenceDurationToVadFrames(2000)).equals(63);
      check(VoiceInputService.silenceDurationToVadFrames(2017)).equals(64);
    });

    test('preserves longer server STT silence windows', () {
      check(VoiceInputService.silenceDurationToVadFrames(3000)).equals(94);
      check(VoiceInputService.silenceDurationToVadFrames(5000)).equals(157);
    });
  });

  group('VoiceInputService.resolveServerLanguageHint', () {
    test('uses explicit STT language before locale fallbacks', () {
      final language = VoiceInputService.resolveServerLanguageHint(
        configuredLanguageCode: 'PL',
        selectedLocaleId: 'de_DE',
        fallbackLocale: const Locale('en'),
      );

      check(language).equals('pl');
    });

    test('falls back to selected locale when no explicit language is set', () {
      final language = VoiceInputService.resolveServerLanguageHint(
        selectedLocaleId: 'de_DE',
        fallbackLocale: const Locale('en'),
      );

      check(language).equals('de');
    });

    test('falls back to device locale when selected locale is unavailable', () {
      final language = VoiceInputService.resolveServerLanguageHint(
        fallbackLocale: const Locale('pl'),
      );

      check(language).equals('pl');
    });
  });

  group('VoiceInputService.androidServerVadRecordConfig', () {
    test('uses speech recognition routing outside voice calls', () {
      final config = VoiceInputService.androidServerVadRecordConfigForTesting(
        voiceCallSession: false,
      );

      check(config.audioSource).equals(AndroidAudioSource.voiceRecognition);
      check(config.audioManagerMode).equals(AudioManagerMode.modeNormal);
      check(config.manageBluetooth).isTrue();
    });

    test('uses communication routing during voice calls', () {
      final config = VoiceInputService.androidServerVadRecordConfigForTesting(
        voiceCallSession: true,
      );

      check(config.audioSource).equals(AndroidAudioSource.voiceCommunication);
      check(
        config.audioManagerMode,
      ).equals(AudioManagerMode.modeInCommunication);
      check(config.manageBluetooth).isTrue();
    });
  });

  group('VoiceInputService.shouldSettleNativeDictation', () {
    test('settles cumulative native dictation on final result', () {
      check(
        VoiceInputService.shouldSettleNativeDictationForTesting(
          isFinal: true,
          nativeAccumulateResults: true,
          usingServerStt: false,
        ),
      ).isTrue();
    });

    test('keeps voice-call native STT continuous after final chunks', () {
      check(
        VoiceInputService.shouldSettleNativeDictationForTesting(
          isFinal: true,
          nativeAccumulateResults: false,
          usingServerStt: false,
        ),
      ).isFalse();
    });

    test('does not settle server STT through the native final path', () {
      check(
        VoiceInputService.shouldSettleNativeDictationForTesting(
          isFinal: true,
          nativeAccumulateResults: true,
          usingServerStt: true,
        ),
      ).isFalse();
    });
  });

  group('localVoiceRecognitionAvailableProvider', () {
    test('forces a local STT probe even in server-only mode', () async {
      final fakeService = _FakeVoiceInputService(
        hasLocalSttValue: false,
        onDeviceSupportValue: true,
      );
      final container = ProviderContainer(
        overrides: [voiceInputServiceProvider.overrideWithValue(fakeService)],
      );
      addTearDown(container.dispose);

      final available = await container.read(
        localVoiceRecognitionAvailableProvider.future,
      );

      check(available).isTrue();
      check(fakeService.initializeForceLocalSttArgs).deepEquals([true]);
    });
  });
}

class _FakeVoiceInputService extends VoiceInputService {
  _FakeVoiceInputService({
    required this.hasLocalSttValue,
    required this.onDeviceSupportValue,
  });

  final bool hasLocalSttValue;
  final bool onDeviceSupportValue;
  final List<bool> initializeForceLocalSttArgs = <bool>[];

  @override
  bool get hasLocalStt => hasLocalSttValue;

  @override
  Future<bool> initialize({bool forceLocalStt = false}) async {
    initializeForceLocalSttArgs.add(forceLocalStt);
    return true;
  }

  @override
  Future<bool> checkOnDeviceSupport() async => onDeviceSupportValue;

  @override
  Future<void> dispose() async {}
}
