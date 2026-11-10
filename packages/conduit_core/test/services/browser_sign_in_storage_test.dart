import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/auth_types.dart';
import 'package:conduit_core/models/browser_sign_in_config.dart';
import 'package:conduit_core/models/browser_sign_in_session.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:hive_ce/hive.dart';
import 'package:test/test.dart';

/// The browser sign-in settings each server keeps, and the identity
/// provider session each account signed in through the browser keeps.
///
/// What must hold across every operation: an account keeps its session only
/// while its saved sign-in -- live or in its vault -- is a browser sign-in,
/// and a rolled-back operation puts the session back as it was.
void main() {
  late Directory tempDir;
  late _RefusingSecureStore secure;
  late OptimizedStorageService storage;
  late WorkerManager workerManager;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('browser-sign-in-test');
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

  const settings = BrowserSignInConfig(provider: 'oidc', clientId: 'conduit');

  ServerConfig account(String id, {String url = 'https://chat.example.com'}) =>
      ServerConfig(id: id, name: 'Chat', url: url);

  Future<String> serverOf(String accountId) async =>
      (await storage.getOpenWebUiRegistryStrict()).account(accountId)!.serverId;

  Future<BrowserSignInSession> sessionFor(
    String accountId, {
    String refreshToken = 'refresh',
    BrowserSignInConfig config = settings,
  }) async => BrowserSignInSession(
    serverId: await serverOf(accountId),
    provider: config.provider,
    clientId: config.clientId,
    issuer: 'https://id.example.com',
    tokenEndpoint: 'https://id.example.com/token',
    refreshToken: '$refreshToken-$accountId',
    owuiUserId: 'user-$accountId',
  );

  Map<String, String> browserSignIn(String accountId) => {
    'serverId': accountId,
    'username': 'jwt_user',
    'password': 'jwt-$accountId',
    'authType': AuthTypes.ssoBrowser,
  };

  Future<BrowserSignInSession?> storedSession(String accountId) async =>
      BrowserSignInSession.tryDecode(
        await secure.read(key: 'browser_sign_in_session_v1:$accountId'),
      );

  /// What [action] told of as dropped, once its notice was delivered.
  Future<List<StoredBrowserSignInSession>> droppedBy(
    Future<void> Function() action,
  ) async {
    final dropped = <StoredBrowserSignInSession>[];
    final subscription = storage.droppedBrowserSessions.listen(dropped.addAll);
    try {
      await action();
      await Future<void>.delayed(Duration.zero);
    } finally {
      await subscription.cancel();
    }
    return dropped;
  }

  Future<Map<String, dynamic>?> vaultedCredentials(String id) async {
    final raw = await secure.read(key: 'user_credentials_server_v1:$id');
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Signs [accountId] in through the browser, as a browser sign-in commits.
  Future<BrowserSignInSession> signInWithBrowser(String accountId) async {
    final session = await sessionFor(accountId);
    final ownership = await storage.captureSavedServerSessionOwnership(
      accountId,
    );
    check(
      await storage.commitExistingServerSession(
        ownership: ownership!,
        token: 'token-$accountId',
        canCommit: () => true,
        publish: () {},
        rememberedCredentials: browserSignIn(accountId),
        browserSession: BrowserSessionCommit.replace(session),
      ),
    ).isTrue();
    return session;
  }

  /// [ids] saved on one server set up for browser sign-in.
  Future<void> saveAccounts(List<String> ids) async {
    await storage.saveServerConfigs([for (final id in ids) account(id)]);
    await storage.setServerBrowserSignIn(await serverOf(ids.first), settings);
  }

  group('settings', () {
    test('are shared by every account on the server', () async {
      await storage.saveServerConfigs([
        account('a'),
        account('b'),
        account('c', url: 'https://other.example.com'),
      ]);

      await storage.setServerBrowserSignIn(await serverOf('a'), settings);

      check(await storage.browserSignInConfigForAccount('a')).equals(settings);
      check(await storage.browserSignInConfigForAccount('b')).equals(settings);
      check(await storage.browserSignInConfigForAccount('c')).isNull();
      check(await storage.browserSignInConfigForAccount('gone')).isNull();
    });

    test('changed, end the sessions issued under the old ones', () async {
      await saveAccounts(['a', 'b']);
      await storage.saveServerConfigs([
        account('a'),
        account('b'),
        account('c', url: 'https://other.example.com'),
      ]);
      await storage.setServerBrowserSignIn(await serverOf('c'), settings);
      final sessionA = await signInWithBrowser('a');
      final sessionB = await signInWithBrowser('b');
      final sessionC = await signInWithBrowser('c');

      final ended = await storage.setServerBrowserSignIn(
        await serverOf('a'),
        const BrowserSignInConfig(provider: 'oidc', clientId: 'another'),
      );

      check(ended).unorderedEquals([
        (accountId: 'a', session: sessionA),
        (accountId: 'b', session: sessionB),
      ]);
      check(await storedSession('a')).isNull();
      check(await storedSession('b')).isNull();
      check(await storedSession('c')).equals(sessionC);
      check(await storage.browserSignInConfigForAccount('a')).equals(
        const BrowserSignInConfig(provider: 'oidc', clientId: 'another'),
      );
    });

    test('changed, are saved even when a session cannot be ended, which '
        'the sweep takes later', () async {
      await saveAccounts(['a', 'b']);
      final sessionA = await signInWithBrowser('a');
      final sessionB = await signInWithBrowser('b');
      secure.undeletableKey = 'browser_sign_in_session_v1:b';
      const another = BrowserSignInConfig(provider: 'oidc', clientId: 'x');

      final ended = await storage.setServerBrowserSignIn(
        await serverOf('a'),
        another,
      );

      // What it ended, it says, so it is revoked.
      check(ended).deepEquals([(accountId: 'a', session: sessionA)]);
      check(await storage.browserSignInConfigForAccount('b')).equals(another);
      check(await storedSession('b')).equals(sessionB);

      secure.undeletableKey = null;
      check(
        await storage.sweepOrphanBrowserSignInSessions(),
      ).deepEquals([(accountId: 'b', session: sessionB)]);
      check(await storedSession('b')).isNull();
    });

    test('removed, end the sessions too', () async {
      await saveAccounts(['a']);
      final session = await signInWithBrowser('a');

      final ended = await storage.setServerBrowserSignIn(
        await serverOf('a'),
        null,
      );

      check(ended).deepEquals([(accountId: 'a', session: session)]);
      check(await storedSession('a')).isNull();
      check(await storage.browserSignInConfigForAccount('a')).isNull();
    });

    test('saved again unchanged, end nothing', () async {
      await saveAccounts(['a']);
      final session = await signInWithBrowser('a');

      check(await storage.setServerBrowserSignIn(await serverOf('a'), settings))
          .isEmpty();
      check(await storedSession('a')).equals(session);
    });

    test('saved again as the issuer the sessions came from, end nothing', () async {
      await saveAccounts(['a']);
      final session = await signInWithBrowser('a');
      const typed = BrowserSignInConfig(
        provider: 'oidc',
        clientId: 'conduit',
        issuer: 'https://ID.example.com:443/.well-known/openid-configuration',
      );

      check(
        await storage.setServerBrowserSignIn(await serverOf('a'), typed),
      ).isEmpty();

      check(await storedSession('a')).equals(session);
      check(await storage.browserSignInConfigForAccount('a')).equals(typed);
    });

    test('do not change who is signed in', () async {
      await storage.saveServerConfigs([account('a')]);
      final ownership = await storage.captureSavedServerSessionOwnership('a');

      await storage.setServerBrowserSignIn(await serverOf('a'), settings);

      check(
        await storage.commitExistingServerSession(
          ownership: ownership!,
          token: 'token-a',
          canCommit: () => true,
          publish: () {},
        ),
      ).isTrue();
    });

    test('are refused for a server no longer saved', () async {
      await check(storage.setServerBrowserSignIn('server:gone', settings))
          .throws<StateError>();
    });

    test('stay through edits of the server\'s routes', () async {
      await saveAccounts(['a']);
      final serverId = await serverOf('a');

      await storage.editServerEndpoints(
        serverId,
        (endpoints) => [
          ...endpoints,
          OpenWebUiEndpoint(id: 'lan', url: 'http://10.0.0.2:3000'),
        ],
      );
      final server = (await storage.getOpenWebUiRegistryStrict()).server(
        serverId,
      )!;
      // A server saved without them, as a caller that knows only its name
      // and routes saves it.
      await storage.saveServer(
        OpenWebUiServer(
          id: server.id,
          name: 'Renamed',
          endpoints: server.endpoints.reversed.toList(),
        ),
      );
      final saved = (await storage.getOpenWebUiRegistryStrict()).server(
        serverId,
      )!;
      check(saved.name).equals('Renamed');
      check(saved.endpoints).length.equals(2);
      check(saved.browserSignIn).equals(settings);

      await storage.saveServerConfigs([
        account('a', url: 'https://moved.test'),
      ]);
      check(await storage.browserSignInConfigForAccount('a')).equals(settings);
    });

    test('stay through a sign-out that keeps server details, which ends '
        'every session', () async {
      await saveAccounts(['a']);
      await signInWithBrowser('a');

      check(
        await storage.clearAllIf(
          canClear: () => true,
          preserveServerDetails: true,
        ),
      ).isTrue();

      final registry = await storage.getOpenWebUiRegistryStrict();
      check(registry.servers.single.browserSignIn).equals(settings);
      check(await storedSession('a')).isNull();
    });
  });

  group('a session commit', () {
    test('keeps the session a browser sign-in issued', () async {
      await saveAccounts(['a']);

      final session = await signInWithBrowser('a');

      check(await storage.browserSignInSessionFor('a')).equals(session);
      check((await storage.getSavedCredentialsStrict())?['authType'])
          .equals(AuthTypes.ssoBrowser);
    });

    test('of any other sign-in ends it', () async {
      await saveAccounts(['a']);
      await signInWithBrowser('a');
      final ownership = await storage.captureSavedServerSessionOwnership('a');

      await storage.commitExistingServerSession(
        ownership: ownership!,
        token: 'password-token',
        canCommit: () => true,
        publish: () {},
        rememberedCredentials: {
          'serverId': 'a',
          'username': 'me@example.com',
          'password': 'pw',
        },
      );

      check(await storedSession('a')).isNull();
    });

    test('that forgets the saved sign-in ends it', () async {
      await saveAccounts(['a']);
      await signInWithBrowser('a');
      final ownership = await storage.captureSavedServerSessionOwnership('a');

      await storage.commitExistingServerSession(
        ownership: ownership!,
        token: 'typed-token',
        canCommit: () => true,
        publish: () {},
      );

      check(await storedSession('a')).isNull();
    });

    test('that keeps the saved sign-in keeps it', () async {
      await saveAccounts(['a']);
      final session = await signInWithBrowser('a');
      final ownership = await storage.captureSavedServerSessionOwnership('a');

      await storage.commitExistingServerSession(
        ownership: ownership!,
        token: 'validated-token',
        canCommit: () => true,
        publish: () {},
        expectedSavedCredentials: browserSignIn('a'),
      );

      check(await storedSession('a')).equals(session);
    });

    test('of a renewal keeps the rotated session saved before it', () async {
      await saveAccounts(['a']);
      final session = await signInWithBrowser('a');
      final rotated = session.copyWith(refreshToken: 'rotated');
      check(
        await storage.replaceBrowserSignInSessionIfCurrent(
          'a',
          expected: session,
          next: rotated,
        ),
      ).isTrue();
      final ownership = await storage.captureSavedServerSessionOwnership('a');

      await storage.commitExistingServerSession(
        ownership: ownership!,
        token: 'renewed-token',
        canCommit: () => true,
        publish: () {},
        rememberedCredentials: {
          ...browserSignIn('a'),
          'password': 'renewed-jwt',
        },
        browserSession: BrowserSessionCommit.keep,
      );

      check(await storedSession('a')).equals(rotated);
      check((await storage.getSavedCredentialsStrict())?['password'])
          .equals('renewed-jwt');
    });

    test('refuses a session without a saved browser sign-in', () async {
      await saveAccounts(['a']);
      final session = await sessionFor('a');

      for (final (remembered, expected, mode) in [
        (
          {'serverId': 'a', 'username': 'me', 'password': 'pw'},
          null,
          BrowserSessionCommit.replace(session),
        ),
        (null, null, BrowserSessionCommit.replace(session)),
        (null, null, BrowserSessionCommit.keep),
        (
          {'serverId': 'a', 'username': 'me', 'password': 'pw'},
          null,
          BrowserSessionCommit.keep,
        ),
      ]) {
        final ownership = await storage.captureSavedServerSessionOwnership('a');
        await check(
          storage.commitExistingServerSession(
            ownership: ownership!,
            token: 'token',
            canCommit: () => true,
            publish: () {},
            rememberedCredentials: remembered,
            expectedSavedCredentials: expected,
            browserSession: mode,
          ),
        ).throws<ArgumentError>();
      }
      check(await storage.getAuthTokenStrict()).isNull();
    });

    test('drops a session issued under other settings', () async {
      await saveAccounts(['a']);
      final stale = await sessionFor(
        'a',
        config: const BrowserSignInConfig(provider: 'oidc', clientId: 'old'),
      );
      final ownership = await storage.captureSavedServerSessionOwnership('a');

      check(
        await storage.commitExistingServerSession(
          ownership: ownership!,
          token: 'token-a',
          canCommit: () => true,
          publish: () {},
          rememberedCredentials: browserSignIn('a'),
          browserSession: BrowserSessionCommit.replace(stale),
        ),
      ).isTrue();

      check(await storedSession('a')).isNull();
      check(await storage.getAuthTokenStrict()).equals('token-a');
      // Without its session the sign-in cannot renew, and must not say so.
      check((await storage.getSavedCredentialsStrict())?['authType'])
          .equals(AuthTypes.sso);
    });

    test('that fails puts the session back as it was', () async {
      await saveAccounts(['a']);
      final session = await signInWithBrowser('a');
      final ownership = await storage.captureSavedServerSessionOwnership('a');
      final replacement = await sessionFor('a', refreshToken: 'newer');

      final committed = await storage
          .commitExistingServerSession(
            ownership: ownership!,
            token: 'token-newer',
            canCommit: () => true,
            publish: () => throw StateError('publication failed'),
            rememberedCredentials: browserSignIn('a'),
            browserSession: BrowserSessionCommit.replace(replacement),
          )
          .then((_) => true, onError: (Object _) => false);

      check(committed).isFalse();
      check(await storedSession('a')).equals(session);
      check(await storage.getAuthTokenStrict()).equals('token-a');
    });

    test('that fails takes back a session it wrote', () async {
      await saveAccounts(['a']);
      final ownership = await storage.captureSavedServerSessionOwnership('a');
      final session = await sessionFor('a');

      await check(
        storage.commitExistingServerSession(
          ownership: ownership!,
          token: 'token-a',
          canCommit: () => true,
          publish: () => throw StateError('publication failed'),
          rememberedCredentials: browserSignIn('a'),
          browserSession: BrowserSessionCommit.replace(session),
        ),
      ).throws<StateError>();

      check(await storedSession('a')).isNull();
    });

    test('of another account leaves this one\'s session', () async {
      await saveAccounts(['a', 'b']);
      final sessionA = await signInWithBrowser('a');

      final sessionB = await signInWithBrowser('b');

      check(await storedSession('a')).equals(sessionA);
      check(await storedSession('b')).equals(sessionB);
      check((await vaultedCredentials('a'))?['authType'])
          .equals(AuthTypes.ssoBrowser);
    });
  });

  group('a session dropped outside a sign-out is told of', () {
    test('when another sign-in replaces it', () async {
      await saveAccounts(['a']);
      final session = await signInWithBrowser('a');
      final ownership = await storage.captureSavedServerSessionOwnership('a');

      final dropped = await droppedBy(
        () => storage.commitExistingServerSession(
          ownership: ownership!,
          token: 'password-token',
          canCommit: () => true,
          publish: () {},
          rememberedCredentials: {
            'serverId': 'a',
            'username': 'me@example.com',
            'password': 'pw',
          },
        ),
      );

      check(dropped).deepEquals([(accountId: 'a', session: session)]);
    });

    test('when a new browser sign-in replaces it, but not when renewed in '
        'place', () async {
      await saveAccounts(['a']);
      final first = await signInWithBrowser('a');

      final replaced = await droppedBy(() async {
        final ownership = await storage.captureSavedServerSessionOwnership(
          'a',
        );
        await storage.commitExistingServerSession(
          ownership: ownership!,
          token: 'token-newer',
          canCommit: () => true,
          publish: () {},
          rememberedCredentials: browserSignIn('a'),
          browserSession: BrowserSessionCommit.replace(
            await sessionFor('a', refreshToken: 'newer'),
          ),
        );
      });
      final again = await droppedBy(() async {
        final ownership = await storage.captureSavedServerSessionOwnership(
          'a',
        );
        await storage.commitExistingServerSession(
          ownership: ownership!,
          token: 'token-again',
          canCommit: () => true,
          publish: () {},
          rememberedCredentials: browserSignIn('a'),
          browserSession: BrowserSessionCommit.replace(
            await sessionFor('a', refreshToken: 'newer'),
          ),
        );
      });

      check(replaced).deepEquals([(accountId: 'a', session: first)]);
      check(again).isEmpty();
    });

    test('never for a commit that is rolled back', () async {
      await saveAccounts(['a']);
      await signInWithBrowser('a');
      final ownership = await storage.captureSavedServerSessionOwnership('a');

      final dropped = await droppedBy(
        () => storage
            .commitExistingServerSession(
              ownership: ownership!,
              token: 'password-token',
              canCommit: () => true,
              publish: () => throw StateError('publication failed'),
            )
            .then((_) {}, onError: (Object _) {}),
      );

      check(dropped).isEmpty();
    });

    test('when a rollback that cannot finish ends the live sign-in', () async {
      await saveAccounts(['a']);
      final session = await signInWithBrowser('a');
      final ownership = await storage.captureSavedServerSessionOwnership('a');
      // The renewal fails, and so does putting back the sign-in it replaced.
      secure.refuseWhen = (key, value) =>
          key == 'user_credentials_v2' &&
          (value?.contains('"password":"jwt-a"') ?? false);

      final dropped = await droppedBy(
        () => check(
          storage.commitExistingServerSession(
            ownership: ownership!,
            token: 'token-renewed',
            canCommit: () => true,
            publish: () => throw StateError('publication failed'),
            rememberedCredentials: {
              ...browserSignIn('a'),
              'password': 'jwt-renewed',
            },
            browserSession: BrowserSessionCommit.keep,
          ),
        ).throws<ServerConfigSessionRollbackException>(),
      );

      secure.refuseWhen = null;
      check(await storage.getSavedCredentialsStrict()).isNull();
      check(await storedSession('a')).isNull();
      check(dropped).deepEquals([(accountId: 'a', session: session)]);
    });

    test('when the saved sign-in it renews is deleted', () async {
      await saveAccounts(['a']);
      final session = await signInWithBrowser('a');

      final dropped = await droppedBy(
        () => storage.deleteSavedCredentialsIfMatches(browserSignIn('a')),
      );

      check(dropped).deepEquals([(accountId: 'a', session: session)]);
    });

    test('when the saved sign-in is deleted whoever it names', () async {
      await saveAccounts(['a']);
      final session = await signInWithBrowser('a');

      final dropped = await droppedBy(storage.deleteSavedCredentials);

      check(dropped).deepEquals([(accountId: 'a', session: session)]);
      check(await storedSession('a')).isNull();
    });

    test('when choosing the account to sign in to afresh', () async {
      await saveAccounts(['a']);
      final session = await signInWithBrowser('a');

      final dropped = await droppedBy(
        () => storage.selectUnauthenticatedServerConfig(
          account('a'),
          publish: () {},
        ),
      );

      check(dropped).deepEquals([(accountId: 'a', session: session)]);
    });

    test('when a proxy sign-in commits for the account', () async {
      await saveAccounts(['a']);
      final session = await signInWithBrowser('a');
      final staged = await storage.stageServerConfigCandidate(account('a'));

      final dropped = await droppedBy(
        () => storage.commitServerConfigCandidateSession(
          candidate: account('a'),
          transactionId: staged.transactionId,
          token: 'proxy-token',
          canCommit: () => true,
          publish: () {},
        ),
      );

      check(dropped).deepEquals([(accountId: 'a', session: session)]);
    });

    test('when a merge replaces the existing account\'s own', () async {
      await saveAccounts(['existing', 'new']);
      final existing = await signInWithBrowser('existing');
      await signInWithBrowser('new');

      final dropped = await droppedBy(
        () => storage.mergeActiveAccountInto(
          'existing',
          expectedSourceAccountId: 'new',
        ),
      );

      check(dropped).deepEquals([(accountId: 'existing', session: existing)]);
    });

    test('when the account\'s server moves', () async {
      await saveAccounts(['a', 'b']);
      final sessionA = await signInWithBrowser('a');
      final sessionB = await signInWithBrowser('b');

      final dropped = await droppedBy(
        () => storage.saveServerConfigs([
          account('a', url: 'https://elsewhere.test'),
          account('b', url: 'https://elsewhere.test'),
        ]),
      );

      check(dropped).unorderedEquals([
        (accountId: 'a', session: sessionA),
        (accountId: 'b', session: sessionB),
      ]);
    });

    test('when the active account\'s sign-in is cleared other than by a '
        'sign-out', () async {
      await saveAccounts(['a']);
      final session = await signInWithBrowser('a');

      final dropped = await droppedBy(
        () => storage.clearActiveAccountAuthDataIf(
          canClear: () => true,
          tellDroppedBrowserSession: true,
        ),
      );

      check(dropped).deepEquals([(accountId: 'a', session: session)]);
      check(await storedSession('a')).isNull();
    });

    test('but not when a sign-out clears it, which revokes its own', () async {
      await saveAccounts(['a']);
      await signInWithBrowser('a');

      final dropped = await droppedBy(
        () => storage.clearActiveAccountAuthDataIf(canClear: () => true),
      );

      check(dropped).isEmpty();
      check(await storedSession('a')).isNull();
    });

    test('never for a sign-out, which revokes its own', () async {
      await saveAccounts(['a', 'b']);
      await signInWithBrowser('a');
      await signInWithBrowser('b');

      final dropped = await droppedBy(() async {
        await storage.removeInactiveAccount('a');
        await storage.removeAccount('b');
      });

      check(dropped).isEmpty();
    });
  });

  group('compare-and-swap', () {
    test('replaces only the session read', () async {
      await saveAccounts(['a']);
      final session = await signInWithBrowser('a');
      final rotated = session.copyWith(refreshToken: 'rotated');

      check(
        await storage.replaceBrowserSignInSessionIfCurrent(
          'a',
          expected: session,
          next: rotated,
        ),
      ).isTrue();
      // A second renewal that read the first session lost the race.
      check(
        await storage.replaceBrowserSignInSessionIfCurrent(
          'a',
          expected: session,
          next: session.copyWith(refreshToken: 'stale'),
        ),
      ).isFalse();

      check(await storedSession('a')).equals(rotated);
    });

    test('never brings back a session that ended', () async {
      await saveAccounts(['a']);
      final session = await signInWithBrowser('a');
      await storage.clearActiveAccountAuthDataIf(canClear: () => true);

      check(
        await storage.replaceBrowserSignInSessionIfCurrent(
          'a',
          expected: session,
          next: session.copyWith(refreshToken: 'rotated'),
        ),
      ).isFalse();
      check(await storedSession('a')).isNull();
    });

    test('deletes only the session read', () async {
      await saveAccounts(['a']);
      final session = await signInWithBrowser('a');
      final rotated = session.copyWith(refreshToken: 'rotated');
      await storage.replaceBrowserSignInSessionIfCurrent(
        'a',
        expected: session,
        next: rotated,
      );

      check(
        await storage.deleteBrowserSignInSessionIfCurrent(
          'a',
          expected: session,
        ),
      ).isFalse();
      check(await storedSession('a')).equals(rotated);
      check(
        await storage.deleteBrowserSignInSessionIfCurrent(
          'a',
          expected: rotated,
        ),
      ).isTrue();
      check(await storedSession('a')).isNull();
    });

    test('deleting the saved sign-in it renews deletes it', () async {
      await saveAccounts(['a']);
      await signInWithBrowser('a');

      check(await storage.deleteSavedCredentialsIfMatches(browserSignIn('a')))
          .isTrue();

      check(await storedSession('a')).isNull();
    });
  });

  group('a session ends with its account\'s saved sign-in', () {
    test('when choosing the account to sign in to afresh', () async {
      await saveAccounts(['a', 'b']);
      final sessionB = await signInWithBrowser('b');
      await signInWithBrowser('a');

      await storage.selectUnauthenticatedServerConfig(
        account('a'),
        publish: () {},
      );

      check(await storedSession('a')).isNull();
      check(await storedSession('b')).equals(sessionB);
    });

    test('when choosing an account that keeps it in its vault', () async {
      await saveAccounts(['a', 'b']);
      await signInWithBrowser('a');
      await signInWithBrowser('b');

      await storage.selectUnauthenticatedServerConfig(
        account('a'),
        publish: () {},
      );

      check(await storedSession('a')).isNull();
      check(await vaultedCredentials('a')).isNull();
    });

    test('for an account dropped as abandoned', () async {
      await saveAccounts(['a']);
      await signInWithBrowser('a');
      await storage.selectUnauthenticatedServerConfig(
        account('abandoned'),
        publish: () {},
      );
      // Left behind by an interrupted operation.
      await secure.write(
        key: 'browser_sign_in_session_v1:abandoned',
        value: (await sessionFor('a')).encode(),
      );

      await storage.selectUnauthenticatedServerConfig(
        account('retry'),
        publish: () {},
      );

      check(await storedSession('abandoned')).isNull();
      check(await storedSession('a')).isNotNull();
    });

    test('unless the choice is undone', () async {
      await saveAccounts(['a']);
      final session = await signInWithBrowser('a');
      var checks = 0;

      await storage.selectUnauthenticatedServerConfig(
        account('a'),
        // Fails once the saved sign-in and its session have gone.
        canCommit: () => ++checks < 8,
        publish: () {},
      );

      check(await storedSession('a')).equals(session);
      check((await storage.getSavedCredentialsStrict())?['authType'])
          .equals(AuthTypes.ssoBrowser);
    });

    test('when a proxy sign-in commits for the account', () async {
      await saveAccounts(['a']);
      await signInWithBrowser('a');
      final staged = await storage.stageServerConfigCandidate(account('a'));

      check(
        await storage.commitServerConfigCandidateSession(
          candidate: account('a'),
          transactionId: staged.transactionId,
          token: 'proxy-token',
          canCommit: () => true,
          publish: () {},
        ),
      ).isTrue();

      check(await storedSession('a')).isNull();
    });

    test('when signing out of the active account alone', () async {
      await saveAccounts(['a', 'b']);
      final sessionA = await signInWithBrowser('a');
      await signInWithBrowser('b');

      await storage.clearActiveAccountAuthDataIf(canClear: () => true);

      check(await storedSession('b')).isNull();
      check(await storedSession('a')).equals(sessionA);
    });

    test('when signing out of every account', () async {
      await saveAccounts(['a', 'b']);
      await signInWithBrowser('a');
      await signInWithBrowser('b');

      await storage.clearAuthDataIf(canClear: () => true);

      check(await storedSession('a')).isNull();
      check(await storedSession('b')).isNull();
    });

    test('when the vault is emptied', () async {
      await saveAccounts(['a']);
      await signInWithBrowser('a');

      await storage.clearTokenVault();

      check(await storedSession('a')).isNull();
    });

    test('when the account is removed', () async {
      await saveAccounts(['a', 'b']);
      await signInWithBrowser('a');
      final sessionB = await signInWithBrowser('b');

      check(await storage.removeInactiveAccount('a')).isTrue();
      check(await storedSession('a')).isNull();

      await storage.removeAccount('b');
      check(await storedSession('b')).isNull();
      check(sessionB.refreshToken).isNotEmpty();
    });

    test('unless the removal is undone', () async {
      await saveAccounts(['a', 'b']);
      final sessionA = await signInWithBrowser('a');
      await signInWithBrowser('b');
      secure.refusedOnceKey = 'openwebui_registry_v1';

      await check(storage.removeInactiveAccount('a')).throws<StateError>();

      check(await storedSession('a')).equals(sessionA);
    });

    test('when the account\'s server moves', () async {
      await saveAccounts(['a', 'b']);
      await signInWithBrowser('a');
      await signInWithBrowser('b');

      await storage.saveServerConfigs([
        account('a', url: 'https://elsewhere.test'),
        account('b', url: 'https://elsewhere.test'),
      ]);

      check(await storedSession('a')).isNull();
      check(await storedSession('b')).isNull();
    });

    test('but not when switching accounts', () async {
      await saveAccounts(['a', 'b']);
      final sessionA = await signInWithBrowser('a');
      final sessionB = await signInWithBrowser('b');

      await storage.switchActiveServer(fromServerId: 'b', toServerId: 'a');

      check(await storedSession('a')).equals(sessionA);
      check(await storedSession('b')).equals(sessionB);
    });

    test('nor when Open WebUI is parked, and taken up again', () async {
      await saveAccounts(['a']);
      final session = await signInWithBrowser('a');

      await storage.parkActiveServer(fromServerId: 'a');

      // Parked, the browser sign-in waits in the account's vault.
      check(await vaultedCredentials('a'))
          .isNotNull()
          .has((c) => c['authType'], 'authType')
          .equals(AuthTypes.ssoBrowser);
      check(await storedSession('a')).equals(session);
      check(await storage.sweepOrphanBrowserSignInSessions()).isEmpty();

      await storage.switchActiveServer(toServerId: 'a');

      check(await storedSession('a')).equals(session);
      check(await storage.sweepOrphanBrowserSignInSessions()).isEmpty();
    });
  });

  group('folding a duplicate account into an existing one', () {
    Future<BrowserSignInSession> signedInAsNewOverExisting() async {
      await saveAccounts(['existing', 'new']);
      await signInWithBrowser('existing');
      return signInWithBrowser('new');
    }

    test('moves the session with the live sign-in', () async {
      final session = await signedInAsNewOverExisting();

      check(
        await storage.mergeActiveAccountInto(
          'existing',
          expectedSourceAccountId: 'new',
        ),
      ).isTrue();

      check(await storedSession('existing')).equals(session);
      check(await storedSession('new')).isNull();
      check((await storage.getSavedCredentialsStrict())?['serverId'])
          .equals('existing');
    });

    test(
      'ends the existing account\'s own when the new one has none',
      () async {
        await saveAccounts(['existing', 'new']);
        await signInWithBrowser('existing');
        final ownership = await storage.captureSavedServerSessionOwnership(
          'new',
        );
        await storage.commitExistingServerSession(
          ownership: ownership!,
          token: 'token-new',
          canCommit: () => true,
          publish: () {},
        );

        await storage.mergeActiveAccountInto(
          'existing',
          expectedSourceAccountId: 'new',
        );

        check(await storedSession('existing')).isNull();
      },
    );

    test('that fails part-way leaves both sessions as they were', () async {
      final session = await signedInAsNewOverExisting();
      final existing = await storedSession('existing');
      secure.refusedKey = 'openwebui_registry_v1';

      await check(
        storage.mergeActiveAccountInto(
          'existing',
          expectedSourceAccountId: 'new',
        ),
      ).throws<StateError>();

      check(await storedSession('new')).equals(session);
      check(await storedSession('existing')).equals(existing);
    });

    test('that cannot be undone ends the live session with its own', () async {
      final session = await signedInAsNewOverExisting();
      final existing = await storedSession('existing');
      // The registry write fails, and so does putting back the saved
      // sign-in it renamed: the live session's owner can't be told.
      secure.refuseWhen = (key, value) =>
          key == 'openwebui_registry_v1' ||
          (key == 'user_credentials_v2' &&
              (value?.contains('"serverId":"new"') ?? false));

      final dropped = await droppedBy(
        () => check(
          storage.mergeActiveAccountInto(
            'existing',
            expectedSourceAccountId: 'new',
          ),
        ).throws<ServerConfigSessionRollbackException>(),
      );

      secure.refuseWhen = null;
      check(await storage.getSavedCredentialsStrict()).isNull();
      check(await storedSession('new')).isNull();
      check(await storedSession('existing')).equals(existing);
      // Its refresh token is gone from the device, so it can be revoked.
      check(dropped).deepEquals([(accountId: 'new', session: session)]);
    });
  });

  group('the sweep', () {
    test('deletes sessions nothing can renew, and keeps the rest', () async {
      await saveAccounts(['active', 'kept', 'password', 'gone']);
      final kept = await signInWithBrowser('kept');
      await signInWithBrowser('password');
      final password = await storedSession('password');
      final active = await signInWithBrowser('active');
      // Signed in with a password since, by a path that left its session.
      await secure.write(
        key: 'user_credentials_server_v1:password',
        value: jsonEncode({
          'serverId': 'password',
          'username': 'me',
          'password': 'pw',
          'authType': AuthTypes.credentials,
        }),
      );
      final gone = await sessionFor('gone');
      await storage.removeAccount('gone');
      await secure.write(
        key: 'browser_sign_in_session_v1:gone',
        value: gone.encode(),
      );
      await secure.write(
        key: 'browser_sign_in_session_v1:unreadable',
        value: 'not a session',
      );

      final swept = await storage.sweepOrphanBrowserSignInSessions();

      check(swept).unorderedEquals([
        (accountId: 'password', session: password!),
        (accountId: 'gone', session: gone),
      ]);
      check(await storedSession('active')).equals(active);
      check(await storedSession('kept')).equals(kept);
      check(await secure.read(key: 'browser_sign_in_session_v1:unreadable'))
          .isNull();
      check(await storage.sweepOrphanBrowserSignInSessions()).isEmpty();
    });

    test('deletes the active account\'s once its sign-in is not a browser '
        'sign-in', () async {
      await saveAccounts(['a']);
      await signInWithBrowser('a');
      await storage.saveCredentials(
        serverId: 'a',
        username: 'me',
        password: 'pw',
      );

      check(await storage.sweepOrphanBrowserSignInSessions()).length.equals(1);
      check(await storedSession('a')).isNull();
    });

    test('changes nothing when a saved sign-in cannot be read', () async {
      await saveAccounts(['a', 'b']);
      final sessionA = await signInWithBrowser('a');
      await signInWithBrowser('b');
      secure.unreadableKey = 'user_credentials_server_v1:a';

      await check(storage.sweepOrphanBrowserSignInSessions()).throws<Object>();

      secure.unreadableKey = null;
      check(await storedSession('a')).equals(sessionA);
    });
  });

  test('every session can be read for revocation', () async {
    await saveAccounts(['a', 'b']);
    final sessionA = await signInWithBrowser('a');
    final sessionB = await signInWithBrowser('b');
    await secure.write(key: 'browser_sign_in_session_v1:broken', value: '{}');

    check(await storage.browserSignInSessionsForRevocation()).unorderedEquals([
      (accountId: 'a', session: sessionA),
      (accountId: 'b', session: sessionB),
    ]);
  });
}

final class _RefusingSecureStore extends InMemorySecureKeyValueStore {
  String? refusedKey;
  String? refusedOnceKey;
  String? unreadableKey;
  String? undeletableKey;
  bool Function(String key, String? value)? refuseWhen;

  @override
  Future<void> delete({required String key}) {
    if (key == undeletableKey) throw StateError('keychain refused $key');
    return super.delete(key: key);
  }

  @override
  Future<void> write({required String key, required String? value}) {
    if (key == refusedKey) throw StateError('keychain refused $key');
    if (refuseWhen?.call(key, value) ?? false) {
      throw StateError('keychain refused $key');
    }
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
