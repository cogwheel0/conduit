import 'package:checks/checks.dart';
import 'package:conduit/features/chat/services/voice_input_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:vad/vad.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Regression guard for issue #557: on a fresh install iOS reports the mic
  // permission as "denied" (not-determined). checkPermissions() must actively
  // REQUEST the permission so the system dialog appears, rather than only
  // reading the current status and silently failing the voice flow.
  group('VoiceInputService.checkPermissions', () {
    late _MockPermissionHandlerPlatform mockPermissions;
    late PermissionHandlerPlatform originalPlatform;

    setUpAll(() {
      registerFallbackValue(<Permission>[Permission.microphone]);
    });

    setUp(() {
      originalPlatform = PermissionHandlerPlatform.instance;
      mockPermissions = _MockPermissionHandlerPlatform();
      PermissionHandlerPlatform.instance = mockPermissions;
    });

    tearDown(() {
      PermissionHandlerPlatform.instance = originalPlatform;
    });

    test('requests the microphone dialog when status is not granted', () async {
      when(
        () => mockPermissions.checkPermissionStatus(Permission.microphone),
      ).thenAnswer((_) async => PermissionStatus.denied);
      when(
        () => mockPermissions.requestPermissions(any()),
      ).thenAnswer(
        (_) async => {Permission.microphone: PermissionStatus.granted},
      );

      final granted = await VoiceInputService().checkPermissions();

      check(granted).isTrue();
      // The core of the bug: it must call requestPermissions, not just read.
      verify(() => mockPermissions.requestPermissions(any())).called(1);
    });

    test('does not re-prompt when permission is already granted', () async {
      when(
        () => mockPermissions.checkPermissionStatus(Permission.microphone),
      ).thenAnswer((_) async => PermissionStatus.granted);

      final granted = await VoiceInputService().checkPermissions();

      check(granted).isTrue();
      verifyNever(() => mockPermissions.requestPermissions(any()));
    });

    test(
      'returns false without granting when the user denies the request',
      () async {
        when(
          () => mockPermissions.checkPermissionStatus(Permission.microphone),
        ).thenAnswer((_) async => PermissionStatus.denied);
        when(
          () => mockPermissions.requestPermissions(any()),
        ).thenAnswer(
          (_) async => {Permission.microphone: PermissionStatus.denied},
        );

        final granted = await VoiceInputService().checkPermissions();

        check(granted).isFalse();
        verify(() => mockPermissions.requestPermissions(any())).called(1);
      },
    );
  });
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
    test('uses explicit STT language', () {
      final language = VoiceInputService.resolveServerLanguageHint(
        configuredLanguageCode: 'PL',
      );

      check(language).equals('pl');
    });

    test('omits language when no explicit language is set', () {
      final language = VoiceInputService.resolveServerLanguageHint(
        configuredLanguageCode: null,
      );

      check(language).isNull();
    });

    test('omits language for auto-like inputs', () {
      final language = VoiceInputService.resolveServerLanguageHint(
        configuredLanguageCode: 'auto',
      );

      check(language).isNull();
    });
  });

  group('VoiceInputService server STT consumers', () {
    test('processes samples for a live-mode event-only consumer', () {
      check(
        VoiceInputService.shouldProcessServerSamplesForTesting(
          hasTextConsumer: false,
          hasTranscriptEventConsumer: true,
        ),
      ).isTrue();
    });

    test('processes samples for the normal text consumer', () {
      check(
        VoiceInputService.shouldProcessServerSamplesForTesting(
          hasTextConsumer: true,
          hasTranscriptEventConsumer: false,
        ),
      ).isTrue();
    });

    test('skips samples when every consumer has detached', () {
      check(
        VoiceInputService.shouldProcessServerSamplesForTesting(
          hasTextConsumer: false,
          hasTranscriptEventConsumer: false,
        ),
      ).isFalse();
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

class _MockPermissionHandlerPlatform extends Mock
    with MockPlatformInterfaceMixin
    implements PermissionHandlerPlatform {}
