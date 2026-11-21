@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/librechat/providers/librechat_providers.dart'
    show libreChatDatabaseProvider;
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/sync/primary_sync_provider.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/fake_librechat_chat.dart';
import 'support/null_sink.dart';

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
    final runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
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
