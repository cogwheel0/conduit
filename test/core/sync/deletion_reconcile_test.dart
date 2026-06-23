import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/daos/outbox_dao.dart';
import 'package:conduit/core/sync/chat_locks.dart';
import 'package:conduit/core/sync/clock.dart';
import 'package:conduit/core/sync/deletion_reconcile.dart';
import 'package:conduit/core/sync/pull_sync.dart'
    show kOpenWebUiChatListPageSize;
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_open_webui_server.dart';
import '../../support/fake_sync_api_client.dart';

class FakeSyncClock implements SyncClock {
  int now = 0;
  @override
  int nowEpochSeconds() => now;
}

/// A client whose session dies after enumeration but before the purge phase.
class _SessionDyingClient extends FakeSyncApiClient {
  _SessionDyingClient(super.server);

  var pageOneCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> getChatListPage(int page) {
    if (page == 1) {
      pageOneCalls++;
      if (pageOneCalls > 1) {
        throw StateError('injected main list failure (liveness)');
      }
    }
    return super.getChatListPage(page);
  }
}

/// A client that models broken pagination by returning page 1 for every main
/// list page request.
class _RepeatingFirstPageClient extends FakeSyncApiClient {
  _RepeatingFirstPageClient(super.server);

  final pages = <int>[];

  @override
  Future<List<Map<String, dynamic>>> getChatListPage(int page) {
    pages.add(page);
    if (page > 2) {
      throw StateError('pagination did not stop after a duplicate full page');
    }
    return super.getChatListPage(1);
  }
}

/// A client whose preflight liveness check succeeds, then the per-chat probe
/// sees a real auth failure rather than the vendored NOT_FOUND 401.
class _AuthFailingProbeClient extends FakeSyncApiClient {
  _AuthFailingProbeClient(
    super.server, {
    this.authFailureAfterSuccessfulProbes = 0,
  });

  final int authFailureAfterSuccessfulProbes;

  @override
  Future<bool> probeChatExists(String id) async {
    probeChatExistsCalls++;
    await Future<void>.delayed(Duration.zero);
    if (probeChatExistsCalls <= authFailureAfterSuccessfulProbes) {
      return false;
    }
    final requestOptions = RequestOptions(path: '/api/v1/chats/$id');
    throw DioException(
      requestOptions: requestOptions,
      response: Response<Map<String, dynamic>>(
        requestOptions: requestOptions,
        statusCode: 401,
        data: const {'detail': 'token expired'},
      ),
    );
  }
}

/// Seeds a server-keyed (NON-`local:`) chat row directly, body-synced, clean.
Future<void> seedServerChat(
  AppDatabase db, {
  required String id,
  bool deleted = false,
  int updatedAt = 100,
}) async {
  await db
      .into(db.chats)
      .insert(
        ChatsCompanion.insert(
          id: id,
          title: 'Title $id',
          createdAt: 50,
          updatedAt: updatedAt,
          serverUpdatedAt: Value(updatedAt),
          dirty: const Value(false),
          deleted: Value(deleted),
          bodySynced: const Value(true),
          rawExtra: const Value('{}'),
          blobMeta: const Value('{}'),
        ),
      );
}

void main() {
  late FakeOpenWebUiServer server;
  late FakeSyncApiClient client;
  late AppDatabase db;
  late ConversationLocks locks;
  late FakeSyncClock clock;
  late DeletionReconcile reconcile;

  setUp(() {
    server = FakeOpenWebUiServer(nowEpochSeconds: () => 7000);
    client = FakeSyncApiClient(server);
    db = AppDatabase(NativeDatabase.memory());
    locks = ConversationLocks();
    clock = FakeSyncClock()..now = 1_000_000;
    reconcile = DeletionReconcile(
      client: client,
      db: db,
      locks: locks,
      clock: clock,
    );
  });

  tearDown(() async {
    await db.close();
  });

  Map<String, dynamic> blobFor(String id) => <String, dynamic>{
    'id': '',
    'title': 'Title $id',
    'history': <String, dynamic>{
      'messages': <String, dynamic>{},
      'currentId': null,
    },
  };

  group('pagination absence is NOT a delete signal', () {
    test(
      'server list enumeration stops when a full page adds no new ids',
      () async {
        for (var i = 0; i < kOpenWebUiChatListPageSize; i++) {
          final id = 'chat-${i.toString().padLeft(2, '0')}';
          server.seedChat(
            id: id,
            blob: blobFor(id),
            createdAt: 50,
            updatedAt: 100 + i,
          );
          await seedServerChat(db, id: id);
        }
        final repeatingClient = _RepeatingFirstPageClient(server);
        reconcile = DeletionReconcile(
          client: repeatingClient,
          db: db,
          locks: locks,
          clock: clock,
        );

        final result = await reconcile.run(ReconcileReason.manualRefresh);

        check(result.ran).isTrue();
        check(result.candidates).equals(0);
        check(result.purged).equals(0);
        check(repeatingClient.pages).deepEquals([1, 2]);
      },
    );

    test('a chat present on the server but absent from the page set is NOT '
        'purged — the probe confirms it still exists', () async {
      // Both chats exist on the server AND locally.
      for (final id in ['present', 'gappy']) {
        server.seedChat(
          id: id,
          blob: blobFor(id),
          createdAt: 50,
          updatedAt: 100,
        );
        await seedServerChat(db, id: id);
      }

      // Model a pagination race/gap: 'gappy' is dropped from BOTH list
      // enumerations (so the diff flags it as a candidate) while the per-chat
      // probe still finds it on the server.
      client.hideFromListIds.add('gappy');

      final result = await reconcile.run(ReconcileReason.manualRefresh);

      check(result.ran).isTrue();
      check(result.candidates).equals(1); // gappy was a candidate
      check(result.purged).equals(0); // but probe found it -> NOT purged
      check(result.skipped).equals(1);
      check(client.probeChatExistsCalls).equals(1);

      // Both chats survive.
      check(await db.chatsDao.getChat('present')).isNotNull();
      check(await db.chatsDao.getChat('gappy')).isNotNull();
    });
  });

  group('confirmed server delete purges after reconcile', () {
    test(
      'a true server 404 (gone) purges the local chat + its pending ops',
      () async {
        server.seedChat(
          id: 'alive',
          blob: blobFor('alive'),
          createdAt: 50,
          updatedAt: 100,
        );
        await seedServerChat(db, id: 'alive');

        // 'ghost' exists locally but NOT on the server: absent from the list AND
        // the probe reports gone (404).
        await seedServerChat(db, id: 'ghost');
        client.nullChatIds.add('ghost'); // probe -> false (gone)

        // A stale pending op for the ghost should be dropped on purge.
        await db
            .into(db.outboxOps)
            .insert(
              OutboxOpsCompanion.insert(
                kind: OutboxKind.updateChat.name,
                chatId: const Value('ghost'),
                payload: const Value('{}'),
              ),
            );

        final result = await reconcile.run(ReconcileReason.manualRefresh);

        check(result.purged).equals(1);
        check(result.candidates).equals(1);
        check(await db.chatsDao.getChat('ghost')).isNull();
        check(await db.chatsDao.getChat('alive')).isNotNull();
        final ops = await db.outboxDao.pendingForChat('ghost');
        check(ops).isEmpty();
      },
    );

    test(
      'a 401 NOT_FOUND (vendored normal-user not-ours) also counts as gone',
      () async {
        // A surviving server chat keeps the candidate fraction under the safety
        // valve threshold.
        for (final id in ['s1', 's2', 's3']) {
          server.seedChat(
            id: id,
            blob: blobFor(id),
            createdAt: 50,
            updatedAt: 100,
          );
          await seedServerChat(db, id: id);
        }
        await seedServerChat(db, id: 'ghost401');
        client.probe401GoneIds.add('ghost401');

        final result = await reconcile.run(ReconcileReason.manualRefresh);
        check(result.purged).equals(1);
        check(await db.chatsDao.getChat('ghost401')).isNull();
      },
    );

    test('a session that dies mid-run (liveness ping fails) ABORTS without '
        'purging any candidate or advancing the throttle', () async {
      // Three live server chats keep the candidate fraction under the safety
      // valve; one ghost would otherwise be purged.
      for (final id in ['s1', 's2', 's3']) {
        server.seedChat(
          id: id,
          blob: blobFor(id),
          createdAt: 50,
          updatedAt: 100,
        );
        await seedServerChat(db, id: id);
      }
      await seedServerChat(db, id: 'ghost401');

      // The probe would report the ghost gone (a 401), but the SESSION is dead
      // before the purge phase. The single pre-purge liveness check must catch
      // it and abort.
      final dying = _SessionDyingClient(server)
        ..probe401GoneIds.add('ghost401');
      final dyingReconcile = DeletionReconcile(
        client: dying,
        db: db,
        locks: locks,
        clock: clock,
      );

      final result = await dyingReconcile.run(ReconcileReason.manualRefresh);

      check(result.aborted).isTrue();
      check(result.purged).equals(0);
      check(result.skipped).equals(1);
      check(dying.probeChatExistsCalls).equals(0);
      // The ghost is NOT purged — its 401 was ambiguous with the dead token.
      check(await db.chatsDao.getChat('ghost401')).isNotNull();
      // Throttle not advanced: a later authenticated run retries.
      check(await db.syncMetaDao.getLastFullReconcileAt()).equals(0);
    });

    test(
      'liveness is checked once for multiple confirmed-gone candidates',
      () async {
        for (final id in ['s1', 's2', 's3']) {
          server.seedChat(
            id: id,
            blob: blobFor(id),
            createdAt: 50,
            updatedAt: 100,
          );
          await seedServerChat(db, id: id);
        }
        for (final id in ['ghost-a', 'ghost-b']) {
          await seedServerChat(db, id: id);
        }

        client.probe401GoneIds.addAll(['ghost-a', 'ghost-b']);

        final result = await reconcile.run(ReconcileReason.manualRefresh);

        check(result.aborted).isFalse();
        check(result.purged).equals(2);
        check(result.skipped).equals(0);
        check(client.probeChatExistsCalls).equals(2);
        // One main-list fetch for enumeration, one for the pre-purge liveness
        // check; not one liveness request per candidate.
        check(client.chatListPageRequests).equals(2);
        check(await db.chatsDao.getChat('ghost-a')).isNull();
        check(await db.chatsDao.getChat('ghost-b')).isNull();
      },
    );

    test(
      'a transient probe error SKIPS (does not purge) the candidate',
      () async {
        for (final id in ['s1', 's2', 's3']) {
          server.seedChat(
            id: id,
            blob: blobFor(id),
            createdAt: 50,
            updatedAt: 100,
          );
          await seedServerChat(db, id: id);
        }
        await seedServerChat(db, id: 'flaky');
        client.probeThrowIds.add('flaky');

        final result = await reconcile.run(ReconcileReason.manualRefresh);
        check(result.purged).equals(0);
        check(result.skipped).equals(1);
        // Survives this run; reconcile is best-effort + re-runs.
        check(await db.chatsDao.getChat('flaky')).isNotNull();
      },
    );

    test(
      'a terminal probe auth failure aborts without advancing the throttle',
      () async {
        final authFailing = _AuthFailingProbeClient(server);
        final authFailingReconcile = DeletionReconcile(
          client: authFailing,
          db: db,
          locks: locks,
          clock: clock,
        );
        await seedServerChat(db, id: 'auth-failed');

        final result = await authFailingReconcile.run(
          ReconcileReason.manualRefresh,
        );

        check(result.aborted).isTrue();
        check(result.purged).equals(0);
        check(result.skipped).equals(1);
        check(authFailing.probeChatExistsCalls).equals(1);
        check(await db.chatsDao.getChat('auth-failed')).isNotNull();
        check(await db.syncMetaDao.getLastFullReconcileAt()).equals(0);
      },
    );

    test(
      'a mid-loop terminal auth failure aborts without advancing the throttle',
      () async {
        final authFailing = _AuthFailingProbeClient(
          server,
          authFailureAfterSuccessfulProbes: 1,
        );
        final authFailingReconcile = DeletionReconcile(
          client: authFailing,
          db: db,
          locks: locks,
          clock: clock,
        );
        await seedServerChat(db, id: 'ghost-1');
        await seedServerChat(db, id: 'ghost-2');

        final result = await authFailingReconcile.run(
          ReconcileReason.manualRefresh,
        );

        check(result.aborted).isTrue();
        check(result.purged).equals(1);
        check(result.skipped).equals(1);
        check(authFailing.probeChatExistsCalls).equals(2);
        final remaining = [
          await db.chatsDao.getChat('ghost-1'),
          await db.chatsDao.getChat('ghost-2'),
        ].whereType<ChatRow>().toList();
        check(remaining.length).equals(1);
        check(await db.syncMetaDao.getLastFullReconcileAt()).equals(0);
      },
    );
  });

  group('local: chats are never candidates', () {
    test('a local:-keyed chat absent from the server is left alone', () async {
      await db
          .into(db.chats)
          .insert(
            ChatsCompanion.insert(
              id: 'local:fresh',
              title: 'Fresh',
              createdAt: 50,
              updatedAt: 100,
              dirty: const Value(true),
              bodySynced: const Value(true),
              rawExtra: const Value('{}'),
              blobMeta: const Value('{}'),
            ),
          );

      final result = await reconcile.run(ReconcileReason.manualRefresh);
      check(result.candidates).equals(0);
      check(result.purged).equals(0);
      check(await db.chatsDao.getChat('local:fresh')).isNotNull();
    });

    test('an already-tombstoned chat is not a reconcile candidate', () async {
      await seedServerChat(db, id: 'tombstoned', deleted: true);
      final result = await reconcile.run(ReconcileReason.manualRefresh);
      check(result.candidates).equals(0);
    });
  });

  group('throttle (≤ once / 24h + manual override)', () {
    test('background reason is throttled to once per 24h', () async {
      await seedServerChat(db, id: 'a');
      server.seedChat(
        id: 'a',
        blob: blobFor('a'),
        createdAt: 50,
        updatedAt: 100,
      );

      // First background run executes + records last_full_reconcile_at.
      final first = await reconcile.run(ReconcileReason.background);
      check(first.ran).isTrue();
      check(await db.syncMetaDao.getLastFullReconcileAt()).equals(1_000_000);

      // A second background run < 24h later is skipped entirely.
      clock.now = 1_000_000 + 86399;
      final second = await reconcile.run(ReconcileReason.background);
      check(second.ran).isFalse();

      // Past 24h it runs again.
      clock.now = 1_000_000 + 86400;
      final third = await reconcile.run(ReconcileReason.background);
      check(third.ran).isTrue();
    });

    test('manualRefresh bypasses the throttle', () async {
      await reconcile.run(ReconcileReason.background); // sets the gate
      clock.now = 1_000_000 + 10; // well within 24h
      final manual = await reconcile.run(ReconcileReason.manualRefresh);
      check(manual.ran).isTrue();
    });

    test('an enumeration failure does NOT advance the throttle', () async {
      await seedServerChat(db, id: 'a');
      client.failChatListPages.add(1);

      final result = await reconcile.run(ReconcileReason.manualRefresh);
      check(result.ran).isFalse();
      // Gate untouched so the next trigger retries.
      check(await db.syncMetaDao.getLastFullReconcileAt()).equals(0);
    });
  });

  group('safety valve against a token-expiry mass-delete', () {
    test('aborts (purges nothing) when candidates exceed the floor AND half '
        'the local set', () async {
      // 8 local server chats, NONE on the server list -> all 8 candidates,
      // above both the absolute floor (5) and 50% -> abort.
      final ids = List.generate(8, (i) => 'c$i');
      for (final id in ids) {
        await seedServerChat(db, id: id);
        client.probe401GoneIds.add(id); // would be "gone" if probed
      }

      final result = await reconcile.run(ReconcileReason.manualRefresh);
      check(result.aborted).isTrue();
      check(result.purged).equals(0);
      // Nothing probed (aborted before the probe loop).
      check(client.probeChatExistsCalls).equals(0);
      for (final id in ids) {
        check(await db.chatsDao.getChat(id)).isNotNull();
      }
      // Abort does NOT advance the throttle (retried, not suppressed).
      check(await db.syncMetaDao.getLastFullReconcileAt()).equals(0);
    });

    test(
      'a SMALL library is NOT blocked: a single genuinely-deleted chat is '
      'purged (regression — the fraction valve must not trip below the floor)',
      () async {
        // The user has one server chat; it was deleted on the server. Old bug:
        // 1 > 1*0.5 tripped the valve and the phantom row never purged.
        await seedServerChat(db, id: 'only');
        client.nullChatIds.add('only'); // probe -> gone

        final result = await reconcile.run(ReconcileReason.manualRefresh);
        check(result.aborted).isFalse();
        check(result.candidates).equals(1);
        check(result.purged).equals(1);
        check(await db.chatsDao.getChat('only')).isNull();
      },
    );
  });

  group('idempotence', () {
    test('a second reconcile after a purge is a no-op', () async {
      server.seedChat(
        id: 'keep',
        blob: blobFor('keep'),
        createdAt: 50,
        updatedAt: 100,
      );
      await seedServerChat(db, id: 'keep');
      await seedServerChat(db, id: 'gone');
      client.nullChatIds.add('gone');

      final first = await reconcile.run(ReconcileReason.manualRefresh);
      check(first.purged).equals(1);

      final second = await reconcile.run(ReconcileReason.manualRefresh);
      check(second.candidates).equals(0);
      check(second.purged).equals(0);
    });
  });
}
