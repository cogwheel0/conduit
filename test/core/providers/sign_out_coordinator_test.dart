import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/database_manager.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/services/secure_credential_storage.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_mcp_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

final class _ClearedAuthStateManager extends AuthStateManager {
  _ClearedAuthStateManager([this.outcome = FullAppDataClearOutcome.cleared]);

  final FullAppDataClearOutcome outcome;

  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.authenticated, token: 'session-token');

  @override
  Future<FullAppDataClearOutcome> logoutAndClearAppData({
    required bool keepServerDetails,
    required Future<void> Function() beforeClear,
  }) async {
    await beforeClear();
    return outcome;
  }
}

/// Wipes the device stores the way the real full-data clear does.
final class _WipingAuthStateManager extends _ClearedAuthStateManager {
  @override
  Future<FullAppDataClearOutcome> logoutAndClearAppData({
    required bool keepServerDetails,
    required Future<void> Function() beforeClear,
  }) async {
    await beforeClear();
    await PreferencesStore.clear();
    await SecureCredentialStorage(instance: ref.read(secureStorageProvider))
        .clearAll();
    return FullAppDataClearOutcome.cleared;
  }
}

final class _EmptyDirectProfiles extends DirectConnectionProfilesController {
  @override
  Future<List<DirectConnectionProfile>> build() async => const [];
}

final class _EmptyHermesConfig extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    PreferencesStore.debugReset();
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await PreferencesStore.ensureInitialized();
  });

  tearDown(PreferencesStore.debugReset);

  test('full-data sign-out purges the direct-local chat database', () async {
    var purgeCalls = 0;
    final container = ProviderContainer(
      overrides: [
        authStateManagerProvider.overrideWith(_ClearedAuthStateManager.new),
        directConnectionProfilesProvider.overrideWith(_EmptyDirectProfiles.new),
        hermesConfigProvider.overrideWith(_EmptyHermesConfig.new),
        directLocalDatabasePurgeProvider.overrideWithValue(() async {
          purgeCalls++;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(authStateManagerProvider.future);
    await container.read(directConnectionProfilesProvider.future);
    container.read(hermesConfigProvider);
    final result = await container
        .read(signOutCoordinatorProvider)
        .signOut(keepServerDetails: true);

    check(result).equals(SignOutRequestResult.completed);
    check(purgeCalls).equals(1);
  });

  test(
    'WebView failure cannot skip an otherwise successful local-data purge',
    () async {
      check(
        classifyFullAppDataClearOutcome(
          completeLocalCleanup: false,
          clearAllAppData: true,
          durableAuthDataCleared: true,
        ),
      ).equals(
        FullAppDataClearOutcome.localDataClearedSessionCleanupIncomplete,
      );

      var purgeCalls = 0;
      final container = ProviderContainer(
        overrides: [
          authStateManagerProvider.overrideWith(
            () => _ClearedAuthStateManager(
              FullAppDataClearOutcome.localDataClearedSessionCleanupIncomplete,
            ),
          ),
          directConnectionProfilesProvider.overrideWith(
            _EmptyDirectProfiles.new,
          ),
          hermesConfigProvider.overrideWith(_EmptyHermesConfig.new),
          directLocalDatabasePurgeProvider.overrideWithValue(() async {
            purgeCalls++;
          }),
        ],
      );
      addTearDown(container.dispose);

      await container.read(authStateManagerProvider.future);
      await container.read(directConnectionProfilesProvider.future);
      container.read(hermesConfigProvider);
      await container
          .read(signOutCoordinatorProvider)
          .signOut(keepServerDetails: true);

      check(purgeCalls).equals(1);
    },
  );

  // Riverpod keeps a notifier instance across `invalidate`, so a completed
  // clear must release the controllers' sign-out barriers itself. Otherwise
  // their rebuilds keep serving the connections captured before the wipe.
  test('a completed clear forgets Direct, MCP and Hermes connections and lets '
      'new ones be added', () async {
    final container = ProviderContainer(
      overrides: [
        authStateManagerProvider.overrideWith(_WipingAuthStateManager.new),
        directLocalDatabasePurgeProvider.overrideWithValue(() async {}),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authStateManagerProvider.future);
    final profiles = container.read(directConnectionProfilesProvider.notifier);
    await container.read(directConnectionProfilesProvider.future);
    await profiles.upsert(
      DirectConnectionProfile(
        id: 'before',
        name: 'Before sign-out',
        adapterKey: 'openai-compatible',
        baseUrl: 'http://localhost:1234/v1',
        apiKey: 'sk-before',
      ),
    );
    final mcpServers = container.read(directMcpServersProvider.notifier);
    await container.read(directMcpServersProvider.future);
    await mcpServers.upsert(_mcpServer('mcp-before'));
    final hermes = container.read(hermesConfigProvider.notifier);
    await hermes.saveConnection(baseUrl: 'http://localhost:8642');
    check(container.read(hermesConfigProvider).baseUrl).isNotEmpty();

    await container
        .read(signOutCoordinatorProvider)
        .signOut(keepServerDetails: false);

    check(await container.read(directConnectionProfilesProvider.future))
        .isEmpty();
    check(await container.read(directMcpServersProvider.future)).isEmpty();
    check(container.read(hermesConfigProvider).baseUrl).isEmpty();

    await profiles.upsert(
      DirectConnectionProfile(
        id: 'after',
        name: 'After sign-out',
        adapterKey: 'openai-compatible',
        baseUrl: 'http://localhost:1235/v1',
      ),
    );
    check(
      (await container.read(directConnectionProfilesProvider.future))
          .map((profile) => profile.id),
    ).deepEquals(['after']);
    await mcpServers.upsert(_mcpServer('mcp-after'));
    check(
      (await container.read(directMcpServersProvider.future))
          .map((server) => server.id),
    ).deepEquals(['mcp-after']);
    await hermes.saveConnection(baseUrl: 'http://localhost:8643');
    check(container.read(hermesConfigProvider).baseUrl)
        .equals('http://localhost:8643');
  });

  test('a completed clear leaves no incomplete-clear marker', () async {
    final container = ProviderContainer(
      overrides: [
        authStateManagerProvider.overrideWith(
          () => _ClearedAuthStateManager(FullAppDataClearOutcome.cleared),
        ),
        directConnectionProfilesProvider.overrideWith(_EmptyDirectProfiles.new),
        hermesConfigProvider.overrideWith(_EmptyHermesConfig.new),
        directLocalDatabasePurgeProvider.overrideWithValue(() async {}),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authStateManagerProvider.future);
    await container.read(directConnectionProfilesProvider.future);
    container.read(hermesConfigProvider);

    await container
        .read(signOutCoordinatorProvider)
        .signOut(keepServerDetails: true);

    check(PreferencesStore.getBool(PreferenceKeys.incompleteAppDataClear))
        .isNull();
  });

  test('a completed clear resets host-registered providers', () async {
    var builds = 0;
    final registered = Provider<int>((ref) => ++builds);
    final container = ProviderContainer(
      overrides: [
        authStateManagerProvider.overrideWith(_ClearedAuthStateManager.new),
        directConnectionProfilesProvider.overrideWith(_EmptyDirectProfiles.new),
        hermesConfigProvider.overrideWith(_EmptyHermesConfig.new),
        directLocalDatabasePurgeProvider.overrideWithValue(() async {}),
        signOutResetTargetsProvider.overrideWithValue([registered]),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authStateManagerProvider.future);
    await container.read(directConnectionProfilesProvider.future);
    container.read(hermesConfigProvider);
    check(container.read(registered)).equals(1);

    await container
        .read(signOutCoordinatorProvider)
        .signOut(keepServerDetails: true);

    check(container.read(registered)).equals(2);
  });

  test('an incomplete clear leaves the restart marker armed', () async {
    final container = ProviderContainer(
      overrides: [
        authStateManagerProvider.overrideWith(
          () => _ClearedAuthStateManager(FullAppDataClearOutcome.incomplete),
        ),
        directConnectionProfilesProvider.overrideWith(_EmptyDirectProfiles.new),
        hermesConfigProvider.overrideWith(_EmptyHermesConfig.new),
        directLocalDatabasePurgeProvider.overrideWithValue(() async {}),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authStateManagerProvider.future);
    await container.read(directConnectionProfilesProvider.future);
    container.read(hermesConfigProvider);

    await container
        .read(signOutCoordinatorProvider)
        .signOut(keepServerDetails: true);

    check(PreferencesStore.getBool(PreferenceKeys.incompleteAppDataClear))
        .equals(true);
  });

  test(
    'failed direct-local purge keeps destructive-clear barriers closed',
    () async {
      final container = ProviderContainer(
        overrides: [
          authStateManagerProvider.overrideWith(_ClearedAuthStateManager.new),
          directConnectionProfilesProvider.overrideWith(
            _EmptyDirectProfiles.new,
          ),
          hermesConfigProvider.overrideWith(_EmptyHermesConfig.new),
          directLocalDatabasePurgeProvider.overrideWithValue(
            () => Future<void>.error(StateError('delete failed')),
          ),
        ],
      );
      addTearDown(container.dispose);
      final directRuns = container.read(directRunRegistryProvider);
      addTearDown(() {
        PreferencesStore.resumeWritesAfterAppDataClear();
        SecureCredentialStorage.resumeDirectIdentityWritesAfterAppDataClear();
        directRuns.resumeAdmissionAfterAppDataClearAbort();
      });

      await container.read(authStateManagerProvider.future);
      await container.read(directConnectionProfilesProvider.future);
      container.read(hermesConfigProvider);

      await check(
        container
            .read(signOutCoordinatorProvider)
            .signOut(keepServerDetails: true),
      ).throws<StateError>();
      await check(
        PreferencesStore.put('post-purge-failure', 'must-stay-blocked'),
      ).throws<StateError>();
      check(
        () => directRuns.reserve((
          ownerConversationId: 'post-purge-failure',
          assistantMessageId: 'assistant',
        ), 'profile'),
      ).throws<StateError>();
    },
  );

  test('direct-local purge reopens an empty on-device chat store', () async {
    final tempDir = Directory.systemTemp.createTempSync(
      'conduit_sign_out_direct_local',
    );
    final manager = DatabaseManager(
      databaseDirectory: () async => tempDir,
      openDatabase: (fileName) => AppDatabase(
        NativeDatabase(File(p.join(tempDir.path, '$fileName.sqlite'))),
      ),
    );
    addTearDown(() async {
      await manager.closeActive();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final container = ProviderContainer(
      overrides: [
        directLocalDatabaseManagerProvider.overrideWithValue(manager),
      ],
    );
    addTearDown(container.dispose);

    final database = manager.openForServerId(kDirectLocalDatabaseId);
    await database.chatsDao.upsertLocalOnlyChat(
      rows: ChatBlobMapper.blobToRows(
        chatId: 'device-chat',
        blob: const <String, dynamic>{
          'title': 'Device chat',
          'history': <String, dynamic>{
            'messages': <String, dynamic>{},
            'currentId': null,
          },
        },
        title: 'Device chat',
        folderId: null,
        pinned: false,
        archived: false,
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    check(await database.chatsDao.getChat('device-chat')).isNotNull();

    await container.read(directLocalDatabasePurgeProvider)();
    final reopened = manager.openForServerId(kDirectLocalDatabaseId);

    check(await reopened.chatsDao.getChat('device-chat')).isNull();
  });
}

DirectMcpServer _mcpServer(String id) => DirectMcpServer(
  id: id,
  name: 'Server $id',
  endpoint: 'https://$id.example/mcp',
);
