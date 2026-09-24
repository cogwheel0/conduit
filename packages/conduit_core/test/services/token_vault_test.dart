import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/secure_credential_storage.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:hive_ce/hive.dart';
import 'package:test/test.dart';

/// The per-server token vault.
///
/// The vault exists so switching between two servers you are signed into does
/// not mean signing in twice. It sits *beside* the single active token rather
/// than replacing it, because the ownership arbitration, the revocation
/// markers and the incomplete-logout fence are all built around there being
/// exactly one live session -- and giving that phrase a parameter would mean
/// touching every one of them.
///
/// What is asserted here is the part that can go wrong quietly: which token
/// is live after a switch, and whether signing out really ends every session
/// or only the visible one.
void main() {
  late Directory tempDir;
  late InMemorySecureKeyValueStore secureStore;
  late OptimizedStorageService storage;
  late WorkerManager workerManager;
  late Box<dynamic> preferences;
  late Box<dynamic> caches;
  late Box<dynamic> attachmentQueue;
  late Box<dynamic> metadata;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('token-vault-test');
    Hive.init(tempDir.path);
    preferences = await Hive.openBox<dynamic>(HiveBoxNames.preferences);
    caches = await Hive.openBox<dynamic>(HiveBoxNames.caches);
    attachmentQueue = await Hive.openBox<dynamic>(HiveBoxNames.attachmentQueue);
    metadata = await Hive.openBox<dynamic>(HiveBoxNames.metadata);

    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();

    secureStore = InMemorySecureKeyValueStore();
    workerManager = WorkerManager(maxConcurrentTasks: 1);
    storage = OptimizedStorageService(
      secureStorage: secureStore,
      boxes: HiveBoxes(
        preferences: preferences,
        caches: caches,
        attachmentQueue: attachmentQueue,
        metadata: metadata,
      ),
      workerManager: workerManager,
    );
  });

  tearDown(() async {
    workerManager.dispose();
    PreferencesStore.debugReset();
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ServerConfig server(String id) =>
      ServerConfig(id: id, name: id, url: 'https://$id.example.com');

  Future<void> configure(List<String> ids) =>
      storage.saveServerConfigs(ids.map(server).toList(growable: false));

  group('switchActiveServer', () {
    test(
      'stashes the outgoing session and restores the incoming one',
      () async {
        await configure(<String>['a', 'b']);
        await storage.setActiveServerId('a');
        await storage.saveAuthToken('token-for-a');

        final adoptedB = await storage.switchActiveServer(
          fromServerId: 'a',
          toServerId: 'b',
        );
        // B has never signed in, so there is nothing to adopt -- and the caller
        // is told so rather than left holding A's bearer.
        check(adoptedB).isFalse();
        check(await storage.getAuthTokenStrict()).isNull();

        await storage.saveAuthToken('token-for-b');

        final adoptedA = await storage.switchActiveServer(
          fromServerId: 'b',
          toServerId: 'a',
        );
        check(adoptedA).isTrue();
        check(await storage.getAuthTokenStrict()).equals('token-for-a');
        check(await storage.getActiveServerId()).equals('a');
      },
    );

    test('never leaves the previous server\'s token live', () async {
      await configure(<String>['a', 'b']);
      await storage.setActiveServerId('a');
      await storage.saveAuthToken('token-for-a');

      await storage.switchActiveServer(fromServerId: 'a', toServerId: 'b');

      // The failure this guards against: pointing at B while still holding
      // A's bearer, which would send A's credentials to B. Two mechanisms
      // enforce it -- `_setActiveServerIdUnlocked` drops the token on any
      // active-id change, and `switchActiveServer` clears it explicitly when
      // there is nothing to adopt -- so this passes with either one removed.
      // It asserts the property rather than one implementation of it.
      check(await storage.getAuthTokenStrict()).isNull();
      check(await storage.vaultedServerIds()).which((it) => it.contains('a'));
    });

    test('an adopted token is removed from the vault', () async {
      await configure(<String>['a', 'b']);
      await storage.setActiveServerId('a');
      await storage.saveAuthToken('token-for-a');
      await storage.switchActiveServer(fromServerId: 'a', toServerId: 'b');
      await storage.saveAuthToken('token-for-b');
      await storage.switchActiveServer(fromServerId: 'b', toServerId: 'a');

      // One copy of a credential, not two. A stale vault copy is how a
      // revoked session comes back.
      check(await storage.vaultedServerIds()).not((it) => it.contains('a'));
      check(await storage.vaultedServerIds()).which((it) => it.contains('b'));
    });

    test('switching with no active session stashes nothing', () async {
      await configure(<String>['a', 'b']);
      await storage.setActiveServerId('a');

      await storage.switchActiveServer(fromServerId: 'a', toServerId: 'b');

      // An empty stash entry would later read as "a is signed in".
      check(await storage.vaultedServerIds()).isEmpty();
    });

    test('switching to the same server is not a round trip', () async {
      await configure(<String>['a']);
      await storage.setActiveServerId('a');
      await storage.saveAuthToken('token-for-a');

      final adopted = await storage.switchActiveServer(
        fromServerId: 'a',
        toServerId: 'a',
      );

      // True because the server does have a live session -- the return value
      // answers "is this server signed in afterwards", which is what the
      // caller needs in order to choose between the app and a sign-in form.
      check(adopted).isTrue();
      check(await storage.getAuthTokenStrict()).equals('token-for-a');
      check(await storage.vaultedServerIds()).isEmpty();
    });

    test('a first connection with no previous server adopts nothing', () async {
      await configure(<String>['a']);

      check(
        await storage.switchActiveServer(fromServerId: null, toServerId: 'a'),
      ).isFalse();
      check(await storage.getActiveServerId()).equals('a');
    });
  });

  group('signing out', () {
    test('empties the vault, not just the live slot', () async {
      await configure(<String>['a', 'b']);
      await storage.setActiveServerId('a');
      await storage.saveAuthToken('token-for-a');
      await storage.switchActiveServer(fromServerId: 'a', toServerId: 'b');
      await storage.saveAuthToken('token-for-b');

      check(await storage.vaultedServerIds()).which((it) => it.contains('a'));

      await storage.clearAuthDataIf(canClear: () => true);

      // Otherwise "sign out" is not true: A's session would still be in the
      // keychain, and switching back would silently resurrect a session the
      // user believed they had ended.
      check(await storage.vaultedServerIds()).isEmpty();
      check(await storage.getAuthTokenStrict()).isNull();
    });

    test('clearTokenVault empties it on its own', () async {
      await configure(<String>['a', 'b']);
      await storage.setActiveServerId('a');
      await storage.saveAuthToken('token-for-a');
      await storage.switchActiveServer(fromServerId: 'a', toServerId: 'b');

      await storage.clearTokenVault();
      check(await storage.vaultedServerIds()).isEmpty();
    });
  });

  group('SecureCredentialStorage vault keys', () {
    test('a vaulted token is not readable as the active token', () async {
      final credentials = SecureCredentialStorage(instance: secureStore);
      await credentials.saveServerToken('a', 'token-for-a');

      // Distinct keys, so the vault can never be mistaken for the live slot.
      check(await credentials.getAuthTokenStrict()).isNull();
      check(await credentials.getServerToken('a')).equals('token-for-a');
    });

    test('deleting one server\'s token leaves the others', () async {
      final credentials = SecureCredentialStorage(instance: secureStore);
      await credentials.saveServerToken('a', 'token-for-a');
      await credentials.saveServerToken('b', 'token-for-b');

      await credentials.deleteServerToken('a');
      check(await credentials.getServerToken('a')).isNull();
      check(await credentials.getServerToken('b')).equals('token-for-b');
    });

    test('a server id containing the separator round-trips', () async {
      final credentials = SecureCredentialStorage(instance: secureStore);
      // Ids are UUIDs today, but a prefix scheme that breaks on an unexpected
      // character is the kind of thing that fails years later.
      await credentials.saveServerToken('a:b:c', 'token');
      check(await credentials.getServerToken('a:b:c')).equals('token');
      check(await credentials.vaultedServerIds())
          .which((it) => it.contains('a:b:c'));
    });
  });
}
