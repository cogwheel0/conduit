import 'package:checks/checks.dart';
import 'package:conduit/features/chat/services/voice_input_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
