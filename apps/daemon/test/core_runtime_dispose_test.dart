@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:conduit_core/database/app_database.dart' show AppDatabase;
import 'package:conduit_core/database/database_provider.dart'
    show
        appDatabaseProvider,
        directLocalDatabaseProvider,
        kDirectLocalDatabaseFileName;
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart'
    show libreChatDatabaseProvider;
import 'package:conduit_core/persistence/hive_boxes.dart' show HiveBoxNames;
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/sync/primary_sync_provider.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:drift/drift.dart' show QueryExecutor, QueryInterceptor;
import 'package:hive_ce/hive.dart';
import 'package:test/test.dart';

import 'support/fake_librechat_chat.dart';
import 'support/fake_owui_auth_server.dart';
import 'support/core.dart';
import 'support/null_sink.dart';
import 'support/runtime.dart' show testBootstrapConfig;

/// Disposing the runtime while a LibreChat list refresh nobody waits on is
/// still out. The process exits, or a test deletes the directory, once
/// dispose returns: nothing may write the account database after that, and
/// a server that does not answer must not hold it up.
void main() {
  test('dispose cuts off a LibreChat refresh the server holds, and nothing '
      'writes the account database after it', () async {
    final bench = await _Bench.start();
    // The server lists the conversations only once the test lets it, which
    // is after dispose has returned.
    final listed = Completer<void>();
    final answer = Completer<void>();
    addTearDown(() {
      if (!answer.isCompleted) answer.complete();
    });
    bench.libreChat.fake.beforeAnswer = (request) async {
      if (request.method != 'GET' || request.path != '/api/convos') return;
      if (!listed.isCompleted) listed.complete();
      await answer.future;
    };

    final refreshed = bench.refresh();
    await listed.future;
    await bench.dispose();
    final writtenAtDispose = List.of(bench.writes);
    await refreshed;

    expect(
      bench.writes,
      writtenAtDispose,
      reason: 'a write came after dispose',
    );
  });

  test('dispose arriving while a LibreChat refresh writes waits for those '
      'writes', () async {
    final bench = await _Bench.start();
    // Dispose comes as the refresh stores the conversation it listed; what
    // it writes after that needs no server.
    final disposed = Completer<Future<void>>();
    final stored = bench.database.tableUpdates().listen((updates) {
      if (disposed.isCompleted) return;
      if (updates.any((update) => update.table == 'messages')) {
        disposed.complete(bench.dispose());
      }
    });
    addTearDown(stored.cancel);

    final refreshed = bench.refresh();
    await (await disposed.future);
    final writtenAtDispose = List.of(bench.writes);
    await refreshed;

    expect(
      writtenAtDispose,
      contains('sync_meta'),
      reason: "the refresh's watermark landed after dispose returned",
    );
    expect(
      bench.writes,
      writtenAtDispose,
      reason: 'a write came after dispose',
    );
  });

  test('dispose returns once the Open WebUI account database is closed', () async {
    addTearDown(PreferencesStore.debugReset);
    final temporary = Directory.systemTemp.createTempSync('runtime-dispose');
    addTearDown(() => temporary.deleteSync(recursive: true));
    final runtime = await startTestCore(temporary);
    addTearDown(runtime.dispose);
    final database = await _openWebUiDatabase(runtime);

    await runtime.dispose();

    await expectLater(
      database.customSelect('SELECT 1').get(),
      throwsA(anything),
      reason: 'the database was still open once dispose returned',
    );
  });

  test('a database that fails to close stops nothing else: the others and '
      "the host's stores close, and the daemon stops", () async {
    addTearDown(PreferencesStore.debugReset);
    final temporary = Directory.systemTemp.createTempSync('runtime-dispose');
    addTearDown(() => temporary.deleteSync(recursive: true));
    final runtime = await startTestCore(
      temporary,
      interceptDatabase: (fileName) =>
          fileName == kDirectLocalDatabaseFileName ? _CloseFails() : null,
    );
    addTearDown(runtime.dispose);
    final direct = runtime.container.read(directLocalDatabaseProvider);
    await direct.customSelect('SELECT 1').get();
    final account = await _openWebUiDatabase(runtime);
    final daemon = DaemonServer(
      config: testBootstrapConfig(temporary),
      directories: DaemonDirectories.create(temporary.path),
      daemonVersion: '0.0.0-test',
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    addTearDown(daemon.stop);
    await daemon.start();
    daemon.attachCore(runtime);

    await daemon.stop();
    await daemon.onStopped;
    await daemon.stop();
    await runtime.dispose();

    await expectLater(
      account.customSelect('SELECT 1').get(),
      throwsA(anything),
      reason: 'the account database was left open',
    );
    expect(Hive.isBoxOpen(HiveBoxNames.preferences), isFalse);
  });
}

/// Fails every close, as a database whose file went away would.
final class _CloseFails extends QueryInterceptor {
  @override
  Future<void> close(QueryExecutor inner) async {
    await inner.close();
    throw StateError('the database could not be closed');
  }
}

/// The Open WebUI account database of [runtime], once it is signed in to a
/// fake server and the database is open.
Future<AppDatabase> _openWebUiDatabase(CoreRuntime runtime) async {
  final owui = await FakeOwuiAuthServer.start(
    users: const {
      'ada@example.com': (id: 'user-ada', name: 'Ada', password: 'pw-ada'),
    },
  );
  addTearDown(owui.close);
  final accounts = AccountsService(runtime.container, events: EventBus());
  addTearDown(accounts.dispose);
  final auth = AuthService(runtime.container);
  addTearDown(auth.dispose);
  await accounts.add(
    AddAccount(server: ServerDraft(name: 'Lab', url: owui.url), force: true),
  );
  await auth.loginWithPassword(
    const PasswordLogin(username: 'ada@example.com', password: 'pw-ada'),
  );
  final opened = Completer<AppDatabase>();
  final watch = runtime.container.listen<AppDatabase?>(appDatabaseProvider, (
    _,
    database,
  ) {
    if (database != null && !opened.isCompleted) opened.complete(database);
  }, fireImmediately: true);
  addTearDown(watch.close);
  final database = await opened.future;
  await database.customSelect('SELECT 1').get();
  return database;
}

/// A runtime signed in to a fake LibreChat server that has one conversation
/// for the next refresh to store, and the tables the account database
/// writes from then on.
final class _Bench {
  _Bench._(this.runtime, this.libreChat, this._accounts);

  final CoreRuntime runtime;
  final FakeLibreChatChat libreChat;
  final AccountsService _accounts;
  final List<String> writes = <String>[];
  late final database = runtime.container.read(libreChatDatabaseProvider)!;
  Future<void>? _disposing;

  static Future<_Bench> start() async {
    // Each runtime reads its own preferences: the store is the process's.
    addTearDown(PreferencesStore.debugReset);
    final temporary = Directory.systemTemp.createTempSync('runtime-dispose');
    addTearDown(() => temporary.deleteSync(recursive: true));
    final runtime = await startTestCore(temporary);
    final libreChat = await FakeLibreChatChat.start();
    addTearDown(libreChat.close);
    libreChat.fake.addUser(email: 'avery@example.com', password: 'pw-avery');
    final events = EventBus();
    final accounts = AccountsService(runtime.container, events: events);
    final bench = _Bench._(runtime, libreChat, accounts);
    addTearDown(bench.dispose);
    final signedIn =
        await LibreChatService(
          runtime.container,
          events: events,
          accounts: accounts,
        ).signIn(
          LibreChatSignIn(
            url: libreChat.url,
            email: 'avery@example.com',
            password: 'pw-avery',
          ),
        );
    expect(signedIn.outcome, LibreChatSignInOutcome.signedIn);
    libreChat.fake.addConversation(
      'conv-trail',
      title: 'Trail snacks',
      messageList: const [
        {
          'messageId': 'trail-q',
          'parentMessageId': '00000000-0000-0000-0000-000000000000',
          'isCreatedByUser': true,
          'text': 'Snacks for a ridge walk?',
          'createdAt': '2026-10-18T10:00:00.000Z',
        },
        {
          'messageId': 'trail-a',
          'parentMessageId': 'trail-q',
          'isCreatedByUser': false,
          'text': 'Dates and almonds.',
          'createdAt': '2026-10-18T10:00:05.000Z',
        },
      ],
    );
    final watch = bench.database.tableUpdates().listen(
      (updates) => bench.writes.addAll(updates.map((update) => update.table)),
    );
    addTearDown(watch.cancel);
    return bench;
  }

  /// The refresh a settled turn asks for, which nothing waits on.
  Future<Object?> refresh() => runtime.container
      .read(primarySyncProvider)
      .requestPull(reason: 'cache-refresh');

  Future<void> dispose() => _disposing ??= () {
    _accounts.dispose();
    return runtime.dispose();
  }();
}
