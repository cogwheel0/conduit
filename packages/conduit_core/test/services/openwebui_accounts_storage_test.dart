import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
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

/// Several accounts sharing the one live session slot.
///
/// The live token and saved sign-in always belong to the active account; the
/// others keep theirs in the vault. What must hold across every operation:
/// a session is never lost, never in two places, and never filed under an
/// account it does not belong to.
void main() {
  late Directory tempDir;
  late InMemorySecureKeyValueStore secure;
  late OptimizedStorageService storage;
  late WorkerManager workerManager;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('accounts-storage-test');
    Hive.init(tempDir.path);
    final boxes = HiveBoxes(
      preferences: await Hive.openBox<dynamic>(HiveBoxNames.preferences),
      caches: await Hive.openBox<dynamic>(HiveBoxNames.caches),
      attachmentQueue: await Hive.openBox<dynamic>(
        HiveBoxNames.attachmentQueue,
      ),
      metadata: await Hive.openBox<dynamic>(HiveBoxNames.metadata),
    );
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();
    secure = InMemorySecureKeyValueStore();
    workerManager = WorkerManager(maxConcurrentTasks: 1);
    storage = OptimizedStorageService(
      secureStorage: secure,
      boxes: boxes,
      workerManager: workerManager,
    );
  });

  tearDown(() async {
    workerManager.dispose();
    PreferencesStore.debugReset();
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ServerConfig account(String id, {String url = 'https://chat.example.com'}) =>
      ServerConfig(id: id, name: 'Chat', url: url);

  Future<String?> vaultedToken(String id) =>
      secure.read(key: 'auth_token_server_v1:$id');

  Future<Map<String, dynamic>?> vaultedCredentials(String id) async {
    final raw = await secure.read(key: 'user_credentials_server_v1:$id');
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> signIn(String id, {String? password}) async {
    await storage.setActiveServerId(id);
    await storage.saveAuthToken('token-$id');
    if (password != null) {
      await storage.saveCredentials(
        serverId: id,
        username: 'user-$id',
        password: password,
      );
    }
  }

  group('switching', () {
    test('moves the token and the saved sign-in both ways', () async {
      await storage.saveServerConfigs([account('a'), account('b')]);
      await signIn('a', password: 'pw-a');

      check(
        await storage.switchActiveServer(fromServerId: 'a', toServerId: 'b'),
      ).isFalse();
      check(await vaultedToken('a')).equals('token-a');
      check(await vaultedCredentials('a')).isNotNull().containsKey('password');
      check(await storage.getAuthTokenStrict()).isNull();
      check(await storage.getSavedCredentialsStrict()).isNull();

      check(
        await storage.switchActiveServer(fromServerId: 'b', toServerId: 'a'),
      ).isTrue();
      check(await storage.getAuthTokenStrict()).equals('token-a');
      check((await storage.getSavedCredentialsStrict())?['password'])
          .equals('pw-a');
      check(await vaultedToken('a')).isNull();
      check(await vaultedCredentials('a')).isNull();
    });

    test('a saved sign-in alone is enough to come back to', () async {
      await storage.saveServerConfigs([account('a'), account('b')]);
      await storage.setActiveServerId('a');
      await storage.saveCredentials(
        serverId: 'a',
        username: 'user-a',
        password: 'pw-a',
      );

      await storage.switchActiveServer(fromServerId: 'a', toServerId: 'b');
      check(
        await storage.switchActiveServer(fromServerId: 'b', toServerId: 'a'),
      ).isTrue();
      check(await storage.getAuthTokenStrict()).isNull();
      check((await storage.getSavedCredentialsStrict())?['username'])
          .equals('user-a');
    });

    test('lists which accounts hold a session', () async {
      await storage.saveServerConfigs([
        account('a'),
        account('b'),
        account('c'),
      ]);
      await signIn('a');
      await storage.switchActiveServer(fromServerId: 'a', toServerId: 'b');
      await storage.saveAuthToken('token-b');

      check(await storage.accountIdsWithSession()).deepEquals({'a', 'b'});
    });
  });

  group('adding an account', () {
    test('keeps the previous account signed in, in its vault', () async {
      await storage.saveServerConfigs([account('a')]);
      await signIn('a', password: 'pw-a');

      await storage.selectUnauthenticatedServerConfig(
        account('new'),
        publish: () {},
      );

      check((await storage.getServerConfigs()).map((config) => config.id))
          .deepEquals(['a', 'new']);
      check(await storage.getActiveServerId()).equals('new');
      check(await storage.getAuthTokenStrict()).isNull();
      check(await vaultedToken('a')).equals('token-a');
      final registry = await storage.getOpenWebUiRegistryStrict();
      check(registry.servers).length.equals(1);
    });

    test('drops an earlier sign-in that never got anywhere', () async {
      await storage.saveServerConfigs([account('a')]);
      await signIn('a');
      await storage.selectUnauthenticatedServerConfig(
        account('abandoned'),
        publish: () {},
      );

      await storage.selectUnauthenticatedServerConfig(
        account('retry'),
        publish: () {},
      );

      check((await storage.getServerConfigs()).map((config) => config.id))
          .deepEquals(['a', 'retry']);
      check(await vaultedToken('a')).equals('token-a');
    });

    test('a commit for another account files the old session away', () async {
      await storage.saveServerConfigs([account('a'), account('b')]);
      await signIn('a', password: 'pw-a');
      final ownership = await storage.captureSavedServerSessionOwnership('b');

      final committed = await storage.commitExistingServerSession(
        ownership: ownership!,
        token: 'token-b',
        canCommit: () => true,
        publish: () {},
      );

      check(committed).isTrue();
      check(await storage.getActiveServerId()).equals('b');
      check(await storage.getAuthTokenStrict()).equals('token-b');
      check(await vaultedToken('a')).equals('token-a');
      check((await vaultedCredentials('a'))?['password']).equals('pw-a');
    });

    test('a failed commit leaves no copy behind in the vault', () async {
      await storage.saveServerConfigs([account('a'), account('b')]);
      await signIn('a');
      final ownership = await storage.captureSavedServerSessionOwnership('b');
      var checks = 0;

      final committed = await storage.commitExistingServerSession(
        ownership: ownership!,
        token: 'token-b',
        canCommit: () => ++checks < 4,
        publish: () {},
      );

      check(committed).isFalse();
      check(await storage.getActiveServerId()).equals('a');
      check(await storage.getAuthTokenStrict()).equals('token-a');
      check(await vaultedToken('a')).isNull();
    });
  });

  group('removing an account', () {
    test('an inactive one loses its vault and its record', () async {
      await storage.saveServerConfigs([
        account('a'),
        account('b', url: 'https://other.example.com'),
      ]);
      await signIn('b');
      await storage.switchActiveServer(fromServerId: 'b', toServerId: 'a');

      check(await storage.removeAccount('b')).isFalse();

      check((await storage.getServerConfigs()).map((config) => config.id))
          .deepEquals(['a']);
      check(await vaultedToken('b')).isNull();
      final registry = await storage.getOpenWebUiRegistryStrict();
      check(registry.servers).length.equals(1);
      check(await storage.getActiveServerId()).equals('a');
    });

    test('the active one hands over to the next account', () async {
      await storage.saveServerConfigs([account('a'), account('b')]);
      await signIn('b', password: 'pw-b');
      await storage.switchActiveServer(fromServerId: 'b', toServerId: 'a');
      await storage.saveAuthToken('token-a');

      check(await storage.removeAccount('a', thenActivate: 'b')).isTrue();

      check(await storage.getActiveServerId()).equals('b');
      check(await storage.getAuthTokenStrict()).equals('token-b');
      check((await storage.getSavedCredentialsStrict())?['password'])
          .equals('pw-b');
      check(await vaultedToken('b')).isNull();
      check((await storage.getServerConfigs()).map((config) => config.id))
          .deepEquals(['b']);
    });

    test('the last one leaves nothing active', () async {
      await storage.saveServerConfigs([account('a')]);
      await signIn('a', password: 'pw-a');

      check(await storage.removeAccount('a')).isFalse();

      check(await storage.getServerConfigs()).isEmpty();
      check(PreferencesStore.getString(PreferenceKeys.activeServerId)).isNull();
      check(await storage.getAuthTokenStrict()).isNull();
      check(await storage.getSavedCredentialsStrict()).isNull();
    });
  });

  group('signing in as an existing account', () {
    test('folds the new account into the existing one', () async {
      await storage.saveServerConfigs([account('existing'), account('new')]);
      await signIn('existing');
      await storage.switchActiveServer(
        fromServerId: 'existing',
        toServerId: 'new',
      );
      await storage.saveAuthToken('fresh-token');
      await storage.saveCredentials(
        serverId: 'new',
        username: 'user',
        password: 'pw',
      );

      await storage.mergeActiveAccountInto(
        'existing',
        expectedSourceAccountId: 'new',
      );

      check(await storage.getActiveServerId()).equals('existing');
      check(await storage.getAuthTokenStrict()).equals('fresh-token');
      check((await storage.getSavedCredentialsStrict())?['serverId'])
          .equals('existing');
      check(await vaultedToken('existing')).isNull();
      check((await storage.getServerConfigs()).map((config) => config.id))
          .deepEquals(['existing']);
    });

    test('does nothing when another account has since become active', () async {
      await storage.saveServerConfigs([account('existing'), account('new')]);
      await signIn('existing');

      await storage.mergeActiveAccountInto(
        'existing',
        expectedSourceAccountId: 'new',
      );

      check((await storage.getServerConfigs()).map((config) => config.id))
          .deepEquals(['existing', 'new']);
      check(await storage.getAuthTokenStrict()).equals('token-existing');
    });
  });

  test('signing out of the active account leaves the others', () async {
    await storage.saveServerConfigs([account('a'), account('b')]);
    await signIn('b');
    await storage.switchActiveServer(fromServerId: 'b', toServerId: 'a');
    await storage.saveAuthToken('token-a');

    check(await storage.clearActiveAccountAuthDataIf(canClear: () => true))
        .isTrue();

    check(await storage.getAuthTokenStrict()).isNull();
    check(await vaultedToken('b')).equals('token-b');
  });

  test('recording the proven user does not invalidate a sign-in', () async {
    await storage.saveServerConfigs([account('a')]);
    await storage.setActiveServerId('a');
    final ownership = await storage.captureServerSessionOwnership(
      validatedConfig: account('a'),
      requireActive: true,
    );

    await storage.bindAccountUser('a', 'user-1');

    check(
      await storage.commitExistingServerSession(
        ownership: ownership!,
        token: 'token-a',
        canCommit: () => true,
        publish: () {},
      ),
    ).isTrue();
    final registry = await storage.getOpenWebUiRegistryStrict();
    check(registry.account('a')?.userId).equals('user-1');
    check(registry).isA<OpenWebUiRegistry>();
  });
}
