import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/auth/token_validator.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/server_tls_http_client_factory.dart';
import 'package:conduit_core/services/settings_service.dart';

import 'realtime_bridge_transport.dart';
import 'realtime_call_ports.dart';

/// Builds the device's realtime audio engine, or returns null on a host
/// without one; calls are then Standard.
final realtimePcmAudioFactoryProvider =
    Provider<RealtimePcmAudioPort? Function()>((ref) => () => null);

/// Finds the realtime voice for a call with a model; see
/// [resolveRealtimeCallRoute].
final realtimeCallRouteResolverProvider =
    Provider<Future<RealtimeCallRoute> Function(Model model)>(
      (ref) =>
          (model) => resolveRealtimeCallRoute(ref, model),
    );

/// Why a call runs as a Standard call instead of a realtime one.
enum RealtimeCallBlock {
  /// The user chose Standard calls.
  standardChosen,

  /// Temporary chats keep Standard calls.
  temporaryChat,

  /// The model's backend has no realtime voice Conduit can use.
  unsupportedBackend,

  /// The Voice provider has no realtime model, voice or transcription model.
  voiceProviderIncomplete,

  /// The Open WebUI server has realtime calls off, or predates them.
  serverRealtimeOff,

  /// The account may not call, or its permissions could not be read.
  callNotPermitted,

  /// The account signed in with an API key, which realtime calls refuse.
  noSessionToken,
}

/// The voice a realtime call with a model would use, or why it has none.
typedef RealtimeCallRoute = ({
  RealtimeBridgeTransport? bridge,
  RealtimeCallBlock? block,
});

RealtimeCallRoute _blocked(RealtimeCallBlock block) =>
    (bridge: null, block: block);

/// Finds the realtime voice for a call with [model] in the open chat: Open
/// WebUI's own when its server offers one, the Voice provider for Direct and
/// Apple chats. Fails closed: anything unknown makes the call Standard.
Future<RealtimeCallRoute> resolveRealtimeCallRoute(Ref ref, Model model) async {
  if (ref.read(appSettingsProvider).voiceCallMode == VoiceCallMode.standard) {
    return _blocked(RealtimeCallBlock.standardChosen);
  }
  final active = ref.read(activeConversationProvider);
  if (ref.read(temporaryChatEnabledProvider) ||
      (active != null && isTemporaryChat(active.id))) {
    return _blocked(RealtimeCallBlock.temporaryChat);
  }
  // Hermes voice runs over WebRTC; until it lands its calls are Standard.
  if (isHermesModel(model)) {
    return _blocked(RealtimeCallBlock.unsupportedBackend);
  }

  if (isDeviceDirectModel(ref.read(directModelRegistryProvider), model)) {
    final voice = ref.read(directVoiceProviderProvider);
    final settings = voice?.settings;
    final realtimeModel = settings?.realtimeModel;
    final realtimeVoice = settings?.realtimeVoice;
    final transcriptionModel = settings?.transcriptionModel;
    if (voice == null ||
        realtimeModel == null ||
        realtimeVoice == null ||
        transcriptionModel == null) {
      return _blocked(RealtimeCallBlock.voiceProviderIncomplete);
    }
    return (
      bridge: DirectRealtimeBridge(
        profile: voice.profile,
        model: realtimeModel,
        voice: realtimeVoice,
        transcriptionModel: transcriptionModel,
        instructions: settings!.realtimeInstructions,
      ),
      block: null,
    );
  }
  // A Direct connection relayed through Open WebUI is not a server model, and
  // the server's bridge only takes server models.
  if (isLocallyMintedDirectModel(model)) {
    return _blocked(RealtimeCallBlock.unsupportedBackend);
  }

  final config = ref.read(backendConfigProvider).value;
  if (config?.enableRealtimeCall != true) {
    return _blocked(RealtimeCallBlock.serverRealtimeOff);
  }
  final permitted = await ref
      .read(chatCallPermittedProvider.future)
      .timeout(const Duration(seconds: 3), onTimeout: () => null);
  if (permitted != true) return _blocked(RealtimeCallBlock.callNotPermitted);
  final api = ref.read(apiServiceProvider);
  final token = api?.authToken;
  if (api == null || token == null || TokenValidator.isApiKey(token)) {
    return _blocked(RealtimeCallBlock.noSessionToken);
  }
  final server = api.serverConfig;
  final chatId = active?.id;
  return (
    bridge: OpenWebUiRealtimeBridge(
      server: server,
      token: token,
      modelId: model.id,
      // A chat the server has not created yet is not named.
      chatId: chatId == null || chatId.contains(':') ? null : chatId,
      httpClient: ServerTlsHttpClientFactory.requiresCustomHttpClient(server)
          ? ServerTlsHttpClientFactory.createHttpClient(server)
          : null,
    ),
    block: null,
  );
}
