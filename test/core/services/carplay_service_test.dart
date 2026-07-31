import 'dart:async';

import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/carplay_service.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/chat/voice_mode/chat_voice_mode_controller.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
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
        expect(result['error'], contains('Sign in'));
        expect(voice.startCalls, 0);
      },
    );

    test(
      'startVoiceConversation starts signed-out Hermes voice mode',
      () async {
        final voice = _FakeVoiceCallController();
        final container = _buildContainer(
          voice: voice,
          authState: AuthNavigationState.needsLogin,
          selectedModel: hermesSyntheticModel(),
          hermesConfig: _usableHermesConfig,
        );
        addTearDown(container.dispose);

        final result = await _invokeNative('startVoiceConversation');

        expect(result['success'], isTrue);
        expect(voice.startCalls, 1);
        expect(voice.startedByStartNewConversation.single, isTrue);
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
        expect(result['error'], contains('Choose a model'));
        expect(voice.startCalls, 0);
      },
    );

    test(
      'disconnect during in-flight readiness cancels native start',
      () async {
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
        expect(voice.stopCalls, 0);
        expect(voice.startedByStartNewConversation.single, isTrue);
      },
    );

    test('does not take ownership of an already-active phone call', () async {
      final voice = _FakeVoiceCallController(
        startResult: ChatVoiceModeStartResult.alreadyActive,
      );
      final container = _buildContainer(voice: voice);
      addTearDown(container.dispose);

      final start = await _invokeNative('startVoiceConversation');
      final disconnect = await _invokeNative('carPlaySceneDidDisconnect');

      expect(start['success'], isTrue);
      expect(disconnect['success'], isTrue);
      expect(voice.stopCalls, 0);
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

      voice.setSnapshot(
        const ChatVoiceModeSnapshot(phase: ChatVoiceModePhase.listening),
      );
      await _flushMicrotasks(3);
      voice.setSnapshot(
        const ChatVoiceModeSnapshot(
          phase: ChatVoiceModePhase.listening,
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
  HermesConfig? hermesConfig,
}) {
  final container = ProviderContainer(
    overrides: [
      chatVoiceModeControllerProvider.overrideWith(() => voice),
      authNavigationStateProvider.overrideWithValue(authState),
      reviewerModeProvider.overrideWithValue(false),
      selectedModelProvider.overrideWithValue(selectedModel),
      defaultModelProvider.overrideWith((ref) => selectedModel),
      if (hermesConfig != null)
        hermesConfigProvider.overrideWith(
          () => _FixedHermesConfig(hermesConfig),
        ),
      if (hermesConfig != null)
        hermesSecretsLoadingProvider.overrideWith(_SettledHermesSecrets.new),
    ],
  );
  container.read(_testCarPlayCoordinatorProvider);
  return container;
}

const _usableHermesConfig = HermesConfig(
  enabled: true,
  baseUrl: 'https://hermes.example/v1',
  apiKey: 'hermes-key',
);

final class _FixedHermesConfig extends HermesConfigController {
  _FixedHermesConfig(this._config);

  final HermesConfig _config;

  @override
  HermesConfig build() => _config;
}

final class _SettledHermesSecrets extends HermesSecretsLoading {
  @override
  bool build() => false;
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

final class _FakeVoiceCallController extends ChatVoiceModeController {
  _FakeVoiceCallController({
    this.startCompleter,
    this.startResult = ChatVoiceModeStartResult.started,
  });

  final Completer<void>? startCompleter;
  final ChatVoiceModeStartResult startResult;
  final startedByStartNewConversation = <bool>[];
  int startCalls = 0;
  int stopCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;

  @override
  ChatVoiceModeSnapshot build() => const ChatVoiceModeSnapshot();

  @override
  Future<ChatVoiceModeStartResult> start({
    required bool startNewConversation,
    bool Function()? shouldStart,
    bool readinessResolved = false,
  }) async {
    startCalls += 1;
    startedByStartNewConversation.add(startNewConversation);
    await startCompleter?.future;
    if (shouldStart != null && !shouldStart()) {
      return ChatVoiceModeStartResult.cancelled;
    }
    if (startResult == ChatVoiceModeStartResult.started ||
        startResult == ChatVoiceModeStartResult.alreadyActive) {
      state = const ChatVoiceModeSnapshot(phase: ChatVoiceModePhase.listening);
    } else if (startResult == ChatVoiceModeStartResult.failed) {
      state = const ChatVoiceModeSnapshot(
        phase: ChatVoiceModePhase.error,
        errorMessage: 'Unable to start test voice call.',
      );
    }
    return startResult;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
    state = const ChatVoiceModeSnapshot(phase: ChatVoiceModePhase.ended);
  }

  @override
  Future<void> pause() async {
    pauseCalls += 1;
    state = const ChatVoiceModeSnapshot(phase: ChatVoiceModePhase.paused);
  }

  @override
  Future<void> resume() async {
    resumeCalls += 1;
    state = const ChatVoiceModeSnapshot(phase: ChatVoiceModePhase.listening);
  }

  void setSnapshot(ChatVoiceModeSnapshot snapshot) {
    state = snapshot;
  }
}
