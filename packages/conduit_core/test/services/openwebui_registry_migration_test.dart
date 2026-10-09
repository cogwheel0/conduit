import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/openwebui_account_owner_marker.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:hive_ce/hive.dart';
import 'package:test/test.dart';

const _legacyKey = 'server_configs_v2';
const _registryKey = 'openwebui_registry_v1';
const _credentialsKey = 'user_credentials_v2';

/// Moving the one-server config list into the registry.
///
/// It runs once, on the first read after an upgrade, at a moment when the
/// Keychain may still be locked. What must hold: a failed read writes
/// nothing, a crash part-way leaves a readable state, and the account that
/// was signed in stays signed in with its data under the same id.
void main() {
  late Directory tempDir;
  late _ScriptedSecureStore secureStore;
  late WorkerManager workerManager;
  late Box<dynamic> preferences;
  late Box<dynamic> caches;
  late Box<dynamic> attachmentQueue;
  late Box<dynamic> metadata;

  OptimizedStorageService newStorage() => OptimizedStorageService(
    secureStorage: secureStore,
    boxes: HiveBoxes(
      preferences: preferences,
      caches: caches,
      attachmentQueue: attachmentQueue,
      metadata: metadata,
    ),
    workerManager: workerManager,
  );

  ServerConfig server(String id, {String? url, bool isActive = false}) =>
      ServerConfig(
        id: id,
        name: id,
        url: url ?? 'https://$id.example.com',
        isActive: isActive,
      );

  void seedLegacy(List<ServerConfig> configs) {
    secureStore.values[_legacyKey] = jsonEncode([
      for (final config in configs) config.toJson(),
    ]);
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('registry-migration-test');
    Hive.init(tempDir.path);
    preferences = await Hive.openBox<dynamic>(HiveBoxNames.preferences);
    caches = await Hive.openBox<dynamic>(HiveBoxNames.caches);
    attachmentQueue = await Hive.openBox<dynamic>(HiveBoxNames.attachmentQueue);
    metadata = await Hive.openBox<dynamic>(HiveBoxNames.metadata);
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();
    secureStore = _ScriptedSecureStore();
    workerManager = WorkerManager(maxConcurrentTasks: 1);
  });

  tearDown(() async {
    workerManager.dispose();
    PreferencesStore.debugReset();
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('the signed-in server becomes an account under the same id', () async {
    final active = server('active')
        .copyWith(customHeaders: const {'X-Tenant': 't', 'Cookie': 'proxy=1'});
    seedLegacy([active]);
    await PreferencesStore.put(PreferenceKeys.activeServerId, 'active');
    await const PreferencesOpenWebUiAccountOwnerMarkerStore().write('active', (
      tokenFingerprint: 'fingerprint',
      userId: 'user-1',
    ));

    final storage = newStorage();

    check(await storage.getServerConfigsStrict()).deepEquals([active]);
    check(await storage.getActiveServerId()).equals('active');
    check(secureStore.values.containsKey(_legacyKey)).isFalse();
    final registry = OpenWebUiRegistry.decode(
      secureStore.values[_registryKey]!,
    );
    check(registry.account('active')!.userId).equals('user-1');
    check(registry.servers.single.endpoints.single.customHeaders)
        .deepEquals({'X-Tenant': 't'});
  });

  test('rows with nothing behind them are left out', () async {
    seedLegacy([
      server('stale-1'),
      server('active'),
      server('credential-owner'),
      server('vaulted'),
      server('stale-2'),
    ]);
    await PreferencesStore.put(PreferenceKeys.activeServerId, 'active');
    secureStore.values['user_credentials_v2'] = jsonEncode({
      'serverId': 'credential-owner',
      'username': 'u',
      'password': 'p',
    });
    secureStore.values['auth_token_server_v1:vaulted'] = 'vaulted-token';

    final configs = await newStorage().getServerConfigsStrict();

    check(configs.map((config) => config.id).toSet())
        .deepEquals({'active', 'credential-owner', 'vaulted'});
  });

  test('a saved sign-in follows the account its owner collapsed into', () async {
    seedLegacy([
      server('active', url: 'https://chat.example.com'),
      server('owner', url: 'https://chat.example.com'),
    ]);
    await PreferencesStore.put(PreferenceKeys.activeServerId, 'active');
    // Left behind by an interrupted commit: the sign-in names the older
    // account of the same user on the same server.
    secureStore.values['user_credentials_v2'] = jsonEncode({
      'serverId': 'owner',
      'username': 'u',
      'password': 'p',
    });
    const markers = PreferencesOpenWebUiAccountOwnerMarkerStore();
    for (final id in ['active', 'owner']) {
      await markers.write(id, (tokenFingerprint: 'fp-$id', userId: 'user-1'));
    }

    final configs = await newStorage().getServerConfigsStrict();

    check(configs.map((config) => config.id)).deepEquals(['active']);
    final saved =
        jsonDecode(secureStore.values['user_credentials_v2']!)
            as Map<String, dynamic>;
    check(saved['serverId']).equals('active');
    check(saved['password']).equals('p');
  });

  test('a sign-in deleted while the migration moves it stays deleted', () async {
    seedLegacy([
      server('active', url: 'https://chat.example.com'),
      server('owner', url: 'https://chat.example.com'),
    ]);
    await PreferencesStore.put(PreferenceKeys.activeServerId, 'active');
    secureStore.values[_credentialsKey] = jsonEncode({
      'serverId': 'owner',
      'username': 'u',
      'password': 'p',
    });
    const markers = PreferencesOpenWebUiAccountOwnerMarkerStore();
    for (final id in ['active', 'owner']) {
      await markers.write(id, (tokenFingerprint: 'fp-$id', userId: 'user-1'));
    }
    secureStore.heldReads.add(_credentialsKey);
    final storage = newStorage();

    final migrating = storage.getServerConfigsStrict();
    await secureStore.heldReadStarted.future;
    // Signing out lands after the migration read the sign-in it will move.
    final deleting = storage.deleteSavedCredentials();
    await pumpEventQueue();
    secureStore.releaseHeldReads.complete();
    await Future.wait([migrating, deleting]);

    check(secureStore.values.containsKey(_credentialsKey)).isFalse();
    check(await newStorage().getSavedCredentialsStrict()).isNull();
  });

  for (final (name, migrate) in <(
    String,
    Future<Object?> Function(OptimizedStorageService),
  )>[
    ('registry read', (storage) => storage.getOpenWebUiRegistryStrict()),
    ('user binding', (storage) => storage.bindAccountUser('active', 'user-1')),
  ]) {
    test('a sign-in deleted while a $name migrates stays deleted', () async {
      seedLegacy([
        server('active', url: 'https://chat.example.com'),
        server('owner', url: 'https://chat.example.com'),
      ]);
      await PreferencesStore.put(PreferenceKeys.activeServerId, 'active');
      secureStore.values[_credentialsKey] = jsonEncode({
        'serverId': 'owner',
        'username': 'u',
        'password': 'p',
      });
      const markers = PreferencesOpenWebUiAccountOwnerMarkerStore();
      for (final id in ['active', 'owner']) {
        await markers.write(id, (tokenFingerprint: 'fp-$id', userId: 'user-1'));
      }
      secureStore.heldReads.add(_credentialsKey);
      final storage = newStorage();

      final migrating = migrate(storage);
      await secureStore.heldReadStarted.future;
      final deleting = storage.deleteSavedCredentials();
      await pumpEventQueue();
      secureStore.releaseHeldReads.complete();
      await Future.wait([migrating, deleting]);

      check(secureStore.values.containsKey(_credentialsKey)).isFalse();
    });
  }

  test('a sign-in read before any server list names the kept account', () async {
    seedLegacy([
      server('active', url: 'https://chat.example.com'),
      server('owner', url: 'https://chat.example.com'),
    ]);
    await PreferencesStore.put(PreferenceKeys.activeServerId, 'active');
    secureStore.values[_credentialsKey] = jsonEncode({
      'serverId': 'owner',
      'username': 'u',
      'password': 'p',
    });
    const markers = PreferencesOpenWebUiAccountOwnerMarkerStore();
    for (final id in ['active', 'owner']) {
      await markers.write(id, (tokenFingerprint: 'fp-$id', userId: 'user-1'));
    }
    final storage = newStorage();

    // A cold start without a token reads the sign-in first, then looks up
    // the server it names.
    final saved = await storage.getSavedCredentialsStrict();

    check(saved).isNotNull()['serverId'].equals('active');
    check(
      await storage.captureSavedServerSessionOwnership(saved!['serverId']!),
    ).isNotNull();
  });

  test('a lone config without an active id is kept as the fallback', () async {
    seedLegacy([server('only')]);

    final configs = await newStorage().getServerConfigsStrict();

    check(configs.map((config) => config.id)).deepEquals(['only']);
  });

  test('a read failure writes nothing and leaves the legacy list', () async {
    seedLegacy([server('active', isActive: true)]);
    secureStore.failingReads.add('user_credentials_v2');

    final storage = newStorage();

    await check(storage.getServerConfigsStrict()).throws<StateError>();
    check(secureStore.values.containsKey(_registryKey)).isFalse();
    check(secureStore.values.containsKey(_legacyKey)).isTrue();

    secureStore.failingReads.clear();
    check((await storage.getServerConfigsStrict()).map((config) => config.id))
        .deepEquals(['active']);
    check(secureStore.values.containsKey(_legacyKey)).isFalse();
  });

  test('an unverifiable registry write is undone and reported', () async {
    seedLegacy([server('active', isActive: true)]);
    secureStore.corruptWritesTo.add(_registryKey);

    final storage = newStorage();

    await check(storage.getServerConfigsStrict()).throws<StateError>();
    check(secureStore.values.containsKey(_registryKey)).isFalse();
    check(secureStore.values.containsKey(_legacyKey)).isTrue();
  });

  test(
    'a failed legacy delete still leaves the registry authoritative',
    () async {
      seedLegacy([server('active', isActive: true)]);
      secureStore.failingDeletes.add(_legacyKey);

      final storage = newStorage();
      check((await storage.getServerConfigsStrict()).map((config) => config.id))
          .deepEquals(['active']);
      check(secureStore.values.containsKey(_legacyKey)).isTrue();

      // A later edit lands in the registry; the stale list is never read.
      await storage.saveServerConfigs([
        server('active', isActive: true).copyWith(name: 'Renamed'),
      ]);
      final reloaded = newStorage();
      check((await reloaded.getServerConfigsStrict()).single.name)
          .equals('Renamed');
    },
  );

  test('a registry, once written, is the only thing read', () async {
    final storage = newStorage();
    await storage.saveServerConfigs([server('current', isActive: true)]);
    seedLegacy([server('ghost', isActive: true)]);
    secureStore.readCounts.clear();

    final configs = await newStorage().getServerConfigsStrict();

    check(configs.map((config) => config.id)).deepEquals(['current']);
    check(secureStore.readCounts[_legacyKey]).isNull();
  });
}

/// An in-memory secure store whose reads, writes and deletes can be made to
/// fail per key.
final class _ScriptedSecureStore implements SecureKeyValueStore {
  final Map<String, String> values = <String, String>{};
  final Map<String, int> readCounts = <String, int>{};
  final Set<String> failingReads = <String>{};
  final Set<String> failingDeletes = <String>{};

  /// Keys whose writes are accepted but read back as something else.
  final Set<String> corruptWritesTo = <String>{};

  /// Keys whose next read answers with the value it found, but only once
  /// [releaseHeldReads] completes: a reader paused between its read and
  /// whatever it does next.
  final Set<String> heldReads = <String>{};
  final Completer<void> heldReadStarted = Completer<void>();
  final Completer<void> releaseHeldReads = Completer<void>();

  @override
  Future<String?> read({required String key}) async {
    readCounts.update(key, (count) => count + 1, ifAbsent: () => 1);
    if (failingReads.contains(key)) throw StateError('read failed: $key');
    if (heldReads.remove(key)) {
      final value = values[key];
      heldReadStarted.complete();
      await releaseHeldReads.future;
      return value;
    }
    return values[key];
  }

  @override
  Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = corruptWritesTo.contains(key) ? '$value ' : value;
    }
  }

  @override
  Future<void> delete({required String key}) async {
    if (failingDeletes.contains(key)) throw StateError('delete failed: $key');
    values.remove(key);
  }

  @override
  Future<bool> containsKey({required String key}) async =>
      values.containsKey(key);

  @override
  Future<Map<String, String>> readAll() async => Map.of(values);

  @override
  Future<void> deleteAll() async => values.clear();
}
