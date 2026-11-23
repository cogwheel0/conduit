import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/services/chat_backend_readiness.dart';
import 'package:conduit_core/features/chat/services/chat_message_actions.dart';
import 'package:conduit_core/features/chat/services/historical_message_regeneration.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_handle.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_store.dart';
import 'package:conduit_core/features/librechat/models/librechat_model.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

final class _OpenDatabaseAccess extends OpenWebUiDatabaseAccessNotifier {
  @override
  OpenWebUiDatabaseAccessPhase build() => OpenWebUiDatabaseAccessPhase.open;
}

final class _Hermes extends HermesConfigController {
  _Hermes(this.config);

  final HermesConfig config;

  @override
  HermesConfig build() => config;

  @override
  Future<String> ensureSessionKey() async => 'memory';
}

final class _Auth extends AuthStateManager {
  _Auth(this.settled);

  final AuthState settled;

  @override
  Future<AuthState> build() async => settled;
}

final class _Active extends ActiveConversationNotifier {
  _Active(this.conversation);

  final Conversation conversation;

  @override
  Conversation? build() => conversation;
}

final class _Transcript extends ChatMessagesNotifier {
  _Transcript(this.initial);

  final List<ChatMessage> initial;

  @override
  List<ChatMessage> build() => initial;
}

final class _Selected extends SelectedModel {
  _Selected(this.model);

  final Model model;

  @override
  Model build() => model;
}

const _apiKeyHermes = HermesConfig(
  enabled: true,
  baseUrl: 'https://agent.example.test',
  apiKey: 'synthetic-key',
  sessionKey: 'memory',
);

final _gatewayAwaitingSignIn = HermesConfig(
  enabled: true,
  baseUrl: 'https://agent.example.test',
  mode: HermesBackendMode.desktopGateway,
  desktopAuthKind: HermesDesktopAuthKind.nativePkce,
  desktopCredentials: HermesDesktopCredentials(),
);

HermesApiService _hermesService() =>
    HermesApiService(config: _apiKeyHermes, dio: Dio());

ApiService _api() => ApiService(
  serverConfig: const ServerConfig(
    id: 'server',
    name: 'Server',
    url: 'https://server.example.test',
  ),
  workerManager: WorkerManager(),
);

const _signedIn = AuthState(
  status: AuthStatus.authenticated,
  token: 'synthetic-token',
  user: User(
    id: 'user-1',
    username: 'river',
    email: 'river@example.test',
    role: 'user',
  ),
);

const _signedOut = AuthState(status: AuthStatus.unauthenticated);

LibreChatSessionHandle _libreChatSession() {
  final handle = LibreChatSessionHandle(
    session: const LibreChatSession(
      accessToken: 'synthetic-access',
      user: LibreChatUser(id: 'lc-user'),
    ),
    store: InMemoryLibreChatSessionStore(),
    renew: (current) async => current,
  );
  addTearDown(handle.dispose);
  return handle;
}

final _profile = DirectConnectionProfile(
  id: 'profile',
  name: 'Provider',
  adapterKey: kOpenAiCompatibleAdapterKey,
  baseUrl: 'https://provider.example.test/v1',
  modelIdPrefix: 'pfx',
);

Model _directModel(DirectModelRegistry registry, DirectModelSource source) =>
    registry
        .replaceProfileModels(
          _profile,
          [DirectRemoteModel(id: 'm', name: 'm')],
          source: source,
          openWebUiUrlIndex: source == DirectModelSource.openWebUi ? 1 : null,
        )
        .single;

final _libreChatModel = libreChatCatalog(
  startupConfig: const {},
  endpoints: const {
    'openAI': {'order': 0},
  },
  models: const {
    'openAI': ['synthetic-model'],
  },
).single;

const _openWebUiModel = Model(id: 'server-model', name: 'Server model');

Conversation _nativeHermesChat() => markNativeHermesConversation(
  Conversation(
    id: 'local:hermes_session-1',
    title: 'Agent chat',
    createdAt: DateTime.utc(2026, 11, 1),
    updatedAt: DateTime.utc(2026, 11, 1),
  ),
);

void main() {
  setUp(() => PreferencesStore.debugOverride(InMemoryKeyValueStore()));
  tearDown(PreferencesStore.debugReset);

  ProviderContainer containerWith({
    HermesConfig hermes = const HermesConfig(),
    HermesApiService? hermesService,
    LibreChatSessionHandle? libreChat,
    ApiService? api,
    AuthState auth = _signedOut,
    DirectModelRegistry? registry,
    bool reviewerMode = false,
    List<Override> extra = const [],
  }) {
    final container = ProviderContainer(
      overrides: [
        hermesConfigProvider.overrideWith(() => _Hermes(hermes)),
        hermesApiServiceProvider.overrideWithValue(hermesService),
        libreChatSessionHandleProvider.overrideWithValue(libreChat),
        apiServiceProvider.overrideWithValue(api),
        authStateManagerProvider.overrideWith(() => _Auth(auth)),
        directModelRegistryProvider.overrideWithValue(
          registry ?? DirectModelRegistry(),
        ),
        reviewerModeProvider.overrideWithValue(reviewerMode),
        ...extra,
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('chatBackendNotReady', () {
    test('Hermes: not set up, waiting for its sign-in, or ready', () {
      check(chatBackendNotReady(containerWith(), hermesSyntheticModel()))
          .equals(ChatBackendNotReady.hermesNotConfigured);
      check(
        chatBackendNotReady(
          containerWith(
            hermes: _gatewayAwaitingSignIn,
            hermesService: _hermesService(),
          ),
          hermesSyntheticModel(),
        ),
      ).equals(ChatBackendNotReady.hermesAwaitsSignIn);
      check(
        chatBackendNotReady(
          containerWith(hermes: _apiKeyHermes, hermesService: _hermesService()),
          hermesSyntheticModel(),
        ),
      ).isNull();
    });

    // Regenerate and edit answer through the open chat's backend whichever
    // model is picked.
    test('a Hermes chat is asked of Hermes whatever model is picked', () {
      check(
        chatBackendNotReady(
          containerWith(api: _api(), auth: _signedIn),
          _openWebUiModel,
          conversation: _nativeHermesChat(),
        ),
      ).equals(ChatBackendNotReady.hermesNotConfigured);
    });

    test('LibreChat: signed out or signed in', () {
      check(chatBackendNotReady(containerWith(), _libreChatModel))
          .equals(ChatBackendNotReady.libreChatSignedOut);
      check(
        chatBackendNotReady(
          containerWith(libreChat: _libreChatSession()),
          _libreChatModel,
        ),
      ).isNull();
    });

    test(
      'Open WebUI: no server, signed out, signed in, or reviewer mode',
      () async {
        check(chatBackendNotReady(containerWith(), _openWebUiModel))
            .equals(ChatBackendNotReady.openWebUiSignedOut);

        final signedOut = containerWith(api: _api());
        await signedOut.read(authStateManagerProvider.future);
        check(chatBackendNotReady(signedOut, _openWebUiModel))
            .equals(ChatBackendNotReady.openWebUiSignedOut);

        final signedIn = containerWith(api: _api(), auth: _signedIn);
        await signedIn.read(authStateManagerProvider.future);
        check(chatBackendNotReady(signedIn, _openWebUiModel)).isNull();

        check(
          chatBackendNotReady(
            containerWith(reviewerMode: true),
            _openWebUiModel,
          ),
        ).isNull();
      },
    );

    test('Direct: a device connection needs no server; one through Open '
        'WebUI does; one whose connection is gone cannot answer', () {
      final device = DirectModelRegistry();
      check(
        chatBackendNotReady(
          containerWith(registry: device),
          _directModel(device, DirectModelSource.device),
        ),
      ).isNull();

      final server = DirectModelRegistry();
      check(
        chatBackendNotReady(
          containerWith(registry: server),
          _directModel(server, DirectModelSource.openWebUi),
        ),
      ).equals(ChatBackendNotReady.openWebUiSignedOut);

      final gone = _directModel(
        DirectModelRegistry(),
        DirectModelSource.device,
      );
      check(
        chatBackendNotReady(containerWith(api: _api(), auth: _signedIn), gone),
      ).equals(ChatBackendNotReady.modelUnavailable);
    });
  });

  // The phone wrote the question and an answer reading "Hermes is not
  // configured" into the chat; the desktop refused and wrote nothing.
  group('a turn whose backend is not ready writes nothing', () {
    late AppDatabase database;

    setUp(() => database = AppDatabase(NativeDatabase.memory()));
    tearDown(() => database.close());

    ProviderContainer composerHolding(Model model) => containerWith(
      extra: [
        openWebUiDatabaseAccessProvider.overrideWith(_OpenDatabaseAccess.new),
        appDatabaseProvider.overrideWithValue(database),
        socketServiceProvider.overrideWithValue(null),
        selectedModelProvider.overrideWith(() => _Selected(model)),
      ],
    )..listen(chatMessagesProvider, (_, _) {});

    ProviderContainer unconfiguredHermes() =>
        composerHolding(hermesSyntheticModel());

    final question = ChatMessage(
      id: 'q1',
      role: 'user',
      content: 'Plan the week',
      timestamp: DateTime.utc(2026, 11, 2),
    );
    final answer = ChatMessage(
      id: 'a1',
      role: 'assistant',
      content: 'Monday: rest',
      timestamp: DateTime.utc(2026, 11, 2),
      metadata: const {'parentId': 'q1'},
    );

    test('a send', () async {
      final container = unconfiguredHermes();

      await check(durableSend(container, 'Plan the week', null))
          .throws<ChatBackendNotReadyException>(
            (it) => it
                .has((error) => error.reason, 'reason')
                .equals(ChatBackendNotReady.hermesNotConfigured),
          );
      check(container.read(chatMessagesProvider)).isEmpty();
    });

    test('a regenerate', () async {
      final container = unconfiguredHermes();
      container.read(chatMessagesProvider.notifier).setMessages([
        question,
        answer,
      ]);

      await check(regenerateHistoricalMessageById(container, 'a1'))
          .throws<ChatBackendNotReadyException>();
      check(container.read(chatMessagesProvider))
          .deepEquals([question, answer]);
    });

    test('an edit', () async {
      final container = unconfiguredHermes();
      container.read(chatMessagesProvider.notifier).setMessages([
        question,
        answer,
      ]);

      await check(
        resendEditedUserMessage(
          container,
          messageId: 'q1',
          newText: 'Plan the month',
        ),
      ).throws<ChatBackendNotReadyException>();
      check(container.read(chatMessagesProvider))
          .deepEquals([question, answer]);
    });

    // The edit used to cut the transcript first and fail on the model after.
    test('an edit on a model whose connection was removed', () async {
      final container = composerHolding(
        _directModel(DirectModelRegistry(), DirectModelSource.device),
      );
      container.read(chatMessagesProvider.notifier).setMessages([
        question,
        answer,
      ]);

      await check(
        resendEditedUserMessage(
          container,
          messageId: 'q1',
          newText: 'Plan the month',
        ),
      ).throws<ChatBackendNotReadyException>(
        (it) => it
            .has((error) => error.reason, 'reason')
            .equals(ChatBackendNotReady.modelUnavailable),
      );
      check(container.read(chatMessagesProvider))
          .deepEquals([question, answer]);
    });
  });

  // A Compare Models answer regenerates on its own column's model, a model
  // of the chat's server, whatever the composer holds.
  group('a comparison column is asked of its chat\'s server', () {
    final question = ChatMessage(
      id: 'q1',
      role: 'user',
      content: 'Name a river',
      timestamp: DateTime.utc(2026, 11, 2),
      metadata: const {
        'models': ['model-a', 'model-b'],
      },
    );
    final answer = ChatMessage(
      id: 'a1',
      role: 'assistant',
      content: 'The Tay',
      model: 'model-a',
      timestamp: DateTime.utc(2026, 11, 2),
      metadata: const {'parentId': 'q1'},
    );

    ProviderContainer comparison({required bool signedIn}) {
      final chat = withChatStorageProvenance(
        Conversation(
          id: 'chat-1',
          title: 'Rivers',
          createdAt: DateTime.utc(2026, 11, 2),
          updatedAt: DateTime.utc(2026, 11, 2),
          messages: [question, answer],
        ),
        ChatStorageKind.openWebUi,
      );
      final container = containerWith(
        api: signedIn ? _api() : null,
        extra: [
          isAuthenticatedProvider2.overrideWithValue(signedIn),
          activeConversationProvider.overrideWith(() => _Active(chat)),
          chatMessagesProvider.overrideWith(
            () => _Transcript([question, answer]),
          ),
          socketServiceProvider.overrideWithValue(null),
          // Not set up: a send from the composer would be refused.
          selectedModelProvider.overrideWith(
            () => _Selected(hermesSyntheticModel()),
          ),
        ],
      )..listen(chatMessagesProvider, (_, _) {});
      return container;
    }

    test('an unconfigured Hermes in the composer does not refuse it', () {
      final container = comparison(signedIn: true);
      final model = regenerationModelFor(
        container,
        question: question,
        answer: answer,
      );
      check(model).isNotNull().has((it) => it.id, 'id').equals('model-a');
      check(
        chatBackendNotReady(
          container,
          model!,
          conversation: container.read(activeConversationProvider),
        ),
      ).isNull();
    });

    test('a signed-out server does', () async {
      final container = comparison(signedIn: false);
      await check(regenerateHistoricalMessageById(container, 'a1'))
          .throws<ChatBackendNotReadyException>(
            (it) => it
                .has((error) => error.reason, 'reason')
                .equals(ChatBackendNotReady.openWebUiSignedOut),
          );
      check(container.read(chatMessagesProvider))
          .deepEquals([question, answer]);
    });
  });
}
