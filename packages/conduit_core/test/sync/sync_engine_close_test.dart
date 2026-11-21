import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/sync/sync_api_client.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/testing.dart';
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

void main() {
  test('close waits for a pull still storing the chat it read, and a '
      'closed engine starts no more', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final server = FakeOpenWebUiServer()
      ..seedChat(
        id: 'chat-1',
        blob: const <String, dynamic>{'title': 'Kettle'},
        createdAt: 100,
        updatedAt: 150,
      );
    final client = FakeSyncApiClient(server);
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(database: db),
        isAuthenticatedProvider2.overrideWithValue(true),
        reviewerModeProvider.overrideWithValue(false),
        currentUserProvider2.overrideWithValue(
          const User(
            id: FakeOpenWebUiServer.userId,
            username: 'ada',
            email: 'ada@example.com',
            role: 'user',
          ),
        ),
        socketServiceProvider.overrideWithValue(null),
        syncApiClientProvider.overrideWith((ref) => client),
      ],
    );
    addTearDown(container.dispose);
    container.listen(syncEngineProvider, (_, _) {});
    final engine = container.read(syncEngineProvider.notifier);
    // The test's own transaction keeps the pull's write waiting on the
    // database.
    final holding = Completer<void>();
    final release = Completer<void>();
    final transaction = db.transaction(() async {
      holding.complete();
      await release.future;
    });
    await holding.future;
    final ended = <String>[];

    final pulled = engine
        .pullChatNow('chat-1')
        .then((_) => ended.add('pulled'));
    final closed = engine.close().then((_) => ended.add('closed'));
    release.complete();
    await Future.wait<void>([transaction, pulled, closed]);

    check(ended).deepEquals(['pulled', 'closed']);
    check(await db.chatsDao.getChat('chat-1')).isNotNull();
    check(await engine.requestPull(reason: 'after close')).isNull();
    check(await engine.pullChatNow('chat-1')).isNull();
    check(client.chatFetchStarts).deepEquals(['chat-1']);
  });
}
