@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/database/app_database.dart' show AppDatabase;
import 'package:conduit_core/database/database_provider.dart'
    show appDatabaseProvider, openWebUiCertifiedDatabaseServerProvider;
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/sync/primary_sync_provider.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:drift/drift.dart' show Value;
import 'package:test/test.dart';

import 'support/fake_owui_auth_server.dart';
import 'support/null_sink.dart';

const _chatId = 'chat-shelf';

/// Disposing the runtime while Open WebUI sync work nobody waits on is still
/// out: the first pull after sign-in, or the outbox drain a shutdown's flush
/// gave up on. The process exits, or a test deletes the directory, once
/// dispose returns: nothing may write the account database after that, and
/// a server that does not answer must not hold it up.
void main() {
  test('dispose cuts off a pull the server holds, and nothing writes the '
      'account database after it', () async {
    final bench = await _Bench.start(holdChatReads: true);
    await bench.owui.chats.chatReadAsked.future;
    bench.recordWrites();

    await bench.dispose();
    final writtenAtDispose = List.of(bench.writes);
    bench.owui.chats.holdChatReads!.complete();
    await bench.firstPull;

    expect(
      bench.writes,
      writtenAtDispose,
      reason: 'a write came after dispose',
    );
  });

  test('dispose cuts off the drain a flush gave up on, and the outcome the '
      'drain records lands before dispose returns', () async {
    final bench = await _Bench.start();
    await bench.firstPull;
    final saved = bench.hold(bench.owui.chats.holdChatSaves = Completer());
    await bench.database.chatsDao.updateEnvelopeWithOutbox(
      _chatId,
      title: const Value('Shelf labels'),
      enqueue: true,
    );

    final pending = await bench.runtime.flushOutbox(budget: Duration.zero);
    await bench.owui.chats.chatSaveAsked.future;
    bench.recordWrites();
    await bench.dispose();
    final writtenAtDispose = List.of(bench.writes);
    saved.complete();

    expect(pending, 1);
    expect(
      writtenAtDispose,
      contains('outbox_ops'),
      reason: "the drain's outcome landed after dispose returned",
    );
  });
}

/// A runtime signed in to a fake Open WebUI server that keeps one chat, and
/// the first pull certification asks for, which reads it.
final class _Bench {
  _Bench._(this.runtime, this.owui, this._accounts, this._auth);

  final CoreRuntime runtime;
  final FakeOwuiAuthServer owui;
  final AccountsService _accounts;
  final AuthService _auth;
  late final Future<Object?> firstPull;
  final List<String> writes = <String>[];
  late final AppDatabase database = runtime.container.read(
    appDatabaseProvider,
  )!;
  Future<void>? _disposing;

  static Future<_Bench> start({bool holdChatReads = false}) async {
    // Each runtime reads its own preferences: the store is the process's.
    addTearDown(PreferencesStore.debugReset);
    final temporary = Directory.systemTemp.createTempSync('owui-dispose');
    addTearDown(() => temporary.deleteSync(recursive: true));
    final runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    final owui =
        await FakeOwuiAuthServer.start(
            users: const {
              'ada@example.com': (
                id: 'user-ada',
                name: 'Ada',
                password: 'pw-ada',
              ),
            },
          )
          ..models = const ['kettle-model'];
    addTearDown(owui.close);
    owui.chats.seed(_chatId, userId: 'user-ada', title: 'Shelf');
    final events = EventBus();
    final accounts = AccountsService(runtime.container, events: events);
    final auth = AuthService(runtime.container);
    final bench = _Bench._(runtime, owui, accounts, auth);
    addTearDown(bench.dispose);
    if (holdChatReads) bench.hold(owui.chats.holdChatReads = Completer());

    // Certification asks for the first pull once it has opened the
    // database, later in the task that announces it: joining it from a
    // microtask joins that pull before it starts.
    final asked = Completer<void>();
    final certified = runtime.container.listen<Object?>(
      openWebUiCertifiedDatabaseServerProvider,
      (_, next) {
        if (next == null || asked.isCompleted) return;
        scheduleMicrotask(() {
          bench.firstPull = runtime.container
              .read(primarySyncProvider)
              .requestPull(reason: 'cache-refresh');
          asked.complete();
        });
      },
    );
    await accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Lab', url: owui.url),
        force: true,
      ),
    );
    await auth.loginWithPassword(
      const PasswordLogin(username: 'ada@example.com', password: 'pw-ada'),
    );
    await asked.future;
    certified.close();
    return bench;
  }

  /// Lets the server answer what [held] holds once the test ends, before
  /// the runtime is disposed.
  Completer<void> hold(Completer<void> held) {
    addTearDown(() {
      if (!held.isCompleted) held.complete();
    });
    return held;
  }

  /// Records the tables the account database writes from now on.
  void recordWrites() {
    final watch = database.tableUpdates().listen(
      (updates) => writes.addAll(updates.map((update) => update.table)),
    );
    addTearDown(watch.cancel);
  }

  Future<void> dispose() => _disposing ??= () {
    _accounts.dispose();
    _auth.dispose();
    return runtime.dispose();
  }();
}
