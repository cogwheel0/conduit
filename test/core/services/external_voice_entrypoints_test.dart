import 'dart:async';

import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit/platform/app_intents_service.dart';
import 'package:conduit/platform/home_widget_service.dart';
import 'package:conduit/platform/quick_actions_service.dart';
import 'package:conduit/platform/android_assistant_handler.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/chat/voice_call/presentation/voice_call_launcher.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';

const _assistantChannel = 'app.cogwheel.conduit/assistant';
const _codec = StandardMethodCodec();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  });

  tearDown(() {
    AndroidAssistantHandler.platform.setMethodCallHandler(null);
    PreferencesStore.debugReset();
  });

  test('Android Assistant delegates signed-out Hermes voice calls', () async {
    late _RecordingVoiceCallLauncher launcher;
    final container = _buildContainer((ref) {
      return launcher = _RecordingVoiceCallLauncher(ref);
    });
    addTearDown(container.dispose);
    container.read(androidAssistantProvider);

    await _invokeAndroidAssistant('startVoiceCall');

    expect(launcher.startNewConversationCalls, [isTrue]);
  });

  test('Siri intent delegates signed-out Hermes voice calls', () async {
    late _RecordingVoiceCallLauncher launcher;
    final container = _buildContainer((ref) {
      return launcher = _RecordingVoiceCallLauncher(ref);
    });
    addTearDown(container.dispose);

    final response = await container
        .read(appIntentCoordinatorProvider.notifier)
        .startVoiceCall('signed-out-hermes-voice');

    expect(response.success, isTrue);
    expect(launcher.startNewConversationCalls, [isTrue]);
  });

  test('voice quick action bypasses a signed-out queue head', () {
    expect(
      quickActionDispatchIndex(
        queuedTypes: const ['conduit_voice_call'],
        authState: AuthNavigationState.needsLogin,
        voiceCanBypassAuthLoading: false,
      ),
      isNull,
    );
    expect(
      quickActionDispatchIndex(
        queuedTypes: const ['conduit_new_chat', 'conduit_voice_call'],
        authState: AuthNavigationState.needsLogin,
        voiceCanBypassAuthLoading: false,
      ),
      isNull,
    );
    expect(
      quickActionDispatchIndex(
        queuedTypes: const ['conduit_new_chat', 'conduit_voice_call'],
        authState: AuthNavigationState.needsLogin,
        voiceCanBypassAuthLoading: true,
      ),
      1,
    );
    expect(
      quickActionDispatchIndex(
        queuedTypes: const ['conduit_voice_call'],
        authState: AuthNavigationState.needsLogin,
        voiceCanBypassAuthLoading: true,
      ),
      0,
    );
    expect(
      quickActionDispatchIndex(
        queuedTypes: const ['conduit_voice_call'],
        authState: AuthNavigationState.loading,
        voiceCanBypassAuthLoading: false,
      ),
      isNull,
    );
    expect(
      quickActionDispatchIndex(
        queuedTypes: const ['conduit_new_chat', 'conduit_voice_call'],
        authState: AuthNavigationState.loading,
        voiceCanBypassAuthLoading: true,
      ),
      1,
    );
    expect(
      quickActionDispatchIndex(
        queuedTypes: const ['conduit_voice_call'],
        authState: AuthNavigationState.authenticated,
        voiceCanBypassAuthLoading: false,
      ),
      0,
    );
  });

  test('voice home widget is not gated by OpenWebUI auth', () {
    expect(
      homeWidgetVoiceActionCanDispatch(
        Uri.parse('conduit://mic'),
        canBypassOpenWebUiAuth: true,
      ),
      isTrue,
    );
    expect(
      homeWidgetVoiceActionCanDispatch(
        Uri.parse('conduit://mic'),
        canBypassOpenWebUiAuth: false,
      ),
      isFalse,
    );
    expect(
      homeWidgetVoiceActionCanDispatch(
        Uri.parse('conduit://new_chat'),
        canBypassOpenWebUiAuth: true,
      ),
      isFalse,
    );
    expect(homeWidgetActionOf(Uri.parse('conduit://mic')), WidgetActions.mic);
    expect(homeWidgetActionOf(Uri.parse('conduit:///mic')), WidgetActions.mic);
    expect(homeWidgetActionOf(Uri.parse('conduit:///')), isNull);
  });
}

ProviderContainer _buildContainer(
  VoiceCallLauncher Function(Ref ref) createLauncher,
) {
  return ProviderContainer(
    overrides: [
      authNavigationStateProvider.overrideWithValue(
        AuthNavigationState.needsLogin,
      ),
      selectedModelProvider.overrideWithValue(hermesSyntheticModel()),
      voiceCallLauncherProvider.overrideWith(createLauncher),
    ],
  );
}

Future<void> _invokeAndroidAssistant(String method) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final data = _codec.encodeMethodCall(MethodCall(method));
  final completer = Completer<ByteData?>();
  await messenger.handlePlatformMessage(
    _assistantChannel,
    data,
    completer.complete,
  );
  await completer.future;
}

final class _RecordingVoiceCallLauncher extends VoiceCallLauncher {
  _RecordingVoiceCallLauncher(super.ref);

  final startNewConversationCalls = <bool>[];

  @override
  Future<void> launch({required bool startNewConversation}) async {
    startNewConversationCalls.add(startNewConversation);
  }
}
