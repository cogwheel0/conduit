// The voice-mode controller's own tests moved to conduit_core with it
// (packages/conduit_core/test/features/chat/voice_mode/). What stays here
// is the launcher, which owns navigation into the chat.
import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/chat/voice_call/presentation/voice_call_launcher.dart';
import 'package:conduit/features/chat/voice_mode/chat_voice_mode_controller.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/testing.dart';
import 'package:flutter_test/flutter_test.dart';

const _model = Model(id: 'test-model', name: 'Test Model');
const _fallbackModel = Model(id: 'fallback-model', name: 'Fallback Model');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('launcher starts voice mode for signed-out Hermes', () async {
    final input = _FakeVoiceInput();
    final audioSession = _FakeAudioSession();
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
        voiceModeInputProvider.overrideWithValue(input),
        voiceAudioSessionProvider.overrideWithValue(audioSession),
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
        isA<VoiceCallStartException>()
            .having(
              (error) => error.message,
              'message',
              'Rejected test voice start.',
            )
            .having((error) => error.kind, 'kind', isNull),
      ),
    );
  });
}

const _usableHermesConfig = HermesConfig(
  enabled: true,
  baseUrl: 'https://hermes.example/v1',
  apiKey: 'hermes-key',
);

class _FixedHermesConfig extends HermesConfigController {
  _FixedHermesConfig(this._config);

  final HermesConfig _config;

  @override
  HermesConfig build() => _config;
}

class _SeededSelectedModel extends SelectedModel {
  _SeededSelectedModel(this._model);

  final Model _model;

  @override
  Model build() => _model;
}

class _SettledHermesSecrets extends HermesSecretsLoading {
  @override
  bool build() => false;
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

/// Listens once and never hears anything: enough for the launcher to reach
/// the listening phase.
class _FakeVoiceInput extends UnavailableVoiceModeInput {
  int beginCalls = 0;

  @override
  Future<bool> initialize({bool forceLocalStt = false}) async => true;

  @override
  Future<bool> checkPermissions() async => true;

  @override
  Future<Stream<VoiceTranscriptEvent>> beginListeningEvents({
    bool iosAudioSessionManagedExternally = false,
  }) async {
    beginCalls += 1;
    return StreamController<VoiceTranscriptEvent>.broadcast().stream;
  }
}

class _FakeAudioSession extends NoVoiceAudioSession {
  int listeningCalls = 0;

  @override
  Future<void> configureForListening() async {
    listeningCalls += 1;
  }
}
