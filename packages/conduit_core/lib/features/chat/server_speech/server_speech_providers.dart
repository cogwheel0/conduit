import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';

import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';

import 'direct_server_speech.dart';
import 'direct_voice_provider_settings.dart';
import 'hermes_server_speech.dart';
import 'openwebui_server_speech.dart';
import 'server_speech.dart';

/// The Voice provider's connection with its settings.
typedef DirectVoiceProvider = ({
  DirectConnectionProfile profile,
  DirectVoiceProviderSettings settings,
});

/// The Voice provider, when the chosen connection still exists, is enabled,
/// and speaks the OpenAI-compatible API; null otherwise.
final directVoiceProviderProvider = Provider<DirectVoiceProvider?>((ref) {
  final settings = ref.watch(
    appSettingsProvider.select((settings) => settings.directVoiceProvider),
  );
  if (settings == null) return null;
  final profiles = ref.watch(directConnectionProfilesProvider).value;
  final profile = profiles
      ?.where((profile) => profile.id == settings.profileId)
      .firstOrNull;
  if (profile == null || !canBeVoiceProvider(profile)) return null;
  return (profile: profile, settings: settings);
});

/// Speech for the selected model's own backend, or null when it has none.
///
/// Hermes chats use their gateway's audio relay, which only the Desktop
/// Gateway serves. Direct and Apple chats use the Voice provider. Every other
/// model belongs to the Open WebUI server. Audio is never sent to a backend
/// the chat does not belong to; without one the device engines are used.
final serverSpeechProviderProvider = Provider<ServerSpeechProvider?>((ref) {
  final model = ref.watch(selectedModelProvider);
  if (model != null && isHermesModel(model)) {
    final service = ref.watch(hermesApiServiceProvider);
    return service is HermesDesktopApiService
        ? HermesServerSpeech(service)
        : null;
  }
  if (model != null && _isDeviceDirectModel(ref, model)) {
    final voice = ref.watch(directVoiceProviderProvider);
    if (voice == null) return null;
    return DirectServerSpeech(
      profile: voice.profile,
      settings: voice.settings,
      clientPool: ref.watch(directHttpClientPoolProvider),
    );
  }
  final api = ref.watch(apiServiceProvider);
  return api == null ? null : OpenWebUiServerSpeech(api);
});

/// Whether [model] is a Direct or Apple model run from this device, rather
/// than a Direct connection an Open WebUI server relays.
bool _isDeviceDirectModel(Ref ref, Model model) {
  if (!isLocallyMintedDirectModel(model)) return false;
  // The registry mutates in place; discovery is its invalidation signal.
  ref.watch(directModelDiscoveryProvider);
  final binding = ref.watch(directModelRegistryProvider).resolve(model);
  return binding == null || binding.source == DirectModelSource.device;
}
