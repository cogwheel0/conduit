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

    test('a switch that fails taking up the saved sign-in keeps it filed',
        () async {
      await storage.saveServerConfigs([account('a'), account('b')]);
      await signIn('b', password: 'pw-b');
      await storage.switchActiveServer(fromServerId: 'b', toServerId: 'a');
      await storage.saveAuthToken('token-a');
      secure.refusedOnceKey = 'user_credentials_v2';

      await check(
        storage.switchActiveServer(fromServerId: 'a', toServerId: 'b'),
      ).throws<StateError>();

      // Chosen again, it takes up its session; leaving it files it again.
      check(
        await storage.switchActiveServer(fromServerId: 'b', toServerId: 'b'),
      ).isTrue();
      check(await storage.getAuthTokenStrict()).equals('token-b');
      check((await storage.getSavedCredentialsStrict())?['password'])
          .equals('pw-b');
      await storage.switchActiveServer(fromServerId: 'b', toServerId: 'a');
      check((await vaultedCredentials('b'))?['password']).equals('pw-b');
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

    test('lists a saved sign-in under the account it names', () async {
      await storage.saveServerConfigs([account('a'), account('c')]);
      await storage.setActiveServerId('a');
      // From before accounts existed: C's sign-in, live while A is active.
      await storage.saveCredentials(
        serverId: 'c',
        username: 'user-c',
        password: 'pw-c',
      );

      check(await storage.accountIdsWithSession()).deepEquals({'c'});
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

    // Before accounts existed, a saved sign-in could outlive a server change
    // and name another account while this one is active.
    test('signing in afresh to the active account files another account\'s '
        'saved sign-in under it', () async {
      await storage.saveServerConfigs([account('a'), account('b')]);
      await signIn('a');
      await storage.saveCredentials(
        serverId: 'b',
        username: 'user-b',
        password: 'pw-b',
      );

      final selected = await storage.selectUnauthenticatedServerConfig(
        account('a'),
        publish: () {},
      );

      check(selected).isTrue();
      check((await vaultedCredentials('b'))?['password']).equals('pw-b');
      check(await storage.getSavedCredentialsStrict()).isNull();
    });

    test('choosing the active account takes up its kept session when the '
        'saved sign-in is another account\'s', () async {
      await storage.saveServerConfigs([account('a'), account('b')]);
      await signIn('a');
      // A switch that failed part-way: A active, its session in its vault.
      await storage.switchActiveServer(fromServerId: 'a', toServerId: 'b');
      await storage.setActiveServerId('a');
      await storage.saveCredentials(
        serverId: 'b',
        username: 'user-b',
        password: 'pw-b',
      );
      check(await vaultedToken('a')).equals('token-a');

      check(
        await storage.switchActiveServer(fromServerId: 'a', toServerId: 'a'),
      ).isTrue();

      check(await storage.getAuthTokenStrict()).equals('token-a');
      check(await vaultedToken('a')).isNull();
      check((await vaultedCredentials('b'))?['password']).equals('pw-b');
    });

    // Chosen from a list read before another sign-out removed it.
    test('removing the active account for one since removed leaves none '
        'active', () async {
      await storage.saveServerConfigs([account('a'), account('b')]);
      await signIn('a');

      check(await storage.removeAccount('a', thenActivate: 'gone')).isFalse();

      check(await storage.getActiveServerId()).isNull();
      check(PreferencesStore.getString(PreferenceKeys.activeServerId))
          .not((it) => it.equals('gone'));
      check((await storage.getServerConfigs()).map((config) => config.id))
          .deepEquals(['b']);
    });

    // Revoking a kept session sends its token to the server it was kept
    // for; an edit moving that server drops the token instead.
    test('a kept session is read with the server it was kept for, never '
        'with where an edit moves it', () async {
      await storage.saveServerConfigs([account('a'), account('b')]);
      await signIn('b');
      await storage.switchActiveServer(fromServerId: 'b', toServerId: 'a');

      final read = storage.vaultedSessions(accountIds: {'b'});
      final moved = storage.saveServerConfigs([
        account('a', url: 'https://elsewhere.test'),
        account('b', url: 'https://elsewhere.test'),
      ]);
      final sessions = await read;
      await moved;

      check(sessions.map((session) => (session.config.url, session.token)))
          .deepEquals([('https://chat.example.com', 'token-b')]);
      check(await storage.vaultedSessions(accountIds: {'b'})).isEmpty();
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

    test('a failed commit puts back the vault through a write refused '
        'once', () async {
      await storage.saveServerConfigs([
        account('a'),
        account('b'),
        account('c'),
      ]);
      await signIn('c', password: 'pw-c-old');
      check(
        await storage.switchActiveServer(fromServerId: 'c', toServerId: 'a'),
      ).isFalse();
      await storage.saveAuthToken('token-a');
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
        canCommit: () {
          if (++checks < 5) return true;
          // The Keychain refuses the first write putting C's sign-in back.
          secure.refusedOnceKey = 'user_credentials_server_v1:c';
          return false;
        },
        publish: () {},
      );

      check(committed).isFalse();
      check(secure.refusedOnceKey).isNull();
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

  // A switch that failed part-way can leave the active account's own session
  // in the vault, where selecting the account again takes it up.
  test('moving the active account drops the session it has kept aside',
      () async {
    await storage.saveServerConfigs([account('a')]);
    await storage.setActiveServerId('a');
    await secure.write(key: 'auth_token_server_v1:a', value: 'stale-a');

    await storage.saveServerConfigs([
      account('a', url: 'https://elsewhere.example.org'),
    ]);

    check(await vaultedToken('a')).isNull();
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

  test('signing out files a saved sign-in naming another account under it',
      () async {
    await storage.saveServerConfigs([account('a'), account('c')]);
    await signIn('a');
    // From before accounts existed: C's sign-in, live while A is active.
    await storage.saveCredentials(
      serverId: 'c',
      username: 'user-c',
      password: 'pw-c',
    );

    check(
      await storage.clearActiveAccountAuthDataIf(canClear: () => true),
    ).isTrue();

    check((await vaultedCredentials('c'))?['password']).equals('pw-c');
    check(await storage.getSavedCredentialsStrict()).isNull();
    check(await storage.getAuthTokenStrict()).isNull();
  });

  test('signing out keeps a saved sign-in for another account it could not '
      'file', () async {
    await storage.saveServerConfigs([account('a'), account('c')]);
    await signIn('a');
    await storage.saveCredentials(
      serverId: 'c',
      username: 'user-c',
      password: 'pw-c',
    );
    secure.refusedKey = 'user_credentials_server_v1:c';

    await check(
      storage.clearActiveAccountAuthDataIf(canClear: () => true),
    ).throws<Object>();

    secure.refusedKey = null;
    // Still where it was, for the next commit to file.
    final live = await secure.read(key: 'user_credentials_v2');
    check((jsonDecode(live!) as Map)['serverId']).equals('c');
    check(await secure.read(key: 'auth_token_v2')).isNull();
  });

  group('removing an account', () {
    test('the active one files a saved sign-in naming another account under '
        'it', () async {
      await storage.saveServerConfigs([account('a'), account('c')]);
      await signIn('a');
      // From before accounts existed: C's sign-in, live while A is active.
      await storage.saveCredentials(
        serverId: 'c',
        username: 'user-c',
        password: 'pw-c',
      );

      await storage.removeAccount('a');

      check((await vaultedCredentials('c'))?['password']).equals('pw-c');
      check(await storage.getSavedCredentialsStrict()).isNull();
      check((await storage.getServerConfigs()).map((config) => config.id))
          .deepEquals(['c']);
    });

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

    test('the active one hands a saved sign-in naming the next account to it',
        () async {
      await storage.saveServerConfigs([account('a'), account('c')]);
      await signIn('c', password: 'pw-c-old');
      await storage.switchActiveServer(fromServerId: 'c', toServerId: 'a');
      await storage.saveAuthToken('token-a');
      // From before accounts existed: C's sign-in, live while A is active.
      await storage.saveCredentials(
        serverId: 'c',
        username: 'user-c',
        password: 'pw-c-new',
      );

      check(await storage.removeAccount('a', thenActivate: 'c')).isTrue();

      check(await storage.getAuthTokenStrict()).equals('token-c');
      check((await storage.getSavedCredentialsStrict())?['password'])
          .equals('pw-c-new');
      check(await vaultedCredentials('c')).isNull();
    });

    test('the active one stays when the next one\'s session cannot be read',
        () async {
      await storage.saveServerConfigs([account('a'), account('b')]);
      await signIn('b', password: 'pw-b');
      await storage.switchActiveServer(fromServerId: 'b', toServerId: 'a');
      await storage.saveAuthToken('token-a');
      secure.unreadableKey = 'auth_token_server_v1:b';

      await check(
        storage.removeAccount('a', thenActivate: 'b'),
      ).throws<StateError>();

      secure.unreadableKey = null;
      check(await storage.getActiveServerId()).equals('a');
      check(await storage.getAuthTokenStrict()).equals('token-a');
      check(await vaultedToken('b')).equals('token-b');
      check((await storage.getServerConfigs()).map((config) => config.id))
          .deepEquals(['a', 'b']);
    });

    test('the active one is left as it was when handing over fails', () async {
      await storage.saveServerConfigs([
        account('a'),
        account('b'),
        account('c'),
      ]);
      await signIn('b');
      await storage.switchActiveServer(fromServerId: 'b', toServerId: 'c');
      await storage.saveAuthToken('token-c');
      await storage.saveCredentials(
        serverId: 'c',
        username: 'user-c',
        password: 'pw-c-old',
      );
      await storage.switchActiveServer(fromServerId: 'c', toServerId: 'a');
      await storage.saveAuthToken('token-a');
      // From before accounts existed: C's newer sign-in, live while A is.
      await storage.saveCredentials(
        serverId: 'c',
        username: 'user-c',
        password: 'pw-c-new',
      );
      // B's token is refused as it is taken up, after everything else.
      secure.refusedOnceKey = 'auth_token_v2';

      await check(
        storage.removeAccount('a', thenActivate: 'b'),
      ).throws<StateError>();

      check(await storage.getActiveServerId()).equals('a');
      check((await storage.getServerConfigs()).map((config) => config.id))
          .deepEquals(['a', 'b', 'c']);
      check(await storage.getAuthTokenStrict()).equals('token-a');
      check((await storage.getSavedCredentialsStrict())?['password'])
          .equals('pw-c-new');
      check((await vaultedCredentials('c'))?['password']).equals('pw-c-old');
      check(await vaultedToken('b')).equals('token-b');
    });

    test('an inactive one takes its sign-in from the live slots', () async {
      await storage.saveServerConfigs([account('a'), account('b')]);
      await signIn('a');
      // From before accounts existed: B's sign-in, live while A is active.
      await storage.saveCredentials(
        serverId: 'b',
        username: 'user-b',
        password: 'pw-b',
      );

      check(await storage.removeInactiveAccount('b')).isTrue();

      check(await storage.getSavedCredentialsStrict()).isNull();
      check(await storage.getAuthTokenStrict()).equals('token-a');
      check(await storage.getActiveServerId()).equals('a');
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

  group('leaving an added account before it signs in', () {
    // B is signed in; A is added from it, and A's sign-in has not finished.
    Future<void> addPendingFromSignedIn() async {
      await storage.saveServerConfigs([account('a'), account('b')]);
      await signIn('b', password: 'pw-b');
      await storage.switchActiveServer(fromServerId: 'b', toServerId: 'a');
    }

    Future<void> checkKept() async {
      check(await storage.getActiveServerId()).equals('a');
      check((await storage.getServerConfigs()).map((config) => config.id))
          .deepEquals(['a', 'b']);
      check(await vaultedToken('b')).equals('token-b');
    }

    test('removes it and hands over to the next account', () async {
      await addPendingFromSignedIn();

      check(await storage.removePendingAccount('a', thenActivate: 'b'))
          .equals(true);

      check(await storage.getActiveServerId()).equals('b');
      check(await storage.getAuthTokenStrict()).equals('token-b');
      check((await storage.getSavedCredentialsStrict())?['password'])
          .equals('pw-b');
      check(await vaultedToken('b')).isNull();
      check((await storage.getServerConfigs()).map((config) => config.id))
          .deepEquals(['b']);
    });

    test('stays when the next account\'s session cannot be read', () async {
      await addPendingFromSignedIn();
      secure.unreadableKey = 'auth_token_server_v1:b';

      // Gone first, it could not be cancelled again to try once more.
      await check(
        storage.removePendingAccount('a', thenActivate: 'b'),
      ).throws<StateError>();

      secure.unreadableKey = null;
      await checkKept();
      check(await storage.removePendingAccount('a', thenActivate: 'b'))
          .equals(true);
      check(await storage.getAuthTokenStrict()).equals('token-b');
    });

    test('is not held up by a saved sign-in for another account', () async {
      await storage.saveServerConfigs([
        account('a'),
        account('b'),
        account('c'),
      ]);
      await signIn('b', password: 'pw-b');
      await storage.switchActiveServer(fromServerId: 'b', toServerId: 'a');
      // From before accounts existed: C's sign-in, live while A is active.
      await storage.saveCredentials(
        serverId: 'c',
        username: 'user-c',
        password: 'pw-c',
      );

      check(await storage.removePendingAccount('a', thenActivate: 'b'))
          .equals(true);

      check(await storage.getActiveServerId()).equals('b');
      check((await vaultedCredentials('c'))?['password']).equals('pw-c');
    });

    test('is refused when it would hand over to itself', () async {
      await addPendingFromSignedIn();

      check(await storage.removePendingAccount('a', thenActivate: 'a'))
          .isNull();

      await checkKept();
    });

    test('is refused once the account to hand over to is gone', () async {
      await addPendingFromSignedIn();
      await storage.removeInactiveAccount('b');

      check(await storage.removePendingAccount('a', thenActivate: 'b'))
          .isNull();

      check(await storage.getActiveServerId()).equals('a');
      check((await storage.getServerConfigs()).map((config) => config.id))
          .deepEquals(['a']);
    });

    test('is refused once a sign-in has reached it', () async {
      await addPendingFromSignedIn();
      await storage.saveAuthToken('token-a');

      check(await storage.removePendingAccount('a', thenActivate: 'b'))
          .isNull();

      await checkKept();
      check(await storage.getAuthTokenStrict()).equals('token-a');
    });

    test('is refused once a saved sign-in has reached it', () async {
      await addPendingFromSignedIn();
      await storage.saveCredentials(
        serverId: 'a',
        username: 'user-a',
        password: 'pw-a',
      );

      check(await storage.removePendingAccount('a', thenActivate: 'b'))
          .isNull();

      await checkKept();
      check((await storage.getSavedCredentialsStrict())?['password'])
          .equals('pw-a');
    });

    // As a switch that failed part-way leaves it: active, its session still
    // in its vault.
    test('is refused while a session of its own is in its vault', () async {
      await addPendingFromSignedIn();
      await secure.write(key: 'auth_token_server_v1:a', value: 'token-a');

      check(await storage.removePendingAccount('a', thenActivate: 'b'))
          .isNull();

      await checkKept();
      check(await vaultedToken('a')).equals('token-a');
    });

    test('is refused once its user is known', () async {
      await addPendingFromSignedIn();
      await storage.bindAccountUser('a', 'user-a');

      check(await storage.removePendingAccount('a', thenActivate: 'b'))
          .isNull();

      await checkKept();
    });

    test('is refused once it is no longer the active account', () async {
      await storage.saveServerConfigs([
        account('a'),
        account('b'),
        account('c'),
      ]);
      await signIn('b', password: 'pw-b');
      await storage.switchActiveServer(fromServerId: 'b', toServerId: 'a');
      // Switched away meanwhile, to an account with no session either.
      await storage.switchActiveServer(fromServerId: 'a', toServerId: 'c');

      check(await storage.removePendingAccount('a', thenActivate: 'b'))
          .isNull();

      check(await storage.getActiveServerId()).equals('c');
      check((await storage.getServerConfigs()).map((config) => config.id))
          .deepEquals(['a', 'b', 'c']);
      check(await vaultedToken('b')).equals('token-b');
    });
  });

  group('an account active as storage counts it', () {
    test('has its id kept once certified', () async {
      await storage.saveServerConfigs([account('a')]);
      await PreferencesStore.remove(PreferenceKeys.activeServerId);

      await storage.recordEffectiveActiveAccount('a');

      check(PreferencesStore.getString(PreferenceKeys.activeServerId))
          .equals('a');
    });

    test('leaves another account kept as active alone', () async {
      await storage.saveServerConfigs([account('a'), account('b')]);
      await storage.setActiveServerId('b');

      await storage.recordEffectiveActiveAccount('a');

      check(PreferencesStore.getString(PreferenceKeys.activeServerId))
          .equals('b');
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

    test('does nothing when a newer session has committed since', () async {
      await storage.saveServerConfigs([account('existing'), account('new')]);
      await signIn('existing');
      await storage.switchActiveServer(
        fromServerId: 'existing',
        toServerId: 'new',
      );
      await storage.saveAuthToken('newer-token');

      final merged = await storage.mergeActiveAccountInto(
        'existing',
        expectedSourceAccountId: 'new',
        expectedToken: 'checked-token',
      );

      check(merged).isFalse();
      check((await storage.getServerConfigs()).map((config) => config.id))
          .deepEquals(['existing', 'new']);
      check(await storage.getAuthTokenStrict()).equals('newer-token');
    });

    test('fails rather than declines when the token cannot be read', () async {
      await storage.saveServerConfigs([account('existing'), account('new')]);
      await signIn('existing');
      await storage.switchActiveServer(
        fromServerId: 'existing',
        toServerId: 'new',
      );
      await storage.saveAuthToken('checked-token');
      storage.clearCache();
      secure.unreadableKey = 'auth_token_v2';

      await check(
        storage.mergeActiveAccountInto(
          'existing',
          expectedSourceAccountId: 'new',
          expectedToken: 'checked-token',
        ),
      ).throws<StateError>();

      secure.unreadableKey = null;
      check((await storage.getServerConfigs()).map((config) => config.id))
          .deepEquals(['existing', 'new']);
      check(await storage.getActiveServerId()).equals('new');
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

    // A switch that failed part-way can leave the source's own session in
    // its vault too.
    test('a merge leaves nothing kept under the account it removes', () async {
      await signedInAsNewOverExisting();
      await secure.write(key: 'auth_token_server_v1:new', value: 'stale-new');

      check(
        await storage.mergeActiveAccountInto(
          'existing',
          expectedSourceAccountId: 'new',
        ),
      ).isTrue();

      check(await vaultedToken('new')).isNull();
      check(await storage.getAuthTokenStrict()).equals('fresh-token');
    });

    test('a merge that fails part-way keeps what was kept under the source',
        () async {
      await signedInAsNewOverExisting();
      await secure.write(key: 'auth_token_server_v1:new', value: 'stale-new');
      secure.refusedKey = 'openwebui_registry_v1';

      await check(
        storage.mergeActiveAccountInto(
          'existing',
          expectedSourceAccountId: 'new',
        ),
      ).throws<StateError>();

      check(await vaultedToken('new')).equals('stale-new');
    });

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

    // Left naming the target while the source is active, the saved sign-in
    // would be filed under the target the next time the session moves.
    test('a merge whose saved sign-in cannot be put back ends the live '
        'session', () async {
      await signedInAsNewOverExisting();
      var accountsRefused = false;
      secure.beforeWrite = (key) {
        if (key == 'openwebui_registry_v1') {
          accountsRefused = true;
          throw StateError('keychain refused $key');
        }
        // Nor, after that, can the sign-in be put back.
        if (accountsRefused && key == 'user_credentials_v2') {
          throw StateError('keychain refused $key');
        }
      };

      await check(
        storage.mergeActiveAccountInto(
          'existing',
          expectedSourceAccountId: 'new',
        ),
      ).throws<ServerConfigSessionRollbackException>();
      secure.beforeWrite = null;

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

  // A failed wipe leaves writes building on what it meant to leave, until
  // one lands; from then on, on what was written.
  test('after a failed wipe, a write builds on the last one written', () async {
    await storage.saveServerConfigs([account('a')]);
    secure.refusesDeleteAll = true;
    await check(storage.clearAll()).throws<StateError>();
    secure.refusesDeleteAll = false;

    await storage.saveServerConfigs([account('a')]);
    await storage.bindAccountUser('a', 'user-1');
    await storage.saveServerConfigs([account('a')]);

    final stored = OpenWebUiRegistry.decode(
      (await secure.read(key: 'openwebui_registry_v1'))!,
    );
    check(stored.account('a')?.userId).equals('user-1');
  });

  group('routes to a server', () {
    Future<OpenWebUiServer> addRoute(String id, String url) async {
      final server =
          (await storage.getOpenWebUiRegistryStrict()).servers.single;
      final next = OpenWebUiServer(
        id: server.id,
        name: server.name,
        endpoints: [
          ...server.endpoints,
          OpenWebUiEndpoint(id: id, url: url),
        ],
      );
      await storage.saveServer(next);
      return next;
    }

    test('adding and reordering routes keeps every session', () async {
      await storage.saveServerConfigs([account('a'), account('b')]);
      await signIn('b');
      await storage.switchActiveServer(fromServerId: 'b', toServerId: 'a');
      await storage.saveAuthToken('token-a');

      final server = await addRoute('lan', 'http://10.0.0.2:3000');
      await storage.saveServer(
        OpenWebUiServer(
          id: server.id,
          name: server.name,
          endpoints: server.endpoints.reversed.toList(),
        ),
      );

      check(await storage.getAuthTokenStrict()).equals('token-a');
      check(await vaultedToken('b')).equals('token-b');
      check((await storage.getServerConfigs()).first.url)
          .equals('http://10.0.0.2:3000');
    });

    test('a sign-in validated on one route cannot commit on another', () async {
      await storage.saveServerConfigs([account('a')]);
      await storage.setActiveServerId('a');
      final server = await addRoute('lan', 'http://10.0.0.2:3000');
      final ownership = await storage.captureServerSessionOwnership(
        validatedConfig: (await storage.getServerConfigs()).single,
        requireActive: true,
      );

      check(await storage.selectEndpoint(server.id, 'lan')).isTrue();

      check(
        await storage.commitExistingServerSession(
          ownership: ownership!,
          token: 'token-a',
          canCommit: () => true,
          publish: () {},
        ),
      ).isFalse();
      check((await storage.getServerConfigs()).single.url)
          .equals('http://10.0.0.2:3000');
    });

    test('a captured proxy cookie travels only on its own route', () async {
      await storage.saveServerConfigs([account('a')]);
      final server = await addRoute('proxy', 'https://proxy.example.com');

      await storage.saveEndpointSessionHeaders(
        accountId: 'a',
        endpointId: 'proxy',
        headers: const {'Cookie': 'authelia=1', 'X-Other': 'dropped'},
      );

      check((await storage.getServerConfigs()).single.customHeaders).isEmpty();
      await storage.selectEndpoint(server.id, 'proxy');
      check((await storage.getServerConfigs()).single.customHeaders)
          .deepEquals({'Cookie': 'authelia=1'});
    });

    test('removing the route in use falls back to the first', () async {
      await storage.saveServerConfigs([account('a')]);
      final server = await addRoute('lan', 'http://10.0.0.2:3000');
      await storage.selectEndpoint(server.id, 'lan');

      await storage.saveServer(
        OpenWebUiServer(
          id: server.id,
          name: server.name,
          endpoints: [server.endpoints.first],
        ),
      );

      check((await storage.getServerConfigs()).single.url)
          .equals('https://chat.example.com');
      check(storage.endpointSelection).isEmpty();
    });
  });
}

/// Refuses writes to [refusedKey], and reads of [unreadableKey], once set,
/// as a locked Keychain does; [refusedOnceKey] refuses its next write only.
final class _RefusingSecureStore extends InMemorySecureKeyValueStore {
  String? refusedKey;
  String? refusedOnceKey;
  String? unreadableKey;
  bool refusesDeleteAll = false;

  /// Runs before each write, and refuses it by throwing.
  void Function(String key)? beforeWrite;

  @override
  Future<void> deleteAll() {
    if (refusesDeleteAll) throw StateError('keychain refused to clear');
    return super.deleteAll();
  }

  @override
  Future<void> write({required String key, required String? value}) {
    beforeWrite?.call(key);
    if (key == refusedKey) throw StateError('keychain refused $key');
    if (key == refusedOnceKey) {
      refusedOnceKey = null;
      throw StateError('keychain refused $key');
    }
    return super.write(key: key, value: value);
  }

  @override
  Future<String?> read({required String key}) {
    if (key == unreadableKey) throw StateError('keychain locked');
    return super.read(key: key);
  }
}
