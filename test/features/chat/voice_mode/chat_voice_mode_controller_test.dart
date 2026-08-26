import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/providers/backend_mode_providers.dart';
import 'package:conduit/core/services/callkit_service.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/core/services/socket_service.dart';
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
import 'package:flutter/widgets.dart';

import '../../../support/openwebui_storage_test_overrides.dart';

const _model = Model(id: 'test-model', name: 'Test Model');
const _fallbackModel = Model(id: 'fallback-model', name: 'Fallback Model');

final _voiceReadinessTestProvider = FutureProvider<VoiceCallEligibility>(
  resolveVoiceCallEligibility,
);
final _boundedVoiceReadinessTestProvider = FutureProvider<VoiceCallEligibility>(
  (ref) => resolveVoiceCallEligibility(
    ref,
    readinessTimeout: const Duration(milliseconds: 10),
  ),
);
final _voiceSocketTestProvider =
    NotifierProvider<_VoiceSocketTestController, SocketService?>(
      _VoiceSocketTestController.new,
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

    check(container.read(chatVoiceModeControllerProvider).phase)
        .equals(ChatVoiceModePhase.idle);
    check(tts.stopStreamingCalls).equals(0);
    check(tts.stopCalls).equals(0);
  });

  test(
    'start requests microphone access before opening its background lease',
    () async {
      final input = _FakeVoiceInputService()..permissionsGranted = false;
      final background = _FakeChatVoiceBackgroundCoordinator();
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(const AppSettings()),
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
            _FakeChatVoiceAudioSessionCoordinator(),
          ),
        ],
      );
      addTearDown(container.dispose);

      final result = await container
          .read(chatVoiceModeControllerProvider.notifier)
          .start(startNewConversation: false, admittedModel: _model);

      check(result).equals(ChatVoiceModeStartResult.failed);
      check(input.permissionCalls).equals(1);
      check(input.beginCalls).equals(0);
      check(background.started).isEmpty();
      check(container.read(chatVoiceModeControllerProvider).phase)
          .equals(ChatVoiceModePhase.error);
    },
  );

  test('voice call follows model and socket ownership changes', () async {
    final hermesModel = hermesSyntheticModel();
    final firstSocket = SocketService(
      serverConfig: const ServerConfig(
        id: 'voice-socket-lease-a',
        name: 'Voice socket lease A',
        url: 'https://example.com',
      ),
    );
    final replacementSocket = SocketService(
      serverConfig: const ServerConfig(
        id: 'voice-socket-lease-b',
        name: 'Voice socket lease B',
        url: 'https://example.com',
      ),
    );
    final container = ProviderContainer(
      overrides: [
        preferredBackendProvider.overrideWith(_DirectPreferredBackend.new),
        selectedModelProvider.overrideWith(
          () => _SeededSelectedModel(hermesModel),
        ),
        socketServiceProvider.overrideWith(
          (ref) => ref.watch(_voiceSocketTestProvider),
        ),
        appSettingsProvider.overrideWithValue(const AppSettings()),
        voiceInputServiceProvider.overrideWithValue(_FakeVoiceInputService()),
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
    addTearDown(firstSocket.dispose);
    addTearDown(replacementSocket.dispose);

    final controller = container.read(chatVoiceModeControllerProvider.notifier);
    check(
      await controller.start(
        startNewConversation: false,
        admittedModel: hermesModel,
      ),
    ).equals(ChatVoiceModeStartResult.started);
    check(firstSocket.backgroundActivityLeaseCount).equals(0);

    container.read(_voiceSocketTestProvider.notifier).set(firstSocket);
    await pumpEventQueue();
    check(firstSocket.backgroundActivityLeaseCount).equals(0);

    container
        .read(selectedModelProvider.notifier)
        .set(_model, allowHidden: true);
    await pumpEventQueue();
    check(firstSocket.backgroundActivityLeaseCount).equals(1);

    container.read(_voiceSocketTestProvider.notifier).set(replacementSocket);
    await pumpEventQueue();
    check(firstSocket.backgroundActivityLeaseCount).equals(0);
    check(replacementSocket.backgroundActivityLeaseCount).equals(1);

    container
        .read(selectedModelProvider.notifier)
        .set(hermesModel, allowHidden: true);
    await pumpEventQueue();
    check(replacementSocket.backgroundActivityLeaseCount).equals(1);
    container
        .read(selectedModelProvider.notifier)
        .set(_model, allowHidden: true);
    await pumpEventQueue();
    check(replacementSocket.backgroundActivityLeaseCount).equals(1);

    await controller.pause();
    check(replacementSocket.backgroundActivityLeaseCount).equals(1);
    await controller.stop();
    check(replacementSocket.backgroundActivityLeaseCount).equals(0);

    check(
      await controller.start(
        startNewConversation: false,
        admittedModel: _model,
      ),
    ).equals(ChatVoiceModeStartResult.started);
    check(replacementSocket.backgroundActivityLeaseCount).equals(1);
    container.dispose();
    check(replacementSocket.backgroundActivityLeaseCount).equals(0);
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
    check(container.read(chatVoiceModeControllerProvider).phase)
        .equals(ChatVoiceModePhase.listening);
    await container.read(chatVoiceModeControllerProvider.notifier).stop();
  });

  test('launcher retains the model admitted before startup', () async {
    final controller = _RecordingVoiceStartController();
    late ProviderContainer container;
    final socket = _SelectionChangingSocketService(() {
      container
          .read(selectedModelProvider.notifier)
          .set(_fallbackModel, allowHidden: true);
    });
    container = ProviderContainer(
      overrides: [
        authNavigationStateProvider.overrideWithValue(
          AuthNavigationState.authenticated,
        ),
        reviewerModeProvider.overrideWithValue(true),
        selectedModelProvider.overrideWith(() => _SeededSelectedModel(_model)),
        socketServiceProvider.overrideWithValue(socket),
        chatVoiceModeControllerProvider.overrideWith(() => controller),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(socket.dispose);

    await container
        .read(voiceCallLauncherProvider)
        .launch(startNewConversation: true);

    check(container.read(selectedModelProvider)).identicalTo(_fallbackModel);
    check(controller.admittedModels.single).identicalTo(_model);
    check(controller.startedByStartNewConversation.single).isTrue();
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
    check(container.read(chatVoiceModeControllerProvider).phase)
        .equals(ChatVoiceModePhase.ended);
    check(container.read(activeConversationProvider)?.id)
        .equals(conversation.id);
  });

  test('stop cancels a start waiting for voice readiness', () async {
    final input = _FakeVoiceInputService();
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(),
        authNavigationStateProvider.overrideWithValue(
          AuthNavigationState.loading,
        ),
        reviewerModeProvider.overrideWithValue(false),
        preferredBackendProvider.overrideWith(_OwuiPreferredBackend.new),
        selectedModelProvider.overrideWith(_NullSelectedModel.new),
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
    final start = controller.start(startNewConversation: false);
    await _until(() => controller.isWaitingForStartReadiness);

    await controller.stop().timeout(const Duration(seconds: 1));

    check(await start.timeout(const Duration(seconds: 1)))
        .equals(ChatVoiceModeStartResult.cancelled);
    check(input.initializeCalls).equals(0);
    check(container.read(chatVoiceModeControllerProvider).phase)
        .equals(ChatVoiceModePhase.idle);
  });

  test(
    'start surfaces eligibility failures before services initialize',
    () async {
      final container = ProviderContainer(
        overrides: [
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.authenticated,
          ),
          reviewerModeProvider.overrideWithValue(true),
          selectedModelProvider.overrideWithValue(_model),
          voiceCallEligibilityProvider.overrideWith((ref) {
            throw StateError('eligibility exploded');
          }),
        ],
      );
      addTearDown(container.dispose);

      final result = await container
          .read(chatVoiceModeControllerProvider.notifier)
          .start(startNewConversation: false);
      final snapshot = container.read(chatVoiceModeControllerProvider);

      check(result).equals(ChatVoiceModeStartResult.failed);
      check(snapshot.phase).equals(ChatVoiceModePhase.error);
      check(snapshot.errorMessage).isNotNull().contains('eligibility exploded');
      check(snapshot.activeCallId).isNull();
    },
  );

  test('timeout clears the active CallKit call from error state', () async {
    final input = _FakeVoiceInputService()
      ..beginListeningError = TimeoutException('voice input timed out');
    final callKit = _AvailableCallKitService();
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
        callKitServiceProvider.overrideWithValue(callKit),
        chatVoiceModeBackgroundCoordinatorProvider.overrideWithValue(
          _FakeChatVoiceBackgroundCoordinator(),
        ),
        chatVoiceAudioSessionCoordinatorProvider.overrideWithValue(
          _FakeChatVoiceAudioSessionCoordinator(),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(callKit.dispose);

    final result = await container
        .read(chatVoiceModeControllerProvider.notifier)
        .start(startNewConversation: false);
    await _until(() => callKit.endedCallIds.contains('call-1'));
    final snapshot = container.read(chatVoiceModeControllerProvider);

    check(result).equals(ChatVoiceModeStartResult.failed);
    check(snapshot.phase).equals(ChatVoiceModePhase.error);
    check(snapshot.errorMessage).equals('Voice services timed out. Try again.');
    check(snapshot.activeCallId).isNull();
  });

  test('stop cancels a start during voice input initialization', () async {
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

    final controller = container.read(chatVoiceModeControllerProvider.notifier);
    final start = controller.start(startNewConversation: false);
    await _until(() => input.initializeCalls == 1);

    final stop = controller.stop();
    input.initializeGate!.complete(true);

    check(await start.timeout(const Duration(seconds: 1)))
        .equals(ChatVoiceModeStartResult.cancelled);
    await stop.timeout(const Duration(seconds: 1));
    check(input.beginCalls).equals(0);
    check(container.read(chatVoiceModeControllerProvider).phase)
        .equals(ChatVoiceModePhase.ended);
  });

  test('provider disposal cancels a start during initialization', () async {
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

    final start = container
        .read(chatVoiceModeControllerProvider.notifier)
        .start(startNewConversation: false);
    await _until(() => input.initializeCalls == 1);

    container.dispose();
    input.initializeGate!.complete(true);

    check(await start.timeout(const Duration(seconds: 1)))
        .equals(ChatVoiceModeStartResult.cancelled);
  });

  test('new voice conversation preserves an admitted model after selection changes', () async {
    final input = _FakeVoiceInputService();
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(),
        authNavigationStateProvider.overrideWithValue(
          AuthNavigationState.authenticated,
        ),
        reviewerModeProvider.overrideWithValue(true),
        selectedModelProvider.overrideWith(
          () => _SeededSelectedModel(_fallbackModel),
        ),
        isManualModelSelectionProvider.overrideWith(_ManualModelSelection.new),
        modelsProvider.overrideWith(() => _FixedModels(const [_fallbackModel])),
        optimizedStorageServiceProvider.overrideWithValue(
          _FakeOptimizedStorageService(),
        ),
        appSettingsProvider.overrideWithValue(
          const AppSettings(defaultModel: 'fallback-model'),
        ),
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

    final result = await container
        .read(chatVoiceModeControllerProvider.notifier)
        .start(startNewConversation: true, admittedModel: _model);
    final resolvedDefault = await container.read(defaultModelProvider.future);

    check(result).equals(ChatVoiceModeStartResult.started);
    check(resolvedDefault).identicalTo(_model);
    check(container.read(selectedModelProvider)).identicalTo(_model);
    check(container.read(isManualModelSelectionProvider)).isTrue();
  });

  test(
    'new voice conversation owns a transcript emitted during listener startup',
    () async {
      final input = _FakeVoiceInputService()
        ..bufferedFinalWhenIntensityStarts = 'first words';
      final container = ProviderContainer(
        overrides: [
          ...openWebUiStorageOpenOverrides(),
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.authenticated,
          ),
          reviewerModeProvider.overrideWithValue(true),
          selectedModelProvider.overrideWith(
            () => _SeededSelectedModel(_model),
          ),
          isManualModelSelectionProvider.overrideWith(
            _ManualModelSelection.new,
          ),
          appSettingsProvider.overrideWithValue(const AppSettings()),
          voiceInputServiceProvider.overrideWithValue(input),
          textToSpeechServiceProvider.overrideWithValue(
            _FakeTextToSpeechService(),
          ),
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
      addTearDown(container.dispose);

      final existingConversation = Conversation(
        id: 'existing-chat',
        title: 'Existing chat',
        createdAt: DateTime(2024),
        updatedAt: DateTime(2024),
        messages: [
          ChatMessage(
            id: 'existing-message',
            role: 'user',
            content: 'existing words',
            timestamp: DateTime(2024),
          ),
        ],
      );
      container
          .read(activeConversationProvider.notifier)
          .set(existingConversation);
      final existingConversationSnapshots = <Conversation>[];
      final activeConversationSubscription = container.listen(
        activeConversationProvider,
        (_, next) {
          if (next?.id == existingConversation.id) {
            existingConversationSnapshots.add(next!);
          }
        },
        fireImmediately: true,
      );
      addTearDown(activeConversationSubscription.close);

      final result = await container
          .read(chatVoiceModeControllerProvider.notifier)
          .start(startNewConversation: true);
      await _until(() {
        final active = container.read(activeConversationProvider);
        return active != null &&
            active.id != existingConversation.id &&
            active.messages.any((message) => message.content == 'first words');
      });

      final messages = container.read(chatMessagesProvider);
      final activeConversation = container.read(activeConversationProvider)!;
      check(result).equals(ChatVoiceModeStartResult.started);
      check(messages.first.content).equals('first words');
      check(messages.first.role).equals('user');
      final persistedTranscript = activeConversation.messages.firstWhere(
        (message) => message.content == 'first words',
      );
      check(persistedTranscript.role).equals('user');
      final oldConversationTranscripts = existingConversationSnapshots.expand(
        (conversation) => conversation.messages.where(
          (message) => message.content == 'first words',
        ),
      );
      check(oldConversationTranscripts).isEmpty();
      final activeConversationId = activeConversation.id;
      check(activeConversationId).isNotNull();
      check(activeConversationId)
          .not((id) => id.equals(existingConversation.id));
    },
  );

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
    check(eligibility.reason)
        .equals(VoiceCallEligibilityReason.authenticationRequired);
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
    check(eligibility.reason)
        .equals(VoiceCallEligibilityReason.backendUnavailable);
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
      check(eligibility.reason)
          .equals(VoiceCallEligibilityReason.modelRequired);
    },
  );

  test(
    'sends transcript through chat voice mode and resumes listening',
    () async {
      final input = _FakeVoiceInputService();
      final tts = _FakeTextToSpeechService();
      final background = _FakeChatVoiceBackgroundCoordinator();
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
            background,
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
      expect(background.keepAliveCalls, 1);
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
    'assistant response errors end voice mode without speaking emptiness',
    () async {
      final input = _FakeVoiceInputService();
      final tts = _FakeTextToSpeechService();
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
      addTearDown(container.dispose);
      final controller = container.read(
        chatVoiceModeControllerProvider.notifier,
      );

      await controller.start(startNewConversation: false);
      await input.completeCurrent('trigger a failed response');
      await _until(
        () =>
            container.read(chatVoiceModeControllerProvider).phase ==
            ChatVoiceModePhase.sending,
      );
      final assistant = container
          .read(chatMessagesProvider)
          .lastWhere((message) => message.role == 'assistant');
      container
          .read(chatMessagesProvider.notifier)
          .failLastStreamingAssistant(
            StateError('network unavailable'),
            assistantMessageId: assistant.id,
          );

      await _until(
        () =>
            container.read(chatVoiceModeControllerProvider).phase ==
            ChatVoiceModePhase.error,
      );
      check(container.read(chatVoiceModeControllerProvider).errorMessage)
          .equals(
            'An unexpected error occurred while processing your request. '
            'Please try again or check your connection.',
          );
      check(tts.finishedTexts).isEmpty();
    },
  );

  test('response-wait capture failure ends and cleans up the call', () async {
    final input = _FakeVoiceInputService();
    final audioSession = _FakeChatVoiceAudioSessionCoordinator()
      ..throwOnResponseWaitBegin = true;
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
          audioSession,
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(chatVoiceModeControllerProvider.notifier);

    await controller.start(startNewConversation: false);
    final responseWaitStopsBeforeTurn = audioSession.responseWaitEndCalls;
    await input.completeCurrent('trigger capture failure');
    await _until(
      () =>
          container.read(chatVoiceModeControllerProvider).phase ==
          ChatVoiceModePhase.error,
    );

    check(container.read(chatVoiceModeControllerProvider).errorMessage)
        .isNotNull()
        .contains('response-wait capture failed');
    check(audioSession.responseWaitEndCalls)
        .isGreaterThan(responseWaitStopsBeforeTurn);
  });

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
      check(container.read(chatVoiceModeControllerProvider).phase)
          .equals(ChatVoiceModePhase.listening);
    },
  );

  test(
    'native STT pauses during assistant speech when barge-in is disabled',
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

      check(container.read(chatMessagesProvider).first.content)
          .equals('continuous final');
      check(input.beginCalls).equals(2);
      check(input.stopCalls).isGreaterThan(0);
      check(input.isListening).isTrue();
      await controller.stop();
    },
  );

  test('failed assistant speech resumes listening', () async {
    final input = _FakeVoiceInputService()..nativeLocalStt = true;
    final tts = _FakeTextToSpeechService()..holdCompletion = true;
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
    await input.completeCurrent('speak this', close: false);
    await _until(() => tts.finishedTexts.isNotEmpty);

    // TTS never completes; it fails instead. The recognizer was stopped for
    // playback, so the turn must still end and listening must resume.
    tts.emitError('tts engine unavailable');
    await _until(
      () =>
          container.read(chatVoiceModeControllerProvider).phase ==
          ChatVoiceModePhase.listening,
    );

    // Resuming clears the error banner, so the recovery itself is the
    // assertion: the recognizer is live again instead of stranded.
    check(input.isListening).isTrue();
    check(input.beginCalls).equals(2);
    await controller.stop();
  });

  test(
    'starts on the speakerphone when no audio accessory is attached',
    () async {
      final audioSession = _FakeChatVoiceAudioSessionCoordinator()
        ..defaultsToSpeakerphone = true;
      final container = ProviderContainer(
        overrides: [
          ...openWebUiStorageOpenOverrides(),
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.authenticated,
          ),
          selectedModelProvider.overrideWithValue(_model),
          appSettingsProvider.overrideWithValue(const AppSettings()),
          reviewerModeProvider.overrideWithValue(true),
          voiceInputServiceProvider.overrideWithValue(_FakeVoiceInputService()),
          textToSpeechServiceProvider.overrideWithValue(
            _FakeTextToSpeechService(),
          ),
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
      await pumpEventQueue();

      check(audioSession.defaultRouteCalls).equals(1);
      check(
        container.read(chatVoiceModeControllerProvider).isSpeakerphoneEnabled,
      ).isTrue();

      // The default is only a starting point: the button still turns it off.
      await controller.toggleSpeakerphone();
      check(
        container.read(chatVoiceModeControllerProvider).isSpeakerphoneEnabled,
      ).isFalse();
      check(audioSession.speakerphoneCalls).deepEquals(<bool>[false]);

      await controller.stop();
    },
  );

  test('follows the audio route the coordinator picks mid-call', () async {
    final audioSession = _FakeChatVoiceAudioSessionCoordinator()
      ..defaultsToSpeakerphone = true;
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(),
        authNavigationStateProvider.overrideWithValue(
          AuthNavigationState.authenticated,
        ),
        selectedModelProvider.overrideWithValue(_model),
        appSettingsProvider.overrideWithValue(const AppSettings()),
        reviewerModeProvider.overrideWithValue(true),
        voiceInputServiceProvider.overrideWithValue(_FakeVoiceInputService()),
        textToSpeechServiceProvider.overrideWithValue(
          _FakeTextToSpeechService(),
        ),
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
    await pumpEventQueue();
    check(container.read(chatVoiceModeControllerProvider).isSpeakerphoneEnabled)
        .isTrue();

    // A headset connected mid-call takes playback off the loudspeaker, and the
    // overlay's speaker button has to say so.
    audioSession.routeChanges.add(false);
    await pumpEventQueue();
    check(container.read(chatVoiceModeControllerProvider).isSpeakerphoneEnabled)
        .isFalse();

    audioSession.routeChanges.add(true);
    await pumpEventQueue();
    check(container.read(chatVoiceModeControllerProvider).isSpeakerphoneEnabled)
        .isTrue();

    await controller.stop();

    // A late event from a torn-down call cannot revive the speaker state.
    audioSession.routeChanges.add(true);
    await pumpEventQueue();
    check(container.read(chatVoiceModeControllerProvider).isSpeakerphoneEnabled)
        .isFalse();
  });

  test(
    'speakerphone toggle drives the audio session on every platform',
    () async {
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
          voiceInputServiceProvider.overrideWithValue(_FakeVoiceInputService()),
          textToSpeechServiceProvider.overrideWithValue(
            _FakeTextToSpeechService(),
          ),
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

      check(
        container.read(chatVoiceModeControllerProvider).isSpeakerphoneEnabled,
      ).isFalse();
      await controller.toggleSpeakerphone();
      check(
        container.read(chatVoiceModeControllerProvider).isSpeakerphoneEnabled,
      ).isTrue();
      await controller.toggleSpeakerphone();
      check(
        container.read(chatVoiceModeControllerProvider).isSpeakerphoneEnabled,
      ).isFalse();

      check(audioSession.speakerphoneCalls).deepEquals(<bool>[true, false]);
      await controller.stop();
    },
  );

  test('speakerphone toggle stays put when the platform refuses', () async {
    final audioSession = _FakeChatVoiceAudioSessionCoordinator()
      ..speakerphoneRouteApplies = false;
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(),
        authNavigationStateProvider.overrideWithValue(
          AuthNavigationState.authenticated,
        ),
        selectedModelProvider.overrideWithValue(_model),
        appSettingsProvider.overrideWithValue(const AppSettings()),
        reviewerModeProvider.overrideWithValue(true),
        voiceInputServiceProvider.overrideWithValue(_FakeVoiceInputService()),
        textToSpeechServiceProvider.overrideWithValue(
          _FakeTextToSpeechService(),
        ),
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

    await controller.toggleSpeakerphone();

    // Audio is still coming out of the earpiece, so a button that flipped to
    // speaker would be pointing at a route nobody is hearing.
    check(container.read(chatVoiceModeControllerProvider).isSpeakerphoneEnabled)
        .isFalse();
    check(audioSession.speakerphoneCalls).deepEquals(<bool>[true]);
    await controller.stop();
  });

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
          appSettingsProvider.overrideWithValue(
            const AppSettings(voiceBargeInEnabled: true),
          ),
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
          appSettingsProvider.overrideWithValue(
            const AppSettings(voiceBargeInEnabled: true),
          ),
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
      check(userMessages)
          .deepEquals(<String>['first assistant turn', 'second barge in turn']);
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
    'keeps a CallKit response alive while the app is backgrounded',
    () async {
      final input = _FakeVoiceInputService()
        ..localSttAvailable = false
        ..serverSttAvailable = true
        ..sttPreference = SttPreference.serverOnly;
      final tts = _FakeTextToSpeechService()..holdCompletion = true;
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
      expect(audioSession.registeredCallIds, <String>['call-1']);
      await _until(() => callKit.connectedCallIds.contains('call-1'));

      final messages = container.read(chatMessagesProvider.notifier);
      messages.didChangeAppLifecycleState(AppLifecycleState.paused);
      final responseWaitStopsBeforeTurn = audioSession.responseWaitEndCalls;
      await input.completeCurrent('background voice response');
      await _until(() => tts.finishedTexts.isNotEmpty);

      expect(tts.fedTexts.join('\n'), contains('background voice response'));
      expect(audioSession.responseWaitCallIds, <String?>['call-1']);
      expect(audioSession.responseWaitEndCalls, responseWaitStopsBeforeTurn);

      tts.emitCompleted();
      await _until(() => input.beginCalls == 2);
      expect(
        audioSession.responseWaitEndCalls,
        greaterThan(responseWaitStopsBeforeTurn),
      );

      await controller.stop();

      expect(background.stopped, <String>[background.started.single.leaseId]);
      expect(callKit.endedCallIds, <String>['call-1']);
      expect(background.externalAudioSessionOwners.last, isFalse);
      expect(audioSession.deactivateCalls, 1);
    },
  );

  test(
    'muting keeps response-wait capture and surfaces runtime failure',
    () async {
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
      await input.completeCurrent('keep the muted response alive');
      await _until(() => tts.finishedTexts.isNotEmpty);
      final responseWaitStopsBeforeMute = audioSession.responseWaitEndCalls;

      await controller.toggleMute();

      check(container.read(chatVoiceModeControllerProvider).isMuted).isTrue();
      check(audioSession.responseWaitCallIds).deepEquals(<String?>[null, null]);
      check(audioSession.responseWaitEndCalls)
          .equals(responseWaitStopsBeforeMute);

      audioSession.emitResponseCaptureStreamError(
        StateError('native response capture route failed'),
      );
      await _until(
        () =>
            container.read(chatVoiceModeControllerProvider).phase ==
            ChatVoiceModePhase.error,
      );
      check(container.read(chatVoiceModeControllerProvider).errorMessage)
          .isNotNull()
          .contains('native response capture route failed');
    },
  );

  test(
    'stale response handoffs finish before teardown and replacement',
    () async {
      final handoffGate = Completer<void>();
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
      await input.completeCurrent('keep the first response alive');
      await _until(() => tts.finishedTexts.isNotEmpty);

      input.nextResponseWaitHandoffGate = handoffGate;
      final staleMute = controller.toggleMute();
      await _until(() => input.responseWaitHandoffCalls == 2);

      final responseWaitStopsBeforeTeardown = audioSession.responseWaitEndCalls;
      final captureStartsBeforeTeardown =
          audioSession.responseWaitCallIds.length;
      container.invalidate(chatVoiceModeControllerProvider);
      final replacement = container.read(
        chatVoiceModeControllerProvider.notifier,
      );
      final replacementStart = replacement.start(startNewConversation: false);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      check(audioSession.responseWaitEndCalls)
          .equals(responseWaitStopsBeforeTeardown);
      check(input.beginCalls).equals(1);

      handoffGate.complete();
      await staleMute;
      await replacementStart;

      check(audioSession.responseWaitCallIds.length)
          .equals(captureStartsBeforeTeardown);
      check(input.nativeCaptureDetachedForResponseWait).isFalse();
      check(input.beginCalls).equals(2);

      final sendHandoffGate = Completer<void>();
      input.nextResponseWaitHandoffGate = sendHandoffGate;
      await input.completeCurrent('stale replacement response');
      await _until(() => input.responseWaitHandoffCalls == 3);

      final responseWaitStopsBeforeSendTeardown =
          audioSession.responseWaitEndCalls;
      final captureStartsBeforeSendTeardown =
          audioSession.responseWaitCallIds.length;
      final speakingCallsBeforeSendTeardown = audioSession.speakingCalls;
      container.invalidate(chatVoiceModeControllerProvider);
      final secondReplacement = container.read(
        chatVoiceModeControllerProvider.notifier,
      );
      final secondReplacementStart = secondReplacement.start(
        startNewConversation: false,
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      check(audioSession.responseWaitEndCalls)
          .equals(responseWaitStopsBeforeSendTeardown);
      check(input.beginCalls).equals(2);

      sendHandoffGate.complete();
      await secondReplacementStart;

      check(audioSession.responseWaitCallIds.length)
          .equals(captureStartsBeforeSendTeardown);
      check(audioSession.speakingCalls).equals(speakingCallsBeforeSendTeardown);
      check(input.nativeCaptureDetachedForResponseWait).isFalse();
      check(input.beginCalls).equals(3);
      await secondReplacement.stop();
    },
  );

  test(
    'server recorder owns response wait and resumes without restart',
    () async {
      final input = _FakeVoiceInputService()
        ..localSttAvailable = false
        ..serverSttAvailable = true
        ..sttPreference = SttPreference.serverOnly
        ..holdServerRecorderOnComplete = true;
      final tts = _FakeTextToSpeechService()..holdCompletion = true;
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
      final stopsBeforeTurn = input.stopCalls;
      await input.completeCurrent('keep one live server recorder');
      await _until(() => tts.finishedTexts.isNotEmpty);
      await _until(
        () =>
            container.read(chatVoiceModeControllerProvider).phase ==
            ChatVoiceModePhase.speaking,
      );

      check(input.responseWaitHandoffCalls).equals(1);
      check(input.isHoldingServerRecorderForResponse).isTrue();
      check(input.stopCalls).equals(stopsBeforeTurn);
      check(audioSession.responseWaitCallIds).isEmpty();

      await controller.toggleMute();
      check(container.read(chatVoiceModeControllerProvider).phase)
          .equals(ChatVoiceModePhase.muted);
      await controller.toggleMute();
      check(container.read(chatVoiceModeControllerProvider).isMuted).isFalse();
      check(container.read(chatVoiceModeControllerProvider).phase)
          .equals(ChatVoiceModePhase.speaking);
      check(input.isHoldingServerRecorderForResponse).isTrue();
      check(input.beginCalls).equals(1);
      check(input.stopCalls).equals(stopsBeforeTurn);
      check(audioSession.responseWaitCallIds).isEmpty();

      tts.emitCompleted();
      await _until(() => input.beginCalls == 2);
      check(input.isHoldingServerRecorderForResponse).isFalse();
      check(input.stopCalls).equals(stopsBeforeTurn);

      await controller.stop();
    },
  );

  test('fails the call when held server response capture dies', () async {
    final input = _FakeVoiceInputService()
      ..localSttAvailable = false
      ..serverSttAvailable = true
      ..sttPreference = SttPreference.serverOnly
      ..holdServerRecorderOnComplete = true;
    final tts = _FakeTextToSpeechService()..holdCompletion = true;
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
    addTearDown(input.closeResponseCaptureFailures);
    final controller = container.read(chatVoiceModeControllerProvider.notifier);

    await controller.start(startNewConversation: false);
    await input.completeCurrent('keep server capture failure visible');
    await _until(
      () =>
          input.isHoldingServerRecorderForResponse &&
          tts.finishedTexts.isNotEmpty,
    );

    input.emitResponseCaptureFailure(StateError('held microphone failed'));
    await _until(
      () =>
          container.read(chatVoiceModeControllerProvider).phase ==
          ChatVoiceModePhase.error,
    );

    check(container.read(chatVoiceModeControllerProvider).errorMessage)
        .isNotNull()
        .contains('held microphone failed');
    check(input.isHoldingServerRecorderForResponse).isFalse();
    check(input.stopCalls).isGreaterThan(0);
  });

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
    expect(audioSession.responseWaitCallIds, <String?>[null]);

    await controller.resume();
    expect(audioSession.responseWaitCallIds, <String?>[null, null]);
    await _until(() => tts.finishedTexts.isNotEmpty);

    expect(tts.finishedTexts.single, isNotEmpty);
    await _until(() => input.beginCalls == 2);
    expect(
      container.read(chatVoiceModeControllerProvider).phase,
      ChatVoiceModePhase.listening,
    );

    await controller.stop();
  });

  test('unmuting a paused assistant turn resumes its speech', () async {
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
    await input.completeCurrent('pause, mute, then resume this response');
    await _until(
      () =>
          container.read(chatVoiceModeControllerProvider).phase ==
          ChatVoiceModePhase.speaking,
    );

    await controller.pause();
    await controller.toggleMute();
    await controller.toggleMute();

    check(container.read(chatVoiceModeControllerProvider).isMuted).isFalse();
    check(container.read(chatVoiceModeControllerProvider).phase)
        .equals(ChatVoiceModePhase.speaking);
    check(tts.pauseCalls).equals(1);
    check(tts.resumeCalls).equals(1);
    check(audioSession.responseWaitCallIds).deepEquals(<String?>[null, null]);

    await controller.stop();
  });

  test(
    'stop completes every teardown step and ends CallKit after cleanup errors',
    () async {
      final input = _FakeVoiceInputService()
        ..throwOnResponseCaptureFailureCancel = true;
      final tts = _FakeTextToSpeechService()
        ..throwOnStopStreaming = true
        ..throwOnStop = true;
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

      check(input.responseCaptureFailureSubscriptionCancelled).isTrue();
      check(audioSession.responseCaptureFailureEvents.hasListener).isFalse();
      check(tts.stopStreamingCalls).equals(1);
      check(tts.stopCalls).equals(1);
      // A stop that throws must still hand the shared engine back to read
      // aloud, which does not belong on the call route.
      check(tts.voiceCallFlags).deepEquals(<bool>[true, false]);
      check(background.stopped).length.equals(1);
      check(background.externalAudioSessionOwners.last).isFalse();
      check(audioSession.deactivateCalls).equals(1);
      check(callKit.endedCallIds).deepEquals(<String>['call-1']);
      check(container.read(chatVoiceModeControllerProvider).phase)
          .equals(ChatVoiceModePhase.ended);
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

    check(container.read(chatVoiceModeControllerProvider).phase)
        .equals(ChatVoiceModePhase.listening);
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

    check(container.read(chatVoiceModeControllerProvider).phase)
        .equals(ChatVoiceModePhase.listening);
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
    check(container.read(chatVoiceModeControllerProvider).phase)
        .equals(ChatVoiceModePhase.error);
    check(container.read(chatVoiceModeControllerProvider).errorMessage)
        .isNotNull()
        .contains('timed out');

    staleInputGate.complete();
    await _until(() => !input.isListening);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    check(input.beginCalls).equals(1);
    check(container.read(chatVoiceModeControllerProvider).phase)
        .equals(ChatVoiceModePhase.error);

    await replacementController
        .start(startNewConversation: false)
        .timeout(const Duration(seconds: 1));

    check(input.beginCalls).equals(2);
    check(input.isListening).isTrue();
    check(container.read(chatVoiceModeControllerProvider).phase)
        .equals(ChatVoiceModePhase.listening);
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

  test('provider disposal hands the tts engine back to read aloud', () async {
    final tts = _FakeTextToSpeechService();
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(),
        authNavigationStateProvider.overrideWithValue(
          AuthNavigationState.authenticated,
        ),
        selectedModelProvider.overrideWithValue(_model),
        appSettingsProvider.overrideWithValue(const AppSettings()),
        reviewerModeProvider.overrideWithValue(true),
        voiceInputServiceProvider.overrideWithValue(_FakeVoiceInputService()),
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

    final controller = container.read(chatVoiceModeControllerProvider.notifier);
    await controller.start(startNewConversation: false);
    check(tts.voiceCallFlags).deepEquals(<bool>[true]);

    container.dispose();
    await pumpEventQueue();

    // The engine is shared with read-aloud. Left on the call route it speaks
    // out of the earpiece at call volume.
    check(tts.voiceCallFlags).deepEquals(<bool>[true, false]);
  });
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

class _SeededSelectedModel extends SelectedModel {
  _SeededSelectedModel(this._model);

  final Model _model;

  @override
  Model build() => _model;
}

class _IgnoringSelectedModel extends _NullSelectedModel {
  @override
  void set(Model? model, {bool allowHidden = false}) {}
}

class _FixedModels extends Models {
  _FixedModels(this._models);

  final List<Model> _models;

  @override
  Future<List<Model>> build() async => _models;
}

class _FakeOptimizedStorageService extends Fake
    implements OptimizedStorageService {}

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
    Model? admittedModel,
  }) async {
    state = const ChatVoiceModeSnapshot(
      phase: ChatVoiceModePhase.error,
      errorMessage: 'Rejected test voice start.',
    );
    return ChatVoiceModeStartResult.failed;
  }
}

class _RecordingVoiceStartController extends ChatVoiceModeController {
  final admittedModels = <Model?>[];
  final startedByStartNewConversation = <bool>[];

  @override
  ChatVoiceModeSnapshot build() => const ChatVoiceModeSnapshot();

  @override
  Future<ChatVoiceModeStartResult> start({
    required bool startNewConversation,
    bool Function()? shouldStart,
    Model? admittedModel,
  }) async {
    admittedModels.add(admittedModel);
    startedByStartNewConversation.add(startNewConversation);
    state = const ChatVoiceModeSnapshot(phase: ChatVoiceModePhase.listening);
    return ChatVoiceModeStartResult.started;
  }
}

class _SelectionChangingSocketService extends SocketService {
  _SelectionChangingSocketService(this._onConnectionRead)
    : super(
        serverConfig: const ServerConfig(
          id: 'selection-changing',
          name: 'Selection changing',
          url: 'https://example.com',
        ),
      );

  final void Function() _onConnectionRead;
  bool _selectionChanged = false;

  @override
  bool get isConnected {
    if (!_selectionChanged) {
      _selectionChanged = true;
      _onConnectionRead();
    }
    return true;
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

class _OwuiPreferredBackend extends PreferredBackendController {
  @override
  PreferredBackend build() => PreferredBackend.owui;
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
  int permissionCalls = 0;
  Completer<bool>? initializeGate;
  bool permissionsGranted = true;
  bool localSttAvailable = true;
  bool serverSttAvailable = false;
  SttPreference sttPreference = SttPreference.deviceOnly;
  bool completedTranscriptSendable = false;
  bool nativeLocalStt = false;
  bool nativeCaptureDetachedForResponseWait = false;
  bool holdServerRecorderForResponse = false;
  bool holdServerRecorderOnComplete = false;
  bool throwOnResponseCaptureFailureCancel = false;
  bool responseCaptureFailureSubscriptionCancelled = false;
  bool listening = false;
  int stopCalls = 0;
  int responseWaitHandoffCalls = 0;
  Completer<void>? nextStopListeningGate;
  Completer<void>? nextResponseWaitHandoffGate;
  Object? beginListeningError;
  Object? bufferedErrorWhenIntensityStarts;
  String? bufferedFinalWhenIntensityStarts;
  bool _emittedBufferedTranscriptSignal = false;
  final managedAudioFlags = <bool>[];
  final _responseCaptureFailures = StreamController<Object>.broadcast();
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
  bool get isHoldingServerRecorderForResponse => holdServerRecorderForResponse;

  @override
  bool get isListening => listening;

  @override
  Stream<Object> get responseCaptureFailures {
    final stream = _responseCaptureFailures.stream;
    if (!throwOnResponseCaptureFailureCancel) return stream;
    return _FailingCancelStream<Object>(stream, () {
      responseCaptureFailureSubscriptionCancelled = true;
    });
  }

  @override
  Future<bool> initialize({bool forceLocalStt = false}) async {
    initializeCalls += 1;
    return await initializeGate?.future ?? true;
  }

  @override
  Future<bool> checkPermissions() async {
    permissionCalls += 1;
    return permissionsGranted;
  }

  @override
  Future<Stream<VoiceTranscriptEvent>> beginListeningEvents({
    bool iosAudioSessionManagedExternally = false,
  }) async {
    beginCalls += 1;
    final error = beginListeningError;
    if (error != null) {
      Error.throwWithStackTrace(error, StackTrace.current);
    }
    listening = true;
    nativeCaptureDetachedForResponseWait = false;
    holdServerRecorderForResponse = false;
    completedTranscriptSendable = false;
    managedAudioFlags.add(iosAudioSessionManagedExternally);
    _transcriptController = StreamController<VoiceTranscriptEvent>.broadcast(
      sync:
          bufferedErrorWhenIntensityStarts != null ||
          bufferedFinalWhenIntensityStarts != null,
    );
    _intensityController = StreamController<int>.broadcast();
    return _transcriptController!.stream;
  }

  @override
  Stream<int> get intensityStream {
    final error = bufferedErrorWhenIntensityStarts;
    final finalTranscript = bufferedFinalWhenIntensityStarts;
    if (!_emittedBufferedTranscriptSignal &&
        (error != null || finalTranscript != null)) {
      _emittedBufferedTranscriptSignal = true;
      final controller = _transcriptController;
      if (error != null) {
        controller?.addError(error, StackTrace.current);
      }
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
      holdServerRecorderForResponse = holdServerRecorderOnComplete;
      await controller.close();
    }
  }

  void emitError(Object error) {
    _transcriptController?.addError(error, StackTrace.current);
  }

  void emitResponseCaptureFailure(Object error) {
    _responseCaptureFailures.add(error);
  }

  Future<void> closeResponseCaptureFailures() =>
      _responseCaptureFailures.close();

  @override
  Future<bool> prepareResponseWaitHandoff() async {
    responseWaitHandoffCalls += 1;
    if (holdServerRecorderForResponse) return true;
    await stopListening();
    final gate = nextResponseWaitHandoffGate;
    nextResponseWaitHandoffGate = null;
    await gate?.future;
    nativeCaptureDetachedForResponseWait = true;
    return false;
  }

  @override
  Future<void> stopListening() async {
    stopCalls += 1;
    final stopGate = nextStopListeningGate;
    nextStopListeningGate = null;
    await stopGate?.future;
    listening = false;
    nativeCaptureDetachedForResponseWait = false;
    holdServerRecorderForResponse = false;
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
  final voiceCallFlags = <bool>[];
  bool startedStreaming = false;
  bool holdCompletion = false;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int stopStreamingCalls = 0;
  int stopCalls = 0;
  bool throwOnStopStreaming = false;
  bool throwOnStop = false;
  Completer<void>? firstStopStreamingGate;
  bool _didStart = false;

  @override
  Stream<TtsEvent> get events => _events.stream;

  @override
  void setVoiceCallActive(bool active) {
    voiceCallFlags.add(active);
  }

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
    if (throwOnStop) {
      throw StateError('stop TTS failed');
    }
  }

  void emitError(String message) {
    _events.add(TtsError(message));
  }

  void emitCompleted() {
    _events.add(const TtsCompleted());
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
  int defaultRouteCalls = 0;
  bool throwOnDeactivate = false;
  bool throwOnResponseWaitBegin = false;
  bool defaultsToSpeakerphone = false;
  final speakerphoneCalls = <bool>[];
  final registeredCallIds = <String>[];
  final responseWaitCallIds = <String?>[];
  int responseWaitEndCalls = 0;
  bool speakerphoneRouteApplies = true;
  final routeChanges = StreamController<bool>.broadcast();
  final responseCaptureFailureEvents = StreamController<Object>.broadcast();

  @override
  Stream<bool> get speakerphoneRouteChanges => routeChanges.stream;

  @override
  Stream<Object> get responseCaptureFailures =>
      responseCaptureFailureEvents.stream;

  void emitResponseCaptureFailure(Object error) {
    responseCaptureFailureEvents.add(error);
  }

  void emitResponseCaptureStreamError(Object error) {
    responseCaptureFailureEvents.addError(error);
  }

  @override
  Future<void> applyDefaultSpeakerphoneRoute() async {
    defaultRouteCalls += 1;
  }

  @override
  Future<bool> setSpeakerphoneEnabled(bool enabled) async {
    speakerphoneCalls.add(enabled);
    return speakerphoneRouteApplies;
  }

  @override
  Future<void> configureForListening() async {
    listeningCalls += 1;
    // The real coordinator only announces the default once a configure pass has
    // moved the route, so the fake announces it from the same place.
    if (defaultsToSpeakerphone && !routeChanges.isClosed) {
      defaultsToSpeakerphone = false;
      routeChanges.add(true);
    }
  }

  @override
  Future<void> configureForSpeaking() async {
    speakingCalls += 1;
  }

  @override
  Future<void> setActiveCallKitCallId(String callId) async {
    registeredCallIds.add(callId);
  }

  @override
  Future<void> beginResponseWaitCapture({String? callKitCallId}) async {
    responseWaitCallIds.add(callKitCallId);
    if (throwOnResponseWaitBegin) {
      throw StateError('response-wait capture failed');
    }
  }

  @override
  Future<void> endResponseWaitCapture() async {
    responseWaitEndCalls += 1;
  }

  @override
  Future<void> deactivate() async {
    deactivateCalls += 1;
    if (throwOnDeactivate) {
      throw StateError('audio session deactivation failed');
    }
  }

  @override
  Future<void> dispose() async {
    await routeChanges.close();
    await responseCaptureFailureEvents.close();
  }
}

class _FailingCancelStream<T> extends Stream<T> {
  _FailingCancelStream(this._source, this._onCancel);

  final Stream<T> _source;
  final void Function() _onCancel;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _FailingCancelSubscription<T>(
      _source.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      ),
      _onCancel,
    );
  }
}

class _FailingCancelSubscription<T> implements StreamSubscription<T> {
  _FailingCancelSubscription(this._delegate, this._onCancel);

  final StreamSubscription<T> _delegate;
  final void Function() _onCancel;

  @override
  Future<void> cancel() async {
    await _delegate.cancel();
    _onCancel();
    throw StateError('response capture failure cancellation failed');
  }

  @override
  void onData(void Function(T data)? handleData) =>
      _delegate.onData(handleData);

  @override
  void onError(Function? handleError) => _delegate.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => _delegate.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => _delegate.pause(resumeSignal);

  @override
  void resume() => _delegate.resume();

  @override
  bool get isPaused => _delegate.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _delegate.asFuture<E>(futureValue);
}

class _VoiceSocketTestController extends Notifier<SocketService?> {
  @override
  SocketService? build() => null;

  void set(SocketService? socket) => state = socket;
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 300; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('Condition was not met.');
}
