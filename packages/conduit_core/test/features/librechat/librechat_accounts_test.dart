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
import 'package:conduit_core/features/librechat/services/librechat_session_store.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/database_opener.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
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

    test('database files stay apart from Open WebUI\'s', () {
      final name = libreChatDatabaseFileName('librechat:abc');
      check(name).startsWith('librechat_');
      check(name).not((it) => it.startsWith('server_'));
    });
  });
}
