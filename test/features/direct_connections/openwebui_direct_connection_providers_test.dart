import 'dart:async';

import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/models/backend_config.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/models/user.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/models/openwebui_direct_connection.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit/features/direct_connections/services/openwebui_direct_connection_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('concurrent direct identity key requests converge', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    const storage = FlutterSecureStorage();
    final firstContainer = ProviderContainer(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    final secondContainer = ProviderContainer(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(firstContainer.dispose);
    addTearDown(secondContainer.dispose);

    final keys = await Future.wait<List<int>>([
      firstContainer.read(openWebUiDirectIdentityKeyProvider.future),
      secondContainer.read(openWebUiDirectIdentityKeyProvider.future),
    ]);

    expect(keys.first, hasLength(32));
    expect(keys.last, keys.first);
  });

  test('direct identity key survives provider container recreation', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    const storage = FlutterSecureStorage();
    final firstContainer = ProviderContainer(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    final first = await firstContainer.read(
      openWebUiDirectIdentityKeyProvider.future,
    );
    firstContainer.dispose();

    final secondContainer = ProviderContainer(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(secondContainer.dispose);
    final second = await secondContainer.read(
      openWebUiDirectIdentityKeyProvider.future,
    );

    expect(first, hasLength(32));
    expect(second, first);
  });

  test(
    'effective profiles merge compatible server records and exclude unsupported auth',
    () async {
      final local = _localProfile();
      final store = _storeFor(
        _settings(
          urls: const [
            'https://compatible.example/v1',
            'https://session.example/v1',
          ],
          authTypes: const ['bearer', 'session'],
        ),
      );
      final container = _container(local: [local], store: store);
      addTearDown(container.dispose);

      final snapshot = await container.read(
        openWebUiDirectConnectionsProvider.future,
      );
      final effective = await container.read(
        effectiveDirectConnectionProfilesFutureProvider.future,
      );

      expect(snapshot, isNotNull);
      expect(snapshot!.records, hasLength(2));
      expect(
        snapshot.records.last.compatibility,
        OpenWebUiDirectConnectionCompatibility.unsupportedAuthentication,
      );
      expect(effective.map((profile) => profile.id), [
        local.id,
        snapshot.records.first.profile.id,
      ]);
      expect(effective, isNot(contains(snapshot.records.last.profile)));
    },
  );

  test('server load errors fail open to healthy local profiles', () async {
    final local = _localProfile();
    final store = OpenWebUiDirectConnectionStore(
      serverId: 'server-a',
      accountId: 'account-a',
      readSettings: () async => throw StateError('settings unavailable'),
      writeSettings: (_) async {},
    );
    final container = _container(local: [local], store: store);
    addTearDown(container.dispose);

    final effective = await container.read(
      effectiveDirectConnectionProfilesFutureProvider.future,
    );

    expect(effective, [local]);
    expect(container.read(openWebUiDirectConnectionsProvider).hasError, isTrue);
    expect(
      container.read(effectiveDirectConnectionProfilesProvider).requireValue,
      [local],
    );
  });

  test(
    'server source becoming unavailable revokes only its model bindings',
    () async {
      final local = _localProfile();
      final store = _storeFor(
        _settings(urls: const ['https://remote.example/v1']),
      );
      final source =
          NotifierProvider<_MutableStore, OpenWebUiDirectConnectionStore?>(
            () => _MutableStore(store),
          );
      final container = ProviderContainer(
        overrides: [
          directConnectionProfilesProvider.overrideWith(
            () => _FixedProfiles([local]),
          ),
          openWebUiDirectConnectionStoreProvider.overrideWith(
            (ref) => ref.watch(source),
          ),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        openWebUiDirectConnectionsProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      final snapshot = (await container.read(
        openWebUiDirectConnectionsProvider.future,
      ))!;
      final remote = snapshot.compatibleProfiles.single;
      final registry = container.read(directModelRegistryProvider);
      final localModel = registry.replaceProfileModels(local, [
        DirectRemoteModel(id: 'local-model'),
      ]).single;
      final remoteModel = registry.replaceProfileModels(remote, [
        DirectRemoteModel(id: 'remote-model'),
      ]).single;
      expect(registry.resolve(localModel), isNotNull);
      expect(registry.resolve(remoteModel), isNotNull);

      container.read(source.notifier).set(null);
      await container.read(openWebUiDirectConnectionsProvider.future);
      final effective = await container.read(
        effectiveDirectConnectionProfilesFutureProvider.future,
      );

      expect(registry.resolve(remoteModel), isNull);
      expect(registry.resolve(localModel), isNotNull);
      expect(effective, [local]);
    },
  );

  test('a queued add cannot migrate to a new account store', () async {
    final reloadStarted = Completer<void>();
    final releaseReload = Completer<void>();
    var accountAReads = 0;
    var accountAWrites = 0;
    var accountBWrites = 0;
    final accountASettings = _settings(urls: const []);
    final accountBSettings = _settings(urls: const []);
    final accountAStore = OpenWebUiDirectConnectionStore(
      serverId: 'server-a',
      accountId: 'account-a',
      readSettings: () async {
        accountAReads++;
        if (accountAReads == 2) {
          reloadStarted.complete();
          await releaseReload.future;
        }
        return accountASettings;
      },
      writeSettings: (_) async => accountAWrites++,
    );
    final accountBStore = OpenWebUiDirectConnectionStore(
      serverId: 'server-a',
      accountId: 'account-b',
      readSettings: () async => accountBSettings,
      writeSettings: (_) async => accountBWrites++,
    );
    final source =
        NotifierProvider<_MutableStore, OpenWebUiDirectConnectionStore?>(
          () => _MutableStore(accountAStore),
        );
    final container = ProviderContainer(
      overrides: [
        directConnectionProfilesProvider.overrideWith(
          () => _FixedProfiles(const []),
        ),
        openWebUiDirectConnectionStoreProvider.overrideWith(
          (ref) => ref.watch(source),
        ),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      openWebUiDirectConnectionsProvider,
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await container.read(openWebUiDirectConnectionsProvider.future);
    final controller = container.read(
      openWebUiDirectConnectionsProvider.notifier,
    );

    final reload = controller.reload();
    await reloadStarted.future.timeout(const Duration(seconds: 1));
    final add = controller.add(
      DirectConnectionProfile(
        id: 'draft-from-account-a',
        name: 'Account A draft',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://account-a.example/v1',
        apiKey: 'account-a-secret',
      ),
    );

    container.read(source.notifier).set(accountBStore);
    final accountBSnapshot = await container.read(
      openWebUiDirectConnectionsProvider.future,
    );
    expect(accountBSnapshot?.accountId, 'account-b');
    releaseReload.complete();
    await reload;

    await expectLater(add, throwsA(isA<StateError>()));
    expect(accountAWrites, 0);
    expect(accountBWrites, 0);
  });

  test('queued adds use the latest published document revision', () async {
    var settings = _settings(urls: const []);
    var writes = 0;
    final store = OpenWebUiDirectConnectionStore(
      serverId: 'server-a',
      accountId: 'account-a',
      readSettings: () async => settings,
      writeSettings: (next) async {
        writes++;
        settings = next;
      },
    );
    final container = _container(local: const [], store: store);
    addTearDown(container.dispose);
    await container.read(openWebUiDirectConnectionsProvider.future);
    final controller = container.read(
      openWebUiDirectConnectionsProvider.notifier,
    );

    final first = controller.add(
      DirectConnectionProfile(
        id: 'first-draft',
        name: 'First',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://first.example/v1',
      ),
    );
    final second = controller.add(
      DirectConnectionProfile(
        id: 'second-draft',
        name: 'Second',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://second.example/v1',
      ),
    );

    await Future.wait([first, second]);

    final snapshot = container
        .read(openWebUiDirectConnectionsProvider)
        .requireValue!;
    expect(writes, 2);
    expect(snapshot.records.map((record) => record.profile.baseUrl), [
      'https://first.example/v1',
      'https://second.example/v1',
    ]);
  });

  test('a late initial load cannot overwrite a newer reload', () async {
    final initialReadStarted = Completer<void>();
    final releaseInitialRead = Completer<void>();
    var reads = 0;
    final store = OpenWebUiDirectConnectionStore(
      serverId: 'server-a',
      accountId: 'account-a',
      readSettings: () async {
        reads++;
        if (reads == 1) {
          initialReadStarted.complete();
          await releaseInitialRead.future;
          return _settings(urls: const ['https://stale.example/v1']);
        }
        return _settings(urls: const ['https://fresh.example/v1']);
      },
      writeSettings: (_) async {},
    );
    final container = _container(local: const [], store: store);
    addTearDown(container.dispose);
    final subscription = container.listen(
      openWebUiDirectConnectionsProvider,
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await initialReadStarted.future.timeout(const Duration(seconds: 1));

    await container.read(openWebUiDirectConnectionsProvider.notifier).reload();
    expect(
      container
          .read(openWebUiDirectConnectionsProvider)
          .requireValue!
          .records
          .single
          .profile
          .baseUrl,
      'https://fresh.example/v1',
    );

    releaseInitialRead.complete();
    final settled = await container.read(
      openWebUiDirectConnectionsProvider.future,
    );
    expect(settled?.records.single.profile.baseUrl, 'https://fresh.example/v1');
  });

  test(
    'mutation conflicts publish and revoke against the server winner',
    () async {
      var settings = _settings(urls: const ['https://old.example/v1']);
      final store = OpenWebUiDirectConnectionStore(
        serverId: 'server-a',
        accountId: 'account-a',
        readSettings: () async => settings,
        writeSettings: (_) async {},
      );
      final container = _container(local: const [], store: store);
      addTearDown(container.dispose);

      final initial = (await container.read(
        openWebUiDirectConnectionsProvider.future,
      ))!;
      final staleRecord = initial.records.single;
      final registry = container.read(directModelRegistryProvider);
      final staleModel = registry.replaceProfileModels(staleRecord.profile, [
        DirectRemoteModel(id: 'remote-model'),
      ]).single;
      expect(registry.resolve(staleModel), isNotNull);

      settings = _settings(urls: const ['https://winner.example/v1']);

      await expectLater(
        container
            .read(openWebUiDirectConnectionsProvider.notifier)
            .updateConnection(
              staleRecord,
              staleRecord.profile.copyWith(name: 'Stale edit'),
            ),
        throwsA(isA<OpenWebUiDirectConnectionConflictException>()),
      );

      final published = container
          .read(openWebUiDirectConnectionsProvider)
          .requireValue!;
      expect(
        published.records.single.profile.baseUrl,
        'https://winner.example/v1',
      );
      expect(registry.resolve(staleModel), isNull);
    },
  );

  test(
    'duplicate id moving to another URL index revokes its old binding and run',
    () async {
      var settings = _settings(
        urls: const [
          'https://duplicate.example/v1',
          'https://duplicate.example/v1',
        ],
      );
      final store = OpenWebUiDirectConnectionStore(
        serverId: 'server-a',
        accountId: 'account-a',
        readSettings: () async => settings,
        writeSettings: (next) async => settings = next,
      );
      final container = _container(local: const [], store: store);
      addTearDown(container.dispose);

      final initial = (await container.read(
        openWebUiDirectConnectionsProvider.future,
      ))!;
      final earlierDuplicate = initial.records.first;
      final registry = container.read(directModelRegistryProvider);
      final staleModel = registry
          .replaceProfileModels(
            earlierDuplicate.profile,
            [DirectRemoteModel(id: 'remote-model')],
            source: DirectModelSource.openWebUi,
            openWebUiUrlIndex: earlierDuplicate.index,
          )
          .single;
      final runRegistry = container.read(directRunRegistryProvider);
      final runKey = (
        ownerConversationId: 'conversation',
        assistantMessageId: 'assistant',
      );
      runRegistry.reserve(runKey, earlierDuplicate.profile.id);

      await container
          .read(openWebUiDirectConnectionsProvider.notifier)
          .updateConnection(
            earlierDuplicate,
            earlierDuplicate.profile.copyWith(
              baseUrl: 'https://edited.example/v1',
            ),
          );

      final published = container
          .read(openWebUiDirectConnectionsProvider)
          .requireValue!;
      final retainedDuplicate = published.records.singleWhere(
        (record) => record.profile.baseUrl == 'https://duplicate.example/v1',
      );
      expect(retainedDuplicate.index, 1);
      expect(retainedDuplicate.profile.id, earlierDuplicate.profile.id);
      expect(registry.resolve(staleModel), isNull);
      expect(runRegistry.hasLiveIntent(runKey), isFalse);
    },
  );

  test(
    'uncertain commits revoke stale bindings and require a reload',
    () async {
      var settings = _settings(urls: const ['https://old.example/v1']);
      var failNextRead = false;
      final store = OpenWebUiDirectConnectionStore(
        serverId: 'server-a',
        accountId: 'account-a',
        readSettings: () async {
          if (failNextRead) {
            failNextRead = false;
            throw StateError('reflected server response');
          }
          return settings;
        },
        writeSettings: (payload) async {
          settings = <String, dynamic>{'ui': payload['ui']};
          failNextRead = true;
        },
      );
      final container = _container(local: const [], store: store);
      addTearDown(container.dispose);

      final initial = (await container.read(
        openWebUiDirectConnectionsProvider.future,
      ))!;
      final record = initial.records.single;
      final registry = container.read(directModelRegistryProvider);
      final staleModel = registry.replaceProfileModels(record.profile, [
        DirectRemoteModel(id: 'remote-model'),
      ]).single;

      await expectLater(
        container
            .read(openWebUiDirectConnectionsProvider.notifier)
            .updateConnection(
              record,
              record.profile.copyWith(baseUrl: 'https://new.example/v1'),
            ),
        throwsA(isA<OpenWebUiDirectConnectionCommitUncertainException>()),
      );

      expect(container.read(openWebUiDirectConnectionsProvider).hasError, true);
      expect(registry.resolve(staleModel), isNull);
      await container
          .read(openWebUiDirectConnectionsProvider.notifier)
          .reload();
      expect(
        container
            .read(openWebUiDirectConnectionsProvider)
            .requireValue!
            .records
            .single
            .profile
            .baseUrl,
        'https://new.example/v1',
      );
    },
  );

  test(
    'same-owner metadata refresh keeps the server store and bindings alive',
    () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      SharedPreferences.setMockInitialValues(<String, Object>{
        PreferenceKeys.activeServerId: _server.id,
      });
      PreferencesStore.debugReset();
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());

      final userSource = NotifierProvider<_MutableUser, User?>(
        () => _MutableUser(_user),
      );
      final api = _CountingSettingsApi();
      final backendConfig = _MutableBackendConfig(_backendConfig);
      final container = ProviderContainer(
        overrides: [
          directConnectionProfilesProvider.overrideWith(
            () => _FixedProfiles(const []),
          ),
          activeServerProvider.overrideWith((ref) async => _server),
          apiServiceProvider.overrideWithValue(api),
          backendConfigProvider.overrideWith(() => backendConfig),
          isAuthenticatedProvider2.overrideWithValue(true),
          authTokenProvider3.overrideWithValue('token'),
          currentUserProvider2.overrideWith((ref) => ref.watch(userSource)),
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        ],
      );

      try {
        await container.read(openWebUiDirectIdentityKeyProvider.future);
        await container.read(activeServerProvider.future);
        await container.read(backendConfigProvider.future);
        container
            .read(openWebUiCertifiedDatabaseServerProvider.notifier)
            .set(_server.id);
        container.read(openWebUiDatabaseAccessProvider.notifier).open();

        final store = container.read(openWebUiDirectConnectionStoreProvider);
        expect(store, isNotNull);
        final snapshot = (await container.read(
          openWebUiDirectConnectionsProvider.future,
        ))!;
        final profile = snapshot.compatibleProfiles.single;
        final registry = container.read(directModelRegistryProvider);
        final model = registry.replaceProfileModels(profile, [
          DirectRemoteModel(id: 'remote-model'),
        ]).single;
        expect(api.userSettingsCalls, 1);

        container
            .read(userSource.notifier)
            .set(
              const User(
                id: 'account-a',
                username: 'renamed',
                email: 'renamed@example.com',
                role: 'user',
              ),
            );
        backendConfig.setForTest(
          _backendConfig.copyWith(enableWebSearch: true),
        );
        await Future<void>.delayed(Duration.zero);

        expect(
          container.read(openWebUiDirectConnectionStoreProvider),
          same(store),
        );
        expect(
          container.read(openWebUiDirectConnectionsProvider).requireValue,
          same(snapshot),
        );
        expect(api.userSettingsCalls, 1);
        expect(registry.resolve(model), isNotNull);
      } finally {
        container.dispose();
        api.dispose();
        PreferencesStore.debugReset();
      }
    },
  );
}

const _server = ServerConfig(
  id: 'server-a',
  name: 'Server A',
  url: 'https://server.example',
);

const _user = User(
  id: 'account-a',
  username: 'account-a',
  email: 'account-a@example.com',
  role: 'user',
);

const _backendConfig = BackendConfig(
  serverId: 'server-a',
  enableDirectConnections: true,
  enableWebSearch: false,
);

ProviderContainer _container({
  required List<DirectConnectionProfile> local,
  required OpenWebUiDirectConnectionStore store,
}) => ProviderContainer(
  overrides: [
    directConnectionProfilesProvider.overrideWith(() => _FixedProfiles(local)),
    openWebUiDirectConnectionStoreProvider.overrideWithValue(store),
  ],
);

OpenWebUiDirectConnectionStore _storeFor(Map<String, dynamic> settings) =>
    OpenWebUiDirectConnectionStore(
      serverId: 'server-a',
      accountId: 'account-a',
      readSettings: () async => settings,
      writeSettings: (_) async {},
    );

Map<String, dynamic> _settings({
  required List<String> urls,
  List<String>? authTypes,
}) => <String, dynamic>{
  'ui': <String, dynamic>{
    'directConnections': <String, dynamic>{
      'OPENAI_API_BASE_URLS': urls,
      'OPENAI_API_KEYS': List<String>.filled(urls.length, 'test-key'),
      'OPENAI_API_CONFIGS': <String, dynamic>{
        for (var index = 0; index < urls.length; index++)
          '$index': <String, dynamic>{
            'enable': true,
            'auth_type': authTypes?[index] ?? 'bearer',
          },
      },
    },
  },
};

DirectConnectionProfile _localProfile() => DirectConnectionProfile(
  id: 'local-profile',
  name: 'Local profile',
  adapterKey: kOpenAiCompatibleAdapterKey,
  baseUrl: 'https://local.example/v1',
);

final class _FixedProfiles extends DirectConnectionProfilesController {
  _FixedProfiles(this.profiles);

  final List<DirectConnectionProfile> profiles;

  @override
  Future<List<DirectConnectionProfile>> build() async => profiles;
}

final class _MutableStore extends Notifier<OpenWebUiDirectConnectionStore?> {
  _MutableStore(this.initial);

  final OpenWebUiDirectConnectionStore? initial;

  @override
  OpenWebUiDirectConnectionStore? build() => initial;

  void set(OpenWebUiDirectConnectionStore? value) => state = value;
}

final class _MutableUser extends Notifier<User?> {
  _MutableUser(this.initial);

  final User? initial;

  @override
  User? build() => initial;

  void set(User? value) => state = value;
}

final class _MutableBackendConfig extends BackendConfigNotifier {
  _MutableBackendConfig(this.initial);

  final BackendConfig initial;

  @override
  Future<BackendConfig?> build() async => initial;

  void setForTest(BackendConfig value) => state = AsyncData(value);
}

final class _CountingSettingsApi extends ApiService {
  _CountingSettingsApi._(this._workerManager)
    : super(
        serverConfig: _server,
        workerManager: _workerManager,
        authToken: 'token',
      );

  factory _CountingSettingsApi() => _CountingSettingsApi._(WorkerManager());

  final WorkerManager _workerManager;
  int userSettingsCalls = 0;

  @override
  Future<Map<String, dynamic>> getUserSettings({Object? authSnapshot}) async {
    userSettingsCalls++;
    return _settings(urls: const ['https://remote.example/v1']);
  }

  void dispose() => _workerManager.dispose();
}
