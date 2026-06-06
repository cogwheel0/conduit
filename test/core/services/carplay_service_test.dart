import 'dart:async';

import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/carplay_service.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/chat/voice_call/application/voice_call_controller.dart';
import 'package:conduit/features/chat/voice_call/domain/voice_call_models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('conduit/carplay');
const _codec = StandardMethodCodec();
const _model = Model(id: 'test-model', name: 'Test Model');

final _testCarPlayCoordinatorProvider = Provider<CarPlayCoordinator>((ref) {
  final coordinator = CarPlayCoordinator(ref);
  coordinator.initialize();
  return coordinator;
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> platformCalls;

  setUp(() {
    platformCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          platformCalls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  group('CarPlayCoordinator', () {
    test(
      'startVoiceConversation returns auth failure before starting',
      () async {
        final voice = _FakeVoiceCallController();
        final container = _buildContainer(
          voice: voice,
          authState: AuthNavigationState.needsLogin,
        );
        addTearDown(container.dispose);

        final result = await _invokeNative('startVoiceConversation');

        expect(result['success'], isFalse);
        expect(result['error'], contains('sign in'));
        expect(voice.startCalls, 0);
      },
    );

    test(
      'startVoiceConversation returns model failure before starting',
      () async {
        final voice = _FakeVoiceCallController();
        final container = _buildContainer(voice: voice, selectedModel: null);
        addTearDown(container.dispose);

        final result = await _invokeNative('startVoiceConversation');

        expect(result['success'], isFalse);
        expect(result['error'], contains('select a model'));
        expect(voice.startCalls, 0);
      },
    );

    test('disconnect during in-flight start stops the native call', () async {
      final startCompleter = Completer<void>();
      final voice = _FakeVoiceCallController(startCompleter: startCompleter);
      final container = _buildContainer(voice: voice);
      addTearDown(container.dispose);

      final startFuture = _invokeNative('startVoiceConversation');
      await _until(() => voice.startCalls == 1);

      final disconnect = await _invokeNative('carPlaySceneDidDisconnect');
      expect(disconnect['success'], isTrue);

      startCompleter.complete();
      final result = await startFuture;

      expect(result['success'], isFalse);
      expect(result['error'], contains('disconnected'));
      expect(voice.stopCalls, 1);
      expect(voice.stopReasons.single, CallEndReason.nativeSurface);
      expect(voice.startedByStartNewConversation.single, isTrue);
    });

    test(
      'pause and resume fail when current snapshot disallows them',
      () async {
        final voice = _FakeVoiceCallController();
        final container = _buildContainer(voice: voice);
        addTearDown(container.dispose);

        final pause = await _invokeNative('pauseVoiceConversation');
        final resume = await _invokeNative('resumeVoiceConversation');

        expect(pause['success'], isFalse);
        expect(pause['error'], contains('not currently listening'));
        expect(resume['success'], isFalse);
        expect(resume['error'], contains('No paused'));
        expect(voice.pauseCalls, 0);
        expect(voice.resumeCalls, 0);
      },
    );

    test('snapshot emission dedupes equivalent payloads', () async {
      final voice = _FakeVoiceCallController();
      final container = _buildContainer(voice: voice);
      addTearDown(container.dispose);
      await _flushMicrotasks(3);
      platformCalls.clear();

      voice.setSnapshot(const VoiceCallSnapshot(phase: CallPhase.listening));
      await _flushMicrotasks(3);
      voice.setSnapshot(
        const VoiceCallSnapshot(
          phase: CallPhase.listening,
          transcript: 'payload-ignored-by-carplay',
        ),
      );
      await _flushMicrotasks(3);

      final stateCalls = platformCalls
          .where((call) => call.method == 'voiceConversationStateChanged')
          .toList();
      expect(stateCalls, hasLength(1));
      expect(stateCalls.single.arguments, containsPair('phase', 'listening'));
    });
  });
}

ProviderContainer _buildContainer({
  required _FakeVoiceCallController voice,
  AuthNavigationState authState = AuthNavigationState.authenticated,
  Model? selectedModel = _model,
}) {
  final container = ProviderContainer(
    overrides: [
      voiceCallControllerProvider.overrideWith(() => voice),
      authNavigationStateProvider.overrideWithValue(authState),
      selectedModelProvider.overrideWithValue(selectedModel),
      defaultModelProvider.overrideWith((ref) => selectedModel),
    ],
  );
  container.read(_testCarPlayCoordinatorProvider);
  return container;
}

Future<Map<String, Object?>> _invokeNative(String method) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final data = _codec.encodeMethodCall(MethodCall(method));
  final completer = Completer<ByteData?>();
  await messenger.handlePlatformMessage(
    'conduit/carplay',
    data,
    completer.complete,
  );
  final response = await completer.future;
  final decoded = _codec.decodeEnvelope(response!);
  return Map<String, Object?>.from(decoded as Map);
}

Future<void> _flushMicrotasks(int count) async {
  for (var i = 0; i < count; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 20; i++) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('Condition was not met.');
}

final class _FakeVoiceCallController extends VoiceCallController {
  _FakeVoiceCallController({this.startCompleter});

  final Completer<void>? startCompleter;
  final startedByStartNewConversation = <bool>[];
  final stopReasons = <CallEndReason>[];
  int startCalls = 0;
  int stopCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;

  @override
  VoiceCallSnapshot build() => const VoiceCallSnapshot();

  @override
  Future<void> start({required bool startNewConversation}) async {
    startCalls += 1;
    startedByStartNewConversation.add(startNewConversation);
    await startCompleter?.future;
    state = const VoiceCallSnapshot(phase: CallPhase.listening);
  }

  @override
  Future<void> stop({CallEndReason reason = CallEndReason.user}) async {
    stopCalls += 1;
    stopReasons.add(reason);
    state = const VoiceCallSnapshot(phase: CallPhase.ended);
  }

  @override
  Future<void> pause({CallPauseReason reason = CallPauseReason.user}) async {
    pauseCalls += 1;
    state = const VoiceCallSnapshot(
      phase: CallPhase.paused,
      pauseReasons: {CallPauseReason.user},
    );
  }

  @override
  Future<void> resume({CallPauseReason reason = CallPauseReason.user}) async {
    resumeCalls += 1;
    state = const VoiceCallSnapshot(phase: CallPhase.listening);
  }

  void setSnapshot(VoiceCallSnapshot snapshot) {
    state = snapshot;
  }
}
