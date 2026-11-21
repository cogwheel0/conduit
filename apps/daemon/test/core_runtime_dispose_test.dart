@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/librechat/providers/librechat_providers.dart'
    show libreChatDatabaseProvider;
import 'package:conduit_core/sync/primary_sync_provider.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/fake_librechat_chat.dart';
import 'support/null_sink.dart';

/// Disposing the runtime while work it started still writes the account
/// database. The process exits, or a test deletes the directory, once
/// dispose returns.
void main() {
  test('dispose waits for a LibreChat list refresh still out, and nothing '
      'writes the account database after it', () async {
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
    Future<void>? disposing;
    addTearDown(() => disposing ??= runtime.dispose());
    final libreChat = await FakeLibreChatChat.start();
    addTearDown(libreChat.close);
    libreChat.fake.addUser(email: 'avery@example.com', password: 'pw-avery');
    final events = EventBus();
    final accounts = AccountsService(runtime.container, events: events);
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

    // The server lists the conversations only once the test lets it, and
    // the list then has a new one to store.
    final listed = Completer<void>();
    final answer = Completer<void>();
    libreChat.fake.beforeAnswer = (request) async {
      if (request.method != 'GET' ||
          request.path != '/api/convos' ||
          answer.isCompleted) {
        return;
      }
      if (!listed.isCompleted) listed.complete();
      await answer.future;
    };
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
    final database = runtime.container.read(libreChatDatabaseProvider)!;
    final writes = <String>[];
    final watch = database.tableUpdates().listen(
      (updates) => writes.addAll(updates.map((update) => update.table)),
    );
    addTearDown(watch.cancel);

    final refreshed = runtime.container
        .read(primarySyncProvider)
        .requestPull(reason: 'cache-refresh');
    await listed.future;
    accounts.dispose();
    final disposed = disposing = runtime.dispose();
    answer.complete();
    late final List<String> writtenBeforeDispose;
    await Future.wait<Object?>([
      refreshed,
      disposed.then((_) => writtenBeforeDispose = List.of(writes)),
    ]);

    expect(
      writtenBeforeDispose,
      contains('messages'),
      reason: 'dispose returned before the refresh stored what it listed',
    );
    expect(writes, writtenBeforeDispose, reason: 'a write came after dispose');
  });
}
