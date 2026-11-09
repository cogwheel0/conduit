import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/database_manager.dart';
import 'package:conduit_core/features/librechat/models/librechat_account.dart';
import 'package:conduit_core/features/librechat/models/librechat_capabilities.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_auth_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/features/librechat/services/librechat_registry_store.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_store.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/database_opener.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/chat_picks_session.dart';
import 'package:conduit_core/providers/primary_account_providers.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/providers/storage_providers.dart';
import 'package:conduit_core/testing.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// Opens databases as files in [directory]. [failDirectory] makes the
/// directory unreachable, so a deletion fails; a close waits for [closeGate]
/// while one is set.
final class _TestDatabaseOpener implements DatabaseOpenerPort {
  _TestDatabaseOpener(this.directory);

  final Directory directory;
  bool failDirectory = false;
  Completer<void>? closeGate;

  File file(String fileName) => File('${directory.path}/$fileName.sqlite');

  @override
  QueryExecutor open(String fileName) =>
      NativeDatabase(file(fileName)).interceptWith(_GatedClose(this));

  @override
  Future<Directory> databaseDirectory() async {
    if (failDirectory) throw const FileSystemException('Unavailable');
    return directory;
  }
}

final class _GatedClose extends QueryInterceptor {
  _GatedClose(this._opener);

  final _TestDatabaseOpener _opener;

  @override
  Future<void> close(QueryExecutor inner) async {
    await _opener.closeGate?.future;
    await inner.close();
  }
}

/// Secure storage whose session deletes wait for [hold] while it is set,
/// completing [deleting] when one starts waiting.
final class _HeldSessionDeletes extends InMemorySecureKeyValueStore {
  Completer<void>? hold;
  final Completer<void> deleting = Completer<void>();

  @override
  Future<void> delete({required String key}) async {
    final gate = hold;
    if (gate != null && key.startsWith(SecureLibreChatSessionStore.keyPrefix)) {
      if (!deleting.isCompleted) deleting.complete();
      await gate.future;
    }
    return super.delete(key: key);
  }
}

/// Secure storage whose session writes wait for [hold] while it is set.
final class _HeldSessionWrites extends InMemorySecureKeyValueStore {
  Completer<void>? hold;

  @override
  Future<void> write({required String key, required String? value}) async {
    if (key.startsWith(SecureLibreChatSessionStore.keyPrefix)) {
      await hold?.future;
    }
    return super.write(key: key, value: value);
  }
}

/// Refuses session writes while [fail] is set, as a Keychain that will not
/// write.
final class _FailingSessionWrites extends InMemorySecureKeyValueStore {
  bool fail = false;

  /// Refuses writes of the account registry instead.
  bool failRegistry = false;

  @override
  Future<void> write({required String key, required String? value}) {
    if ((fail && key.startsWith(SecureLibreChatSessionStore.keyPrefix)) ||
        (failRegistry && key == LibreChatRegistryStore.key)) {
      return Future.error(StateError('The Keychain refused the write.'));
    }
    return super.write(key: key, value: value);
  }
}

/// Answers reads only once [ready] completes, as a Keychain still waking
/// up does.
final class _SlowSecureStore extends InMemorySecureKeyValueStore {
  _SlowSecureStore(super.seed, this.ready);

  final Future<void> ready;

  @override
  Future<String?> read({required String key}) async {
    await ready;
    return super.read(key: key);
  }
}

/// Secure storage whose deletes, or session reads, can be made to fail.
final class _FlakySecureStore extends InMemorySecureKeyValueStore {
  _FlakySecureStore(super.seed);

  bool failDeletes = false;
  bool failSessionReads = false;

  @override
  Future<String?> read({required String key}) {
    if (failSessionReads &&
        key.startsWith(SecureLibreChatSessionStore.keyPrefix)) {
      return Future.error(StateError('keychain locked'));
    }
    return super.read(key: key);
  }

  @override
  Future<void> delete({required String key}) {
    if (failDeletes) return Future.error(StateError('keychain locked'));
    return super.delete(key: key);
  }
}

void main() {
  const server = LibreChatServer(baseUrl: 'https://chat.example.com');

  group('registry', () {
    final account = LibreChatAccount.forUser(
      server,
      const LibreChatUser(id: 'u1', name: 'Dev', email: 'dev@example.com'),
      serverTitle: 'Team Chat',
    );

    test('one account per user and server, with an opaque id', () {
      check(account.id).startsWith('librechat:');
      check(account.id).not((it) => it.contains('u1'));
      check(
        LibreChatAccount.idFor(server.baseUrl, 'u1'),
      ).equals(account.id);
      check(
        LibreChatAccount.idFor('https://other.example.com', 'u1'),
      ).not((it) => it.equals(account.id));
    });

    test('round-trips and drops what it cannot read', () {
      final registry = const LibreChatRegistry().upsert(
        account,
        activate: true,
      );
      final json = registry.toJson();
      (json['accounts'] as List).add({'id': 'server-1', 'userId': 'x'});
      final read = LibreChatRegistry.fromJson(json);
      check(read.accounts).deepEquals([account]);
      check(read.activeId).equals(account.id);
      check(
        LibreChatRegistry.fromJson({'version': 99}).accounts,
      ).isEmpty();
    });

    test('a refreshed profile clears what the server no longer has', () {
      final refreshed = account.withUser(
        const LibreChatUser(id: 'u1', username: 'dev'),
      );
      check(refreshed.name).isNull();
      check(refreshed.email).isNull();
      check(refreshed.username).equals('dev');
      check(refreshed.serverTitle).equals('Team Chat');
    });

    test('removing the active account leaves none active', () {
      final registry = const LibreChatRegistry()
          .upsert(account, activate: true)
          .remove(account.id);
      check(registry.accounts).isEmpty();
      check(registry.activeId).isNull();
    });
  });

  group('capabilities', () {
    test('need the interface, the role and the endpoint', () {
      final capabilities = LibreChatCapabilities.from(
        startupConfig: {
          'interface': {
            'webSearch': true,
            'runCode': false,
            'prompts': {'use': true, 'create': false},
            'memories': true,
          },
          'modelSpecs': {
            'enforce': true,
            'list': [
              {'name': 'fast'},
            ],
          },
        },
        permissions: {
          'WEB_SEARCH': <String, Object>{},
          'MEMORIES': {'READ': true, 'CREATE': false},
          'FILE_SEARCH': {'USE': false},
        },
        endpoints: {
          'agents': {
            'capabilities': ['web_search', 'execute_code', 'file_search'],
          },
        },
        serverSearch: true,
      );
      check(capabilities)
        // An empty role entry takes the default grant.
        ..has((it) => it.webSearch, 'webSearch').isTrue()
        // Hidden by the interface even though the endpoint can.
        ..has((it) => it.codeInterpreter, 'codeInterpreter').isFalse()
        // Denied by the role.
        ..has((it) => it.fileSearch, 'fileSearch').isFalse()
        ..has((it) => it.prompts, 'prompts').isTrue()
        ..has((it) => it.createPrompts, 'createPrompts').isFalse()
        ..has((it) => it.memories, 'memories').isTrue()
        ..has((it) => it.createMemories, 'createMemories').isFalse()
        ..has((it) => it.agents, 'agents').isTrue()
        ..has((it) => it.serverSearch, 'serverSearch').isTrue()
        ..has((it) => it.modelSpecsEnforced, 'modelSpecsEnforced').isTrue();
    });

    test('links are offered only where LibreChat makes them public', () {
      LibreChatCapabilities read(Map<String, Object> sharedLinks) =>
          LibreChatCapabilities.from(
            startupConfig: const {},
            permissions: {'SHARED_LINKS': sharedLinks},
            endpoints: const {},
          );
      check(
        read({'CREATE': true, 'SHARE': true, 'SHARE_PUBLIC': true}).sharedLinks,
      ).isTrue();
      // Made, they would open for their owner alone.
      check(
        read({'CREATE': true, 'SHARE': true, 'SHARE_PUBLIC': false})
            .sharedLinks,
      ).isFalse();
      // LibreChat publishes only on an outright grant.
      check(read({'CREATE': true}).sharedLinks).isFalse();
      check(
        read({'CREATE': false, 'SHARE_PUBLIC': true}).sharedLinks,
      ).isFalse();
    });

    test('memories are added, changed and switched by separate permissions',
        () {
      final capabilities = LibreChatCapabilities.from(
        startupConfig: const {},
        permissions: {
          'MEMORIES': {
            'USE': true,
            'READ': true,
            'CREATE': false,
            'UPDATE': true,
            'OPT_OUT': false,
          },
        },
        endpoints: const {},
      );
      check(capabilities)
        ..has((it) => it.createMemories, 'createMemories').isFalse()
        ..has((it) => it.updateMemories, 'updateMemories').isTrue()
        ..has((it) => it.optOutMemories, 'optOutMemories').isFalse();
    });

    test('a feature the role cannot use offers none of its parts', () {
      final capabilities = LibreChatCapabilities.from(
        startupConfig: const {},
        permissions: {
          'PROMPTS': {'USE': false, 'CREATE': true},
          'MEMORIES': {'USE': false, 'READ': true, 'CREATE': true},
        },
        endpoints: const {},
      );
      check(capabilities)
        ..has((it) => it.prompts, 'prompts').isFalse()
        ..has((it) => it.createPrompts, 'createPrompts').isFalse()
        ..has((it) => it.memories, 'memories').isFalse()
        ..has((it) => it.createMemories, 'createMemories').isFalse();
    });

    test('no agents endpoint means no agent tools', () {
      final capabilities = LibreChatCapabilities.from(
        startupConfig: const {},
        permissions: const {},
        endpoints: const {'Ollama': <String, Object>{}},
      );
      check(capabilities.webSearch).isFalse();
      check(capabilities.agents).isFalse();
      check(capabilities.modelSpecsEnforced).isFalse();
    });
  });

  group('providers', () {
    late FakeLibreChatServer fake;
    late InMemorySecureKeyValueStore secure;
    late _TestDatabaseOpener opener;
    late ProviderContainer container;

    ProviderContainer newContainer() {
      final created = ProviderContainer(
        overrides: [
          secureStorageProvider.overrideWithValue(secure),
          libreChatHttpAdapterProvider.overrideWithValue(fake),
          databaseOpenerProvider.overrideWithValue(opener),
        ],
        retry: (_, _) => null,
      );
      addTearDown(created.dispose);
      return created;
    }

    setUp(() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
      await PreferencesStore.ensureInitialized();
      addTearDown(PreferencesStore.debugReset);
      final directory = await Directory.systemTemp.createTemp('lc-accounts');
      addTearDown(() => directory.delete(recursive: true));
      fake = FakeLibreChatServer()..addUser();
      secure = InMemorySecureKeyValueStore();
      opener = _TestDatabaseOpener(directory);
      container = newContainer();
    });

    Future<LibreChatSession> signIn([LibreChatServer on = server]) async {
      final auth = LibreChatAuthService(on, adapter: fake);
      addTearDown(auth.close);
      return ((await auth.signIn(
                email: 'dev@example.com',
                password: 'devpassword',
              ))
              as LibreChatSignedIn)
          .session;
    }

    test('a saved sign-in becomes the signed-in account', () async {
      check(
        await container.read(libreChatSessionProvider.future),
      ).isA<LibreChatNoAccount>();

      final session = await signIn();
      final account = await container
          .read(libreChatAccountsProvider)
          .saveSignedIn(server: server, session: session);

      check(container.read(activeLibreChatAccountProvider)).equals(account);
      final state = await container.read(libreChatSessionProvider.future);
      check(state).isA<LibreChatSignedInState>();
      check(
        await SecureLibreChatSessionStore(secure, account.id).read(),
      ).equals(session);

      final api = container.read(libreChatApiServiceProvider)!;
      check((await api.currentUser()).id).equals(session.user.id);
    });

    test('a saved session waits for the accounts to load', () async {
      await container
          .read(libreChatAccountsProvider)
          .saveSignedIn(server: server, session: await signIn());
      // A cold start on a Keychain that answers slowly.
      final keychain = Completer<void>();
      secure = _SlowSecureStore(await secure.readAll(), keychain.future);
      final restarted = newContainer();
      final seen = <LibreChatSessionState>[];
      restarted.listen<AsyncValue<LibreChatSessionState>>(
        libreChatSessionProvider,
        (_, next) {
          if (next.value case final value?) seen.add(value);
        },
        fireImmediately: true,
      );

      await pumpEventQueue();
      // Not "no account": routing would send a returning user to set up.
      check(restarted.read(libreChatSessionProvider).isLoading).isTrue();
      check(seen).isEmpty();

      keychain.complete();
      check(
        await restarted.read(libreChatSessionProvider.future),
      ).isA<LibreChatSignedInState>();
      // One session opened, not one opened and then dropped for another.
      await pumpEventQueue();
      check(seen).length.equals(1);
    });

    test('a session that ends asks for sign-in and keeps the account', () async {
      final account = await container
          .read(libreChatAccountsProvider)
          .saveSignedIn(server: server, session: await signIn());
      await container.read(libreChatSessionProvider.future);
      final api = container.read(libreChatApiServiceProvider)!;

      fake.endSessions();
      await check(api.currentUser()).throws<Object>();
      final state = container.read(libreChatSessionProvider).asData?.value;
      check(state).isA<LibreChatNeedsSignIn>().has(
        (it) => it.account.id,
        'account',
      ).equals(account.id);
      check(container.read(activeLibreChatAccountProvider)).isNotNull();
      check(await SecureLibreChatSessionStore(secure, account.id).read())
          .isNull();
    });

    test('a stored session for another user never opens', () async {
      final session = await signIn();
      final account = await container
          .read(libreChatAccountsProvider)
          .saveSignedIn(server: server, session: session);
      await SecureLibreChatSessionStore(secure, account.id).write(
        session.copyWith(user: const LibreChatUser(id: 'someone-else')),
      );
      container.invalidate(libreChatSessionProvider);
      check(
        await container.read(libreChatSessionProvider.future),
      ).isA<LibreChatNeedsSignIn>();
      check(container.read(libreChatHttpClientProvider)).isNull();
    });

    test('signing out ends the session on the server and forgets it', () async {
      final account = await container
          .read(libreChatAccountsProvider)
          .saveSignedIn(server: server, session: await signIn());
      await container.read(libreChatAccountsProvider).signOut(account.id);
      check(fake.refreshTokens).isEmpty();
      check(container.read(activeLibreChatAccountProvider)).isNull();
      check(
        await SecureLibreChatSessionStore(secure, account.id).read(),
      ).isNull();
    });

    test('signing in again while the old sign-out waits keeps the new '
        'sign-in', () async {
      final accounts = container.read(libreChatAccountsProvider);
      final account = await accounts.saveSignedIn(
        server: server,
        session: await signIn(),
      );
      final release = Completer<void>();
      fake.on('POST', '/api/auth/logout', (request, match) async {
        await release.future;
        return FakeLibreChatResponse.json({'message': 'Logout successful'});
      });
      final signingOut = accounts.signOut(account.id);
      await pumpEventQueue();
      final again = await signIn();
      await accounts.saveSignedIn(server: server, session: again);

      release.complete();
      await signingOut;
      check(
        await SecureLibreChatSessionStore(secure, account.id).read(),
      ).equals(again);
      check(container.read(activeLibreChatAccountProvider)?.id).equals(
        account.id,
      );
    });

    test('a write the session in use is making lands before the sign-out '
        'clears it', () async {
      final held = _HeldSessionWrites();
      secure = held;
      final signedIn = newContainer();
      final account = await signedIn
          .read(libreChatAccountsProvider)
          .saveSignedIn(server: server, session: await signIn());
      final state =
          await signedIn.read(libreChatSessionProvider.future)
              as LibreChatSignedInState;
      // A response's cookie is being saved as the user signs out.
      held.hold = Completer<void>();
      final absorbing = state.handle.absorbCookies(['extra=1; Path=/']);
      await pumpEventQueue();
      final signingOut = signedIn
          .read(libreChatAccountsProvider)
          .signOut(account.id);
      await pumpEventQueue();

      held.hold!.complete();
      await absorbing;
      await signingOut;
      check(await SecureLibreChatSessionStore(held, account.id).read()).isNull();
    });

    test('a session signed in to again is not overwritten by the one it '
        'replaced', () async {
      final accounts = container.read(libreChatAccountsProvider);
      final account = await accounts.saveSignedIn(
        server: server,
        session: await signIn(),
      );
      final first =
          await container.read(libreChatSessionProvider.future)
              as LibreChatSignedInState;
      final second = await signIn();
      await accounts.saveSignedIn(server: server, session: second);

      // The session replaced hears of a cookie: it is not saved over the
      // new one.
      await first.handle.absorbCookies(['late=1; Path=/']);
      final stored = await SecureLibreChatSessionStore(
        secure,
        account.id,
      ).read();
      check(stored!.accessToken).equals(second.accessToken);
    });

    test('a session that ends after it was replaced leaves the new one',
        () async {
      final accounts = container.read(libreChatAccountsProvider);
      final account = await accounts.saveSignedIn(
        server: server,
        session: await signIn(),
      );
      final first =
          await container.read(libreChatSessionProvider.future)
              as LibreChatSignedInState;
      final second = await signIn();
      await accounts.saveSignedIn(server: server, session: second);

      // The replaced session's renewal comes back expired, and it ends.
      await first.handle.end();
      final stored = await SecureLibreChatSessionStore(
        secure,
        account.id,
      ).read();
      check(stored?.accessToken).equals(second.accessToken);
    });

    test('a sign-in that cannot be saved leaves the session in use saving',
        () async {
      final failing = _FailingSessionWrites();
      secure = failing;
      final signedIn = newContainer();
      final accounts = signedIn.read(libreChatAccountsProvider);
      final account = await accounts.saveSignedIn(
        server: server,
        session: await signIn(),
      );
      await signedIn.read(libreChatSessionProvider.future);

      failing.fail = true;
      final again = await signIn();
      await check(
        accounts.saveSignedIn(server: server, session: again),
      ).throws<StateError>();
      failing.fail = false;

      final state =
          await signedIn.read(libreChatSessionProvider.future)
              as LibreChatSignedInState;
      await state.handle.absorbCookies(['late=1; Path=/']);
      final stored = await SecureLibreChatSessionStore(
        failing,
        account.id,
      ).read();
      check(stored!.cookies.value('late')).equals('1');
    });

    test('a sign-in whose account cannot be saved leaves the session in use '
        'saving', () async {
      final failing = _FailingSessionWrites();
      secure = failing;
      final signedIn = newContainer();
      final accounts = signedIn.read(libreChatAccountsProvider);
      final account = await accounts.saveSignedIn(
        server: server,
        session: await signIn(),
      );
      await signedIn.read(libreChatSessionProvider.future);

      failing.failRegistry = true;
      final again = await signIn();
      await check(
        accounts.saveSignedIn(server: server, session: again),
      ).throws<StateError>();
      failing.failRegistry = false;

      final state =
          await signedIn.read(libreChatSessionProvider.future)
              as LibreChatSignedInState;
      await state.handle.absorbCookies(['late=1; Path=/']);
      final stored = await SecureLibreChatSessionStore(
        failing,
        account.id,
      ).read();
      check(stored!.cookies.value('late')).equals('1');
    });

    test('a session switched away from saves nothing past its sign-out',
        () async {
      const other = LibreChatServer(baseUrl: 'https://other.example.com');
      final held = _HeldSessionWrites();
      secure = held;
      final signedIn = newContainer();
      final accounts = signedIn.read(libreChatAccountsProvider);
      final a = await accounts.saveSignedIn(
        server: server,
        session: await signIn(),
      );
      final first =
          await signedIn.read(libreChatSessionProvider.future)
              as LibreChatSignedInState;
      await accounts.saveSignedIn(server: other, session: await signIn(other));
      check(
        (await signedIn.read(libreChatSessionProvider.future)
                as LibreChatSignedInState)
            .account
            .id,
      ).not((it) => it.equals(a.id));

      // A's session, no longer in use, is saving a response's cookie as A is
      // signed out.
      held.hold = Completer<void>();
      final absorbing = first.handle.absorbCookies(['extra=1; Path=/']);
      await pumpEventQueue();
      final signingOut = accounts.signOut(a.id);
      await pumpEventQueue();
      held.hold!.complete();
      await absorbing;
      await signingOut;
      check(await SecureLibreChatSessionStore(held, a.id).read()).isNull();

      // Nor does a cookie it hears of later come back.
      await first.handle.absorbCookies(['late=1; Path=/']);
      check(await SecureLibreChatSessionStore(held, a.id).read()).isNull();
    });

    test('a sign-in landing while a sign-out forgets the account keeps it',
        () async {
      final held = _HeldSessionDeletes();
      secure = held;
      final accounts = newContainer().read(libreChatAccountsProvider);
      final account = await accounts.saveSignedIn(
        server: server,
        session: await signIn(),
      );
      held.hold = Completer<void>();
      final signingOut = accounts.signOut(account.id);
      // The sign-out has told the server and is forgetting the account.
      await held.deleting.future;

      final again = await signIn();
      final signingIn = accounts.saveSignedIn(server: server, session: again);
      await pumpEventQueue();
      held.hold!.complete();
      await signingOut;
      await signingIn;

      check(await SecureLibreChatSessionStore(held, account.id).read())
          .equals(again);
    });

    test('a sign-in waiting on a sign-out is not saved after a full '
        'sign-out', () async {
      final held = _HeldSessionDeletes();
      secure = held;
      final container = newContainer();
      final accounts = container.read(libreChatAccountsProvider);
      final account = await accounts.saveSignedIn(
        server: server,
        session: await signIn(),
      );
      final release = held.hold = Completer<void>();
      final signingOut = accounts.signOut(account.id);
      await held.deleting.future;
      final signingIn = accounts.saveSignedIn(
        server: server,
        session: await signIn(),
      );
      // Expected from the start: it fails as soon as the sign-out lets it
      // go, which may be before the test looks again.
      final refused = check(signingIn).throws<StateError>();
      await pumpEventQueue();

      // Every account is signed out of, and that is over, while the sign-in
      // still waits.
      held.hold = null;
      final registry = container.read(libreChatRegistryProvider.notifier);
      await registry.blockForAppDataClear();
      await container.read(libreChatRegistryStoreProvider).deleteAll();
      registry.finishAppDataClear();
      release.complete();
      await signingOut;

      await refused;
      check(await SecureLibreChatSessionStore(held, account.id).read())
          .isNull();
      check(
        (await container.read(libreChatRegistryStoreProvider).read()).accounts,
      ).isEmpty();
    });

    test('a sign-in waiting on a session that is ending is not saved after '
        'a full sign-out', () async {
      final held = _HeldSessionDeletes();
      secure = held;
      final container = newContainer();
      final accounts = container.read(libreChatAccountsProvider);
      final account = await accounts.saveSignedIn(
        server: server,
        session: await signIn(),
      );
      final first =
          await container.read(libreChatSessionProvider.future)
              as LibreChatSignedInState;
      // The session in use ends, and clearing it is slow.
      final release = held.hold = Completer<void>();
      final ending = first.handle.end();
      await held.deleting.future;
      final signingIn = accounts.saveSignedIn(
        server: server,
        session: await signIn(),
      );
      final refused = check(signingIn).throws<StateError>();
      await pumpEventQueue();

      // Every account is signed out of while the sign-in waits on that clear.
      held.hold = null;
      final registry = container.read(libreChatRegistryProvider.notifier);
      await registry.blockForAppDataClear();
      await container.read(libreChatRegistryStoreProvider).deleteAll();
      registry.finishAppDataClear();
      release.complete();
      await ending;

      await refused;
      check(await SecureLibreChatSessionStore(held, account.id).read())
          .isNull();
      check(
        (await container.read(libreChatRegistryStoreProvider).read()).accounts,
      ).isEmpty();
    });

    test('a renewal while the sign-out waits does not stop it', () async {
      final accounts = container.read(libreChatAccountsProvider);
      final account = await accounts.saveSignedIn(
        server: server,
        session: await signIn(),
      );
      final release = Completer<void>();
      fake.on('POST', '/api/auth/logout', (request, match) async {
        await release.future;
        return FakeLibreChatResponse.json({'message': 'Logout successful'});
      });
      final signingOut = accounts.signOut(account.id);
      await pumpEventQueue();
      // A request renews the session meanwhile, storing what it rotated to.
      final store = SecureLibreChatSessionStore(secure, account.id);
      await store.write(await signIn());

      release.complete();
      await signingOut;
      check(await store.read()).isNull();
      check(
        (await container.read(libreChatRegistryProvider.future)).byId(
          account.id,
        ),
      ).isNull();
    });

    test('a role that cannot be read grants nothing', () async {
      fake
        ..on(
          'GET',
          '/api/endpoints',
          (request, match) => FakeLibreChatResponse.json({
            'agents': {
              'capabilities': ['web_search'],
            },
          }),
        )
        ..on(
          'GET',
          '/api/roles/(.+)',
          (request, match) => FakeLibreChatResponse.json(
            {'message': 'Unavailable'},
            statusCode: 503,
          ),
        );
      await container
          .read(libreChatAccountsProvider)
          .saveSignedIn(server: server, session: await signIn());
      await container.read(libreChatSessionProvider.future);
      await check(
        container.read(libreChatCapabilitiesProvider.future),
      ).throws<LibreChatApiException>();
    });

    test('a renewal that changes the role reads its permissions', () async {
      final user = fake.addUser(email: 'promoted@example.com');
      final roles = <String>[];
      fake
        ..on(
          'GET',
          '/api/endpoints',
          (request, match) => FakeLibreChatResponse.json({
            'agents': {'capabilities': <String>[]},
          }),
        )
        ..on('GET', '/api/roles/(.+)', (request, match) {
          roles.add(match.group(1)!);
          return FakeLibreChatResponse.json({
            'name': match.group(1),
            'permissions': <String, dynamic>{},
          });
        });
      final auth = LibreChatAuthService(server, adapter: fake);
      addTearDown(auth.close);
      final signedIn =
          await auth.signIn(email: user.email, password: user.password)
              as LibreChatSignedIn;
      await container
          .read(libreChatAccountsProvider)
          .saveSignedIn(server: server, session: signedIn.session);
      await container.read(libreChatSessionProvider.future);
      await container.read(libreChatCapabilitiesProvider.future);
      check(roles).deepEquals(['USER']);

      user.role = 'ADMIN';
      fake.expireAccessTokens();
      await container.read(libreChatApiServiceProvider)!.currentUser();
      await container.read(libreChatCapabilitiesProvider.future);
      check(roles).deepEquals(['USER', 'ADMIN']);
    });

    test('a renewal that renames the user updates the account labels',
        () async {
      final user = fake.addUser(email: 'renamed@example.com', name: 'Old');
      final auth = LibreChatAuthService(server, adapter: fake);
      addTearDown(auth.close);
      final signedIn =
          await auth.signIn(email: user.email, password: user.password)
              as LibreChatSignedIn;
      await container
          .read(libreChatAccountsProvider)
          .saveSignedIn(server: server, session: signedIn.session);
      await container.read(libreChatSessionProvider.future);
      check(
        container.read(libreChatPrimaryUserProvider)?.displayName,
      ).equals('Old');

      user.name = 'New';
      fake.expireAccessTokens();
      await container.read(libreChatApiServiceProvider)!.currentUser();
      check(
        container.read(libreChatPrimaryUserProvider)?.displayName,
      ).equals('New');
    });

    test('a full sign-out stops session writes until it is over', () async {
      final accounts = container.read(libreChatAccountsProvider);
      final account = await accounts.saveSignedIn(
        server: server,
        session: await signIn(),
      );
      final state =
          await container.read(libreChatSessionProvider.future)
              as LibreChatSignedInState;
      final registry = container.read(libreChatRegistryProvider.notifier);

      await registry.blockForAppDataClear();
      // The clear empties secure storage.
      await secure.delete(key: SecureLibreChatSessionStore.keyFor(account.id));
      // A response landing after it does not write the session back.
      await state.handle.absorbCookies(['connect.sid=late']);
      check(
        await SecureLibreChatSessionStore(secure, account.id).read(),
      ).isNull();
      await check(
        accounts.saveSignedIn(server: server, session: await signIn()),
      ).throws<StateError>();

      registry.resumeAfterAppDataClearAbort();
      await container
          .read(libreChatRegistryStoreProvider)
          .sessionStore(account.id)
          .write(state.handle.current!);
      check(
        await SecureLibreChatSessionStore(secure, account.id).read(),
      ).isNotNull();
    });

    test('accounts a full sign-out could not forget are forgotten at the '
        'next start', () async {
      final account = await container
          .read(libreChatAccountsProvider)
          .saveSignedIn(server: server, session: await signIn());
      await markLibreChatClearPending();

      final next = newContainer();
      check(
        (await next.read(libreChatRegistryProvider.future)).accounts,
      ).isEmpty();
      check(
        await SecureLibreChatSessionStore(secure, account.id).read(),
      ).isNull();
      check(
        PreferencesStore.containsKey(PreferenceKeys.libreChatClearPending),
      ).isFalse();
      check(
        await next.read(libreChatSessionProvider.future),
      ).isA<LibreChatNoAccount>();
    });

    test('accounts a failed clear left stay out until a later start clears '
        'them', () async {
      final old = await container
          .read(libreChatAccountsProvider)
          .saveSignedIn(server: server, session: await signIn());
      await markLibreChatClearPending();
      final flaky = _FlakySecureStore(await secure.readAll())
        ..failDeletes = true;
      secure = flaky;

      final next = newContainer();
      check(
        (await next.read(libreChatRegistryProvider.future)).accounts,
      ).isEmpty();
      // A new sign-in would add to the registry left behind.
      await check(
        next
            .read(libreChatAccountsProvider)
            .saveSignedIn(server: server, session: await signIn()),
      ).throws<StateError>();
      check(PreferencesStore.getBool(PreferenceKeys.libreChatClearPending))
          .equals(true);

      flaky.failDeletes = false;
      final later = newContainer();
      check(
        (await later.read(libreChatRegistryProvider.future)).accounts,
      ).isEmpty();
      check(
        await SecureLibreChatSessionStore(secure, old.id).read(),
      ).isNull();
    });

    test('an unreadable session does not stop a full sign-out', () async {
      final account = await container
          .read(libreChatAccountsProvider)
          .saveSignedIn(server: server, session: await signIn());
      secure = _FlakySecureStore(await secure.readAll())
        ..failSessionReads = true;
      final sessions = await newContainer()
          .read(libreChatAccountsProvider)
          .sessionsForSignOut();
      check(sessions.single.$1.id).equals(account.id);
      check(sessions.single.$2).isNull();
    });

    test('a full sign-out that cannot forget the accounts still ends their '
        'sessions on the server', () async {
      await container
          .read(libreChatAccountsProvider)
          .saveSignedIn(server: server, session: await signIn());
      final flaky = _FlakySecureStore(await secure.readAll());
      secure = flaky;
      final accounts = newContainer().read(libreChatAccountsProvider);
      final sessions = await accounts.sessionsForSignOut();

      flaky.failDeletes = true;
      await check(accounts.forgetAfterSignOut(sessions)).throws<StateError>();
      await pumpEventQueue();
      check(
        fake.requests.where((request) => request.path == '/api/auth/logout'),
      ).length.equals(1);
    });

    test('choosing another LibreChat account starts new chat picks',
        () async {
      final accounts = container.read(libreChatAccountsProvider);
      await accounts.saveSignedIn(server: server, session: await signIn());
      container.listen(chatPicksSessionProvider, (_, _) {});
      final before = container.read(chatPicksSessionProvider);

      const other = LibreChatServer(baseUrl: 'https://other.example.com');
      await accounts.saveSignedIn(server: other, session: await signIn(other));
      check(
        container.read(chatPicksSessionProvider),
      ).not((it) => it.identicalTo(before));
    });

    test('a quick switch back opens once the old connection closed', () async {
      const other = LibreChatServer(baseUrl: 'https://other.example.com');
      final accounts = container.read(libreChatAccountsProvider);
      final a = await accounts.saveSignedIn(
        server: server,
        session: await signIn(),
      );
      final b = await accounts.saveSignedIn(
        server: other,
        session: await signIn(other),
      );
      container.listen(libreChatDatabaseProvider, (_, _) {});
      final registry = container.read(libreChatRegistryProvider.notifier);

      Future<void> use(LibreChatAccount account) async {
        await registry.setActive(account.id);
        await container.read(libreChatSessionProvider.future);
      }

      await use(a);
      final first = container.read(libreChatDatabaseProvider)!;
      await first.customSelect('SELECT 1').get();
      opener.closeGate = Completer<void>();
      await use(b);
      check(container.read(libreChatDatabaseProvider)).isNotNull();
      // A is still closing: no second connection to its file meanwhile.
      await use(a);
      check(container.read(libreChatDatabaseProvider)).isNull();

      opener.closeGate!.complete();
      await pumpEventQueue();
      final reopened = container.read(libreChatDatabaseProvider);
      check(reopened).isNotNull().not((it) => it.identicalTo(first));
      await reopened!.customSelect('SELECT 1').get();
    });

    test('taking up an account counts as using it', () async {
      const other = LibreChatServer(baseUrl: 'https://other.example.com');
      final accounts = container.read(libreChatAccountsProvider);
      final a = await accounts.saveSignedIn(
        server: server,
        session: await signIn(),
      );
      final b = await accounts.saveSignedIn(
        server: other,
        session: await signIn(other),
      );
      await container.read(libreChatRegistryProvider.notifier).setActive(a.id);

      final registry = await container.read(libreChatRegistryProvider.future);
      check(
        registry.byId(a.id)!.lastUsedAt!,
      ).isGreaterThan(registry.byId(b.id)!.lastUsedAt!);
    });

    test('a database a sign-out could not delete stays closed until it is '
        'deleted', () async {
      final account = await container
          .read(libreChatAccountsProvider)
          .saveSignedIn(server: server, session: await signIn());
      final fileName = libreChatDatabaseFileName(account.id);
      opener.file(fileName).writeAsStringSync('');

      opener.failDirectory = true;
      await container.read(libreChatAccountsProvider).signOut(account.id);
      check(
        PreferencesStore.getString(kLibreChatPendingDatabaseWipePreference),
      ).isNotNull().contains(fileName);
      check(
        container
            .read(libreChatDatabaseManagerProvider)
            .openForServerIdIfReady(account.id),
      ).isA<DatabaseOpenDeferred>();

      // The next start deletes it before anything can open it.
      opener.failDirectory = false;
      final next = newContainer();
      await next.read(libreChatDatabaseManagerProvider).finishPendingWipe();
      check(opener.file(fileName).existsSync()).isFalse();
      check(
        PreferencesStore.containsKey(kLibreChatPendingDatabaseWipePreference),
      ).isFalse();
    });

    test('databases two sign-outs could not delete both stay pending',
        () async {
      const other = LibreChatServer(baseUrl: 'https://other.example.com');
      final accounts = container.read(libreChatAccountsProvider);
      final a = await accounts.saveSignedIn(
        server: server,
        session: await signIn(),
      );
      final b = await accounts.saveSignedIn(
        server: other,
        session: await signIn(other),
      );
      for (final account in [a, b]) {
        opener
            .file(libreChatDatabaseFileName(account.id))
            .writeAsStringSync('');
      }

      // The directory cannot be read throughout: each sign-out names only
      // its own file.
      opener.failDirectory = true;
      await accounts.signOut(a.id);
      await accounts.signOut(b.id);

      final recorded = pendingAccountDatabaseWipeFiles(
        PreferencesStore.getString(kLibreChatPendingDatabaseWipePreference)!,
      );
      check(recorded).isNotNull().deepEquals({
        libreChatDatabaseFileName(a.id),
        libreChatDatabaseFileName(b.id),
      });
    });

    test('database files stay apart from Open WebUI\'s', () {
      final name = libreChatDatabaseFileName('librechat:abc');
      check(name).startsWith('librechat_');
      check(name).not((it) => it.startsWith('server_'));
    });
  });
}
