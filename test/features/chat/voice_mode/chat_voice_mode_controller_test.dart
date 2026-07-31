import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/providers/backend_mode_providers.dart';
import 'package:conduit/core/services/callkit_service.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/services/text_to_speech_service.dart';
import 'package:conduit/features/chat/services/voice_input_service.dart';
import 'package:conduit/features/chat/voice_call/voice_call_eligibility.dart';
import 'package:conduit/features/chat/voice_call/presentation/voice_call_launcher.dart';
import 'package:conduit/features/chat/voice_mode/chat_voice_audio_session_coordinator.dart';
import 'package:conduit/features/chat/voice_mode/chat_voice_mode_controller.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/openwebui_storage_test_overrides.dart';

const _model = Model(id: 'test-model', name: 'Test Model');

final _voiceReadinessTestProvider = FutureProvider<VoiceCallEligibility>(
  resolveVoiceCallEligibility,
);
final _boundedVoiceReadinessTestProvider = FutureProvider<VoiceCallEligibility>(
  (ref) => resolveVoiceCallEligibility(
    ref,
    readinessTimeout: const Duration(milliseconds: 10),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cancelSpeaking before start is an idempotent no-op', () async {
    final tts = _FakeTextToSpeechService();
    final container = ProviderContainer(
      overrides: [
        textToSpeechServiceProvider.overrideWithValue(tts),
        chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
          _FakeChatVoiceBackgroundCoordinator(),
        ),
        chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
          _FakeChatVoiceAudioSessionCoordinator(),
        ),
      ],
    );
    addTearDown(container.dispose);

    final controller = container.read(chatVoiceModeControllerProvider.notifier);

    await controller.cancelSpeaking();

    check(
      container.read(chatVoiceModeControllerProvider).phase,
    ).equals(ChatVoiceModePhase.idle);
    check(tts.stopStreamingCalls).equals(0);
    check(tts.stopCalls).equals(0);
  });

  test('launcher starts voice mode for signed-out Hermes', () async {
    final input = _FakeVoiceInputService();
    final tts = _FakeTextToSpeechService();
    final audioSession = _FakeChatVoiceAudioSessionCoordinator();
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(),
        authNavigationStateProvider.overrideWithValue(
          AuthNavigationState.needsLogin,
        ),
        reviewerModeProvider.overrideWithValue(false),
        selectedModelProvider.overrideWithValue(hermesSyntheticModel()),
        hermesConfigProvider.overrideWith(
          () => _FixedHermesConfig(_usableHermesConfig),
        ),
        hermesSecretsLoadingProvider.overrideWith(_SettledHermesSecrets.new),
        socketServiceProvider.overrideWithValue(null),
        appSettingsProvider.overrideWithValue(const AppSettings()),
        voiceInputServiceProvider.overrideWithValue(input),
        textToSpeechServiceProvider.overrideWithValue(tts),
        callKitServiceProvider.overrideWithValue(_UnavailableCallKitService()),
        chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
          _FakeChatVoiceBackgroundCoordinator(),
        ),
        chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
          audioSession,
        ),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(voiceCallLauncherProvider)
        .launch(startNewConversation: false);

    check(input.beginCalls).equals(1);
    check(audioSession.listeningCalls).equals(1);
    check(
      container.read(chatVoiceModeControllerProvider).phase,
    ).equals(ChatVoiceModePhase.listening);
    await container.read(chatVoiceModeControllerProvider.notifier).stop();
  });

  test('launcher propagates controller-side start failure', () async {
    final container = ProviderContainer(
      overrides: [
        authNavigationStateProvider.overrideWithValue(
          AuthNavigationState.authenticated,
        ),
        reviewerModeProvider.overrideWithValue(false),
        selectedModelProvider.overrideWithValue(_model),
        socketServiceProvider.overrideWithValue(null),
        chatVoiceModeControllerProvider.overrideWith(
          _RejectedVoiceStartController.new,
        ),
      ],
    );
    addTearDown(container.dispose);

    await expectLater(
      container
          .read(voiceCallLauncherProvider)
          .launch(startNewConversation: false),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Rejected test voice start.',
        ),
      ),
    );
  });

  test('start cancels cleanly when its external owner disconnects', () async {
    final input = _FakeVoiceInputService()..initializeGate = Completer<bool>();
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(),
        authNavigationStateProvider.overrideWithValue(
          AuthNavigationState.authenticated,
        ),
        reviewerModeProvider.overrideWithValue(true),
        selectedModelProvider.overrideWithValue(_model),
        appSettingsProvider.overrideWithValue(const AppSettings()),
        voiceInputServiceProvider.overrideWithValue(input),
        textToSpeechServiceProvider.overrideWithValue(
          _FakeTextToSpeechService(),
        ),
        callKitServiceProvider.overrideWithValue(_UnavailableCallKitService()),
        chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
          _FakeChatVoiceBackgroundCoordinator(),
        ),
        chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
          _FakeChatVoiceAudioSessionCoordinator(),
        ),
      ],
    );
    addTearDown(container.dispose);

    final conversation = Conversation(
      id: 'existing-chat',
      title: 'Existing chat',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
    );
    container.read(activeConversationProvider.notifier).set(conversation);
    var connected = true;
    final start = container
        .read(chatVoiceModeControllerProvider.notifier)
        .start(startNewConversation: true, shouldStart: () => connected);
    await _until(() => input.initializeCalls == 1);
    connected = false;
    input.initializeGate!.complete(true);

    check(await start).equals(ChatVoiceModeStartResult.cancelled);
    check(input.beginCalls).equals(0);
    check(
      container.read(chatVoiceModeControllerProvider).phase,
    ).equals(ChatVoiceModePhase.ended);
    check(
      container.read(activeConversationProvider)?.id,
    ).equals(conversation.id);
  });

  test('voice eligibility allows trusted device Direct while signed out', () {
    final registry = DirectModelRegistry();
    final model = registry.replaceProfileModels(_directProfile, [
      DirectRemoteModel(id: 'voice-model'),
    ]).single;
    final container = ProviderContainer(
      overrides: [
        authNavigationStateProvider.overrideWithValue(
          AuthNavigationState.needsLogin,
        ),
        reviewerModeProvider.overrideWithValue(false),
        selectedModelProvider.overrideWithValue(model),
        directModelRegistryProvider.overrideWithValue(registry),
        directModelDiscoveryProvider.overrideWith(_DirectDiscoverySignal.new),
      ],
    );
    addTearDown(container.dispose);

    final eligibility = container.read(voiceCallEligibilityProvider);

    check(eligibility.canStart).isTrue();
    check(eligibility.model).identicalTo(model);
  });

  test('voice eligibility still rejects signed-out OpenWebUI', () {
    final container = ProviderContainer(
      overrides: [
        authNavigationStateProvider.overrideWithValue(
          AuthNavigationState.needsLogin,
        ),
        reviewerModeProvider.overrideWithValue(false),
        selectedModelProvider.overrideWithValue(_model),
      ],
    );
    addTearDown(container.dispose);

    final eligibility = container.read(voiceCallEligibilityProvider);

    check(eligibility.canStart).isFalse();
    check(
      eligibility.reason,
    ).equals(VoiceCallEligibilityReason.authenticationRequired);
    check(eligibility.errorMessage).equals('Sign in to start a voice call.');
  });

  test('voice eligibility explains incomplete Hermes configuration', () {
    final container = ProviderContainer(
      overrides: [
        authNavigationStateProvider.overrideWithValue(
          AuthNavigationState.needsLogin,
        ),
        reviewerModeProvider.overrideWithValue(false),
        selectedModelProvider.overrideWithValue(hermesSyntheticModel()),
        hermesConfigProvider.overrideWith(
          () => _FixedHermesConfig(
            const HermesConfig(
              enabled: true,
              baseUrl: 'https://hermes.example/v1',
            ),
          ),
        ),
        hermesSecretsLoadingProvider.overrideWith(_SettledHermesSecrets.new),
      ],
    );
    addTearDown(container.dispose);

    final eligibility = container.read(voiceCallEligibilityProvider);

    check(eligibility.canStart).isFalse();
    check(
      eligibility.reason,
    ).equals(VoiceCallEligibilityReason.backendUnavailable);
    check(eligibility.errorMessage).isNotNull().contains('Hermes');
  });

  test('voice readiness waits for Hermes secrets to hydrate', () async {
    final container = ProviderContainer(
      overrides: [
        authNavigationStateProvider.overrideWithValue(
          AuthNavigationState.needsLogin,
        ),
        reviewerModeProvider.overrideWithValue(false),
        selectedModelProvider.overrideWithValue(hermesSyntheticModel()),
        hermesConfigProvider.overrideWith(_HydratingHermesConfig.new),
        hermesSecretsLoadingProvider.overrideWith(_LoadingHermesSecrets.new),
      ],
    );
    addTearDown(container.dispose);

    var completed = false;
    final readiness = container.read(_voiceReadinessTestProvider.future).then((
      value,
    ) {
      completed = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    check(completed).isFalse();

    (container.read(hermesConfigProvider.notifier) as _HydratingHermesConfig)
        .finishHydration();
    container.read(hermesSecretsLoadingProvider.notifier).set(false);
    final eligibility = await readiness;

    check(eligibility.canStart).isTrue();
  });

  test(
    'voice readiness restores Hermes model after cold-start hydration',
    () async {
      final container = ProviderContainer(
        overrides: [
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.loading,
          ),
          reviewerModeProvider.overrideWithValue(false),
          preferredBackendProvider.overrideWith(_HermesPreferredBackend.new),
          selectedModelProvider.overrideWith(_NullSelectedModel.new),
          isManualModelSelectionProvider.overrideWith(
            _ManualModelSelection.new,
          ),
          hermesConfigProvider.overrideWith(_HydratingHermesConfig.new),
          hermesSecretsLoadingProvider.overrideWith(_LoadingHermesSecrets.new),
        ],
      );
      addTearDown(container.dispose);

      var completed = false;
      final readiness = container.read(_voiceReadinessTestProvider.future).then(
        (value) {
          completed = true;
          return value;
        },
      );
      await Future<void>.delayed(Duration.zero);
      check(completed).isFalse();

      (container.read(hermesConfigProvider.notifier) as _HydratingHermesConfig)
          .finishHydration();
      container.read(hermesSecretsLoadingProvider.notifier).set(false);
      final eligibility = await readiness;

      check(eligibility.canStart).isTrue();
      check(eligibility.model)
          .isNotNull()
          .has((model) => model.id, 'id')
          .equals(hermesSyntheticModel().id);
      check(container.read(isManualModelSelectionProvider)).isFalse();
    },
  );

  test(
    'voice readiness restores device Direct model while OWUI auth loads',
    () async {
      final registry = DirectModelRegistry();
      final model = registry.replaceProfileModels(_directProfile, [
        DirectRemoteModel(id: 'cold-start-voice-model'),
      ]).single;
      final container = ProviderContainer(
        overrides: [
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.loading,
          ),
          reviewerModeProvider.overrideWithValue(false),
          preferredBackendProvider.overrideWith(_DirectPreferredBackend.new),
          selectedModelProvider.overrideWith(_NullSelectedModel.new),
          isManualModelSelectionProvider.overrideWith(
            _ManualModelSelection.new,
          ),
          directModelRegistryProvider.overrideWithValue(registry),
          directModelDiscoveryProvider.overrideWith(
            () => _FixedDirectDiscovery(model),
          ),
          appSettingsProvider.overrideWithValue(
            AppSettings(defaultModel: model.id),
          ),
        ],
      );
      addTearDown(container.dispose);

      final eligibility = await container.read(
        _voiceReadinessTestProvider.future,
      );

      check(eligibility.canStart).isTrue();
      check(eligibility.model?.id).equals(model.id);
      check(container.read(isManualModelSelectionProvider)).isFalse();
    },
  );

  test(
    'voice readiness stops when Hermes model restoration is rejected',
    () async {
      final container = ProviderContainer(
        overrides: [
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.loading,
          ),
          reviewerModeProvider.overrideWithValue(false),
          preferredBackendProvider.overrideWith(_HermesPreferredBackend.new),
          selectedModelProvider.overrideWith(_IgnoringSelectedModel.new),
          isManualModelSelectionProvider.overrideWith(
            _ManualModelSelection.new,
          ),
          hermesConfigProvider.overrideWith(
            () => _FixedHermesConfig(_usableHermesConfig),
          ),
          hermesSecretsLoadingProvider.overrideWith(_SettledHermesSecrets.new),
        ],
      );
      addTearDown(container.dispose);

      final eligibility = await container
          .read(_boundedVoiceReadinessTestProvider.future)
          .timeout(const Duration(seconds: 1));

      check(eligibility.canStart).isFalse();
      check(
        eligibility.reason,
      ).equals(VoiceCallEligibilityReason.modelRequired);
    },
  );

  test(
    'sends transcript through chat voice mode and resumes listening',
    () async {
      final input = _FakeVoiceInputService();
      final tts = _FakeTextToSpeechService();
      final audioSession = _FakeChatVoiceAudioSessionCoordinator();
      final container = ProviderContainer(
        overrides: [
          ...openWebUiStorageOpenOverrides(),
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.authenticated,
          ),
          selectedModelProvider.overrideWithValue(_model),
          appSettingsProvider.overrideWithValue(const AppSettings()),
          reviewerModeProvider.overrideWithValue(true),
          voiceInputServiceProvider.overrideWithValue(input),
          textToSpeechServiceProvider.overrideWithValue(tts),
          callKitServiceProvider.overrideWithValue(
            _UnavailableCallKitService(),
          ),
          chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
            _FakeChatVoiceBackgroundCoordinator(),
          ),
          chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
            audioSession,
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(
        chatVoiceModeControllerProvider.notifier,
      );

      await controller.start(startNewConversation: false);
      expect(input.beginCalls, 1);
      expect(audioSession.listeningCalls, 1);
      expect(
        container.read(chatVoiceModeControllerProvider).phase,
        ChatVoiceModePhase.listening,
      );

      await input.completeCurrent('hello assistant');
      await _until(() => tts.finishedTexts.isNotEmpty);

      final messages = container.read(chatMessagesProvider);
      expect(messages.first.content, 'hello assistant');
      expect(messages.first.role, 'user');
      expect(messages.last.role, 'assistant');
      expect(messages.last.isStreaming, isFalse);
      expect(tts.startedStreaming, isTrue);
      expect(tts.fedTexts.join('\n'), contains('Conduit'));

      await _until(() => input.beginCalls == 2);
      expect(
        container.read(chatVoiceModeControllerProvider).phase,
        ChatVoiceModePhase.listening,
      );
    },
  );

  test(
    'second voice turn does not replay the first assistant response',
    () async {
      final input = _FakeVoiceInputService();
      final tts = _FakeTextToSpeechService();
      final audioSession = _FakeChatVoiceAudioSessionCoordinator();
      final container = ProviderContainer(
        overrides: [
          ...openWebUiStorageOpenOverrides(),
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.authenticated,
          ),
          selectedModelProvider.overrideWithValue(_model),
          appSettingsProvider.overrideWithValue(const AppSettings()),
          reviewerModeProvider.overrideWithValue(true),
          voiceInputServiceProvider.overrideWithValue(input),
          textToSpeechServiceProvider.overrideWithValue(tts),
          callKitServiceProvider.overrideWithValue(
            _UnavailableCallKitService(),
          ),
          chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
            _FakeChatVoiceBackgroundCoordinator(),
          ),
          chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
            audioSession,
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(
        chatVoiceModeControllerProvider.notifier,
      );

      await controller.start(startNewConversation: false);
      await input.completeCurrent('alpha unique voice turn');
      await _until(() => tts.finishedTexts.length == 1);
      expect(audioSession.speakingCalls, greaterThanOrEqualTo(1));
      final firstSpoken = tts.finishedTexts.single ?? '';
      expect(firstSpoken, contains('alpha unique voice turn'));

      await _until(() => input.beginCalls == 2);
      await input.completeCurrent('bravo unique voice turn');
      await _until(() => tts.finishedTexts.length == 2);
      final secondSpoken = tts.finishedTexts.last ?? '';

      expect(secondSpoken, contains('bravo unique voice turn'));
      expect(secondSpoken, isNot(contains('alpha unique voice turn')));
    },
  );

  test(
    'does not send partial-only transcript when listening completes',
    () async {
      final input = _FakeVoiceInputService();
      final tts = _FakeTextToSpeechService();
      final audioSession = _FakeChatVoiceAudioSessionCoordinator();
      final container = ProviderContainer(
        overrides: [
          ...openWebUiStorageOpenOverrides(),
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.authenticated,
          ),
          selectedModelProvider.overrideWithValue(_model),
          appSettingsProvider.overrideWithValue(const AppSettings()),
          reviewerModeProvider.overrideWithValue(true),
          voiceInputServiceProvider.overrideWithValue(input),
          textToSpeechServiceProvider.overrideWithValue(tts),
          callKitServiceProvider.overrideWithValue(
            _UnavailableCallKitService(),
          ),
          chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
            _FakeChatVoiceBackgroundCoordinator(),
          ),
          chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
            audioSession,
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(
        chatVoiceModeControllerProvider.notifier,
      );

      await controller.start(startNewConversation: false);
      await input.completeCurrent('partial transcript', finalResult: false);
      await _until(() => input.beginCalls == 2);

      check(container.read(chatMessagesProvider)).isEmpty();
      check(tts.startedStreaming).isFalse();
      check(
        container.read(chatVoiceModeControllerProvider).phase,
      ).equals(ChatVoiceModePhase.listening);
    },
  );

  test(
    'native continuous STT sends finals without restarting the recognizer',
    () async {
      final input = _FakeVoiceInputService()..nativeLocalStt = true;
      final tts = _FakeTextToSpeechService();
      final audioSession = _FakeChatVoiceAudioSessionCoordinator();
      final container = ProviderContainer(
        overrides: [
          ...openWebUiStorageOpenOverrides(),
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.authenticated,
          ),
          selectedModelProvider.overrideWithValue(_model),
          appSettingsProvider.overrideWithValue(const AppSettings()),
          reviewerModeProvider.overrideWithValue(true),
          voiceInputServiceProvider.overrideWithValue(input),
          textToSpeechServiceProvider.overrideWithValue(tts),
          callKitServiceProvider.overrideWithValue(
            _UnavailableCallKitService(),
          ),
          chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
            _FakeChatVoiceBackgroundCoordinator(),
          ),
          chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
            audioSession,
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(
        chatVoiceModeControllerProvider.notifier,
      );

      await controller.start(startNewConversation: false);
      input.stopCalls = 0;
      await input.completeCurrent('continuous final', close: false);
      await _until(() => tts.finishedTexts.isNotEmpty);
      await _until(
        () =>
            container.read(chatVoiceModeControllerProvider).phase ==
            ChatVoiceModePhase.listening,
      );

      check(
        container.read(chatMessagesProvider).first.content,
      ).equals('continuous final');
      check(input.beginCalls).equals(1);
      check(input.stopCalls).equals(0);
      check(input.isListening).isTrue();
      await controller.stop();
    },
  );

  test(
    'queues final transcripts that arrive while the previous final is sending',
    () async {
      final input = _FakeVoiceInputService()..nativeLocalStt = true;
      final tts = _FakeTextToSpeechService()..holdCompletion = true;
      final audioSession = _FakeChatVoiceAudioSessionCoordinator();
      var stopGenerationCalls = 0;
      final container = ProviderContainer(
        overrides: [
          ...openWebUiStorageOpenOverrides(),
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.authenticated,
          ),
          selectedModelProvider.overrideWithValue(_model),
          appSettingsProvider.overrideWithValue(const AppSettings()),
          reviewerModeProvider.overrideWithValue(true),
          voiceInputServiceProvider.overrideWithValue(input),
          textToSpeechServiceProvider.overrideWithValue(tts),
          stopGenerationProvider.overrideWithValue(() {
            stopGenerationCalls += 1;
          }),
          callKitServiceProvider.overrideWithValue(
            _UnavailableCallKitService(),
          ),
          chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
            _FakeChatVoiceBackgroundCoordinator(),
          ),
          chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
            audioSession,
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(
        chatVoiceModeControllerProvider.notifier,
      );

      await controller.start(startNewConversation: false);
      await input.completeCurrent('first queued final', close: false);
      await input.completeCurrent('second queued final', close: false);
      await input.completeCurrent('third queued final', close: false);
      await _until(
        () =>
            container
                .read(chatMessagesProvider)
                .where((message) => message.role == 'user')
                .length ==
            3,
      );

      final userMessages = container
          .read(chatMessagesProvider)
          .where((message) => message.role == 'user')
          .map((message) => message.content)
          .toList();
      check(userMessages).deepEquals(<String>[
        'first queued final',
        'second queued final',
        'third queued final',
      ]);
      await _until(() => tts.finishedTexts.length == 3);
      check(stopGenerationCalls).equals(2);
      check(input.beginCalls).equals(1);
      await controller.stop();
    },
  );

  test(
    'barge-in stops assistant playback and sends the next final transcript',
    () async {
      final input = _FakeVoiceInputService()..nativeLocalStt = true;
      final tts = _FakeTextToSpeechService()..holdCompletion = true;
      final audioSession = _FakeChatVoiceAudioSessionCoordinator();
      var stopGenerationCalls = 0;
      final container = ProviderContainer(
        overrides: [
          ...openWebUiStorageOpenOverrides(),
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.authenticated,
          ),
          selectedModelProvider.overrideWithValue(_model),
          appSettingsProvider.overrideWithValue(const AppSettings()),
          reviewerModeProvider.overrideWithValue(true),
          voiceInputServiceProvider.overrideWithValue(input),
          textToSpeechServiceProvider.overrideWithValue(tts),
          stopGenerationProvider.overrideWithValue(() {
            stopGenerationCalls += 1;
          }),
          callKitServiceProvider.overrideWithValue(
            _UnavailableCallKitService(),
          ),
          chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
            _FakeChatVoiceBackgroundCoordinator(),
          ),
          chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
            audioSession,
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(
        chatVoiceModeControllerProvider.notifier,
      );

      await controller.start(startNewConversation: false);
      await input.completeCurrent('first assistant turn', close: false);
      await _until(
        () =>
            container.read(chatVoiceModeControllerProvider).phase ==
            ChatVoiceModePhase.speaking,
      );

      await input.completeCurrent('second barge in turn', close: false);
      await _until(() => stopGenerationCalls == 1);
      await _until(
        () =>
            container
                .read(chatMessagesProvider)
                .where((message) => message.role == 'user')
                .length ==
            2,
      );

      final userMessages = container
          .read(chatMessagesProvider)
          .where((message) => message.role == 'user')
          .map((message) => message.content)
          .toList();
      check(
        userMessages,
      ).deepEquals(<String>['first assistant turn', 'second barge in turn']);
      await _until(() => tts.finishedTexts.length == 2);
      check(tts.stopStreamingCalls).equals(1);
      check(tts.stopCalls).equals(1);
      check(input.beginCalls).equals(1);
      await controller.stop();
    },
  );

  test('tracks the spoken assistant chunk and word progress', () async {
    final input = _FakeVoiceInputService();
    final tts = _FakeTextToSpeechService()..holdCompletion = true;
    final audioSession = _FakeChatVoiceAudioSessionCoordinator();
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(),
        authNavigationStateProvider.overrideWithValue(
          AuthNavigationState.authenticated,
        ),
        selectedModelProvider.overrideWithValue(_model),
        appSettingsProvider.overrideWithValue(const AppSettings()),
        reviewerModeProvider.overrideWithValue(true),
        voiceInputServiceProvider.overrideWithValue(input),
        textToSpeechServiceProvider.overrideWithValue(tts),
        callKitServiceProvider.overrideWithValue(_UnavailableCallKitService()),
        chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
          _FakeChatVoiceBackgroundCoordinator(),
        ),
        chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
          audioSession,
        ),
      ],
    );
    addTearDown(container.dispose);

    final controller = container.read(chatVoiceModeControllerProvider.notifier);

    await controller.start(startNewConversation: false);
    await input.completeCurrent('show karaoke progress');
    await _until(() => tts.fedTexts.isNotEmpty);

    tts.emitChunkStarted(0);
    await _until(
      () => container
          .read(chatVoiceModeControllerProvider)
          .spokenResponse
          .trim()
          .isNotEmpty,
    );

    final spoken = container
        .read(chatVoiceModeControllerProvider)
        .spokenResponse;
    final word = RegExp(r'\S+').firstMatch(spoken)!;
    tts.emitWordProgress(word.start, word.end);
    await _until(
      () =>
          container.read(chatVoiceModeControllerProvider).spokenWordStart ==
          word.start,
    );

    final snapshot = container.read(chatVoiceModeControllerProvider);
    check(snapshot.phase).equals(ChatVoiceModePhase.speaking);
    check(snapshot.spokenResponse).equals(spoken);
    check(snapshot.spokenWordEnd).equals(word.end);

    await controller.stop();
  });

  test(
    'holds a voice background lease and uses managed audio during CallKit session',
    () async {
      final input = _FakeVoiceInputService()
        ..localSttAvailable = false
        ..serverSttAvailable = true
        ..sttPreference = SttPreference.serverOnly;
      final tts = _FakeTextToSpeechService();
      final callKit = _AvailableCallKitService();
      final background = _FakeChatVoiceBackgroundCoordinator();
      final audioSession = _FakeChatVoiceAudioSessionCoordinator();
      final container = ProviderContainer(
        overrides: [
          ...openWebUiStorageOpenOverrides(),
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.authenticated,
          ),
          selectedModelProvider.overrideWithValue(_model),
          appSettingsProvider.overrideWithValue(
            const AppSettings(sttPreference: SttPreference.serverOnly),
          ),
          reviewerModeProvider.overrideWithValue(true),
          voiceInputServiceProvider.overrideWithValue(input),
          textToSpeechServiceProvider.overrideWithValue(tts),
          callKitServiceProvider.overrideWithValue(callKit),
          chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
            background,
          ),
          chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
            audioSession,
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(callKit.dispose);

      final controller = container.read(
        chatVoiceModeControllerProvider.notifier,
      );

      await controller.start(startNewConversation: false);

      expect(background.started, hasLength(1));
      expect(background.started.single.leaseId, startsWith('chat-voice-mode-'));
      expect(background.started.single.requiresMicrophone, isTrue);
      expect(background.externalAudioSessionOwners, contains(false));
      expect(input.managedAudioFlags, <bool>[true]);
      expect(audioSession.listeningCalls, 1);
      await _until(() => callKit.connectedCallIds.contains('call-1'));

      await controller.stop();

      expect(background.stopped, <String>[background.started.single.leaseId]);
      expect(callKit.endedCallIds, <String>['call-1']);
      expect(background.externalAudioSessionOwners.last, isFalse);
      expect(audioSession.deactivateCalls, 1);
    },
  );

  test('pausing during sending defers assistant TTS until resume', () async {
    final input = _FakeVoiceInputService();
    final tts = _FakeTextToSpeechService();
    final audioSession = _FakeChatVoiceAudioSessionCoordinator();
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(),
        authNavigationStateProvider.overrideWithValue(
          AuthNavigationState.authenticated,
        ),
        selectedModelProvider.overrideWithValue(_model),
        appSettingsProvider.overrideWithValue(const AppSettings()),
        reviewerModeProvider.overrideWithValue(true),
        voiceInputServiceProvider.overrideWithValue(input),
        textToSpeechServiceProvider.overrideWithValue(tts),
        callKitServiceProvider.overrideWithValue(_UnavailableCallKitService()),
        chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
          _FakeChatVoiceBackgroundCoordinator(),
        ),
        chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
          audioSession,
        ),
      ],
    );
    addTearDown(container.dispose);

    final controller = container.read(chatVoiceModeControllerProvider.notifier);

    await controller.start(startNewConversation: false);
    await input.completeCurrent('pause while sending unique voice turn');
    await _until(
      () =>
          container.read(chatVoiceModeControllerProvider).phase ==
          ChatVoiceModePhase.sending,
    );

    await controller.pause();
    await Future<void>.delayed(const Duration(milliseconds: 900));

    expect(
      container.read(chatVoiceModeControllerProvider).phase,
      ChatVoiceModePhase.paused,
    );
    expect(tts.pauseCalls, 1);
    expect(tts.fedTexts, isEmpty);
    expect(tts.finishedTexts, isEmpty);

    await controller.resume();
    await _until(() => tts.finishedTexts.isNotEmpty);

    expect(tts.finishedTexts.single, isNotEmpty);
    await _until(() => input.beginCalls == 2);
    expect(
      container.read(chatVoiceModeControllerProvider).phase,
      ChatVoiceModePhase.listening,
    );

    await controller.stop();
  });

  test(
    'stop completes every teardown step and ends CallKit after cleanup errors',
    () async {
      final input = _FakeVoiceInputService();
      final tts = _FakeTextToSpeechService()..throwOnStopStreaming = true;
      final callKit = _AvailableCallKitService()..throwOnEnd = true;
      final background = _FakeChatVoiceBackgroundCoordinator()
        ..throwOnStop = true;
      final audioSession = _FakeChatVoiceAudioSessionCoordinator();
      final container = ProviderContainer(
        overrides: [
          ...openWebUiStorageOpenOverrides(),
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.authenticated,
          ),
          selectedModelProvider.overrideWithValue(_model),
          appSettingsProvider.overrideWithValue(const AppSettings()),
          reviewerModeProvider.overrideWithValue(true),
          voiceInputServiceProvider.overrideWithValue(input),
          textToSpeechServiceProvider.overrideWithValue(tts),
          callKitServiceProvider.overrideWithValue(callKit),
          chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
            background,
          ),
          chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
            audioSession,
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(callKit.dispose);

      final controller = container.read(
        chatVoiceModeControllerProvider.notifier,
      );
      await controller.start(startNewConversation: false);

      await controller.stop();

      check(tts.stopStreamingCalls).equals(1);
      check(tts.stopCalls).equals(1);
      check(background.stopped).length.equals(1);
      check(background.externalAudioSessionOwners.last).isFalse();
      check(audioSession.deactivateCalls).equals(1);
      check(callKit.endedCallIds).deepEquals(<String>['call-1']);
      check(
        container.read(chatVoiceModeControllerProvider).phase,
      ).equals(ChatVoiceModePhase.ended);
    },
  );

  test(
    'listen failure ignores buffered input and preserves the active chat',
    () async {
      final input = _FakeVoiceInputService()
        ..bufferedErrorWhenIntensityStarts = StateError('recognizer failed')
        ..bufferedFinalWhenIntensityStarts = 'must not be sent after failure';
      final tts = _FakeTextToSpeechService();
      final uncaught = <Object>[];
      final existingConversation = Conversation(
        id: 'existing-chat',
        title: 'Existing chat',
        createdAt: DateTime(2024),
        updatedAt: DateTime(2024),
      );
      late List<ChatMessage> messages;
      late ChatVoiceModeSnapshot snapshot;
      late Conversation? activeConversation;

      await runZonedGuarded(() async {
        final container = ProviderContainer(
          overrides: [
            ...openWebUiStorageOpenOverrides(),
            authNavigationStateProvider.overrideWithValue(
              AuthNavigationState.authenticated,
            ),
            selectedModelProvider.overrideWithValue(_model),
            appSettingsProvider.overrideWithValue(const AppSettings()),
            reviewerModeProvider.overrideWithValue(true),
            voiceInputServiceProvider.overrideWithValue(input),
            textToSpeechServiceProvider.overrideWithValue(tts),
            callKitServiceProvider.overrideWithValue(
              _UnavailableCallKitService(),
            ),
            chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
              _FakeChatVoiceBackgroundCoordinator(),
            ),
            chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
              _FakeChatVoiceAudioSessionCoordinator(),
            ),
          ],
        );
        final controller = container.read(
          chatVoiceModeControllerProvider.notifier,
        );
        container
            .read(activeConversationProvider.notifier)
            .set(existingConversation);
        await controller.start(startNewConversation: true);
        await _until(
          () =>
              container.read(chatVoiceModeControllerProvider).phase ==
              ChatVoiceModePhase.error,
        );
        await Future<void>.delayed(Duration.zero);

        messages = container.read(chatMessagesProvider);
        snapshot = container.read(chatVoiceModeControllerProvider);
        activeConversation = container.read(activeConversationProvider);
        container.dispose();
        await Future<void>.delayed(Duration.zero);
      }, (error, stackTrace) => uncaught.add(error));

      check(uncaught).isEmpty();
      check(messages).isEmpty();
      check(tts.startedStreaming).isFalse();
      check(snapshot.errorMessage).isNotNull().contains('recognizer failed');
      check(activeConversation?.id).equals(existingConversation.id);
    },
  );

  test('replacement waits for stale teardown and keeps services live', () async {
    final input = _FakeVoiceInputService();
    final staleTtsGate = Completer<void>();
    final tts = _FakeTextToSpeechService()
      ..firstStopStreamingGate = staleTtsGate;
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(),
        authNavigationStateProvider.overrideWithValue(
          AuthNavigationState.authenticated,
        ),
        selectedModelProvider.overrideWithValue(_model),
        appSettingsProvider.overrideWithValue(const AppSettings()),
        reviewerModeProvider.overrideWithValue(true),
        voiceInputServiceProvider.overrideWithValue(input),
        textToSpeechServiceProvider.overrideWithValue(tts),
        callKitServiceProvider.overrideWithValue(_UnavailableCallKitService()),
        chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
          _FakeChatVoiceBackgroundCoordinator(),
        ),
        chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
          _FakeChatVoiceAudioSessionCoordinator(),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(chatVoiceModeControllerProvider.notifier);

    await controller.start(startNewConversation: false);
    input.emitError(StateError('old session failure'));
    await _until(() => tts.stopStreamingCalls == 1);

    // Stop invalidates the detached failure. The replacement must not reuse
    // either singleton while the old teardown is still blocked in TTS cleanup.
    final stopFuture = controller.stop();
    final replacementStart = controller.start(startNewConversation: false);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    check(input.beginCalls).equals(1);

    staleTtsGate.complete();
    await stopFuture;
    await replacementStart;

    check(
      container.read(chatVoiceModeControllerProvider).phase,
    ).equals(ChatVoiceModePhase.listening);
    check(input.isListening).isTrue();

    await input.completeCurrent('replacement session turn');
    await _until(() => tts.startedStreaming && tts.fedTexts.isNotEmpty);
    check(tts.startedStreaming).isTrue();
    await controller.stop();
  });

  test('recreated controller waits for stale input stop', () async {
    final staleInputGate = Completer<void>();
    final input = _FakeVoiceInputService();
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(),
        authNavigationStateProvider.overrideWithValue(
          AuthNavigationState.authenticated,
        ),
        selectedModelProvider.overrideWithValue(_model),
        appSettingsProvider.overrideWithValue(const AppSettings()),
        reviewerModeProvider.overrideWithValue(true),
        voiceInputServiceProvider.overrideWithValue(input),
        textToSpeechServiceProvider.overrideWithValue(
          _FakeTextToSpeechService(),
        ),
        callKitServiceProvider.overrideWithValue(_UnavailableCallKitService()),
        chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
          _FakeChatVoiceBackgroundCoordinator(),
        ),
        chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
          _FakeChatVoiceAudioSessionCoordinator(),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(chatVoiceModeControllerProvider.notifier);

    await controller.start(startNewConversation: false);
    input.nextStopListeningGate = staleInputGate;
    container.invalidate(chatVoiceModeControllerProvider);
    final replacementController = container.read(
      chatVoiceModeControllerProvider.notifier,
    );
    final replacementStart = replacementController.start(
      startNewConversation: false,
    );
    await _until(() => input.stopCalls == 2);

    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    check(input.beginCalls).equals(1);

    staleInputGate.complete();
    await replacementStart;

    check(
      container.read(chatVoiceModeControllerProvider).phase,
    ).equals(ChatVoiceModePhase.listening);
    check(input.isListening).isTrue();
    await replacementController.stop();
  });

  test('timed-out queued replacement never overlaps stale teardown', () async {
    final staleInputGate = Completer<void>();
    final input = _FakeVoiceInputService();
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(),
        authNavigationStateProvider.overrideWithValue(
          AuthNavigationState.authenticated,
        ),
        selectedModelProvider.overrideWithValue(_model),
        appSettingsProvider.overrideWithValue(const AppSettings()),
        reviewerModeProvider.overrideWithValue(true),
        voiceInputServiceProvider.overrideWithValue(input),
        textToSpeechServiceProvider.overrideWithValue(
          _FakeTextToSpeechService(),
        ),
        callKitServiceProvider.overrideWithValue(_UnavailableCallKitService()),
        chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
          _FakeChatVoiceBackgroundCoordinator(),
        ),
        chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
          _FakeChatVoiceAudioSessionCoordinator(),
        ),
        chatVoiceModeServiceLifecycleTimeoutProvider.overrideWithValue(
          const Duration(milliseconds: 100),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(chatVoiceModeControllerProvider.notifier);

    await controller.start(startNewConversation: false);
    input.nextStopListeningGate = staleInputGate;
    container.invalidate(chatVoiceModeControllerProvider);
    await _until(() => input.stopCalls == 2);

    final replacementController = container.read(
      chatVoiceModeControllerProvider.notifier,
    );
    await replacementController
        .start(startNewConversation: false)
        .timeout(const Duration(seconds: 1));

    check(input.beginCalls).equals(1);
    check(input.isListening).isTrue();
    check(
      container.read(chatVoiceModeControllerProvider).phase,
    ).equals(ChatVoiceModePhase.error);
    check(
      container.read(chatVoiceModeControllerProvider).errorMessage,
    ).isNotNull().contains('timed out');

    staleInputGate.complete();
    await _until(() => !input.isListening);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    check(input.beginCalls).equals(1);
    check(
      container.read(chatVoiceModeControllerProvider).phase,
    ).equals(ChatVoiceModePhase.error);

    await replacementController
        .start(startNewConversation: false)
        .timeout(const Duration(seconds: 1));

    check(input.beginCalls).equals(2);
    check(input.isListening).isTrue();
    check(
      container.read(chatVoiceModeControllerProvider).phase,
    ).equals(ChatVoiceModePhase.listening);
    await replacementController.stop();
  });

  test(
    'provider disposal observes detached lease and audio cleanup errors',
    () async {
      final input = _FakeVoiceInputService();
      final background = _FakeChatVoiceBackgroundCoordinator()
        ..throwOnStop = true
        ..throwWhenReleasingExternalOwner = true;
      final audioSession = _FakeChatVoiceAudioSessionCoordinator()
        ..throwOnDeactivate = true;
      final uncaught = <Object>[];

      await runZonedGuarded(() async {
        final container = ProviderContainer(
          overrides: [
            ...openWebUiStorageOpenOverrides(),
            authNavigationStateProvider.overrideWithValue(
              AuthNavigationState.authenticated,
            ),
            selectedModelProvider.overrideWithValue(_model),
            appSettingsProvider.overrideWithValue(const AppSettings()),
            reviewerModeProvider.overrideWithValue(true),
            voiceInputServiceProvider.overrideWithValue(input),
            textToSpeechServiceProvider.overrideWithValue(
              _FakeTextToSpeechService(),
            ),
            callKitServiceProvider.overrideWithValue(
              _UnavailableCallKitService(),
            ),
            chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
              background,
            ),
            chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
              audioSession,
            ),
          ],
        );

        final controller = container.read(
          chatVoiceModeControllerProvider.notifier,
        );
        await controller.start(startNewConversation: false);
        container.dispose();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
      }, (error, stackTrace) => uncaught.add(error));

      check(background.stopped).length.equals(1);
      check(background.externalAudioSessionOwners.last).isFalse();
      check(audioSession.deactivateCalls).equals(1);
      check(uncaught).isEmpty();
    },
  );
}

const _usableHermesConfig = HermesConfig(
  enabled: true,
  baseUrl: 'https://hermes.example/v1',
  apiKey: 'hermes-key',
);

final _directProfile = DirectConnectionProfile(
  id: 'voice-direct-profile',
  name: 'Voice Direct',
  adapterKey: 'ollama',
  baseUrl: 'http://localhost:11434',
);

class _FixedHermesConfig extends HermesConfigController {
  _FixedHermesConfig(this._config);

  final HermesConfig _config;

  @override
  HermesConfig build() => _config;
}

class _DirectDiscoverySignal extends DirectModelDiscoveryController {
  @override
  Future<DirectModelDiscoveryState> build() async =>
      DirectModelDiscoveryState();
}

class _FixedDirectDiscovery extends DirectModelDiscoveryController {
  _FixedDirectDiscovery(this.model);

  final Model model;

  @override
  Future<DirectModelDiscoveryState> build() async =>
      DirectModelDiscoveryState(models: [model]);
}

class _NullSelectedModel extends SelectedModel {
  @override
  Model? build() => null;
}

class _IgnoringSelectedModel extends _NullSelectedModel {
  @override
  void set(Model? model, {bool allowHidden = false}) {}
}

class _ManualModelSelection extends IsManualModelSelection {
  @override
  bool build() => true;
}

class _RejectedVoiceStartController extends ChatVoiceModeController {
  @override
  ChatVoiceModeSnapshot build() => const ChatVoiceModeSnapshot();

  @override
  Future<ChatVoiceModeStartResult> start({
    required bool startNewConversation,
    bool Function()? shouldStart,
    bool readinessResolved = false,
  }) async {
    state = const ChatVoiceModeSnapshot(
      phase: ChatVoiceModePhase.error,
      errorMessage: 'Rejected test voice start.',
    );
    return ChatVoiceModeStartResult.failed;
  }
}

class _HermesPreferredBackend extends PreferredBackendController {
  @override
  PreferredBackend build() => PreferredBackend.hermes;
}

class _DirectPreferredBackend extends PreferredBackendController {
  @override
  PreferredBackend build() => PreferredBackend.direct;
}

class _HydratingHermesConfig extends HermesConfigController {
  @override
  HermesConfig build() =>
      const HermesConfig(enabled: true, baseUrl: 'https://hermes.example/v1');

  void finishHydration() {
    state = _usableHermesConfig;
  }
}

class _LoadingHermesSecrets extends HermesSecretsLoading {
  @override
  bool build() => true;
}

class _SettledHermesSecrets extends HermesSecretsLoading {
  @override
  bool build() => false;
}

class _FakeVoiceInputService extends VoiceInputService {
  _FakeVoiceInputService() : super();

  int beginCalls = 0;
  int initializeCalls = 0;
  Completer<bool>? initializeGate;
  bool localSttAvailable = true;
  bool serverSttAvailable = false;
  SttPreference sttPreference = SttPreference.deviceOnly;
  bool completedTranscriptSendable = false;
  bool nativeLocalStt = false;
  bool listening = false;
  int stopCalls = 0;
  Completer<void>? nextStopListeningGate;
  Object? bufferedErrorWhenIntensityStarts;
  String? bufferedFinalWhenIntensityStarts;
  bool _emittedBufferedFailure = false;
  final managedAudioFlags = <bool>[];
  StreamController<VoiceTranscriptEvent>? _transcriptController;
  StreamController<int>? _intensityController;

  @override
  bool get hasLocalStt => localSttAvailable;

  @override
  bool get hasServerStt => serverSttAvailable;

  @override
  SttPreference get preference => sttPreference;

  @override
  bool get prefersServerOnly => sttPreference == SttPreference.serverOnly;

  @override
  bool get prefersDeviceOnly => sttPreference == SttPreference.deviceOnly;

  @override
  bool get lastCompletedTranscriptSendable => completedTranscriptSendable;

  @override
  bool get isUsingNativeLocalStt => nativeLocalStt;

  @override
  bool get isListening => listening;

  @override
  Future<bool> initialize({bool forceLocalStt = false}) async {
    initializeCalls += 1;
    return await initializeGate?.future ?? true;
  }

  @override
  Future<Stream<VoiceTranscriptEvent>> beginListeningEvents({
    bool iosAudioSessionManagedExternally = false,
  }) async {
    beginCalls += 1;
    listening = true;
    completedTranscriptSendable = false;
    managedAudioFlags.add(iosAudioSessionManagedExternally);
    _transcriptController = StreamController<VoiceTranscriptEvent>.broadcast(
      sync: bufferedErrorWhenIntensityStarts != null,
    );
    _intensityController = StreamController<int>.broadcast();
    return _transcriptController!.stream;
  }

  @override
  Stream<int> get intensityStream {
    final error = bufferedErrorWhenIntensityStarts;
    if (!_emittedBufferedFailure && error != null) {
      _emittedBufferedFailure = true;
      final controller = _transcriptController;
      controller?.addError(error, StackTrace.current);
      final finalTranscript = bufferedFinalWhenIntensityStarts;
      if (controller != null && finalTranscript != null) {
        controller.add(
          VoiceTranscriptEvent(text: finalTranscript, isFinal: true),
        );
        completedTranscriptSendable = true;
      }
    }
    return _intensityController?.stream ?? const Stream<int>.empty();
  }

  Future<void> completeCurrent(
    String transcript, {
    bool finalResult = true,
    bool close = true,
  }) async {
    final controller = _transcriptController;
    if (controller == null) return;
    controller.add(
      VoiceTranscriptEvent(text: transcript, isFinal: finalResult),
    );
    completedTranscriptSendable = finalResult;
    if (close) {
      listening = false;
      await controller.close();
    }
  }

  void emitError(Object error) {
    _transcriptController?.addError(error, StackTrace.current);
  }

  @override
  Future<void> stopListening() async {
    stopCalls += 1;
    final stopGate = nextStopListeningGate;
    nextStopListeningGate = null;
    await stopGate?.future;
    listening = false;
    final controller = _transcriptController;
    _transcriptController = null;
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
  }
}

class _FakeTextToSpeechService extends TextToSpeechService {
  _FakeTextToSpeechService() : super();

  final _events = StreamController<TtsEvent>.broadcast();
  final fedTexts = <String>[];
  final finishedTexts = <String?>[];
  bool startedStreaming = false;
  bool holdCompletion = false;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int stopStreamingCalls = 0;
  int stopCalls = 0;
  bool throwOnStopStreaming = false;
  Completer<void>? firstStopStreamingGate;
  bool _didStart = false;

  @override
  Stream<TtsEvent> get events => _events.stream;

  @override
  List<String> splitTextForSpeech(String text) {
    return text
        .split(RegExp(r'(?<=[.!?])\s+|\n+'))
        .map((chunk) => chunk.trim())
        .where((chunk) => chunk.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<bool> initialize({
    String? deviceVoice,
    String? serverVoice,
    double speechRate = 0.5,
    double pitch = 1.0,
    double volume = 1.0,
    TtsEngine engine = TtsEngine.device,
  }) async {
    return true;
  }

  @override
  Future<void> startStreamingTts() async {
    startedStreaming = true;
    _didStart = false;
  }

  @override
  Future<void> feedStreamingText(String accumulatedText) async {
    fedTexts.add(accumulatedText);
    if (!_didStart && accumulatedText.trim().isNotEmpty) {
      _didStart = true;
      _events.add(const TtsStarted());
    }
  }

  @override
  Future<void> finishStreamingTts({String? finalText}) async {
    finishedTexts.add(finalText);
    if (holdCompletion) {
      return;
    }
    _events.add(const TtsCompleted());
  }

  @override
  Future<void> stopStreamingTts() async {
    stopStreamingCalls += 1;
    if (stopStreamingCalls == 1) {
      await firstStopStreamingGate?.future;
    }
    startedStreaming = false;
    if (throwOnStopStreaming) {
      throw StateError('stop streaming TTS failed');
    }
  }

  @override
  Future<void> pause() async {
    pauseCalls += 1;
    _events.add(const TtsPaused());
  }

  @override
  Future<void> resume() async {
    resumeCalls += 1;
    _events.add(const TtsResumed());
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
    startedStreaming = false;
  }

  void emitChunkStarted(int index) {
    _events.add(TtsChunkStarted(index));
  }

  void emitWordProgress(int start, int end) {
    _events.add(TtsWordProgress(start, end));
  }
}

class _UnavailableCallKitService extends CallKitService {
  @override
  bool get isAvailable => false;

  @override
  Stream<CallEvent> get events => const Stream<CallEvent>.empty();
}

class _AvailableCallKitService extends CallKitService {
  final _events = StreamController<CallEvent>.broadcast();
  final connectedCallIds = <String>[];
  final endedCallIds = <String>[];
  bool throwOnEnd = false;

  @override
  bool get isAvailable => true;

  @override
  Stream<CallEvent> get events => _events.stream;

  @override
  Future<void> checkAndCleanActiveCalls() async {}

  @override
  Future<void> requestPermissions() async {}

  @override
  Future<String?> startOutgoingVoiceCall({
    required String calleeName,
    required String handle,
    String? avatar,
    int? durationMs,
  }) async {
    return 'call-1';
  }

  @override
  Future<void> markCallConnected(String id) async {
    connectedCallIds.add(id);
  }

  @override
  Future<void> endCall(String id) async {
    endedCallIds.add(id);
    if (throwOnEnd) {
      throw StateError('CallKit end failed');
    }
  }

  Future<void> dispose() => _events.close();
}

class _FakeChatVoiceBackgroundCoordinator
    extends ChatVoiceModeBackgroundCoordinator {
  final started = <({String leaseId, bool requiresMicrophone})>[];
  final stopped = <String>[];
  final externalAudioSessionOwners = <bool>[];
  int keepAliveCalls = 0;
  bool throwOnStop = false;
  bool throwWhenReleasingExternalOwner = false;

  @override
  Future<void> startVoiceLease({
    required String leaseId,
    required bool requiresMicrophone,
  }) async {
    started.add((leaseId: leaseId, requiresMicrophone: requiresMicrophone));
  }

  @override
  Future<void> stopVoiceLease(String leaseId) async {
    stopped.add(leaseId);
    if (throwOnStop) {
      throw StateError('background lease stop failed');
    }
  }

  @override
  Future<bool> keepAlive() async {
    keepAliveCalls += 1;
    return true;
  }

  @override
  Future<void> setExternalAudioSessionOwner(bool isExternal) async {
    externalAudioSessionOwners.add(isExternal);
    if (!isExternal && throwWhenReleasingExternalOwner && started.isNotEmpty) {
      throw StateError('external audio owner release failed');
    }
  }
}

class _FakeChatVoiceAudioSessionCoordinator
    extends ChatVoiceAudioSessionCoordinator {
  int listeningCalls = 0;
  int speakingCalls = 0;
  int deactivateCalls = 0;
  bool throwOnDeactivate = false;

  @override
  Future<void> configureForListening() async {
    listeningCalls += 1;
  }

  @override
  Future<void> configureForSpeaking() async {
    speakingCalls += 1;
  }

  @override
  Future<void> deactivate() async {
    deactivateCalls += 1;
    if (throwOnDeactivate) {
      throw StateError('audio session deactivation failed');
    }
  }
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 300; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('Condition was not met.');
}
