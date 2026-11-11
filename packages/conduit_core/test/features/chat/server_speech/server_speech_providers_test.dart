import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/server_speech/direct_server_speech.dart';
import 'package:conduit_core/features/chat/server_speech/direct_voice_provider_settings.dart';
import 'package:conduit_core/features/chat/server_speech/hermes_server_speech.dart';
import 'package:conduit_core/features/chat/server_speech/openwebui_server_speech.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_http_client.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

final class _Discovery extends DirectModelDiscoveryController {
  @override
  Future<DirectModelDiscoveryState> build() async =>
      DirectModelDiscoveryState();
}

final class _Profiles extends DirectConnectionProfilesController {
  _Profiles(this.profiles);

  final List<DirectConnectionProfile> profiles;

  @override
  Future<List<DirectConnectionProfile>> build() async => profiles;
}

final _openAi = DirectConnectionProfile(
  id: 'voice',
  name: 'OpenAI',
  adapterKey: kOpenAiCompatibleAdapterKey,
  baseUrl: 'https://api.openai.com/v1',
  apiKey: 'sk-test',
);

const _voiceSettings = DirectVoiceProviderSettings(
  profileId: 'voice',
  transcriptionModel: 'whisper-1',
);

void main() {
  ApiService openWebUi() => ApiService(
    serverConfig: const ServerConfig(
      id: 'server',
      name: 'Server',
      url: 'https://owui.example',
    ),
    workerManager: WorkerManager(),
  );

  ProviderContainer container({
    Model? model,
    ApiService? api,
    DirectModelRegistry? registry,
    DirectVoiceProvider? voice,
    Object? hermes,
  }) {
    final pool = DirectHttpClientPool();
    addTearDown(pool.dispose);
    final c = ProviderContainer(
      overrides: [
        selectedModelProvider.overrideWithValue(model),
        apiServiceProvider.overrideWithValue(api),
        directModelRegistryProvider.overrideWithValue(
          registry ?? DirectModelRegistry(),
        ),
        directModelDiscoveryProvider.overrideWith(_Discovery.new),
        directVoiceProviderProvider.overrideWithValue(voice),
        directHttpClientPoolProvider.overrideWithValue(pool),
        hermesApiServiceProvider.overrideWithValue(
          hermes as HermesDesktopApiService?,
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('serverSpeechProvider', () {
    test('an Open WebUI model uses its server', () {
      final c = container(
        model: const Model(id: 'llama3', name: 'Llama 3'),
        api: openWebUi(),
      );

      check(c.read(serverSpeechProviderProvider)).isA<OpenWebUiServerSpeech>();
    });

    test('a Direct model uses the Voice provider', () {
      final registry = DirectModelRegistry();
      final model = registry.replaceProfileModels(_openAi, [
        DirectRemoteModel(id: 'gpt-5'),
      ]).single;
      final c = container(
        model: model,
        api: openWebUi(),
        registry: registry,
        voice: (profile: _openAi, settings: _voiceSettings),
      );

      final speech = c.read(serverSpeechProviderProvider);
      check(speech).isA<DirectServerSpeech>();
      check(speech!.canTranscribe).isTrue();
      check(speech.canSynthesize).isFalse();
    });

    test('a Direct model without a Voice provider never uses Open WebUI', () {
      final registry = DirectModelRegistry();
      final model = registry.replaceProfileModels(_openAi, [
        DirectRemoteModel(id: 'gpt-5'),
      ]).single;
      final c = container(model: model, api: openWebUi(), registry: registry);

      check(c.read(serverSpeechProviderProvider)).isNull();
    });

    test('a Hermes model uses the Desktop Gateway relay', () {
      final service = HermesDesktopApiService(
        config: HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          mode: HermesBackendMode.desktopGateway,
        ),
      );
      addTearDown(service.close);
      final c = container(
        model: hermesSyntheticModel(),
        api: openWebUi(),
        hermes: service,
      );

      check(c.read(serverSpeechProviderProvider)).isA<HermesServerSpeech>();
    });

    test('a Hermes model on the Responses API server has none', () {
      final c = ProviderContainer(
        overrides: [
          selectedModelProvider.overrideWithValue(hermesSyntheticModel()),
          apiServiceProvider.overrideWithValue(openWebUi()),
          hermesApiServiceProvider.overrideWithValue(
            HermesApiService(
              config: HermesConfig(
                enabled: true,
                baseUrl: 'https://hermes.example',
                apiKey: 'key',
              ),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);

      check(c.read(serverSpeechProviderProvider)).isNull();
    });
  });

  group('directVoiceProvider', () {
    Future<DirectVoiceProvider?> resolve(
      List<DirectConnectionProfile> profiles,
    ) async {
      final c = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AppSettings(directVoiceProvider: _voiceSettings),
          ),
          directConnectionProfilesProvider.overrideWith(
            () => _Profiles(profiles),
          ),
        ],
      );
      addTearDown(c.dispose);
      await c.read(directConnectionProfilesProvider.future);
      return c.read(directVoiceProviderProvider);
    }

    test('names an enabled OpenAI-compatible connection', () async {
      final voice = await resolve([_openAi]);

      check(voice).isNotNull();
      check(voice!.profile.id).equals('voice');
      check(voice.settings).equals(_voiceSettings);
    });

    test('is gone when the connection is removed or disabled', () async {
      check(await resolve(const [])).isNull();
      check(
        await resolve([
          DirectConnectionProfile(
            id: 'voice',
            name: 'OpenAI',
            adapterKey: kOpenAiCompatibleAdapterKey,
            baseUrl: 'https://api.openai.com/v1',
            enabled: false,
          ),
        ]),
      ).isNull();
    });

    test('an Ollama connection cannot be the Voice provider', () async {
      check(
        await resolve([
          DirectConnectionProfile(
            id: 'voice',
            name: 'Ollama',
            adapterKey: kOllamaAdapterKey,
            baseUrl: 'http://localhost:11434',
          ),
        ]),
      ).isNull();
    });
  });
}
