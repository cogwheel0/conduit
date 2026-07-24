import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/auth/auth_state_manager.dart';
import 'package:conduit/core/database/chat_database_repository.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/database/mappers/conversation_assembler.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/providers/backend_mode_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [HermesConfigController] stand-in that yields a fixed config without
/// touching shared preferences or secure storage (the real `build()` loads
/// secrets asynchronously, which is unavailable in a plain unit test).
class _FakeHermesConfigController extends HermesConfigController {
  _FakeHermesConfigController(this._config);

  final HermesConfig _config;

  @override
  HermesConfig build() => _config;
}

class _FakePreferredBackendController extends PreferredBackendController {
  _FakePreferredBackendController(this._backend);

  final PreferredBackend _backend;

  @override
  PreferredBackend build() => _backend;
}

class _MutablePreferredBackendController extends PreferredBackendController {
  _MutablePreferredBackendController(this._initial);

  final PreferredBackend _initial;

  @override
  PreferredBackend build() => _initial;

  void publish(PreferredBackend backend) => state = backend;
}

class _FakeAuthStateManager extends AuthStateManager {
  _FakeAuthStateManager(this._status);

  final AuthStatus _status;

  @override
  Future<AuthState> build() async => AuthState(
    status: _status,
    token: _status == AuthStatus.authenticated ? 'openwebui-token' : null,
  );
}

class _RefreshingAuthStateManager extends AuthStateManager {
  @override
  Future<AuthState> build() async => const AuthState(
    status: AuthStatus.authenticated,
    token: 'openwebui-token',
  );

  void beginRefresh() => state = const AsyncData(
    AuthState(
      status: AuthStatus.loading,
      token: 'openwebui-token',
      isLoading: true,
    ),
  );

  void finishSignedOut() =>
      state = const AsyncData(AuthState(status: AuthStatus.unauthenticated));
}

class _CandidateTokenAuthStateManager extends AuthStateManager {
  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.unauthenticated);

  void beginForegroundLogin() => state = const AsyncData(
    AuthState(
      status: AuthStatus.loading,
      token: 'unvalidated-candidate-token',
      isLoading: true,
    ),
  );
}

class _PendingInitialAuthStateManager extends AuthStateManager {
  _PendingInitialAuthStateManager(this._authState);

  final Future<AuthState> _authState;

  @override
  Future<AuthState> build() => _authState;
}

class _BackgroundLoginAuthStateManager extends AuthStateManager {
  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.loading, isLoading: true);

  void finishAuthenticated() => state = const AsyncData(
    AuthState(status: AuthStatus.authenticated, token: 'openwebui-token'),
  );
}

class _TokenRetainingErrorAuthStateManager extends AuthStateManager {
  @override
  Future<AuthState> build() async => const AuthState(
    status: AuthStatus.authenticated,
    token: 'openwebui-token',
  );

  void publishError() => state = const AsyncData(
    AuthState(
      status: AuthStatus.error,
      token: 'openwebui-token',
      error: 'connection issue',
    ),
  );
}

class _SessionSwitchAuthStateManager extends AuthStateManager {
  @override
  Future<AuthState> build() async => const AuthState(
    status: AuthStatus.authenticated,
    token: 'session-a-token',
  );

  void publishSessionB() => state = const AsyncData(
    AuthState(status: AuthStatus.authenticated, token: 'session-b-token'),
  );
}

class _FixedDirectDiscovery extends DirectModelDiscoveryController {
  _FixedDirectDiscovery(this._models);

  final List<Model> _models;

  @override
  Future<DirectModelDiscoveryState> build() async =>
      DirectModelDiscoveryState(models: _models);

  @override
  Future<void> refresh() async {}
}

class _ControllableDirectDiscovery extends DirectModelDiscoveryController {
  _ControllableDirectDiscovery(this._initial);

  final Future<DirectModelDiscoveryState> _initial;

  @override
  Future<DirectModelDiscoveryState> build() => _initial;

  void publish(List<Model> models) {
    state = AsyncData(DirectModelDiscoveryState(models: models));
  }

  @override
  Future<void> refresh() async {}
}

class _FixedModels extends Models {
  _FixedModels(this._models);

  final List<Model> _models;

  @override
  Future<List<Model>> build() async => _models;
}

class _FixedConversations extends Conversations {
  _FixedConversations(this._conversations);

  final List<Conversation> _conversations;

  @override
  Future<List<Conversation>> build() async => _conversations;
}

class _PendingConversations extends Conversations {
  _PendingConversations(this._conversations);

  final Future<List<Conversation>> _conversations;

  @override
  Future<List<Conversation>> build() => _conversations;
}

class _ThrowingChatDatabaseRepository extends Fake
    implements ChatDatabaseRepository {
  _ThrowingChatDatabaseRepository(this.error);

  final Object error;

  @override
  Future<LocatedConversation?> loadConversation(
    String chatId, {
    ChatStorageKind? preferred,
    ConversationParseOffload? offload,
    bool Function(ChatDatabaseLocation location)? locationIsCurrent,
  }) async {
    throw error;
  }
}

class _OpenWebUiPreferenceRepository extends Fake
    implements ChatDatabaseRepository {
  ChatStorageKind? preferredStorage;

  @override
  Future<LocatedConversation?> loadConversation(
    String chatId, {
    ChatStorageKind? preferred,
    ConversationParseOffload? offload,
    bool Function(ChatDatabaseLocation location)? locationIsCurrent,
  }) async {
    preferredStorage = preferred;
    if (preferred != ChatStorageKind.openWebUi) {
      throw AmbiguousChatStorageException(chatId);
    }
    return null;
  }
}

class _PendingModels extends Models {
  _PendingModels(this._models);

  final Future<List<Model>> _models;

  @override
  Future<List<Model>> build() => _models;
}

class _CachedOpenWebUiStorage extends Fake implements OptimizedStorageService {
  static const staleModel = Model(
    id: 'owui-stale',
    name: 'Signed-out OpenWebUI model',
  );
  final List<List<Model>> savedModelLists = <List<Model>>[];

  @override
  Future<List<Model>> getLocalModels() async => const [staleModel];

  @override
  Future<Model?> getLocalDefaultModel() async => staleModel;

  @override
  Future<void> saveLocalDefaultModel(Model? model) async {}

  @override
  Future<void> saveLocalModels(List<Model> models) async {
    savedModelLists.add(List<Model>.of(models));
  }
}

class _ThrowingDefaultModelStorage extends _CachedOpenWebUiStorage {
  @override
  Future<void> saveLocalDefaultModel(Model? model) async {
    throw StateError('default model cache is unavailable');
  }
}

class _RetainedOpenWebUiApi extends ApiService {
  _RetainedOpenWebUiApi(this.workerManager)
    : super(serverConfig: _server, workerManager: workerManager);

  final WorkerManager workerManager;

  @override
  Future<String?> getDefaultModel() async =>
      _CachedOpenWebUiStorage.staleModel.id;

  @override
  Future<List<Model>> getModels({bool includeHidden = false}) async => const [
    _CachedOpenWebUiStorage.staleModel,
  ];
}

class _CountingOpenWebUiApi extends _RetainedOpenWebUiApi {
  _CountingOpenWebUiApi(super.workerManager);

  var modelFetches = 0;

  @override
  Future<List<Model>> getModels({bool includeHidden = false}) async {
    modelFetches += 1;
    return super.getModels(includeHidden: includeHidden);
  }
}

class _ConversationFallbackApi extends _RetainedOpenWebUiApi {
  _ConversationFallbackApi(super.workerManager);

  var conversationFetches = 0;

  @override
  Future<Conversation> getConversation(String id) async {
    conversationFetches += 1;
    return Conversation(
      id: id,
      title: 'Recovered from OpenWebUI',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2),
    );
  }
}

const _usableHermes = HermesConfig(
  enabled: true,
  baseUrl: 'https://hermes.example/v1',
  apiKey: 'secret-key',
);

const _disabledHermes = HermesConfig(enabled: false);

// Enabled but missing the API key → not usable.
const _incompleteHermes = HermesConfig(
  enabled: true,
  baseUrl: 'https://hermes.example/v1',
);

const _server = ServerConfig(
  id: 'srv-1',
  name: 'Example',
  url: 'https://owui.example',
);

({DirectModelRegistry registry, Model model}) _directModelFixture() {
  final profile = DirectConnectionProfile(
    id: 'direct-profile',
    name: 'Direct provider',
    adapterKey: 'ollama',
    baseUrl: 'http://localhost:11434',
  );
  final registry = DirectModelRegistry();
  final model = registry.replaceProfileModels(profile, [
    DirectRemoteModel(id: 'local-model'),
  ]).single;
  return (registry: registry, model: model);
}

void main() {
  /// Builds a container wired for [hermesOnlyModeProvider] with all three of its
  /// inputs overridden.
  Future<ProviderContainer> makeContainer({
    required HermesConfig hermesConfig,
    required ServerConfig? activeServer,
    bool reviewerMode = false,
    PreferredBackend preferredBackend = PreferredBackend.unset,
    AuthStatus authStatus = AuthStatus.unauthenticated,
  }) async {
    final container = ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(reviewerMode),
        hermesConfigProvider.overrideWith(
          () => _FakeHermesConfigController(hermesConfig),
        ),
        activeServerProvider.overrideWith((ref) async => activeServer),
        preferredBackendProvider.overrideWith(
          () => _FakePreferredBackendController(preferredBackend),
        ),
        authStateManagerProvider.overrideWith(
          () => _FakeAuthStateManager(authStatus),
        ),
      ],
    );
    addTearDown(container.dispose);
    // Settle the active-server future so the derived provider reads AsyncData.
    await container.read(activeServerProvider.future);
    await container.read(authStateManagerProvider.future);
    return container;
  }

  group('hermesOnlyModeProvider', () {
    test('true when Hermes is usable and there is no OWUI server', () async {
      final container = await makeContainer(
        hermesConfig: _usableHermes,
        activeServer: null,
      );
      check(container.read(hermesOnlyModeProvider)).isTrue();
    });

    test(
      'false when Direct is primary and usable Hermes is also configured',
      () async {
        final container = await makeContainer(
          hermesConfig: _usableHermes,
          activeServer: null,
          preferredBackend: PreferredBackend.direct,
        );
        check(container.read(hermesOnlyModeProvider)).isFalse();
      },
    );

    test('false when an OWUI server is active', () async {
      final container = await makeContainer(
        hermesConfig: _usableHermes,
        activeServer: _server,
      );
      check(container.read(hermesOnlyModeProvider)).isFalse();
    });

    test(
      'true when preferred Hermes retains a signed-out OWUI server',
      () async {
        final container = await makeContainer(
          hermesConfig: _usableHermes,
          activeServer: _server,
          preferredBackend: PreferredBackend.hermes,
        );
        check(container.read(hermesOnlyModeProvider)).isTrue();
      },
    );

    test(
      'false when preferred Hermes also has an authenticated OWUI session',
      () async {
        final container = await makeContainer(
          hermesConfig: _usableHermes,
          activeServer: _server,
          preferredBackend: PreferredBackend.hermes,
          authStatus: AuthStatus.authenticated,
        );
        check(container.read(hermesOnlyModeProvider)).isFalse();
      },
    );

    test('false when Hermes is disabled', () async {
      final container = await makeContainer(
        hermesConfig: _disabledHermes,
        activeServer: null,
      );
      check(container.read(hermesOnlyModeProvider)).isFalse();
    });

    test('false when Hermes is enabled but not usable (no key)', () async {
      final container = await makeContainer(
        hermesConfig: _incompleteHermes,
        activeServer: null,
      );
      check(container.read(hermesOnlyModeProvider)).isFalse();
    });

    test('reviewer mode takes precedence over Hermes-only', () async {
      final container = await makeContainer(
        hermesConfig: _usableHermes,
        activeServer: null,
        reviewerMode: true,
      );
      check(container.read(hermesOnlyModeProvider)).isFalse();
    });

    test('false while the active OWUI server is still loading', () {
      final pendingServer = Completer<ServerConfig?>();
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          hermesConfigProvider.overrideWith(
            () => _FakeHermesConfigController(_usableHermes),
          ),
          activeServerProvider.overrideWith((ref) => pendingServer.future),
        ],
      );
      addTearDown(() {
        pendingServer.complete(null);
        container.dispose();
      });

      check(container.read(activeServerProvider).isLoading).isTrue();
      check(container.read(hermesOnlyModeProvider)).isFalse();
    });

    test(
      'true for preferred Hermes while an authenticated OWUI server loads',
      () async {
        final pendingServer = Completer<ServerConfig?>();
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_usableHermes),
            ),
            activeServerProvider.overrideWith((ref) => pendingServer.future),
            preferredBackendProvider.overrideWith(
              () => _FakePreferredBackendController(PreferredBackend.hermes),
            ),
            authStateManagerProvider.overrideWith(
              () => _FakeAuthStateManager(AuthStatus.authenticated),
            ),
          ],
        );
        addTearDown(() {
          pendingServer.complete(null);
          container.dispose();
        });
        await container.read(authStateManagerProvider.future);

        check(container.read(hermesOnlyModeProvider)).isTrue();
      },
    );

    test('false when loading the active OWUI server fails', () async {
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          hermesConfigProvider.overrideWith(
            () => _FakeHermesConfigController(_usableHermes),
          ),
          activeServerProvider.overrideWith(
            (ref) => Future<ServerConfig?>.error(StateError('storage failed')),
          ),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(activeServerProvider.future),
        throwsStateError,
      );
      check(container.read(activeServerProvider).hasError).isTrue();
      check(container.read(hermesOnlyModeProvider)).isFalse();
    });

    test(
      'true for preferred Hermes when an authenticated OWUI server fails',
      () async {
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_usableHermes),
            ),
            activeServerProvider.overrideWith(
              (ref) =>
                  Future<ServerConfig?>.error(StateError('storage failed')),
            ),
            preferredBackendProvider.overrideWith(
              () => _FakePreferredBackendController(PreferredBackend.hermes),
            ),
            authStateManagerProvider.overrideWith(
              () => _FakeAuthStateManager(AuthStatus.authenticated),
            ),
          ],
        );
        addTearDown(container.dispose);
        await container.read(authStateManagerProvider.future);

        await expectLater(
          container.read(activeServerProvider.future),
          throwsStateError,
        );
        check(container.read(hermesOnlyModeProvider)).isTrue();
      },
    );

    test(
      'stays true when OWUI refresh states retain a previous server',
      () async {
        Future<ServerConfig?> serverAttempt = Future.value(_server);
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_usableHermes),
            ),
            activeServerProvider.overrideWith((ref) => serverAttempt),
            preferredBackendProvider.overrideWith(
              () => _FakePreferredBackendController(PreferredBackend.hermes),
            ),
            authStateManagerProvider.overrideWith(
              () => _FakeAuthStateManager(AuthStatus.authenticated),
            ),
          ],
        );
        addTearDown(container.dispose);
        final subscription = container.listen(
          hermesOnlyModeProvider,
          (_, _) {},
        );
        addTearDown(subscription.close);
        await container.read(activeServerProvider.future);
        await container.read(authStateManagerProvider.future);
        check(subscription.read()).isFalse();

        final pendingServer = Completer<ServerConfig?>();
        serverAttempt = pendingServer.future;
        container.invalidate(activeServerProvider);
        await Future<void>.delayed(Duration.zero);

        final refreshing = container.read(activeServerProvider);
        check(refreshing.isLoading).isTrue();
        check(refreshing.hasValue).isTrue();
        check(subscription.read()).isTrue();

        pendingServer.complete(_server);
        await container.read(activeServerProvider.future);
        serverAttempt = Future<ServerConfig?>.error(
          StateError('refresh failed'),
        );
        container.invalidate(activeServerProvider);
        await expectLater(
          container.read(activeServerProvider.future),
          throwsStateError,
        );

        final failedRefresh = container.read(activeServerProvider);
        check(failedRefresh.hasError).isTrue();
        check(failedRefresh.hasValue).isTrue();
        check(subscription.read()).isTrue();
      },
    );
  });

  group('signed-out retained OpenWebUI model reconciliation', () {
    for (final preferredBackend in [
      PreferredBackend.hermes,
      PreferredBackend.direct,
    ]) {
      test(
        'modelsProvider replaces stale selection for ${preferredBackend.name}',
        () async {
          final direct = _directModelFixture();
          final expectedModel = preferredBackend == PreferredBackend.hermes
              ? hermesSyntheticModel()
              : direct.model;
          final container = ProviderContainer(
            overrides: [
              reviewerModeProvider.overrideWithValue(false),
              authStateManagerProvider.overrideWith(
                () => _FakeAuthStateManager(AuthStatus.unauthenticated),
              ),
              preferredBackendProvider.overrideWith(
                () => _FakePreferredBackendController(preferredBackend),
              ),
              hermesConfigProvider.overrideWith(
                () => _FakeHermesConfigController(
                  preferredBackend == PreferredBackend.hermes
                      ? _usableHermes
                      : _disabledHermes,
                ),
              ),
              directModelRegistryProvider.overrideWithValue(direct.registry),
              directModelDiscoveryProvider.overrideWith(
                () => _FixedDirectDiscovery(
                  preferredBackend == PreferredBackend.direct
                      ? [direct.model]
                      : const [],
                ),
              ),
            ],
          );
          addTearDown(container.dispose);
          await container.read(authStateManagerProvider.future);
          await container.read(directModelDiscoveryProvider.future);
          container
              .read(selectedModelProvider.notifier)
              .set(_CachedOpenWebUiStorage.staleModel);
          container.read(isManualModelSelectionProvider.notifier).set(true);

          await container.read(modelsProvider.future);
          await Future<void>.delayed(Duration.zero);

          final selected = container.read(selectedModelProvider);
          check(selected).isNotNull();
          if (preferredBackend == PreferredBackend.hermes) {
            check(isHermesModel(selected!)).isTrue();
          } else {
            check(selected).identicalTo(expectedModel);
            check(direct.registry.resolve(selected!)).isNotNull();
          }
          check(container.read(isManualModelSelectionProvider)).isFalse();
        },
      );

      test(
        'defaultModel ignores retained OpenWebUI API for ${preferredBackend.name}',
        () async {
          final direct = _directModelFixture();
          final localModel = preferredBackend == PreferredBackend.hermes
              ? hermesSyntheticModel()
              : direct.model;
          final workerManager = WorkerManager();
          final api = _RetainedOpenWebUiApi(workerManager);
          final container = ProviderContainer(
            overrides: [
              reviewerModeProvider.overrideWithValue(false),
              authStateManagerProvider.overrideWith(
                () => _FakeAuthStateManager(AuthStatus.unauthenticated),
              ),
              preferredBackendProvider.overrideWith(
                () => _FakePreferredBackendController(preferredBackend),
              ),
              apiServiceProvider.overrideWithValue(api),
              appSettingsProvider.overrideWithValue(
                const AppSettings(defaultModel: 'owui-stale'),
              ),
              optimizedStorageServiceProvider.overrideWithValue(
                _CachedOpenWebUiStorage(),
              ),
              hermesConfigProvider.overrideWith(
                () => _FakeHermesConfigController(
                  preferredBackend == PreferredBackend.hermes
                      ? _usableHermes
                      : _disabledHermes,
                ),
              ),
              directModelRegistryProvider.overrideWithValue(direct.registry),
              directModelDiscoveryProvider.overrideWith(
                () => _FixedDirectDiscovery(
                  preferredBackend == PreferredBackend.direct
                      ? [direct.model]
                      : const [],
                ),
              ),
              modelsProvider.overrideWith(() => _FixedModels([localModel])),
            ],
          );
          addTearDown(container.dispose);
          addTearDown(workerManager.dispose);
          await container.read(authStateManagerProvider.future);
          await container.read(directModelDiscoveryProvider.future);
          container
              .read(selectedModelProvider.notifier)
              .set(_CachedOpenWebUiStorage.staleModel);
          container.read(isManualModelSelectionProvider.notifier).set(true);

          final selected = await container.read(defaultModelProvider.future);

          check(selected).isNotNull();
          if (preferredBackend == PreferredBackend.hermes) {
            check(isHermesModel(selected!)).isTrue();
          } else {
            check(selected).identicalTo(localModel);
          }
          check(container.read(selectedModelProvider)).identicalTo(selected);
          check(container.read(isManualModelSelectionProvider)).isFalse();
        },
      );

      test(
        'sign-out cleanup rebuild keeps ${preferredBackend.name} selected',
        () async {
          final direct = _directModelFixture();
          final workerManager = WorkerManager();
          final container = ProviderContainer(
            overrides: [
              reviewerModeProvider.overrideWithValue(false),
              authStateManagerProvider.overrideWith(
                () => _FakeAuthStateManager(AuthStatus.unauthenticated),
              ),
              preferredBackendProvider.overrideWith(
                () => _FakePreferredBackendController(preferredBackend),
              ),
              apiServiceProvider.overrideWithValue(
                _RetainedOpenWebUiApi(workerManager),
              ),
              hermesConfigProvider.overrideWith(
                () => _FakeHermesConfigController(
                  preferredBackend == PreferredBackend.hermes
                      ? _usableHermes
                      : _disabledHermes,
                ),
              ),
              directModelRegistryProvider.overrideWithValue(direct.registry),
              directModelDiscoveryProvider.overrideWith(
                () => _FixedDirectDiscovery(
                  preferredBackend == PreferredBackend.direct
                      ? [direct.model]
                      : const [],
                ),
              ),
            ],
          );
          addTearDown(container.dispose);
          addTearDown(workerManager.dispose);
          await container.read(authStateManagerProvider.future);
          await container.read(directModelDiscoveryProvider.future);

          container
              .read(selectedModelProvider.notifier)
              .set(_CachedOpenWebUiStorage.staleModel);
          container.read(isManualModelSelectionProvider.notifier).set(true);
          container.invalidate(selectedModelProvider);
          container.invalidate(defaultModelProvider);
          await Future<void>.delayed(Duration.zero);

          final selected = container.read(selectedModelProvider);
          check(selected).isNotNull();
          if (preferredBackend == PreferredBackend.hermes) {
            check(isHermesModel(selected!)).isTrue();
          } else {
            check(selected).identicalTo(direct.model);
            check(direct.registry.resolve(selected!)).isNotNull();
          }
          await Future<void>.delayed(Duration.zero);
          check(container.read(isManualModelSelectionProvider)).isFalse();
        },
      );
    }

    test(
      'direct-only defaultModel honors the configured direct model',
      () async {
        final profile = DirectConnectionProfile(
          id: 'direct-profile',
          name: 'Direct provider',
          adapterKey: 'ollama',
          baseUrl: 'http://localhost:11434',
        );
        final registry = DirectModelRegistry();
        final directModels = registry.replaceProfileModels(profile, [
          DirectRemoteModel(id: 'first-model'),
          DirectRemoteModel(id: 'preferred-model'),
        ]);
        final preferredModel = directModels.last;
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            authStateManagerProvider.overrideWith(
              () => _FakeAuthStateManager(AuthStatus.unauthenticated),
            ),
            preferredBackendProvider.overrideWith(
              () => _FakePreferredBackendController(PreferredBackend.direct),
            ),
            apiServiceProvider.overrideWithValue(null),
            appSettingsProvider.overrideWithValue(
              AppSettings(defaultModel: preferredModel.id),
            ),
            optimizedStorageServiceProvider.overrideWithValue(
              _CachedOpenWebUiStorage(),
            ),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_disabledHermes),
            ),
            directModelRegistryProvider.overrideWithValue(registry),
            directModelDiscoveryProvider.overrideWith(
              () => _FixedDirectDiscovery(directModels),
            ),
          ],
        );
        addTearDown(container.dispose);
        await container.read(authStateManagerProvider.future);
        await container.read(directModelDiscoveryProvider.future);
        container.read(selectedModelProvider.notifier).set(directModels.first);
        container.read(isManualModelSelectionProvider.notifier).set(false);

        final selected = await container.read(defaultModelProvider.future);

        check(selected).identicalTo(preferredModel);
        check(
          container.read(selectedModelProvider),
        ).identicalTo(preferredModel);
      },
    );

    test(
      'direct-only cold selection starts on the configured direct model',
      () async {
        final profile = DirectConnectionProfile(
          id: 'direct-profile',
          name: 'Direct provider',
          adapterKey: 'ollama',
          baseUrl: 'http://localhost:11434',
        );
        final registry = DirectModelRegistry();
        final directModels = registry.replaceProfileModels(profile, [
          DirectRemoteModel(id: 'first-model'),
          DirectRemoteModel(id: 'preferred-model'),
        ]);
        final preferredModel = directModels.last;
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            authStateManagerProvider.overrideWith(
              () => _FakeAuthStateManager(AuthStatus.unauthenticated),
            ),
            preferredBackendProvider.overrideWith(
              () => _FakePreferredBackendController(PreferredBackend.direct),
            ),
            apiServiceProvider.overrideWithValue(null),
            appSettingsProvider.overrideWithValue(
              AppSettings(defaultModel: preferredModel.id),
            ),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_disabledHermes),
            ),
            directModelRegistryProvider.overrideWithValue(registry),
            directModelDiscoveryProvider.overrideWith(
              () => _FixedDirectDiscovery(directModels),
            ),
          ],
        );
        addTearDown(container.dispose);
        await container.read(authStateManagerProvider.future);
        await container.read(directModelDiscoveryProvider.future);

        check(
          container.read(selectedModelProvider),
        ).identicalTo(preferredModel);
      },
    );

    test(
      'auth refresh preserves OWUI selection until terminal local fallback',
      () async {
        final workerManager = WorkerManager();
        final api = _RetainedOpenWebUiApi(workerManager);
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            preferredBackendProvider.overrideWith(
              () => _FakePreferredBackendController(PreferredBackend.hermes),
            ),
            authStateManagerProvider.overrideWith(
              _RefreshingAuthStateManager.new,
            ),
            apiServiceProvider.overrideWithValue(api),
            optimizedStorageServiceProvider.overrideWithValue(
              _CachedOpenWebUiStorage(),
            ),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_usableHermes),
            ),
            directModelDiscoveryProvider.overrideWith(
              () => _FixedDirectDiscovery(const []),
            ),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(workerManager.dispose);
        await container.read(authStateManagerProvider.future);
        await container.read(directModelDiscoveryProvider.future);
        await container.read(modelsProvider.future);
        container
            .read(selectedModelProvider.notifier)
            .set(_CachedOpenWebUiStorage.staleModel);
        container.read(isManualModelSelectionProvider.notifier).set(true);

        (container.read(authStateManagerProvider.notifier)
                as _RefreshingAuthStateManager)
            .beginRefresh();
        await container.read(modelsProvider.future);
        final selectedDefault = await container.read(
          defaultModelProvider.future,
        );

        check(selectedDefault).identicalTo(_CachedOpenWebUiStorage.staleModel);
        check(
          container.read(selectedModelProvider),
        ).identicalTo(_CachedOpenWebUiStorage.staleModel);
        check(container.read(isManualModelSelectionProvider)).isTrue();

        (container.read(authStateManagerProvider.notifier)
                as _RefreshingAuthStateManager)
            .finishSignedOut();
        await container.read(modelsProvider.future);
        await Future<void>.delayed(Duration.zero);

        final accountlessSelection = container.read(selectedModelProvider);
        check(accountlessSelection).isNotNull();
        check(isHermesModel(accountlessSelection!)).isTrue();
        check(container.read(isManualModelSelectionProvider)).isFalse();
      },
    );

    test(
      'explicit model refresh retains remote cache during token revalidation',
      () async {
        final workerManager = WorkerManager();
        final storage = _CachedOpenWebUiStorage();
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            preferredBackendProvider.overrideWith(
              () => _FakePreferredBackendController(PreferredBackend.owui),
            ),
            authStateManagerProvider.overrideWith(
              _RefreshingAuthStateManager.new,
            ),
            apiServiceProvider.overrideWithValue(
              _RetainedOpenWebUiApi(workerManager),
            ),
            optimizedStorageServiceProvider.overrideWithValue(storage),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_disabledHermes),
            ),
            directModelDiscoveryProvider.overrideWith(
              () => _FixedDirectDiscovery(const []),
            ),
            modelsProvider.overrideWith(
              () => _FixedModels(const [_CachedOpenWebUiStorage.staleModel]),
            ),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(workerManager.dispose);
        await container.read(authStateManagerProvider.future);
        await container.read(modelsProvider.future);
        storage.savedModelLists.clear();

        (container.read(authStateManagerProvider.notifier)
                as _RefreshingAuthStateManager)
            .beginRefresh();
        await container.read(modelsProvider.notifier).refresh();
        await Future<void>.delayed(Duration.zero);

        check(
          container.read(modelsProvider).requireValue,
        ).deepEquals(const [_CachedOpenWebUiStorage.staleModel]);
        check(
          storage.savedModelLists.any((models) => models.isEmpty),
        ).isFalse();
      },
    );

    test(
      'candidate token cannot authorize model refresh before login commits',
      () async {
        final workerManager = WorkerManager();
        final storage = _CachedOpenWebUiStorage();
        final api = _CountingOpenWebUiApi(workerManager);
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            authStateManagerProvider.overrideWith(
              _CandidateTokenAuthStateManager.new,
            ),
            apiServiceProvider.overrideWithValue(api),
            optimizedStorageServiceProvider.overrideWithValue(storage),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_disabledHermes),
            ),
            directModelDiscoveryProvider.overrideWith(
              () => _FixedDirectDiscovery(const []),
            ),
            modelsProvider.overrideWith(
              () => _FixedModels(const [_CachedOpenWebUiStorage.staleModel]),
            ),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(workerManager.dispose);
        await container.read(authStateManagerProvider.future);
        await container.read(modelsProvider.future);
        storage.savedModelLists.clear();

        (container.read(authStateManagerProvider.notifier)
                as _CandidateTokenAuthStateManager)
            .beginForegroundLogin();
        await container.read(modelsProvider.notifier).refresh();
        await Future<void>.delayed(Duration.zero);

        check(api.modelFetches).equals(0);
        check(storage.savedModelLists).isEmpty();
        check(
          container.read(modelsProvider).requireValue,
        ).deepEquals(const [_CachedOpenWebUiStorage.staleModel]);
      },
    );

    test('cold-start default waits for terminal auth before Hermes', () async {
      final authState = Completer<AuthState>();
      final workerManager = WorkerManager();
      final api = _RetainedOpenWebUiApi(workerManager);
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          preferredBackendProvider.overrideWith(
            () => _FakePreferredBackendController(PreferredBackend.hermes),
          ),
          authStateManagerProvider.overrideWith(
            () => _PendingInitialAuthStateManager(authState.future),
          ),
          apiServiceProvider.overrideWithValue(api),
          optimizedStorageServiceProvider.overrideWithValue(
            _CachedOpenWebUiStorage(),
          ),
          hermesConfigProvider.overrideWith(
            () => _FakeHermesConfigController(_usableHermes),
          ),
          directModelDiscoveryProvider.overrideWith(
            () => _FixedDirectDiscovery(const []),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(workerManager.dispose);
      await container.read(directModelDiscoveryProvider.future);

      final pendingDefault = container.read(defaultModelProvider.future);
      await Future<void>.delayed(Duration.zero);
      authState.complete(const AuthState(status: AuthStatus.unauthenticated));
      final selected = await pendingDefault.timeout(const Duration(seconds: 2));

      check(selected).isNotNull();
      check(isHermesModel(selected!)).isTrue();
      check(container.read(selectedModelProvider)).identicalTo(selected);
    });

    test('preference changes reconcile between local transports', () async {
      final direct = _directModelFixture();
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          authStateManagerProvider.overrideWith(
            () => _FakeAuthStateManager(AuthStatus.unauthenticated),
          ),
          preferredBackendProvider.overrideWith(
            () => _MutablePreferredBackendController(PreferredBackend.direct),
          ),
          hermesConfigProvider.overrideWith(
            () => _FakeHermesConfigController(_usableHermes),
          ),
          directModelRegistryProvider.overrideWithValue(direct.registry),
          directModelDiscoveryProvider.overrideWith(
            () => _FixedDirectDiscovery([direct.model]),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(authStateManagerProvider.future);
      await container.read(directModelDiscoveryProvider.future);
      await container.read(modelsProvider.future);
      await Future<void>.delayed(Duration.zero);
      check(container.read(selectedModelProvider)).identicalTo(direct.model);

      (container.read(preferredBackendProvider.notifier)
              as _MutablePreferredBackendController)
          .publish(PreferredBackend.hermes);
      await container.read(modelsProvider.future);
      await Future<void>.delayed(Duration.zero);

      final hermes = container.read(selectedModelProvider);
      check(hermes).isNotNull();
      check(isHermesModel(hermes!)).isTrue();
    });

    test('Direct discovery refresh preserves a manual model choice', () async {
      final profile = DirectConnectionProfile(
        id: 'two-model-profile',
        name: 'Two model provider',
        adapterKey: 'ollama',
        baseUrl: 'http://localhost:11434',
      );
      final registry = DirectModelRegistry();
      final directModels = registry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'first-model'),
        DirectRemoteModel(id: 'second-model'),
      ]);
      final discovery = _ControllableDirectDiscovery(
        Future.value(DirectModelDiscoveryState(models: directModels)),
      );
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          authStateManagerProvider.overrideWith(
            () => _FakeAuthStateManager(AuthStatus.unauthenticated),
          ),
          preferredBackendProvider.overrideWith(
            () => _FakePreferredBackendController(PreferredBackend.direct),
          ),
          apiServiceProvider.overrideWithValue(null),
          appSettingsProvider.overrideWithValue(
            AppSettings(defaultModel: directModels.first.id),
          ),
          hermesConfigProvider.overrideWith(
            () => _FakeHermesConfigController(_disabledHermes),
          ),
          directModelRegistryProvider.overrideWithValue(registry),
          directModelDiscoveryProvider.overrideWith(() => discovery),
        ],
      );
      addTearDown(container.dispose);
      await container.read(authStateManagerProvider.future);
      await container.read(directModelDiscoveryProvider.future);
      container.read(selectedModelProvider);
      container.read(selectedModelProvider.notifier).set(directModels.last);
      container.read(isManualModelSelectionProvider.notifier).set(true);

      discovery.publish(directModels);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      check(
        container.read(selectedModelProvider),
      ).identicalTo(directModels.last);
      check(container.read(isManualModelSelectionProvider)).isTrue();
    });

    test('Direct discovery refresh replaces a remote manual model', () async {
      final direct = _directModelFixture();
      final discovery = _ControllableDirectDiscovery(
        Future.value(DirectModelDiscoveryState(models: [direct.model])),
      );
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          authStateManagerProvider.overrideWith(
            () => _FakeAuthStateManager(AuthStatus.unauthenticated),
          ),
          preferredBackendProvider.overrideWith(
            () => _FakePreferredBackendController(PreferredBackend.direct),
          ),
          apiServiceProvider.overrideWithValue(null),
          hermesConfigProvider.overrideWith(
            () => _FakeHermesConfigController(_disabledHermes),
          ),
          directModelRegistryProvider.overrideWithValue(direct.registry),
          directModelDiscoveryProvider.overrideWith(() => discovery),
        ],
      );
      addTearDown(container.dispose);
      await container.read(authStateManagerProvider.future);
      await container.read(directModelDiscoveryProvider.future);
      container.read(selectedModelProvider);
      container
          .read(selectedModelProvider.notifier)
          .set(_CachedOpenWebUiStorage.staleModel);
      container.read(isManualModelSelectionProvider.notifier).set(true);

      discovery.publish([direct.model]);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      check(container.read(selectedModelProvider)).identicalTo(direct.model);
      check(container.read(isManualModelSelectionProvider)).isFalse();
    });

    test(
      'backend switch replaces a usable manual model from another backend',
      () async {
        final direct = _directModelFixture();
        final backend = _MutablePreferredBackendController(
          PreferredBackend.direct,
        );
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            authStateManagerProvider.overrideWith(
              () => _FakeAuthStateManager(AuthStatus.unauthenticated),
            ),
            preferredBackendProvider.overrideWith(() => backend),
            apiServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_usableHermes),
            ),
            directModelRegistryProvider.overrideWithValue(direct.registry),
            directModelDiscoveryProvider.overrideWith(
              () => _FixedDirectDiscovery([direct.model]),
            ),
          ],
        );
        addTearDown(container.dispose);
        await container.read(authStateManagerProvider.future);
        await container.read(directModelDiscoveryProvider.future);
        container.read(selectedModelProvider);
        container.read(selectedModelProvider.notifier).set(direct.model);
        container.read(isManualModelSelectionProvider.notifier).set(true);

        backend.publish(PreferredBackend.hermes);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        final selected = container.read(selectedModelProvider);
        check(selected).isNotNull();
        check(isHermesModel(selected!)).isTrue();
        check(container.read(isManualModelSelectionProvider)).isFalse();
      },
    );

    test(
      'Hermes to Direct switch observes pending discovery completion',
      () async {
        final direct = _directModelFixture();
        final pendingDiscovery = Completer<DirectModelDiscoveryState>();
        final discovery = _ControllableDirectDiscovery(pendingDiscovery.future);
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            authStateManagerProvider.overrideWith(
              () => _FakeAuthStateManager(AuthStatus.unauthenticated),
            ),
            preferredBackendProvider.overrideWith(
              () => _MutablePreferredBackendController(PreferredBackend.hermes),
            ),
            apiServiceProvider.overrideWithValue(null),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_usableHermes),
            ),
            directModelRegistryProvider.overrideWithValue(direct.registry),
            directModelDiscoveryProvider.overrideWith(() => discovery),
          ],
        );
        addTearDown(container.dispose);
        await container.read(authStateManagerProvider.future);

        final initial = container.read(selectedModelProvider);
        check(initial).isNotNull();
        check(isHermesModel(initial!)).isTrue();
        (container.read(preferredBackendProvider.notifier)
                as _MutablePreferredBackendController)
            .publish(PreferredBackend.direct);
        await Future<void>.delayed(Duration.zero);

        pendingDiscovery.complete(
          DirectModelDiscoveryState(models: [direct.model]),
        );
        await container.read(directModelDiscoveryProvider.future);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        check(container.read(selectedModelProvider)).identicalTo(direct.model);
      },
    );

    test('Direct restoration rejects a removed registry binding', () async {
      final profile = DirectConnectionProfile(
        id: 'removed-profile',
        name: 'Removed provider',
        adapterKey: 'ollama',
        baseUrl: 'http://localhost:11434',
      );
      final registry = DirectModelRegistry();
      final staleModel = registry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'stale-model'),
      ]).single;
      final discovery = _ControllableDirectDiscovery(
        Future.value(DirectModelDiscoveryState(models: [staleModel])),
      );
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          authStateManagerProvider.overrideWith(
            () => _FakeAuthStateManager(AuthStatus.unauthenticated),
          ),
          preferredBackendProvider.overrideWith(
            () => _FakePreferredBackendController(PreferredBackend.direct),
          ),
          apiServiceProvider.overrideWithValue(null),
          hermesConfigProvider.overrideWith(
            () => _FakeHermesConfigController(_disabledHermes),
          ),
          directModelRegistryProvider.overrideWithValue(registry),
          directModelDiscoveryProvider.overrideWith(() => discovery),
        ],
      );
      addTearDown(container.dispose);
      await container.read(authStateManagerProvider.future);
      await container.read(directModelDiscoveryProvider.future);
      check(container.read(selectedModelProvider)).identicalTo(staleModel);
      container.read(isManualModelSelectionProvider.notifier).set(true);

      registry.removeProfile(profile.id);
      discovery.publish([staleModel]);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      check(container.read(selectedModelProvider)).isNull();
      check(container.read(isManualModelSelectionProvider)).isFalse();
    });

    test('background OpenWebUI login retries a cached null default', () async {
      final workerManager = WorkerManager();
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          authStateManagerProvider.overrideWith(
            _BackgroundLoginAuthStateManager.new,
          ),
          preferredBackendProvider.overrideWith(
            () => _FakePreferredBackendController(PreferredBackend.owui),
          ),
          apiServiceProvider.overrideWithValue(
            _RetainedOpenWebUiApi(workerManager),
          ),
          appSettingsProvider.overrideWithValue(
            const AppSettings(defaultModel: 'owui-stale'),
          ),
          optimizedStorageServiceProvider.overrideWithValue(
            _CachedOpenWebUiStorage(),
          ),
          hermesConfigProvider.overrideWith(
            () => _FakeHermesConfigController(_disabledHermes),
          ),
          directModelDiscoveryProvider.overrideWith(
            () => _FixedDirectDiscovery(const []),
          ),
          modelsProvider.overrideWith(
            () => _FixedModels(const [_CachedOpenWebUiStorage.staleModel]),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(workerManager.dispose);

      check(await container.read(defaultModelProvider.future)).isNull();
      (container.read(authStateManagerProvider.notifier)
              as _BackgroundLoginAuthStateManager)
          .finishAuthenticated();
      for (var attempt = 0; attempt < 10; attempt++) {
        await Future<void>.delayed(Duration.zero);
        if (container.read(selectedModelProvider) != null) break;
      }

      check(container.read(selectedModelProvider)?.id).equals('owui-stale');
    });

    for (final localBackend in [
      PreferredBackend.hermes,
      PreferredBackend.direct,
    ]) {
      test(
        'authenticated default replaces stale ${localBackend.name} selection',
        () async {
          final direct = _directModelFixture();
          final localModel = localBackend == PreferredBackend.hermes
              ? hermesSyntheticModel()
              : direct.model;
          final workerManager = WorkerManager();
          final container = ProviderContainer(
            overrides: [
              reviewerModeProvider.overrideWithValue(false),
              authStateManagerProvider.overrideWith(
                _BackgroundLoginAuthStateManager.new,
              ),
              preferredBackendProvider.overrideWith(
                () => _FakePreferredBackendController(PreferredBackend.owui),
              ),
              apiServiceProvider.overrideWithValue(
                _RetainedOpenWebUiApi(workerManager),
              ),
              appSettingsProvider.overrideWithValue(
                const AppSettings(defaultModel: 'owui-stale'),
              ),
              optimizedStorageServiceProvider.overrideWithValue(
                _CachedOpenWebUiStorage(),
              ),
              hermesConfigProvider.overrideWith(
                () => _FakeHermesConfigController(
                  localBackend == PreferredBackend.hermes
                      ? _usableHermes
                      : _disabledHermes,
                ),
              ),
              directModelRegistryProvider.overrideWithValue(direct.registry),
              directModelDiscoveryProvider.overrideWith(
                () => _FixedDirectDiscovery(
                  localBackend == PreferredBackend.direct
                      ? [direct.model]
                      : const [],
                ),
              ),
              modelsProvider.overrideWith(
                () => _FixedModels(const [_CachedOpenWebUiStorage.staleModel]),
              ),
            ],
          );
          addTearDown(container.dispose);
          addTearDown(workerManager.dispose);
          await container.read(authStateManagerProvider.future);
          await container.read(directModelDiscoveryProvider.future);
          container.read(selectedModelProvider.notifier).set(localModel);
          container.read(isManualModelSelectionProvider.notifier).set(false);

          (container.read(authStateManagerProvider.notifier)
                  as _BackgroundLoginAuthStateManager)
              .finishAuthenticated();
          for (var attempt = 0; attempt < 20; attempt++) {
            await Future<void>.delayed(Duration.zero);
            if (container.read(selectedModelProvider)?.id == 'owui-stale') {
              break;
            }
          }

          check(
            container.read(selectedModelProvider),
          ).identicalTo(_CachedOpenWebUiStorage.staleModel);
          check(container.read(isManualModelSelectionProvider)).isFalse();
        },
      );
    }

    test(
      'authenticated default cannot overwrite token-retaining local recovery',
      () async {
        final pendingModels = Completer<List<Model>>();
        final workerManager = WorkerManager();
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            authStateManagerProvider.overrideWith(
              _TokenRetainingErrorAuthStateManager.new,
            ),
            preferredBackendProvider.overrideWith(
              () => _FakePreferredBackendController(PreferredBackend.hermes),
            ),
            apiServiceProvider.overrideWithValue(
              _RetainedOpenWebUiApi(workerManager),
            ),
            appSettingsProvider.overrideWithValue(
              const AppSettings(defaultModel: 'owui-stale'),
            ),
            optimizedStorageServiceProvider.overrideWithValue(
              _CachedOpenWebUiStorage(),
            ),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_usableHermes),
            ),
            directModelDiscoveryProvider.overrideWith(
              () => _FixedDirectDiscovery(const []),
            ),
            modelsProvider.overrideWith(
              () => _PendingModels(pendingModels.future),
            ),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(workerManager.dispose);
        await container.read(authStateManagerProvider.future);

        final pendingDefault = container.read(defaultModelProvider.future);
        await Future<void>.delayed(Duration.zero);
        (container.read(authStateManagerProvider.notifier)
                as _TokenRetainingErrorAuthStateManager)
            .publishError();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        final localSelection = container.read(selectedModelProvider);
        check(localSelection).isNotNull();
        check(isHermesModel(localSelection!)).isTrue();

        pendingModels.complete(const [_CachedOpenWebUiStorage.staleModel]);
        final resolved = await pendingDefault;

        check(resolved).identicalTo(localSelection);
        check(
          container.read(selectedModelProvider),
        ).identicalTo(localSelection);
      },
    );

    test(
      'session A default cannot write after session B replaces it',
      () async {
        const sessionBSelection = Model(
          id: 'session-b-existing',
          name: 'Session B existing model',
        );
        final pendingModels = Completer<List<Model>>();
        final workerManager = WorkerManager();
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            authStateManagerProvider.overrideWith(
              _SessionSwitchAuthStateManager.new,
            ),
            preferredBackendProvider.overrideWith(
              () => _FakePreferredBackendController(PreferredBackend.owui),
            ),
            apiServiceProvider.overrideWithValue(
              _RetainedOpenWebUiApi(workerManager),
            ),
            appSettingsProvider.overrideWithValue(
              const AppSettings(defaultModel: 'owui-stale'),
            ),
            optimizedStorageServiceProvider.overrideWithValue(
              _CachedOpenWebUiStorage(),
            ),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_disabledHermes),
            ),
            directModelDiscoveryProvider.overrideWith(
              () => _FixedDirectDiscovery(const []),
            ),
            modelsProvider.overrideWith(
              () => _PendingModels(pendingModels.future),
            ),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(workerManager.dispose);
        await container.read(authStateManagerProvider.future);
        container.read(selectedModelProvider.notifier).set(sessionBSelection);

        final pendingDefault = container.read(defaultModelProvider.future);
        await Future<void>.delayed(Duration.zero);
        (container.read(authStateManagerProvider.notifier)
                as _SessionSwitchAuthStateManager)
            .publishSessionB();
        await Future<void>.delayed(Duration.zero);
        pendingModels.complete(const [_CachedOpenWebUiStorage.staleModel]);
        final resolved = await pendingDefault;

        check(resolved).identicalTo(sessionBSelection);
        check(
          container.read(selectedModelProvider),
        ).identicalTo(sessionBSelection);
      },
    );

    test('stale Direct default cannot overwrite a Hermes switch', () async {
      final direct = _directModelFixture();
      final pendingDiscovery = Completer<DirectModelDiscoveryState>();
      final discovery = _ControllableDirectDiscovery(pendingDiscovery.future);
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          authStateManagerProvider.overrideWith(
            () => _FakeAuthStateManager(AuthStatus.unauthenticated),
          ),
          preferredBackendProvider.overrideWith(
            () => _MutablePreferredBackendController(PreferredBackend.direct),
          ),
          apiServiceProvider.overrideWithValue(null),
          optimizedStorageServiceProvider.overrideWithValue(
            _CachedOpenWebUiStorage(),
          ),
          hermesConfigProvider.overrideWith(
            () => _FakeHermesConfigController(_usableHermes),
          ),
          directModelRegistryProvider.overrideWithValue(direct.registry),
          directModelDiscoveryProvider.overrideWith(() => discovery),
        ],
      );
      addTearDown(container.dispose);
      await container.read(authStateManagerProvider.future);

      final pendingDefault = container.read(defaultModelProvider.future);
      unawaited(pendingDefault.catchError((_) => null));
      await Future<void>.delayed(Duration.zero);
      (container.read(preferredBackendProvider.notifier)
              as _MutablePreferredBackendController)
          .publish(PreferredBackend.hermes);
      await Future<void>.delayed(Duration.zero);
      pendingDiscovery.complete(
        DirectModelDiscoveryState(models: [direct.model]),
      );
      await container.read(directModelDiscoveryProvider.future);
      await Future<void>.delayed(Duration.zero);

      final selected = container.read(selectedModelProvider);
      check(selected).isNotNull();
      check(isHermesModel(selected!)).isTrue();
    });

    test(
      'OpenWebUI cache read failure falls back to the authenticated API',
      () async {
        final workerManager = WorkerManager();
        final api = _ConversationFallbackApi(workerManager);
        final summary = Conversation(
          id: 'recoverable-chat',
          title: 'Cached summary',
          createdAt: DateTime.fromMillisecondsSinceEpoch(1),
          updatedAt: DateTime.fromMillisecondsSinceEpoch(2),
        );
        final container = ProviderContainer(
          overrides: [
            authStateManagerProvider.overrideWith(
              () => _FakeAuthStateManager(AuthStatus.authenticated),
            ),
            conversationsProvider.overrideWith(
              () => _FixedConversations([summary]),
            ),
            chatDatabaseRepositoryProvider.overrideWithValue(
              _ThrowingChatDatabaseRepository(
                StateError('corrupt OpenWebUI cache'),
              ),
            ),
            apiServiceProvider.overrideWithValue(api),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(workerManager.dispose);
        // The API ownership token is intentionally fenced by the settled auth
        // epoch. Mirror the production route, which cannot open this screen
        // until authentication bootstrap has completed.
        await container.read(authStateManagerProvider.future);
        await container.read(conversationsProvider.future);
        final scopedId = ChatStorageIdentity(
          rawId: summary.id,
          storage: ChatStorageKind.openWebUi,
        ).scopedId;

        final loaded = await container.read(
          loadConversationProvider(scopedId).future,
        );

        check(loaded.id).equals(summary.id);
        check(loaded.title).equals('Recovered from OpenWebUI');
        check(chatStorageKindOf(loaded)).equals(ChatStorageKind.openWebUi);
        check(api.conversationFetches).equals(1);
      },
    );

    test('unscoped chat collision never falls through to OpenWebUI', () async {
      final workerManager = WorkerManager();
      final api = _ConversationFallbackApi(workerManager);
      final container = ProviderContainer(
        retry: (retryCount, error) => null,
        overrides: [
          authStateManagerProvider.overrideWith(
            () => _FakeAuthStateManager(AuthStatus.authenticated),
          ),
          conversationsProvider.overrideWith(
            () => _FixedConversations(const []),
          ),
          chatDatabaseRepositoryProvider.overrideWithValue(
            _ThrowingChatDatabaseRepository(
              const AmbiguousChatStorageException('collision'),
            ),
          ),
          apiServiceProvider.overrideWithValue(api),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(workerManager.dispose);
      await container.read(conversationsProvider.future);
      final provider = loadConversationProvider('collision');
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(subscription.close);

      await expectLater(
        container.read(provider.future),
        throwsA(isA<AmbiguousChatStorageException>()),
      );

      check(api.conversationFetches).equals(0);
    });

    test(
      'active OpenWebUI summary scopes a legacy id while the list loads',
      () async {
        final workerManager = WorkerManager();
        final api = _ConversationFallbackApi(workerManager);
        final repository = _OpenWebUiPreferenceRepository();
        final pendingConversations = Completer<List<Conversation>>();
        final active = withChatStorageProvenance(
          Conversation(
            id: 'legacy-collision',
            title: 'Active OpenWebUI chat',
            createdAt: DateTime.fromMillisecondsSinceEpoch(1),
            updatedAt: DateTime.fromMillisecondsSinceEpoch(2),
          ),
          ChatStorageKind.openWebUi,
        );
        final container = ProviderContainer(
          retry: (retryCount, error) => null,
          overrides: [
            authStateManagerProvider.overrideWith(
              () => _FakeAuthStateManager(AuthStatus.authenticated),
            ),
            conversationsProvider.overrideWith(
              () => _PendingConversations(pendingConversations.future),
            ),
            chatDatabaseRepositoryProvider.overrideWithValue(repository),
            apiServiceProvider.overrideWithValue(api),
          ],
        );
        addTearDown(() {
          if (!pendingConversations.isCompleted) {
            pendingConversations.complete(const []);
          }
          container.dispose();
        });
        addTearDown(workerManager.dispose);
        // Keep the active-summary fallback inside the authenticated epoch it
        // claims to represent; an AsyncLoading auth seam is not ownership.
        await container.read(authStateManagerProvider.future);
        container.read(conversationsProvider);
        check(container.read(conversationsProvider).isLoading).isTrue();
        container.read(activeConversationProvider.notifier).set(active);

        final loaded = await container.read(
          loadConversationProvider(active.id).future,
        );

        check(loaded.id).equals(active.id);
        check(repository.preferredStorage).equals(ChatStorageKind.openWebUi);
        check(api.conversationFetches).equals(1);
      },
    );

    test('default selection tolerates a local cache write failure', () async {
      final workerManager = WorkerManager();
      final selectedModel = _CachedOpenWebUiStorage.staleModel;
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          authStateManagerProvider.overrideWith(
            () => _FakeAuthStateManager(AuthStatus.authenticated),
          ),
          preferredBackendProvider.overrideWith(
            () => _FakePreferredBackendController(PreferredBackend.owui),
          ),
          apiServiceProvider.overrideWithValue(
            _RetainedOpenWebUiApi(workerManager),
          ),
          appSettingsProvider.overrideWithValue(
            const AppSettings(defaultModel: 'owui-stale'),
          ),
          optimizedStorageServiceProvider.overrideWithValue(
            _ThrowingDefaultModelStorage(),
          ),
          hermesConfigProvider.overrideWith(
            () => _FakeHermesConfigController(_disabledHermes),
          ),
          directModelDiscoveryProvider.overrideWith(
            () => _FixedDirectDiscovery(const []),
          ),
          modelsProvider.overrideWith(() => _FixedModels([selectedModel])),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(workerManager.dispose);
      await container.read(authStateManagerProvider.future);
      await container.read(directModelDiscoveryProvider.future);

      final resolved = await container.read(defaultModelProvider.future);
      await Future<void>.delayed(Duration.zero);

      check(resolved).identicalTo(selectedModel);
      check(container.read(selectedModelProvider)).identicalTo(selectedModel);
    });
  });
}
