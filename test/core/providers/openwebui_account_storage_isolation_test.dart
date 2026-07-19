import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/auth/auth_state_manager.dart';
import 'package:conduit/core/auth/api_auth_interceptor.dart';
import 'package:conduit/core/auth/openwebui_account_owner_marker.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/chat_database_repository.dart';
import 'package:conduit/core/database/database_manager.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/database/local_conversation_loader.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/backend_config.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/models/socket_transport_availability.dart';
import 'package:conduit/core/models/user.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/providers/app_startup_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/direct_connections/direct_connections.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
import 'package:conduit/features/hermes/services/hermes_session_provenance.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _server = ServerConfig(
  id: 'same-server',
  name: 'Same server',
  url: 'http://localhost:0',
);

const _serverTwo = ServerConfig(
  id: 'second-server',
  name: 'Second server',
  url: 'http://localhost:1',
);

final _serverSelectionProvider =
    NotifierProvider<_ServerSelection, ServerConfig>(_ServerSelection.new);

final _apiSelectionProvider = NotifierProvider<_ApiSelection, ApiService?>(
  _ApiSelection.new,
);

class _ServerSelection extends Notifier<ServerConfig> {
  @override
  ServerConfig build() => _server;

  void set(ServerConfig server) => state = server;
}

class _ApiSelection extends Notifier<ApiService?> {
  @override
  ApiService? build() => null;

  void set(ApiService api) => state = api;
}

const _userA = User(
  id: 'user-a',
  username: 'a',
  email: 'a@example.test',
  role: 'user',
);

const _userB = User(
  id: 'user-b',
  username: 'b',
  email: 'b@example.test',
  role: 'user',
);

AuthState _authenticated(String token, User user) =>
    AuthState(status: AuthStatus.authenticated, token: token, user: user);

class _MutableAuthStateManager extends AuthStateManager {
  _MutableAuthStateManager(this.initial);

  final AuthState initial;

  @override
  Future<AuthState> build() async => initial;

  void publish(AuthState value) => state = AsyncData(value);
}

final class _CachedRestartStorage extends Fake
    implements OptimizedStorageService {
  _CachedRestartStorage({required this.token, required this.cachedUser});

  final String token;
  final User? cachedUser;
  final List<User> savedUsers = <User>[];

  @override
  Future<String?> getAuthToken() async => token;

  @override
  Future<String?> getAuthTokenStrict() async => token;

  @override
  Future<User?> getLocalUser() async => cachedUser;

  @override
  Future<User?> getLocalUserWithAvatar() async => cachedUser;

  @override
  Future<String?> getLocalUserAvatar() async => null;

  @override
  Future<void> saveLocalUser(User? user) async {
    if (user != null) savedUsers.add(user);
  }

  @override
  Future<void> saveLocalUserWithAvatar(User user, {String? avatarUrl}) async {
    savedUsers.add(user);
  }

  @override
  Future<void> saveLocalUserAvatar(String? avatarUrl) async {}
}

final class _GatedRestartValidationApi extends ApiService {
  _GatedRestartValidationApi(this.validatedUser)
    : super(serverConfig: _server, workerManager: WorkerManager());

  final Completer<User> validatedUser;

  @override
  Future<bool> checkHealth() async => true;

  @override
  Future<User> getCurrentUser({
    bool suppressAuthFailureNotification = false,
    String? candidateAuthToken,
    ApiAuthSnapshot? authSnapshot,
  }) => validatedUser.future;
}

final class _GatedCurrentUserApi extends ApiService {
  _GatedCurrentUserApi({required ServerConfig server, required this.response})
    : super(serverConfig: server, workerManager: WorkerManager());

  final Completer<User> response;
  final Completer<void> requestStarted = Completer<void>();

  @override
  Future<User> getCurrentUser({
    bool suppressAuthFailureNotification = false,
    String? candidateAuthToken,
    ApiAuthSnapshot? authSnapshot,
  }) {
    if (!requestStarted.isCompleted) requestStarted.complete();
    return response.future;
  }
}

final class _GatedBackendConfigApi extends ApiService {
  _GatedBackendConfigApi({required ServerConfig server, required this.response})
    : super(serverConfig: server, workerManager: WorkerManager());

  final Completer<BackendConfig?> response;
  final Completer<void> requestStarted = Completer<void>();
  int requestCount = 0;

  @override
  Future<BackendConfig?> getBackendConfig() {
    requestCount += 1;
    if (!requestStarted.isCompleted) requestStarted.complete();
    return response.future;
  }
}

final class _BackendCacheTrackingStorage extends Fake
    implements OptimizedStorageService {
  final List<BackendConfig> savedConfigs = <BackendConfig>[];
  final List<SocketTransportAvailability?> savedTransportOptions =
      <SocketTransportAvailability?>[];

  @override
  Future<BackendConfig?> getLocalBackendConfig() async => null;

  @override
  Future<void> saveLocalBackendConfig(BackendConfig? config) async {
    if (config != null) savedConfigs.add(config);
  }

  @override
  Future<void> saveLocalTransportOptions(
    SocketTransportAvailability? options,
  ) async {
    savedTransportOptions.add(options);
  }
}

final class _MemoryAccountOwnerMarkerStore
    implements OpenWebUiAccountOwnerMarkerStore {
  final Map<String, OpenWebUiAccountOwnerMarker> markers =
      <String, OpenWebUiAccountOwnerMarker>{};
  Future<void>? nextWriteGate;
  Completer<String>? nextWriteStarted;

  @override
  OpenWebUiAccountOwnerMarker? read(String serverId) => markers[serverId];

  @override
  Future<void> remove(String serverId) async {
    markers.remove(serverId);
  }

  @override
  Future<void> write(
    String serverId,
    OpenWebUiAccountOwnerMarker marker,
  ) async {
    final gate = nextWriteGate;
    if (gate != null) {
      nextWriteGate = null;
      final started = nextWriteStarted;
      nextWriteStarted = null;
      if (started != null && !started.isCompleted) started.complete(serverId);
      await gate;
    }
    markers[serverId] = marker;
  }
}

final class _TrackingChatDatabaseRepository extends ChatDatabaseRepository {
  _TrackingChatDatabaseRepository(
    AppDatabase directDatabase, {
    List<Future<void>> cancellationResults = const <Future<void>>[],
  }) : _cancellationResults = cancellationResults,
       super(openWebUiDatabase: null, directLocalDatabase: directDatabase);

  final List<Future<void>> _cancellationResults;

  int watchCalls = 0;
  int mergedWatchCalls = 0;
  int directWatchCalls = 0;
  int activeSubscriptions = 0;
  int maxActiveSubscriptions = 0;
  int cancellations = 0;

  @override
  Stream<List<LocatedChatListEntry>> watchMergedChatList({
    int? regularLimit,
    int? archivedLimit,
  }) {
    mergedWatchCalls++;
    return _recordingWatch();
  }

  @override
  Stream<List<LocatedChatListEntry>> watchDirectLocalChatList({
    int? regularLimit,
    int? archivedLimit,
  }) {
    directWatchCalls++;
    return _recordingWatch();
  }

  Stream<List<LocatedChatListEntry>> _recordingWatch() {
    watchCalls++;
    late final StreamController<List<LocatedChatListEntry>> controller;
    controller = StreamController<List<LocatedChatListEntry>>(
      onListen: () {
        activeSubscriptions++;
        if (activeSubscriptions > maxActiveSubscriptions) {
          maxActiveSubscriptions = activeSubscriptions;
        }
        scheduleMicrotask(() {
          if (controller.hasListener && !controller.isClosed) {
            controller.add(const <LocatedChatListEntry>[]);
          }
        });
      },
      onCancel: () async {
        final cancellationIndex = cancellations;
        try {
          if (cancellationIndex < _cancellationResults.length) {
            await _cancellationResults[cancellationIndex];
          }
        } finally {
          activeSubscriptions--;
          cancellations++;
        }
      },
    );
    return controller.stream;
  }
}

Future<void> _seedChat(
  AppDatabase db, {
  required String id,
  required String title,
  String? message,
}) async {
  await db
      .into(db.chats)
      .insert(
        ChatsCompanion.insert(
          id: id,
          title: title,
          createdAt: 1,
          updatedAt: 1,
          bodySynced: const Value(true),
        ),
      );
  if (message == null) return;
  await db
      .into(db.messages)
      .insert(
        MessagesCompanion.insert(
          id: '$id-message',
          chatId: id,
          role: 'assistant',
          content: message,
          createdAt: 1,
          orderIndex: 0,
          payload: '{}',
        ),
      );
}

Conversation _openWebUiConversation(String id, String secret) => Conversation(
  id: id,
  title: 'A private chat',
  createdAt: DateTime.utc(2026, 7, 13),
  updatedAt: DateTime.utc(2026, 7, 13),
  messages: <ChatMessage>[
    ChatMessage(
      id: '$id-message',
      role: 'assistant',
      content: secret,
      timestamp: DateTime.utc(2026, 7, 13),
    ),
  ],
);

Future<
  ({
    ProviderContainer container,
    _MutableAuthStateManager auth,
    AppDatabase serverA,
    AppDatabase serverB,
    AppDatabase direct,
    DatabaseManager manager,
    _ServerSelection serverSelection,
    _MemoryAccountOwnerMarkerStore markerStore,
  })
>
_harness({
  AuthState? initialAuth,
  bool expectInitiallyOpen = true,
  bool seedMatchingOwnerMarker = true,
  OpenWebUiAccountOwnerMarker? ownerMarker,
  OpenWebUiAccountCacheClear? accountCacheClear,
  OpenWebUiDatabasePurge? databasePurge,
  List<Override> additionalOverrides = const <Override>[],
}) async {
  if (!PreferencesStore.isReady) {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    addTearDown(PreferencesStore.debugReset);
  }
  final serverA = AppDatabase(NativeDatabase.memory());
  final serverB = AppDatabase(NativeDatabase.memory());
  final direct = AppDatabase(NativeDatabase.memory());
  final directory = await Directory.systemTemp.createTemp('conduit-account-db');
  var opens = 0;
  final manager = DatabaseManager(
    databaseDirectory: () async => directory,
    openDatabase: (_) => opens++ == 0 ? serverA : serverB,
    databaseFileName: (serverId) => '${serverId}_test',
  );
  check(manager.openFor(_server)).identicalTo(serverA);
  await _seedChat(
    serverA,
    id: 'account-a-chat',
    title: 'A private summary',
    message: 'A private body',
  );
  await _seedChat(
    direct,
    id: 'direct-chat',
    title: 'Device chat',
    message: 'Device body',
  );

  final resolvedInitialAuth = initialAuth ?? _authenticated('token-a', _userA);
  final auth = _MutableAuthStateManager(resolvedInitialAuth);
  final markerStore = _MemoryAccountOwnerMarkerStore();
  final initialToken = resolvedInitialAuth.token;
  final initialUserId = resolvedInitialAuth.user?.id;
  final matchingMarker = initialToken == null
      ? null
      : openWebUiAccountOwnerMarker(token: initialToken, userId: initialUserId);
  final seededMarker =
      ownerMarker ?? (seedMatchingOwnerMarker ? matchingMarker : null);
  if (seededMarker != null) {
    markerStore.markers[_server.id] = seededMarker;
  }
  final container = ProviderContainer(
    overrides: [
      reviewerModeProvider.overrideWithValue(false),
      activeServerProvider.overrideWith(
        (ref) async => ref.watch(_serverSelectionProvider),
      ),
      apiServiceProvider.overrideWithValue(null),
      socketServiceProvider.overrideWithValue(null),
      databaseManagerProvider.overrideWithValue(manager),
      directLocalDatabaseProvider.overrideWithValue(direct),
      authStateManagerProvider.overrideWith(() => auth),
      openWebUiAccountOwnerMarkerStoreProvider.overrideWithValue(markerStore),
      openWebUiAccountCacheClearProvider.overrideWithValue(
        accountCacheClear ?? () async {},
      ),
      openWebUiCertifiedUserPersistProvider.overrideWithValue((_) async {}),
      openWebUiDatabasePurgeProvider.overrideWithValue(
        databasePurge ??
            (serverId) async {
              if (serverId == _serverTwo.id) {
                await serverB.delete(serverB.messages).go();
                await serverB.delete(serverB.chats).go();
              }
              await manager.deleteFor(serverId);
            },
      ),
      ...additionalOverrides,
    ],
  );

  addTearDown(() async {
    container.dispose();
    await manager.closeActive();
    await direct.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  // This is installed before any chat provider, matching ConduitApp.initState.
  container.read(userScopedProviderCleanupProvider);
  await container.read(activeServerProvider.future);
  await container.read(authStateManagerProvider.future);
  await Future<void>.delayed(Duration.zero);
  if (expectInitiallyOpen) {
    check(
      container.read(openWebUiDatabaseAccessProvider),
    ).equals(OpenWebUiDatabaseAccessPhase.open);
  } else {
    await container
        .read(openWebUiAccountStorageIsolationProvider.notifier)
        .settled;
    check(
      container.read(openWebUiDatabaseAccessProvider),
    ).equals(OpenWebUiDatabaseAccessPhase.closed);
  }

  return (
    container: container,
    auth: auth,
    serverA: serverA,
    serverB: serverB,
    direct: direct,
    manager: manager,
    serverSelection: container.read(_serverSelectionProvider.notifier),
    markerStore: markerStore,
  );
}

final class _ThrowingActiveConversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => _openWebUiConversation(
    'visible-state-failure',
    'must still be scrubbed from storage',
  );

  @override
  void set(Conversation? conversation) {
    if (conversation == null) {
      throw StateError('active conversation clear failed');
    }
    super.set(conversation);
  }
}

final class _ThrowingActiveChatIds extends ActiveChatIds {
  @override
  void setAll(Set<String> chatIds) {
    throw StateError('active chat ids clear failed');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test(
    'visible-state scrub logs each best-effort failure and keeps purging',
    () async {
      final previousDebugPrint = debugPrint;
      final logs = <String>[];
      debugPrint = (message, {wrapWidth}) {
        if (message != null) logs.add(message);
      };

      try {
        final harness = await _harness(
          additionalOverrides: <Override>[
            activeConversationProvider.overrideWith(
              _ThrowingActiveConversation.new,
            ),
            activeChatIdsProvider.overrideWith(_ThrowingActiveChatIds.new),
          ],
        );

        harness.auth.publish(
          const AuthState(status: AuthStatus.unauthenticated),
        );
        await Future<void>.delayed(Duration.zero);
        await harness.container
            .read(openWebUiAccountStorageIsolationProvider.notifier)
            .settled;

        check(
          logs.any(
            (message) => message.contains(
              'visible-state-active-conversation-clear-failed',
            ),
          ),
        ).isTrue();
        check(
          logs.any(
            (message) =>
                message.contains('visible-state-provider-reset-failed'),
          ),
        ).isTrue();
        check(
          harness.container.read(openWebUiDatabaseAccessProvider),
        ).equals(OpenWebUiDatabaseAccessPhase.closed);
      } finally {
        debugPrint = previousDebugPrint;
      }
    },
  );

  test('account privacy follows storage provenance, not transport label', () {
    Conversation transport(String backend) => Conversation(
      id: '$backend-chat',
      title: backend,
      createdAt: DateTime.utc(2026, 7, 13),
      updatedAt: DateTime.utc(2026, 7, 13),
      metadata: <String, dynamic>{'backend': backend},
    );

    check(
      conversationUsesOpenWebUiStorage(transport(kDirectTransport)),
    ).isFalse();
    // Serialized backend metadata is server-controlled and therefore cannot
    // claim a process-owned native Hermes shell.
    check(conversationUsesOpenWebUiStorage(transport('hermes'))).isTrue();
    check(
      conversationUsesOpenWebUiStorage(
        markNativeHermesConversation(transport('hermes')),
      ),
    ).isFalse();
    check(
      conversationUsesOpenWebUiStorage(
        withChatStorageProvenance(
          transport(kDirectTransport),
          ChatStorageKind.openWebUi,
        ),
      ),
    ).isTrue();
    check(
      conversationUsesOpenWebUiStorage(
        withChatStorageProvenance(
          transport('hermes'),
          ChatStorageKind.openWebUi,
        ),
      ),
    ).isTrue();
  });

  test(
    'late current-user response from A cannot persist into active server B',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        PreferenceKeys.activeServerId: _server.id,
      });
      PreferencesStore.debugReset();
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());

      const initialAuth = AuthState(
        status: AuthStatus.authenticated,
        token: 'token-a',
      );
      final auth = _MutableAuthStateManager(initialAuth);
      final storage = _CachedRestartStorage(token: 'token-a', cachedUser: null);
      final responseA = Completer<User>();
      final responseB = Completer<User>()..complete(_userB);
      final apiA = _GatedCurrentUserApi(server: _server, response: responseA);
      final apiB = _GatedCurrentUserApi(
        server: _serverTwo,
        response: responseB,
      );
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          activeServerProvider.overrideWith(
            (ref) async => ref.watch(_serverSelectionProvider),
          ),
          apiServiceProvider.overrideWith(
            (ref) => ref.watch(_apiSelectionProvider),
          ),
          optimizedStorageServiceProvider.overrideWithValue(storage),
          authStateManagerProvider.overrideWith(() => auth),
        ],
      );
      try {
        container.read(_apiSelectionProvider.notifier).set(apiA);
        await container.read(authStateManagerProvider.future);
        check(
          (await container.read(activeServerProvider.future))?.id,
        ).equals(_server.id);
        container
            .read(openWebUiCertifiedDatabaseServerProvider.notifier)
            .set(_server.id);
        container.read(openWebUiDatabaseAccessProvider.notifier).open();

        final staleRead = container.read(currentUserProvider.future);
        unawaited(staleRead.catchError((_) => null));
        await apiA.requestStarted.future;

        await PreferencesStore.put(
          PreferenceKeys.activeServerId,
          _serverTwo.id,
        );
        container.read(_serverSelectionProvider.notifier).set(_serverTwo);
        container.read(_apiSelectionProvider.notifier).set(apiB);
        auth.publish(
          const AuthState(status: AuthStatus.authenticated, token: 'token-b'),
        );
        container
            .read(openWebUiCertifiedDatabaseServerProvider.notifier)
            .set(_serverTwo.id);
        check(
          (await container.read(activeServerProvider.future))?.id,
        ).equals(_serverTwo.id);
        container.invalidate(currentUserProvider);

        responseA.complete(_userA);
        final latest = await container.read(currentUserProvider.future);

        check(latest?.id).equals(_userB.id);
        check(
          storage.savedUsers.map((user) => user.id),
        ).not((ids) => ids.contains(_userA.id));
        check(storage.savedUsers.map((user) => user.id)).contains(_userB.id);
      } finally {
        if (!responseA.isCompleted) responseA.complete(_userA);
        container.dispose();
        PreferencesStore.debugReset();
      }
    },
  );

  test('late backend config from A cannot update B state or caches', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PreferenceKeys.activeServerId: _server.id,
    });
    PreferencesStore.debugReset();
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());

    final auth = _MutableAuthStateManager(
      const AuthState(status: AuthStatus.authenticated, token: 'token-a'),
    );
    final storage = _BackendCacheTrackingStorage();
    final responseA = Completer<BackendConfig?>();
    final responseB = Completer<BackendConfig?>()
      ..complete(const BackendConfig(version: 'b-version'));
    final apiA = _GatedBackendConfigApi(server: _server, response: responseA);
    final apiB = _GatedBackendConfigApi(
      server: _serverTwo,
      response: responseB,
    );
    final container = ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(false),
        activeServerProvider.overrideWith(
          (ref) async => ref.watch(_serverSelectionProvider),
        ),
        apiServiceProvider.overrideWith(
          (ref) => ref.watch(_apiSelectionProvider),
        ),
        optimizedStorageServiceProvider.overrideWithValue(storage),
        authStateManagerProvider.overrideWith(() => auth),
      ],
    );
    final backendConfigSubscription = container
        .listen<AsyncValue<BackendConfig?>>(
          backendConfigProvider,
          (_, _) {},
          fireImmediately: true,
        );

    try {
      container.read(_apiSelectionProvider.notifier).set(apiA);
      await container.read(authStateManagerProvider.future);
      await container.read(activeServerProvider.future);
      container
          .read(openWebUiCertifiedDatabaseServerProvider.notifier)
          .set(_server.id);
      container.read(openWebUiDatabaseAccessProvider.notifier).open();
      await container.read(backendConfigProvider.future);
      await apiA.requestStarted.future;

      await PreferencesStore.put(PreferenceKeys.activeServerId, _serverTwo.id);
      container.read(_serverSelectionProvider.notifier).set(_serverTwo);
      container.read(_apiSelectionProvider.notifier).set(apiB);
      auth.publish(
        const AuthState(status: AuthStatus.authenticated, token: 'token-b'),
      );
      container
          .read(openWebUiCertifiedDatabaseServerProvider.notifier)
          .set(_serverTwo.id);
      check(
        (await container.read(activeServerProvider.future))?.id,
      ).equals(_serverTwo.id);

      responseA.complete(const BackendConfig(version: 'a-version'));
      await apiB.requestStarted.future;
      for (var attempt = 0; attempt < 100; attempt++) {
        if (storage.savedConfigs.any(
          (config) => config.serverId == _serverTwo.id,
        )) {
          break;
        }
        await Future<void>.delayed(Duration.zero);
      }

      check(
        storage.savedConfigs.map((config) => config.serverId),
      ).not((ids) => ids.contains(_server.id));
      check(
        storage.savedConfigs.map((config) => config.serverId),
      ).contains(_serverTwo.id);
      check(
        container.read(backendConfigProvider).asData?.value?.serverId,
      ).equals(_serverTwo.id);
    } finally {
      if (!responseA.isCompleted) {
        responseA.complete(const BackendConfig(version: 'a-version'));
      }
      backendConfigSubscription.close();
      container.dispose();
      PreferencesStore.debugReset();
    }
  });

  test(
    'retired backend-config ref does not call API after active-server invalidation',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        PreferenceKeys.activeServerId: _server.id,
      });
      PreferencesStore.debugReset();
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());

      final firstServer = Completer<ServerConfig?>();
      final secondServer = Completer<ServerConfig?>();
      final firstStarted = Completer<void>();
      final secondStarted = Completer<void>();
      var activeServerBuilds = 0;
      final response = Completer<BackendConfig?>()
        ..complete(const BackendConfig(version: 'unused'));
      final api = _GatedBackendConfigApi(server: _server, response: response);
      final storage = _BackendCacheTrackingStorage();
      final epoch = Object();
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          activeServerProvider.overrideWith((ref) async {
            final build = activeServerBuilds++;
            if (build == 0) {
              if (!firstStarted.isCompleted) firstStarted.complete();
              return firstServer.future;
            }
            if (!secondStarted.isCompleted) secondStarted.complete();
            return secondServer.future;
          }),
          apiServiceProvider.overrideWithValue(api),
          optimizedStorageServiceProvider.overrideWithValue(storage),
          openWebUiAuthSessionEpochProvider.overrideWithValue(epoch),
        ],
      );
      final subscription = container.listen<AsyncValue<BackendConfig?>>(
        backendConfigProvider,
        (_, _) {},
        fireImmediately: true,
      );

      try {
        await firstStarted.future;
        await Future<void>.delayed(Duration.zero);

        // Replacing the dependency retires the Ref captured by the first
        // _loadBackendConfig call while it is awaiting the first future.
        container.invalidate(activeServerProvider);
        await secondStarted.future;

        firstServer.complete(_server);
        for (var attempt = 0; attempt < 10; attempt++) {
          await Future<void>.delayed(Duration.zero);
        }

        check(api.requestCount).equals(0);
        check(api.requestStarted.isCompleted).isFalse();
      } finally {
        subscription.close();
        container.dispose();
        if (!firstServer.isCompleted) firstServer.complete(_server);
        if (!secondServer.isCompleted) secondServer.complete(_server);
        await Future<void>.delayed(Duration.zero);
        PreferencesStore.debugReset();
      }
    },
  );

  test('backend config survives an ownership-dependency rebuild', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PreferenceKeys.activeServerId: _server.id,
    });
    PreferencesStore.debugReset();
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());

    final response = Completer<BackendConfig?>()
      ..complete(const BackendConfig(version: 'stable-version'));
    final api = _GatedBackendConfigApi(server: _server, response: response);
    final storage = _BackendCacheTrackingStorage();
    final container = ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(false),
        activeServerProvider.overrideWith((ref) async => _server),
        apiServiceProvider.overrideWithValue(api),
        optimizedStorageServiceProvider.overrideWithValue(storage),
        openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
      ],
    );
    final backendConfigSubscription = container
        .listen<AsyncValue<BackendConfig?>>(
          backendConfigProvider,
          (_, _) {},
          fireImmediately: true,
        );

    try {
      await container.read(activeServerProvider.future);
      container
          .read(openWebUiCertifiedDatabaseServerProvider.notifier)
          .set(_server.id);
      await container.read(backendConfigProvider.future);
      for (var attempt = 0; attempt < 100; attempt++) {
        if (api.requestCount >= 1 &&
            storage.savedConfigs.isNotEmpty &&
            container.read(backendConfigProvider).asData?.value?.version ==
                'stable-version') {
          break;
        }
        await Future<void>.delayed(Duration.zero);
      }
      check(api.requestCount).equals(1);
      check(storage.savedConfigs.length).equals(1);

      // AsyncNotifier keeps the same notifier instance while replacing its Ref.
      // Rebuilding on an ownership gate must rebind storage without a second
      // assignment to a late-final field or retaining the prior owner.
      container.read(openWebUiDatabaseAccessProvider.notifier).open();
      for (var attempt = 0; attempt < 100; attempt++) {
        if (api.requestCount >= 2 &&
            storage.savedConfigs.length >= 2 &&
            container.read(backendConfigProvider).asData?.value?.version ==
                'stable-version') {
          break;
        }
        await Future<void>.delayed(Duration.zero);
      }

      check(api.requestCount).equals(2);
      check(storage.savedConfigs.length).equals(2);
      check(
        container.read(backendConfigProvider).asData?.value?.version,
      ).equals('stable-version');
    } finally {
      backendConfigSubscription.close();
      container.dispose();
      PreferencesStore.debugReset();
    }
  });

  test('rapid account gate rebuilds replace the prior list watcher', () async {
    final direct = AppDatabase(NativeDatabase.memory());
    final repository = _TrackingChatDatabaseRepository(direct);
    final container = ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(false),
        activeServerProvider.overrideWith((ref) async => _server),
        appDatabaseProvider.overrideWithValue(null),
        chatDatabaseRepositoryProvider.overrideWithValue(repository),
      ],
    );
    try {
      await container.read(activeServerProvider.future);
      container
          .read(openWebUiCertifiedDatabaseServerProvider.notifier)
          .set(_server.id);
      container.read(openWebUiDatabaseAccessProvider.notifier).open();
      await container.read(conversationsProvider.future);

      for (var index = 0; index < 5; index++) {
        container.read(openWebUiDatabaseAccessProvider.notifier).close();
        container
            .read(openWebUiCertifiedDatabaseServerProvider.notifier)
            .clear();
        container
            .read(openWebUiCertifiedDatabaseServerProvider.notifier)
            .set(_server.id);
        container.read(openWebUiDatabaseAccessProvider.notifier).open();
        await container.read(conversationsProvider.future);
      }

      check(repository.watchCalls).isGreaterThan(1);
      check(repository.maxActiveSubscriptions).equals(1);
      check(repository.activeSubscriptions).equals(1);
      check(repository.cancellations).equals(repository.watchCalls - 1);
    } finally {
      container.dispose();
      await Future<void>.delayed(Duration.zero);
      check(repository.activeSubscriptions).equals(0);
      await direct.close();
    }
  });

  test(
    'closed account gate subscribes only to the direct-local list',
    () async {
      final direct = AppDatabase(NativeDatabase.memory());
      final repository = _TrackingChatDatabaseRepository(direct);
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          activeServerProvider.overrideWith((ref) async => _server),
          appDatabaseProvider.overrideWithValue(null),
          chatDatabaseRepositoryProvider.overrideWithValue(repository),
        ],
      );
      try {
        await container.read(activeServerProvider.future);
        await container.read(conversationsProvider.future);

        check(repository.directWatchCalls).equals(1);
        check(repository.mergedWatchCalls).equals(0);
        check(repository.activeSubscriptions).equals(1);
      } finally {
        container.dispose();
        await Future<void>.delayed(Duration.zero);
        await direct.close();
      }
    },
  );

  test(
    'list watcher awaits async cancellation and contains cancellation errors',
    () async {
      final direct = AppDatabase(NativeDatabase.memory());
      final firstCancellation = Completer<void>();
      final hostileCancellation = Completer<void>();
      final repository = _TrackingChatDatabaseRepository(
        direct,
        cancellationResults: <Future<void>>[
          firstCancellation.future,
          hostileCancellation.future,
        ],
      );
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          activeServerProvider.overrideWith((ref) async => _server),
          appDatabaseProvider.overrideWithValue(null),
          chatDatabaseRepositoryProvider.overrideWithValue(repository),
        ],
      );
      try {
        await container.read(activeServerProvider.future);
        await container.read(conversationsProvider.future);

        container.read(openWebUiDatabaseAccessProvider.notifier).close();
        final secondBuild = container.read(conversationsProvider.future);
        await Future<void>.delayed(Duration.zero);
        check(repository.watchCalls).equals(1);
        check(repository.activeSubscriptions).equals(1);

        firstCancellation.complete();
        await secondBuild;
        check(repository.watchCalls).equals(2);
        check(repository.maxActiveSubscriptions).equals(1);

        container.read(openWebUiDatabaseAccessProvider.notifier).open();
        final thirdBuild = container.read(conversationsProvider.future);
        await Future<void>.delayed(Duration.zero);
        check(repository.watchCalls).equals(2);
        hostileCancellation.completeError(
          StateError('hostile cancellation'),
          StackTrace.current,
        );
        await thirdBuild;

        check(repository.watchCalls).equals(3);
        check(repository.maxActiveSubscriptions).equals(1);
        check(repository.activeSubscriptions).equals(1);
      } finally {
        container.dispose();
        await Future<void>.delayed(Duration.zero);
        check(repository.activeSubscriptions).equals(0);
        await direct.close();
      }
    },
  );

  test(
    'disposing while list watcher cancellation is pending cannot re-arm it',
    () async {
      final direct = AppDatabase(NativeDatabase.memory());
      final firstCancellation = Completer<void>();
      final repository = _TrackingChatDatabaseRepository(
        direct,
        cancellationResults: <Future<void>>[firstCancellation.future],
      );
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          activeServerProvider.overrideWith((ref) async => _server),
          appDatabaseProvider.overrideWithValue(null),
          chatDatabaseRepositoryProvider.overrideWithValue(repository),
        ],
      );

      await container.read(activeServerProvider.future);
      await container.read(conversationsProvider.future);
      container.read(openWebUiDatabaseAccessProvider.notifier).close();
      final pendingBuild = container.read(conversationsProvider.future);
      await Future<void>.delayed(Duration.zero);

      check(repository.watchCalls).equals(1);
      check(repository.activeSubscriptions).equals(1);

      container.dispose();
      firstCancellation.complete();
      await pendingBuild;
      await Future<void>.delayed(Duration.zero);

      check(repository.watchCalls).equals(1);
      check(repository.activeSubscriptions).equals(0);
      check(repository.cancellations).equals(1);
      await direct.close();
    },
  );

  test(
    'restart with token B and cached user A purges before publishing identity or chats',
    () async {
      const tokenA = 'persisted-token-account-a';
      const tokenB = 'persisted-token-account-b';
      SharedPreferences.setMockInitialValues(<String, Object>{
        PreferenceKeys.activeServerId: _server.id,
      });
      PreferencesStore.debugReset();
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());

      final serverA = AppDatabase(NativeDatabase.memory());
      final serverB = AppDatabase(NativeDatabase.memory());
      final direct = AppDatabase(NativeDatabase.memory());
      final directory = await Directory.systemTemp.createTemp(
        'conduit-restart-owner',
      );
      var opens = 0;
      final manager = DatabaseManager(
        databaseDirectory: () async => directory,
        openDatabase: (_) => opens++ == 0 ? serverA : serverB,
        databaseFileName: (serverId) => '${serverId}_restart_test',
      );
      manager.openFor(_server);
      await _seedChat(
        serverA,
        id: 'stale-account-a-chat',
        title: 'A must stay private',
        message: 'A private restart body',
      );
      await _seedChat(
        direct,
        id: 'restart-direct-chat',
        title: 'Device chat',
        message: 'Device body',
      );

      final markerStore = _MemoryAccountOwnerMarkerStore();
      markerStore.markers[_server.id] = openWebUiAccountOwnerMarker(
        token: tokenA,
        userId: _userA.id,
      )!;
      final validatedUser = Completer<User>();
      final api = _GatedRestartValidationApi(validatedUser);
      final storage = _CachedRestartStorage(token: tokenB, cachedUser: _userA);
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          activeServerProvider.overrideWith((ref) async => _server),
          apiServiceProvider.overrideWithValue(api),
          socketServiceProvider.overrideWithValue(null),
          optimizedStorageServiceProvider.overrideWithValue(storage),
          databaseManagerProvider.overrideWithValue(manager),
          directLocalDatabaseProvider.overrideWithValue(direct),
          openWebUiAccountOwnerMarkerStoreProvider.overrideWithValue(
            markerStore,
          ),
          openWebUiAccountCacheClearProvider.overrideWithValue(() async {}),
          openWebUiDatabasePurgeProvider.overrideWithValue(manager.deleteFor),
        ],
      );

      final authEmissions = <AuthState>[];
      final currentUserIds = <String?>[];
      final asyncCurrentUserIds = <String?>[];
      final conversationEmissions = <List<String>>[];
      final authSubscription = container.listen<AsyncValue<AuthState>>(
        authStateManagerProvider,
        (_, next) {
          final auth = next.asData?.value;
          if (auth != null) authEmissions.add(auth);
        },
        fireImmediately: true,
      );
      final currentUserSubscription = container.listen<User?>(
        currentUserProvider2,
        (_, next) => currentUserIds.add(next?.id),
        fireImmediately: true,
      );
      final asyncCurrentUserSubscription = container.listen<AsyncValue<User?>>(
        currentUserProvider,
        (_, next) {
          if (next.hasValue) asyncCurrentUserIds.add(next.value?.id);
        },
        fireImmediately: true,
      );
      final conversationSubscription = container
          .listen<AsyncValue<List<Conversation>>>(conversationsProvider, (
            _,
            next,
          ) {
            final chats = next.asData?.value;
            if (chats != null) {
              conversationEmissions.add(
                chats.map((chat) => chat.id).toList(growable: false),
              );
            }
          }, fireImmediately: true);

      try {
        container.read(userScopedProviderCleanupProvider);
        await container.read(authStateManagerProvider.future);
        for (var attempt = 0; attempt < 100; attempt++) {
          if (container.read(openWebUiDatabaseAccessProvider) ==
              OpenWebUiDatabaseAccessPhase.closed) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await container
            .read(openWebUiAccountStorageIsolationProvider.notifier)
            .settled;

        check(
          container.read(openWebUiDatabaseAccessProvider),
        ).equals(OpenWebUiDatabaseAccessPhase.closed);
        check(
          authEmissions.any(
            (auth) =>
                auth.status == AuthStatus.authenticated &&
                auth.user?.id == _userA.id,
          ),
        ).isFalse();
        check(currentUserIds.contains(_userA.id)).isFalse();
        check(asyncCurrentUserIds.contains(_userA.id)).isFalse();
        check(
          conversationEmissions.every(
            (ids) => !ids.contains('stale-account-a-chat'),
          ),
        ).isTrue();

        validatedUser.complete(_userB);
        for (var attempt = 0; attempt < 100; attempt++) {
          final auth = container.read(authStateManagerProvider).asData?.value;
          if (auth?.status == AuthStatus.authenticated &&
              auth?.user?.id == _userB.id) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await Future<void>.delayed(Duration.zero);
        await container
            .read(openWebUiAccountStorageIsolationProvider.notifier)
            .settled;

        check(container.read(currentUserProvider2)?.id).equals(_userB.id);
        check(
          container.read(openWebUiDatabaseAccessProvider),
        ).equals(OpenWebUiDatabaseAccessPhase.open);
        check(
          (await container.read(
            conversationsProvider.future,
          )).map((chat) => chat.id).toList(),
        ).deepEquals(<String>['restart-direct-chat']);
        check(
          conversationEmissions.every(
            (ids) => !ids.contains('stale-account-a-chat'),
          ),
        ).isTrue();
        check(
          markerStore.markers[_server.id],
        ).equals(openWebUiAccountOwnerMarker(token: tokenB, userId: _userB.id));
        check(storage.savedUsers.map((user) => user.id)).contains(_userB.id);
      } finally {
        conversationSubscription.close();
        asyncCurrentUserSubscription.close();
        currentUserSubscription.close();
        authSubscription.close();
        container.dispose();
        await manager.closeActive();
        await direct.close();
        if (await directory.exists()) await directory.delete(recursive: true);
        PreferencesStore.debugReset();
      }
    },
  );

  test(
    'matching token marker with no cached user retains DB until validation',
    () async {
      const tokenB = 'persisted-token-owner-b';
      SharedPreferences.setMockInitialValues(<String, Object>{
        PreferenceKeys.activeServerId: _server.id,
      });
      PreferencesStore.debugReset();
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());

      final serverDatabase = AppDatabase(NativeDatabase.memory());
      final direct = AppDatabase(NativeDatabase.memory());
      final directory = await Directory.systemTemp.createTemp(
        'conduit-restart-no-user',
      );
      final manager = DatabaseManager(
        databaseDirectory: () async => directory,
        openDatabase: (_) => serverDatabase,
        databaseFileName: (serverId) => '${serverId}_no_user_test',
      );
      manager.openFor(_server);
      await _seedChat(
        serverDatabase,
        id: 'retained-b-chat',
        title: 'Retained B chat',
        message: 'B body',
      );
      final markerStore = _MemoryAccountOwnerMarkerStore();
      markerStore.markers[_server.id] = openWebUiAccountOwnerMarker(
        token: tokenB,
        userId: _userB.id,
      )!;
      final storage = _CachedRestartStorage(token: tokenB, cachedUser: null);
      final validatedUser = Completer<User>();
      final api = _GatedRestartValidationApi(validatedUser);
      var purgeCalls = 0;
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          activeServerProvider.overrideWith((ref) async => _server),
          apiServiceProvider.overrideWithValue(api),
          socketServiceProvider.overrideWithValue(null),
          optimizedStorageServiceProvider.overrideWithValue(storage),
          databaseManagerProvider.overrideWithValue(manager),
          directLocalDatabaseProvider.overrideWithValue(direct),
          openWebUiAccountOwnerMarkerStoreProvider.overrideWithValue(
            markerStore,
          ),
          openWebUiAccountCacheClearProvider.overrideWithValue(() async {}),
          openWebUiDatabasePurgeProvider.overrideWithValue((serverId) async {
            purgeCalls++;
            await manager.deleteFor(serverId);
          }),
        ],
      );

      try {
        container.read(userScopedProviderCleanupProvider);
        final bootstrap = await container.read(authStateManagerProvider.future);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        check(bootstrap.status).equals(AuthStatus.loading);
        check(bootstrap.user).isNull();
        check(
          container.read(openWebUiDatabaseAccessProvider).allowsAppDatabase,
        ).isFalse();
        check(purgeCalls).equals(0);
        check(
          await serverDatabase.chatsDao.getChat('retained-b-chat'),
        ).isNotNull();

        validatedUser.complete(_userB);
        for (var attempt = 0; attempt < 100; attempt++) {
          if (container.read(openWebUiDatabaseAccessProvider) ==
              OpenWebUiDatabaseAccessPhase.open) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await container
            .read(openWebUiAccountStorageIsolationProvider.notifier)
            .settled;

        check(
          container.read(openWebUiDatabaseAccessProvider),
        ).equals(OpenWebUiDatabaseAccessPhase.open);
        check(container.read(currentUserProvider2)?.id).equals(_userB.id);
        check(purgeCalls).equals(0);
        check(container.read(appDatabaseProvider)).identicalTo(serverDatabase);
        check(
          await serverDatabase.chatsDao.getChat('retained-b-chat'),
        ).isNotNull();
        check(storage.savedUsers.map((user) => user.id)).contains(_userB.id);
      } finally {
        container.dispose();
        await manager.closeActive();
        await direct.close();
        if (await directory.exists()) await directory.delete(recursive: true);
        PreferencesStore.debugReset();
      }
    },
  );

  test(
    'same-server account switch never exposes the prior summary or body',
    () async {
      final harness = await _harness();
      final container = harness.container;
      final before = await container.read(conversationsProvider.future);
      check(
        before.map((chat) => chat.id),
      ).containsEqualInOrder(<String>['account-a-chat', 'direct-chat']);

      final postLogoutEmissions = <List<String>>[];
      final subscription = container.listen<AsyncValue<List<Conversation>>>(
        conversationsProvider,
        (_, next) {
          final value = next.asData?.value;
          if (value != null) {
            postLogoutEmissions.add(value.map((chat) => chat.id).toList());
          }
        },
      );
      addTearDown(subscription.close);
      postLogoutEmissions.clear();

      container
          .read(activeConversationProvider.notifier)
          .set(_openWebUiConversation('account-a-chat', 'A private body'));
      container.read(chatMessagesProvider);

      harness.auth.publish(const AuthState(status: AuthStatus.unauthenticated));
      await Future<void>.delayed(Duration.zero);
      await container
          .read(openWebUiAccountStorageIsolationProvider.notifier)
          .settled;

      check(
        container.read(openWebUiDatabaseAccessProvider),
      ).equals(OpenWebUiDatabaseAccessPhase.closed);
      check(container.read(activeConversationProvider)).isNull();
      check(container.read(chatMessagesProvider)).isEmpty();
      check(
        postLogoutEmissions.every((ids) => !ids.contains('account-a-chat')),
      ).isTrue();

      harness.auth.publish(_authenticated('token-b', _userB));
      await Future<void>.delayed(Duration.zero);
      check(
        container.read(openWebUiDatabaseAccessProvider),
      ).equals(OpenWebUiDatabaseAccessPhase.open);

      final after = await container.read(conversationsProvider.future);
      check(
        after.map((chat) => chat.id).toList(),
      ).deepEquals(<String>['direct-chat']);
      check(await loadLocalConversation(container, 'account-a-chat')).isNull();
    },
  );

  test(
    'purge retries trust once and does not repeat it after success',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        PreferenceKeys.activeServerId: _server.id,
      });
      PreferencesStore.debugReset();
      HermesMixedSessionBindingTrustStore.debugResetRuntimeState();
      final preferences = await SharedPreferences.getInstance();
      var revocationWrites = 0;
      var enforceSingleRevocation = false;
      PreferencesStore.debugOverride(
        preferences,
        writeInterceptor: (_, key, value) async {
          if (enforceSingleRevocation &&
              key == PreferenceKeys.hermesMixedSessionBindingTrust) {
            revocationWrites++;
            if (revocationWrites == 1) return false;
            return revocationWrites == 2 ? null : false;
          }
          return null;
        },
      );
      addTearDown(() {
        HermesMixedSessionBindingTrustStore.debugResetRuntimeState();
        PreferencesStore.debugReset();
      });

      final marker = openWebUiAccountOwnerMarker(
        token: 'token-a',
        userId: _userA.id,
      )!;
      final storageAccountIdentity =
          HermesMixedSessionBindingTrustStore.durableStorageAccountIdentity(
            serverId: _server.id,
            userId: _userA.id,
            tokenFingerprint: marker.tokenFingerprint,
          );
      await HermesMixedSessionBindingTrustStore.remember(
        storageAccountIdentity: storageAccountIdentity,
        conversationId: 'account-a-chat',
        assistantMessageId: 'assistant-a',
        sessionId: 'session-a',
        connectionIdentity: 'connection-a',
      );
      enforceSingleRevocation = true;

      var cacheClearCalls = 0;
      var purgeCalls = 0;
      final harness = await _harness(
        accountCacheClear: () async {
          cacheClearCalls++;
          if (cacheClearCalls == 1) {
            throw StateError('transient cache cleanup failure');
          }
        },
        databasePurge: (_) async {
          purgeCalls++;
        },
      );

      harness.auth.publish(const AuthState(status: AuthStatus.unauthenticated));
      await Future<void>.delayed(Duration.zero);
      await harness.container
          .read(openWebUiAccountStorageIsolationProvider.notifier)
          .settled;

      check(revocationWrites).equals(2);
      check(cacheClearCalls).equals(2);
      check(purgeCalls).equals(1);
      check(harness.markerStore.read(_server.id)).isNull();
      check(
        harness.container.read(openWebUiDatabaseAccessProvider),
      ).equals(OpenWebUiDatabaseAccessPhase.closed);
    },
  );

  test(
    'local conversation read drops a body when its account gate changes mid-load',
    () async {
      final harness = await _harness();
      final container = harness.container;
      final transactionStarted = Completer<void>();
      final releaseTransaction = Completer<void>();
      final blockingTransaction = harness.serverA.transaction(() async {
        transactionStarted.complete();
        await releaseTransaction.future;
      });
      await transactionStarted.future;

      final pending = loadLocalConversation(container, 'account-a-chat');
      await Future<void>.delayed(Duration.zero);

      container.read(openWebUiDatabaseAccessProvider.notifier).beginPurge();
      container.read(openWebUiCertifiedDatabaseServerProvider.notifier).clear();
      releaseTransaction.complete();
      await blockingTransaction;

      check(await pending).isNull();
      check(container.read(activeConversationProvider)).isNull();
    },
  );

  test(
    'unlistened conversation provider stays mounted during repository load',
    () async {
      final harness = await _harness();
      final container = harness.container;
      final transactionStarted = Completer<void>();
      final releaseTransaction = Completer<void>();
      final blockingTransaction = harness.serverA.transaction(() async {
        transactionStarted.complete();
        await releaseTransaction.future;
      });
      try {
        await transactionStarted.future;

        final scopedId = const ChatStorageIdentity(
          rawId: 'account-a-chat',
          storage: ChatStorageKind.openWebUi,
        ).scopedId;
        var completed = false;
        final pending = container
            .read(loadConversationProvider(scopedId).future)
            .then(
              (conversation) {
                completed = true;
                return conversation;
              },
              onError: (Object error, StackTrace stackTrace) {
                completed = true;
                Error.throwWithStackTrace(error, stackTrace);
              },
            );
        await Future<void>.delayed(Duration.zero);
        check(completed).isFalse();

        releaseTransaction.complete();
        await blockingTransaction;

        final conversation = await pending;
        check(conversation.id).equals('account-a-chat');
        check(
          chatStorageKindOf(conversation),
        ).equals(ChatStorageKind.openWebUi);
      } finally {
        if (!releaseTransaction.isCompleted) {
          releaseTransaction.complete();
        }
        await blockingTransaction;
      }
    },
  );

  test(
    'conversation provider drops a repository body when ownership changes mid-load',
    () async {
      final harness = await _harness();
      final container = harness.container;
      final transactionStarted = Completer<void>();
      final releaseTransaction = Completer<void>();
      final blockingTransaction = harness.serverA.transaction(() async {
        transactionStarted.complete();
        await releaseTransaction.future;
      });
      await transactionStarted.future;

      final scopedId = const ChatStorageIdentity(
        rawId: 'account-a-chat',
        storage: ChatStorageKind.openWebUi,
      ).scopedId;
      final pending = container
          .read(loadConversationProvider(scopedId).future)
          .then<Object>(
            (conversation) => conversation,
            onError: (Object error, StackTrace _) => error,
          );
      await Future<void>.delayed(Duration.zero);

      container.read(openWebUiDatabaseAccessProvider.notifier).beginPurge();
      container.read(openWebUiCertifiedDatabaseServerProvider.notifier).clear();
      releaseTransaction.complete();
      await blockingTransaction;

      check(await pending).isA<StateError>();
      check(container.read(activeConversationProvider)).isNull();
    },
  );

  test(
    'new ChatMessages notifier cannot reveal stale OpenWebUI active payload while gated',
    () async {
      final harness = await _harness();
      final container = harness.container;
      harness.auth.publish(const AuthState(status: AuthStatus.unauthenticated));
      await Future<void>.delayed(Duration.zero);
      await container
          .read(openWebUiAccountStorageIsolationProvider.notifier)
          .settled;

      container
          .read(activeConversationProvider.notifier)
          .set(_openWebUiConversation('stale-a', 'must never render'));
      container.invalidate(chatMessagesProvider);
      check(container.read(chatMessagesProvider)).isEmpty();
      await Future<void>.delayed(Duration.zero);
      check(container.read(activeConversationProvider)).isNull();
    },
  );

  test('startup auth error with no token purges before manual login', () async {
    final harness = await _harness(
      initialAuth: const AuthState(
        status: AuthStatus.error,
        error: 'secure storage failed',
      ),
      expectInitiallyOpen: false,
    );
    final container = harness.container;

    harness.auth.publish(_authenticated('token-b', _userB));
    await Future<void>.delayed(Duration.zero);
    check(
      container.read(openWebUiDatabaseAccessProvider),
    ).equals(OpenWebUiDatabaseAccessPhase.open);
    final chats = await container.read(conversationsProvider.future);
    check(
      chats.map((chat) => chat.id).toList(),
    ).deepEquals(<String>['direct-chat']);
    check(await loadLocalConversation(container, 'account-a-chat')).isNull();
  });

  test(
    'server switch during owner-marker write purges the new target first',
    () async {
      final harness = await _harness();
      final container = harness.container;
      final emittedChatIds = <List<String>>[];
      final conversationsSubscription = container.listen(
        conversationsProvider,
        (previous, next) {
          final conversations = next.asData?.value;
          if (conversations != null) {
            emittedChatIds.add(
              conversations.map((chat) => chat.id).toList(growable: false),
            );
          }
        },
        fireImmediately: true,
      );
      addTearDown(conversationsSubscription.close);
      await container.read(conversationsProvider.future);
      await _seedChat(
        harness.serverB,
        id: 'server-b-marker-race-secret',
        title: 'Prior B account',
        message: 'B private marker-race body',
      );
      final markerWriteStarted = Completer<String>();
      final releaseMarkerWrite = Completer<void>();
      harness.markerStore
        ..nextWriteStarted = markerWriteStarted
        ..nextWriteGate = releaseMarkerWrite.future;

      harness.auth.publish(_authenticated('token-b', _userB));
      check(await markerWriteStarted.future).equals(_server.id);

      harness.serverSelection.set(_serverTwo);
      check(
        (await container.read(activeServerProvider.future))?.id,
      ).equals(_serverTwo.id);
      releaseMarkerWrite.complete();
      await container
          .read(openWebUiAccountStorageIsolationProvider.notifier)
          .settled;

      check(
        container.read(openWebUiCertifiedDatabaseServerProvider),
      ).equals(_serverTwo.id);
      check(
        container.read(openWebUiDatabaseAccessProvider),
      ).equals(OpenWebUiDatabaseAccessPhase.open);
      check(
        await harness.serverB.chatsDao.getChat('server-b-marker-race-secret'),
      ).isNull();
      check(
        (await container.read(
          conversationsProvider.future,
        )).map((chat) => chat.id).toList(),
      ).deepEquals(<String>['direct-chat']);
      await Future<void>.delayed(Duration.zero);
      check(emittedChatIds).isNotEmpty();
      check(
        emittedChatIds.every(
          (ids) => !ids.contains('server-b-marker-race-secret'),
        ),
      ).isTrue();
    },
  );

  test(
    'certified server switch purges the target before it can render',
    () async {
      final harness = await _harness();
      final container = harness.container;
      await _seedChat(
        harness.serverB,
        id: 'server-b-prior-account',
        title: 'Prior B account',
        message: 'B private body',
      );
      final emissions = <List<String>>[];
      final subscription = container.listen<AsyncValue<List<Conversation>>>(
        conversationsProvider,
        (_, next) {
          final chats = next.asData?.value;
          if (chats != null) {
            emissions.add(chats.map((chat) => chat.id).toList());
          }
        },
      );
      addTearDown(subscription.close);

      harness.serverSelection.set(_serverTwo);
      await container.read(activeServerProvider.future);
      await Future<void>.delayed(Duration.zero);
      await container
          .read(openWebUiAccountStorageIsolationProvider.notifier)
          .settled;

      check(
        container.read(openWebUiCertifiedDatabaseServerProvider),
      ).equals(_serverTwo.id);
      check(
        container.read(openWebUiDatabaseAccessProvider),
      ).equals(OpenWebUiDatabaseAccessPhase.open);
      final chats = await container.read(conversationsProvider.future);
      check(
        chats.map((chat) => chat.id).toList(),
      ).deepEquals(<String>['direct-chat']);
      check(
        emissions.every((ids) => !ids.contains('server-b-prior-account')),
      ).isTrue();
    },
  );

  test(
    'sign-out preserves active direct-local chat and model selection',
    () async {
      final harness = await _harness();
      final container = harness.container;
      final profile = DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: 'openai-compatible',
        baseUrl: 'http://localhost:1234',
      );
      final registry = DirectModelRegistry();
      final directModel = registry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'model'),
      ]).single;
      final directChat = withChatStorageProvenance(
        Conversation(
          id: 'direct-chat',
          title: 'Device chat',
          createdAt: DateTime.utc(2026, 7, 13),
          updatedAt: DateTime.utc(2026, 7, 13),
          messages: <ChatMessage>[
            ChatMessage(
              id: 'direct-chat-message',
              role: 'assistant',
              content: 'Device body',
              timestamp: DateTime.utc(2026, 7, 13),
            ),
          ],
          metadata: const <String, dynamic>{'backend': kDirectTransport},
        ),
        ChatStorageKind.directLocal,
      );
      container.read(activeConversationProvider.notifier).set(directChat);
      container.read(selectedModelProvider.notifier).set(directModel);
      container.read(chatMessagesProvider);
      container
          .read(activeConversationInPlaceRemapProvider.notifier)
          .mark(
            fromId: 'direct-from',
            toId: 'direct-to',
            namespace: ActiveConversationRemapNamespace.direct,
          );
      final localRemap = container.read(activeConversationInPlaceRemapProvider);

      harness.auth.publish(const AuthState(status: AuthStatus.unauthenticated));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await container
          .read(openWebUiAccountStorageIsolationProvider.notifier)
          .settled;

      check(container.read(activeConversationProvider)).identicalTo(directChat);
      check(container.read(selectedModelProvider)).identicalTo(directModel);
      check(
        container.read(chatMessagesProvider).single.content,
      ).equals('Device body');
      check(
        container.read(activeConversationInPlaceRemapProvider),
      ).identicalTo(localRemap);
    },
  );

  test(
    'sign-out preserves app-owned Hermes chat and model selection',
    () async {
      final harness = await _harness();
      final container = harness.container;
      final hermesModel = hermesSyntheticModel();
      final hermesChat = withChatStorageProvenance(
        Conversation(
          id: 'hermes-runtime-chat',
          title: 'Hermes chat',
          createdAt: DateTime.utc(2026, 7, 13),
          updatedAt: DateTime.utc(2026, 7, 13),
          messages: <ChatMessage>[
            ChatMessage(
              id: 'hermes-message',
              role: 'assistant',
              content: 'Hermes body',
              timestamp: DateTime.utc(2026, 7, 13),
            ),
          ],
          metadata: const <String, dynamic>{'backend': 'hermes'},
        ),
        ChatStorageKind.directLocal,
      );
      container.read(activeConversationProvider.notifier).set(hermesChat);
      container.read(selectedModelProvider.notifier).set(hermesModel);
      container.read(chatMessagesProvider);
      container
          .read(activeConversationInPlaceRemapProvider.notifier)
          .mark(
            fromId: 'hermes-from',
            toId: 'hermes-to',
            namespace: ActiveConversationRemapNamespace.hermes,
          );
      final localRemap = container.read(activeConversationInPlaceRemapProvider);

      harness.auth.publish(const AuthState(status: AuthStatus.unauthenticated));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await container
          .read(openWebUiAccountStorageIsolationProvider.notifier)
          .settled;

      check(container.read(activeConversationProvider)).identicalTo(hermesChat);
      check(container.read(selectedModelProvider)).identicalTo(hermesModel);
      check(
        container.read(chatMessagesProvider).single.content,
      ).equals('Hermes body');
      check(
        container.read(activeConversationInPlaceRemapProvider),
      ).identicalTo(localRemap);
    },
  );
}
