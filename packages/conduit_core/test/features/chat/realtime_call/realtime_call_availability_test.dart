import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/realtime_call/bridge_call_host.dart';
import 'package:conduit_core/features/chat/realtime_call/chat_bridge_call_host.dart';
import 'package:conduit_core/features/chat/realtime_call/realtime_bridge_transport.dart';
import 'package:conduit_core/features/chat/realtime_call/realtime_call_availability.dart';
import 'package:conduit_core/features/chat/server_speech/direct_voice_provider_settings.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/message_voice.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

final class _Config extends BackendConfigNotifier {
  _Config(this.config);

  final BackendConfig? config;

  @override
  Future<BackendConfig?> build() async => config;
}

final class _Active extends ActiveConversationNotifier {
  _Active(this.conversation);

  final Conversation? conversation;

  @override
  Conversation? build() => conversation;
}

final class _Discovery extends DirectModelDiscoveryController {
  @override
  Future<DirectModelDiscoveryState> build() async =>
      DirectModelDiscoveryState();
}

final _openAi = DirectConnectionProfile(
  id: 'voice',
  name: 'OpenAI',
  adapterKey: kOpenAiCompatibleAdapterKey,
  baseUrl: 'https://api.openai.com/v1',
  apiKey: 'sk-test',
);

const _owuiModel = Model(id: 'llama3', name: 'Llama 3');

Conversation _chat(String id) => Conversation(
  id: id,
  title: 'Chat',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

void main() {
  Future<RealtimeCallRoute> route(
    Model model, {
    VoiceCallMode mode = VoiceCallMode.auto,
    bool? realtimeOn = true,
    bool? permitted = true,
    String token = 'eyJhbGciOiJIUzI1NiJ9.e30.sig',
    Conversation? active,
    bool newChat = false,
    DirectModelRegistry? registry,
    DirectVoiceProvider? voice,
  }) async {
    final api = ApiService(
      serverConfig: const ServerConfig(
        id: 'server',
        name: 'Home',
        url: 'https://owui.example',
      ),
      workerManager: WorkerManager(),
    )..updateAuthToken(token);
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWithValue(AppSettings(voiceCallMode: mode)),
        activeConversationProvider.overrideWith(() => _Active(active)),
        apiServiceProvider.overrideWithValue(api),
        backendConfigProvider.overrideWith(
          () => _Config(BackendConfig(enableRealtimeCall: realtimeOn)),
        ),
        chatCallPermittedProvider.overrideWith((ref) async => permitted),
        directModelRegistryProvider.overrideWithValue(
          registry ?? DirectModelRegistry(),
        ),
        directModelDiscoveryProvider.overrideWith(_Discovery.new),
        directVoiceProviderProvider.overrideWithValue(voice),
      ],
    );
    addTearDown(container.dispose);
    await container.read(backendConfigProvider.future);
    return container.read(realtimeCallRouteResolverProvider)(
      model,
      newChat: newChat,
    );
  }

  test('the user can always choose Standard calls', () async {
    check((await route(_owuiModel, mode: VoiceCallMode.standard)).block)
        .equals(RealtimeCallBlock.standardChosen);
  });

  test('Hermes on its Responses API server stays Standard', () async {
    check((await route(hermesSyntheticModel())).block)
        .equals(RealtimeCallBlock.unsupportedBackend);
  });

  group('Hermes Desktop Gateway', () {
    Future<RealtimeCallRoute> hermesRoute(String status) async {
      final service = HermesDesktopApiService(
        config: HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          mode: HermesBackendMode.desktopGateway,
          desktopAuthKind: HermesDesktopAuthKind.dashboardCookie,
        ),
        dashboardBridgeFactory: ({required root, required accessHeaders}) =>
            _StatusBridge(status),
      );
      addTearDown(service.close);
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(const AppSettings()),
          activeConversationProvider.overrideWith(() => _Active(null)),
          hermesApiServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      return container.read(realtimeCallRouteResolverProvider)(
        hermesSyntheticModel(),
      );
    }

    test('a profile in GPT-Live mode opens its calls through Hermes', () async {
      final result = await hermesRoute('{"mode":"gpt-live","available":true}');
      check(result.hermes).isNotNull();
      check(result.block).isNull();
    });

    test('a chained profile, or one without a key, stays Standard', () async {
      check((await hermesRoute('{"mode":"chained","available":true}')).block)
          .equals(RealtimeCallBlock.hermesVoiceLiveOff);
      check((await hermesRoute('{"mode":"gpt-live","available":false}')).block)
          .equals(RealtimeCallBlock.hermesVoiceLiveOff);
    });
  });

  group('Open WebUI', () {
    test('a server with realtime calls gets its own bridge', () async {
      final result = await route(
        _owuiModel,
        active: Conversation(
          id: 'chat-1',
          title: 'Chat',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      );

      final bridge = result.bridge;
      check(bridge).isA<OpenWebUiRealtimeBridge>();
      bridge as OpenWebUiRealtimeBridge;
      check(bridge.modelId).equals('llama3');
      check(bridge.chatId).equals('chat-1');
    });

    test('a call that starts a new chat does not name the open one', () async {
      final result = await route(
        _owuiModel,
        active: _chat('chat-1'),
        newChat: true,
      );

      check((result.bridge! as OpenWebUiRealtimeBridge).chatId).isNull();
    });

    test('a chat the server does not have yet is not named', () async {
      final result = await route(
        _owuiModel,
        active: Conversation(
          id: 'local:abc',
          title: 'Chat',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      );

      // A `local:` chat is a temporary one here; nothing new is named either.
      check(result.block).equals(RealtimeCallBlock.temporaryChat);
    });

    test('a server without realtime calls keeps them Standard', () async {
      check((await route(_owuiModel, realtimeOn: null)).block)
          .equals(RealtimeCallBlock.serverRealtimeOff);
      check((await route(_owuiModel, realtimeOn: false)).block)
          .equals(RealtimeCallBlock.serverRealtimeOff);
    });

    test(
      'an account that may not call, or is unknown, stays Standard',
      () async {
        check((await route(_owuiModel, permitted: false)).block)
            .equals(RealtimeCallBlock.callNotPermitted);
        check((await route(_owuiModel, permitted: null)).block)
            .equals(RealtimeCallBlock.callNotPermitted);
      },
    );

    test('an API key cannot open a realtime call', () async {
      check((await route(_owuiModel, token: 'sk-1234567890')).block)
          .equals(RealtimeCallBlock.noSessionToken);
    });
  });

  group('Direct', () {
    test('a Direct chat speaks through the Voice provider', () async {
      final registry = DirectModelRegistry();
      final model = registry.replaceProfileModels(_openAi, [
        DirectRemoteModel(id: 'gpt-5'),
      ]).single;

      final incomplete = await route(
        model,
        registry: registry,
        voice: (
          profile: _openAi,
          settings: const DirectVoiceProviderSettings(profileId: 'voice'),
        ),
      );
      check(incomplete.block).equals(RealtimeCallBlock.voiceProviderIncomplete);

      final ready = await route(
        model,
        registry: registry,
        voice: (
          profile: _openAi,
          settings: DirectVoiceProviderSettings.forConnection(_openAi),
        ),
      );
      final bridge = ready.bridge;
      check(bridge).isA<DirectRealtimeBridge>();
      check(
        (bridge! as DirectRealtimeBridge).uri.toString(),
      ).equals('wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini');
    });
  });

  test('a Hermes answer waiting for the user is an approval', () {
    ChatMessage hermes(String id, Map<String, Object?> waiting) => ChatMessage(
      id: id,
      role: 'assistant',
      content: '',
      timestamp: DateTime.utc(2026),
      isStreaming: true,
      metadata: {'transport': kHermesTransport, ...waiting},
    );

    final snapshot = realtimeChatSnapshot([
      hermes('a1', {
        kHermesApprovalMeta: {'state': 'pending', 'approvalId': 'x'},
      }),
      hermes('a2', {
        kHermesDecisionMeta: {'state': 'pending', 'requestId': 'y'},
      }),
      hermes('a3', {
        kHermesApprovalMeta: {'state': 'approved', 'approvalId': 'x'},
      }),
    ]);

    check(snapshot.map((entry) => entry['content'])).deepEquals([
      '[Chat model answer; message a1; approval]',
      '[Chat model answer; message a2; approval]',
      '[Chat model answer; message a3; working]',
    ]);
  });

  test('a call writes nothing to a chat it did not start in', () async {
    final container = ProviderContainer(
      overrides: [
        activeConversationProvider.overrideWith(
          () => _Active(_chat('chat-1')),
        ),
      ],
    );
    addTearDown(container.dispose);
    final host = container.read(
      Provider((ref) => ChatBridgeCallHost(ref, onNotice: (_) {})),
    );
    check(host.chatId).equals('chat-1');

    container.read(activeConversationProvider.notifier).set(_chat('chat-2'));

    // Nor does its voice read the chat open now.
    container.read(chatMessagesProvider.notifier).addMessages([
      ChatMessage(
        id: 'u2',
        role: 'user',
        content: 'Something private',
        timestamp: DateTime.utc(2026),
      ),
    ]);
    check(realtimeChatSnapshot(container.read(chatMessagesProvider)))
        .isNotEmpty();
    check(host.chatSnapshot()).isEmpty();
    await check(
      host.recordExchange(
        const RealtimeVoiceExchange(
          userText: 'Thanks',
          userVoice: {},
          voiceModel: 'gpt-realtime',
          replyText: 'You are welcome.',
          replyVoice: {},
        ),
      ),
    ).throws<StateError>();
    await check(host.delegate('Plan my week', userVoice: const {}))
        .throws<StateError>();
  });

  test('a call without a chat does not adopt one the user opens', () {
    final container = ProviderContainer(
      overrides: [activeConversationProvider.overrideWith(() => _Active(null))],
    );
    addTearDown(container.dispose);
    final host = container.read(
      Provider((ref) => ChatBridgeCallHost(ref, onNotice: (_) {})),
    );

    final opened = _chat('chat-2').copyWith(
      messages: [
        ChatMessage(
          id: 'u1',
          role: 'user',
          content: 'Earlier',
          timestamp: DateTime.utc(2026),
        ),
      ],
    );
    check(host.chatId).isNull();
    check(host.createdChat(opened)).isFalse();
  });

  test('the voice reads the chat with each answer labeled', () {
    final snapshot = realtimeChatSnapshot([
      ChatMessage(
        id: 'u1',
        role: 'user',
        content: 'Plan my trip',
        timestamp: DateTime.utc(2026),
      ),
      ChatMessage(
        id: 'a1',
        role: 'assistant',
        content:
            '<details type="reasoning" done="true">\n<summary>Thought</summary>\n'
            '> hmm\n</details>\nDay 1: Oslo.',
        timestamp: DateTime.utc(2026),
        metadata: const {
          kMessageVoiceMetadataKey: {
            'model': 'gpt-realtime',
            'speech': [
              {'transcript': 'Let me plan that.'},
            ],
          },
        },
      ),
      ChatMessage(
        id: 'a2',
        role: 'assistant',
        content: '',
        timestamp: DateTime.utc(2026),
        isStreaming: true,
      ),
    ]);

    check(snapshot).deepEquals([
      {'role': 'user', 'content': 'Plan my trip'},
      {
        'role': 'assistant',
        'content':
            '[Chat model answer; message a1; completed]\nDay 1: Oslo.\n'
            '${kHistoricalVoiceTranscriptPrefix}Let me plan that.',
      },
      {
        'role': 'assistant',
        'content': '[Chat model answer; message a2; working]',
      },
    ]);
  });
}

final class _StatusBridge implements HermesDashboardBridge {
  _StatusBridge(this.body);

  final String body;

  @override
  Future<({int status, String body})> request(
    String method,
    Uri url, {
    String? body,
  }) async => (status: 200, body: this.body);

  @override
  Future<void> reload() async {}

  @override
  Future<void> close() async {}
}
