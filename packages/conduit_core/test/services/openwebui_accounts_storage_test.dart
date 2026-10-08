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
  late _RefusingSecureStore secure;
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
    secure = _RefusingSecureStore();
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

    test(
      'a switch from an account that is no longer active is refused',
      () async {
        await storage.saveServerConfigs([
          account('a'),
          account('b'),
          account('c'),
        ]);
        await signIn('a');

        // The caller last saw B active; A has taken over since.
        await check(
          storage.switchActiveServer(fromServerId: 'b', toServerId: 'c'),
        ).throws<StateError>();

        check(await storage.getActiveServerId()).equals('a');
        check(await storage.getAuthTokenStrict()).equals('token-a');
        check(await vaultedToken('b')).isNull();
      },
    );

    test('a switch to an account no longer saved is refused', () async {
      await storage.saveServerConfigs([account('a'), account('b')]);
      await signIn('a');
      // A sign-out queued ahead of the switch removed it.
      await storage.removeAccount('b');

      await check(
        storage.switchActiveServer(fromServerId: 'a', toServerId: 'b'),
      ).throws<StateError>();

      check(PreferencesStore.getString(PreferenceKeys.activeServerId))
          .equals('a');
      check(await storage.getAuthTokenStrict()).equals('token-a');
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

    group('with an account active only by its flag', () {
      // An install whose saved accounts mark the active one but whose active
      // id is missing: storage still treats A as active and its session as
      // live, though the stricter active id reads null.
      setUp(() async {
        final registry = OpenWebUiRegistry.empty.mergeServerConfigs([
          account('a').copyWith(isActive: true),
          account('b'),
        ]);
        await secure.write(
          key: 'openwebui_registry_v1',
          value: registry.encode(),
        );
        await storage.saveAuthToken('token-a');
      });

      test('a switch away files its session under it', () async {
        check(await storage.getActiveServerId()).isNull();
        check(await storage.getEffectiveActiveServerId()).equals('a');

        await storage.switchActiveServer(fromServerId: 'a', toServerId: 'b');

        check(await vaultedToken('a')).equals('token-a');
        check(await storage.getActiveServerId()).equals('b');
      });

      test('a switch from no account is refused', () async {
        await check(
          storage.switchActiveServer(fromServerId: null, toServerId: 'b'),
        ).throws<StateError>();

        check(await storage.getAuthTokenStrict()).equals('token-a');
      });

      test('switching to it keeps its session', () async {
        check(
          await storage.switchActiveServer(fromServerId: 'a', toServerId: 'a'),
        ).isTrue();

        check(await storage.getAuthTokenStrict()).equals('token-a');
      });
    });

    test('switching to the active account takes up a session left in its '
        'vault', () async {
      await storage.saveServerConfigs([account('a'), account('b')]);
      await signIn('a');
      // A switch that moved the active id and then failed before taking up
      // B's session: B is active with nothing live, its session vaulted.
      await secure.write(key: 'auth_token_server_v1:b', value: 'token-b');
      await storage.setActiveServerId('b');
      check(await storage.getAuthTokenStrict()).isNull();

      check(
        await storage.switchActiveServer(fromServerId: 'b', toServerId: 'b'),
      ).isTrue();

      check(await storage.getAuthTokenStrict()).equals('token-b');
      check(await vaultedToken('b')).isNull();
    });

    test('a switch whose target vault cannot be read changes nothing', () async {
      await storage.saveServerConfigs([
        account('a'),
        account('b'),
        account('c'),
      ]);
      await signIn('b');
      await storage.switchActiveServer(fromServerId: 'b', toServerId: 'a');
      await storage.saveAuthToken('token-a');
      secure.unreadableKey = 'auth_token_server_v1:b';

      await check(
        storage.switchActiveServer(fromServerId: 'a', toServerId: 'b'),
      ).throws<StateError>();
      secure.unreadableKey = null;

      check(await storage.getActiveServerId()).equals('a');
      check(await storage.getAuthTokenStrict()).equals('token-a');
      check(await vaultedToken('a')).isNull();
      // Switching on to another account files A's session, not B's.
      await storage.switchActiveServer(fromServerId: 'a', toServerId: 'c');
      check(await vaultedToken('b')).equals('token-b');
    });

    test('a saved sign-in naming the account switched to stays live', () async {
      await storage.saveServerConfigs([account('a'), account('b')]);
      await signIn('a');
      // From before accounts existed: B's sign-in, live while A is active.
      await storage.saveCredentials(
        serverId: 'b',
        username: 'user-b',
        password: 'pw-b',
      );

      check(
        await storage.switchActiveServer(fromServerId: 'a', toServerId: 'b'),
      ).isTrue();

      check((await storage.getSavedCredentialsStrict())?['password'])
          .equals('pw-b');
      check(await vaultedCredentials('b')).isNull();
      check(await vaultedToken('a')).equals('token-a');
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
        // Four checks pass before persistence starts; the fifth, right after
        // the old session was filed away, fails.
        canCommit: () => ++checks < 5,
        publish: () {},
      );

      check(committed).isFalse();
      check(checks).equals(5);
      check(await storage.getActiveServerId()).equals('a');
      check(await storage.getAuthTokenStrict()).equals('token-a');
      check(await vaultedToken('a')).isNull();
    });

    test('a failed commit puts back what the vault held before', () async {
      await storage.saveServerConfigs([
        account('a'),
        account('b'),
        account('c'),
      ]);
      // C signed in once and was left: its session sits in its vault.
      await signIn('c', password: 'pw-c-old');
      check(
        await storage.switchActiveServer(fromServerId: 'c', toServerId: 'a'),
      ).isFalse();
      await storage.saveAuthToken('token-a');
      // A saved sign-in from before accounts existed names C while A is
      // active, so a commit files it under C, over C's older copy.
      await storage.saveCredentials(
        serverId: 'c',
        username: 'user-c',
        password: 'pw-c-new',
      );
      final ownership = await storage.captureSavedServerSessionOwnership('b');
      var checks = 0;

      final committed = await storage.commitExistingServerSession(
        ownership: ownership!,
        token: 'token-b',
        canCommit: () => ++checks < 5,
        publish: () {},
      );

      check(committed).isFalse();
      // Not signed out by an attempt that never happened.
      check(await vaultedToken('c')).equals('token-c');
      check((await vaultedCredentials('c'))?['password']).equals('pw-c-old');
    });

    test(
      'a fresh sign-in that does not finish keeps the vaulted session',
      () async {
        await storage.saveServerConfigs([account('a'), account('b')]);
        await signIn('b', password: 'pw-b');
        check(
          await storage.switchActiveServer(fromServerId: 'b', toServerId: 'a'),
        ).isFalse();
        await storage.saveAuthToken('token-a');
        var checks = 0;

        // Signing in to B afresh sets aside B's vaulted session; the attempt is
        // then superseded before it publishes.
        final selected = await storage.selectUnauthenticatedServerConfig(
          account('b'),
          // Five checks pass before persistence starts and one after the old
          // session is filed away; the seventh, right after B's vaulted
          // session is set aside, fails.
          canCommit: () => ++checks < 7,
          publish: () {},
        );

        check(selected).isFalse();
        check(checks).equals(7);
        check(await storage.getActiveServerId()).equals('a');
        check(await storage.getAuthTokenStrict()).equals('token-a');
        check(await vaultedToken('b')).equals('token-b');
        check((await vaultedCredentials('b'))?['password']).equals('pw-b');
      },
    );
  });

  test('a server moved by another account\'s edit drops sessions kept aside',
      () async {
    // Three accounts on one server; c is signed in but not active.
    await storage.saveServerConfigs([account('a'), account('b'), account('c')]);
    await signIn('c', password: 'pw-c');
    check(
      await storage.switchActiveServer(fromServerId: 'c', toServerId: 'a'),
    ).isFalse();
    final configs = await storage.getServerConfigs();

    // An edit through b moves the shared endpoint.
    await storage.saveServerConfigs([
      for (final config in configs)
        config.id == 'b'
            ? config.copyWith(url: 'https://elsewhere.example.org')
            : config,
    ]);

    check(await vaultedToken('c')).isNull();
    check(await vaultedCredentials('c')).isNull();
  });

  group('a server moved by selecting an account on it', () {
    // A and B share one server; B is signed in, filed away.
    setUp(() async {
      await storage.saveServerConfigs([account('a'), account('b')]);
      await signIn('b', password: 'pw-b');
      await storage.switchActiveServer(fromServerId: 'b', toServerId: 'a');
      await storage.saveAuthToken('token-a');
    });

    final moved = account('a', url: 'https://moved.example.org');

    test('for a fresh sign-in drops the sessions kept aside on it', () async {
      await storage.selectUnauthenticatedServerConfig(moved, publish: () {});

      final b = (await storage.getServerConfigs())
          .where((config) => config.id == 'b')
          .single;
      check(b.url).equals('https://moved.example.org');
      check(await vaultedToken('b')).isNull();
      check(await vaultedCredentials('b')).isNull();
    });

    test('for a proxy sign-in drops the sessions kept aside on it', () async {
      final staged = await storage.stageServerConfigCandidate(moved);

      check(
        await storage.commitServerConfigCandidateSession(
          candidate: moved,
          transactionId: staged.transactionId,
          token: 'token-a-moved',
          canCommit: () => true,
          publish: () {},
        ),
      ).isTrue();

      check(await vaultedToken('b')).isNull();
      check(await vaultedCredentials('b')).isNull();
      check(await storage.getAuthTokenStrict()).equals('token-a-moved');
    });

    test('a sign-in that does not finish keeps them', () async {
      var checks = 0;
      await storage.selectUnauthenticatedServerConfig(
        moved,
        // Fails once the sessions on the moved server have gone.
        canCommit: () => ++checks < 8,
        publish: () {},
      );

      check(await vaultedToken('b')).equals('token-b');
      check((await vaultedCredentials('b'))?['password']).equals('pw-b');
      check(await storage.getAuthTokenStrict()).equals('token-a');
    });
  });

  test('an account in use that cannot be read is not reported as none', () async {
    await storage.saveServerConfigs([account('a')]);
    await signIn('a');
    storage.clearCache();
    secure.unreadableKey = 'openwebui_registry_v1';

    await check(storage.getEffectiveActiveServerId()).throws<StateError>();
  });

  test('signing out still clears cached user data when the account list '
      'cannot be read', () async {
    await storage.saveServerConfigs([account('a')]);
    await signIn('a');
    final caches = Hive.box<dynamic>(HiveBoxNames.caches);
    await caches.put(HiveStoreKeys.localUser, 'cached user a');
    // Served from the cache until it expires; the read below must fail.
    storage.clearCache();
    secure.unreadableKey = 'openwebui_registry_v1';

    await check(
      storage.clearActiveAccountAuthDataIf(canClear: () => true),
    ).throws<StateError>();

    check(await storage.getAuthTokenStrict()).isNull();
    check(caches.get(HiveStoreKeys.localUser)).isNull();
  });

  group('removing an account', () {
    test('removing an inactive one leaves the active one marked active', () async {
      await storage.saveServerConfigs([account('a'), account('b')]);
      await signIn('a');

      await storage.removeAccount('b');

      check(
        (await storage.getServerConfigs()).map(
          (config) => (config.id, config.isActive),
        ),
      ).deepEquals([('a', true)]);
    });

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

    test('removing an inactive one declines once it is active', () async {
      await storage.saveServerConfigs([
        account('a'),
        account('b'),
        account('c'),
      ]);
      await signIn('a');

      check(await storage.removeInactiveAccount('b')).isTrue();
      check(await storage.removeInactiveAccount('a')).isFalse();

      check(await storage.getAuthTokenStrict()).equals('token-a');
      check(await storage.getActiveServerId()).equals('a');
      check((await storage.getServerConfigs()).map((config) => config.id))
          .deepEquals(['a', 'c']);
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

      final merged = await storage.mergeActiveAccountInto(
        'existing',
        expectedSourceAccountId: 'new',
      );

      check(merged).isTrue();
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

      final merged = await storage.mergeActiveAccountInto(
        'existing',
        expectedSourceAccountId: 'new',
      );

      check(merged).isFalse();
      check((await storage.getServerConfigs()).map((config) => config.id))
          .deepEquals(['existing', 'new']);
      check(await storage.getAuthTokenStrict()).equals('token-existing');
    });

    test('a merge that fails part-way leaves both accounts as they were', () async {
      await storage.saveServerConfigs([account('existing'), account('new')]);
      await signIn('existing', password: 'pw-existing');
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
      secure.refusedKey = 'openwebui_registry_v1';

      await check(
        storage.mergeActiveAccountInto(
          'existing',
          expectedSourceAccountId: 'new',
        ),
      ).throws<StateError>();

      check(await storage.getActiveServerId()).equals('new');
      check((await storage.getSavedCredentialsStrict())?['serverId'])
          .equals('new');
      check(await vaultedToken('existing')).equals('token-existing');
      check((await vaultedCredentials('existing'))?['password'])
          .equals('pw-existing');
    });

    Future<void> signedInAsNewOverExisting() async {
      await storage.saveServerConfigs([account('existing'), account('new')]);
      await signIn('existing', password: 'pw-existing');
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
    }

    test(
      'a merge whose active-id write fails leaves both accounts as they were',
      () async {
        await signedInAsNewOverExisting();
        final prefs = InMemoryKeyValueStore();
        await prefs.setString(PreferenceKeys.activeServerId, 'new');
        var failed = false;
        // The first write of the active id fails after changing the value
        // read back, as SharedPreferences' cache does; later ones succeed.
        PreferencesStore.debugOverride(
          prefs,
          writeInterceptor: (preferences, key, value) async {
            if (key != PreferenceKeys.activeServerId || failed) return null;
            failed = true;
            await preferences.setString(key, value! as String);
            return false;
          },
        );

        await check(
          storage.mergeActiveAccountInto(
            'existing',
            expectedSourceAccountId: 'new',
          ),
        ).throws<StateError>();

        final registry = await storage.getOpenWebUiRegistryStrict();
        check(registry.accounts.map((account) => account.id))
            .deepEquals(['existing', 'new']);
        check(registry.account('new')?.isActive).equals(true);
        check(await storage.getActiveServerId()).equals('new');
        check(await storage.getAuthTokenStrict()).equals('fresh-token');
        check((await storage.getSavedCredentialsStrict())?['serverId'])
            .equals('new');
        check(await vaultedToken('existing')).equals('token-existing');
      },
    );

    test('a merge that cannot be undone ends the live session', () async {
      await signedInAsNewOverExisting();
      final prefs = InMemoryKeyValueStore();
      await prefs.setString(PreferenceKeys.activeServerId, 'new');
      PreferencesStore.debugOverride(
        prefs,
        writeInterceptor: (preferences, key, value) async {
          if (key != PreferenceKeys.activeServerId) return null;
          // Neither the active id nor, after it, the accounts can be written.
          secure.refusedKey = 'openwebui_registry_v1';
          return false;
        },
      );

      await check(
        storage.mergeActiveAccountInto(
          'existing',
          expectedSourceAccountId: 'new',
        ),
      ).throws<ServerConfigSessionRollbackException>();
      secure.refusedKey = null;

      check(await storage.getAuthTokenStrict()).isNull();
      check(await storage.getSavedCredentialsStrict()).isNull();
      check(await vaultedToken('existing')).equals('token-existing');
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

/// Refuses writes to [refusedKey], and reads of [unreadableKey], once set,
/// as a locked Keychain does.
final class _RefusingSecureStore extends InMemorySecureKeyValueStore {
  String? refusedKey;
  String? unreadableKey;

  @override
  Future<void> write({required String key, required String? value}) {
    if (key == refusedKey) throw StateError('keychain refused $key');
    return super.write(key: key, value: value);
  }

  @override
  Future<String?> read({required String key}) {
    if (key == unreadableKey) throw StateError('keychain locked');
    return super.read(key: key);
  }
}
