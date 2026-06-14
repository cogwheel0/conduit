import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/daos/outbox_dao.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late OutboxDao dao;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    dao = db.outboxDao;
  });

  tearDown(() async {
    await db.close();
  });

  // enqueue methods MUST run inside an open transaction (REQ §7.2.1). The DAO
  // helper mirrors how the extended ChatsDao mutation methods will call it.
  Future<int> enqueue({
    required OutboxKind kind,
    String? chatId,
    Map<String, dynamic> payload = const {},
    String? contentHash,
  }) {
    return db.transaction(
      () => dao.enqueue(
        kind: kind,
        chatId: chatId,
        payload: payload,
        contentHash: contentHash,
      ),
    );
  }

  group('OutboxKind', () {
    test('round-trips every kind name', () {
      for (final kind in OutboxKind.values) {
        check(OutboxKind.fromName(kind.name)).equals(kind);
      }
    });

    test('returns null for an unknown name', () {
      check(OutboxKind.fromName('garbage')).isNull();
    });
  });

  group('enqueue payload validation (A1)', () {
    test('createChat requires empty payload + contentHash', () async {
      await check(
        enqueue(
          kind: OutboxKind.createChat,
          chatId: 'local:a',
          contentHash: 'h',
        ),
      ).completes();

      await check(
        enqueue(
          kind: OutboxKind.createChat,
          chatId: 'local:b',
          payload: {'x': 1},
          contentHash: 'h',
        ),
      ).throws<ArgumentError>();

      await check(
        enqueue(kind: OutboxKind.createChat, chatId: 'local:c'),
      ).throws<ArgumentError>();
    });

    test('updateChat/deleteChat require empty payloads', () async {
      await check(
        enqueue(kind: OutboxKind.updateChat, chatId: 'c1', payload: {'x': 1}),
      ).throws<ArgumentError>();
      await check(
        enqueue(kind: OutboxKind.deleteChat, chatId: 'c1', payload: {'x': 1}),
      ).throws<ArgumentError>();
    });

    test('requestCompletion requires the typed fields', () async {
      await check(
        enqueue(
          kind: OutboxKind.requestCompletion,
          chatId: 'c1',
          payload: {'model': 'm', 'toolIds': <String>[]},
        ),
      ).throws<ArgumentError>(); // missing assistantMessageId

      await check(
        enqueue(
          kind: OutboxKind.requestCompletion,
          chatId: 'c1',
          payload: {
            'assistantMessageId': 'a1',
            'model': 'gpt',
            'toolIds': <String>[],
            'filterIds': null,
            'systemPrompt': null,
            'sessionIdOverride': null,
          },
        ),
      ).completes();
    });

    test('folderUpsert/folderDelete require folderId', () async {
      await check(
        enqueue(
          kind: OutboxKind.folderUpsert,
          chatId: 'f1',
          payload: {'createIfAbsent': true},
        ),
      ).throws<ArgumentError>();
      await check(
        enqueue(kind: OutboxKind.folderDelete, chatId: 'f1', payload: {}),
      ).throws<ArgumentError>();
    });
  });

  group('basic enqueue + readback', () {
    test('inserts pending op with attempts=0, no nextAttemptAt', () async {
      final seq = await enqueue(kind: OutboxKind.deleteChat, chatId: 'c1');
      final pending = await dao.pendingForChat('c1');
      check(pending).length.equals(1);
      check(pending.single.seq).equals(seq);
      check(pending.single.kind).equals('deleteChat');
      check(pending.single.status).equals('pending');
      check(pending.single.attempts).equals(0);
      check(pending.single.nextAttemptAt).isNull();
    });
  });

  group('coalescing (A3)', () {
    test('createChat + updateChat collapses into the create', () async {
      final create = await enqueue(
        kind: OutboxKind.createChat,
        chatId: 'local:x',
        contentHash: 'h',
      );
      final surviving = await enqueue(
        kind: OutboxKind.updateChat,
        chatId: 'local:x',
      );
      // The update collapses; the create is the survivor.
      check(surviving).equals(create);
      final pending = await dao.pendingForChat('local:x');
      check(pending).length.equals(1);
      check(pending.single.kind).equals('createChat');
    });

    test(
      'consecutive updateChat collapse to the single pending update',
      () async {
        final first = await enqueue(kind: OutboxKind.updateChat, chatId: 'c1');
        final second = await enqueue(kind: OutboxKind.updateChat, chatId: 'c1');
        final third = await enqueue(kind: OutboxKind.updateChat, chatId: 'c1');
        check(second).equals(first);
        check(third).equals(first);
        final pending = await dao.pendingForChat('c1');
        check(pending).length.equals(1);
        check(pending.single.seq).equals(first);
      },
    );

    test('deleteChat over a pending create is a pure local drop', () async {
      await enqueue(
        kind: OutboxKind.createChat,
        chatId: 'local:x',
        contentHash: 'h',
      );
      await enqueue(kind: OutboxKind.updateChat, chatId: 'local:x');
      final survivor = await enqueue(
        kind: OutboxKind.deleteChat,
        chatId: 'local:x',
      );
      // No remote op survives — the chat never reached the server.
      check(survivor).equals(-1);
      check(await dao.pendingForChat('local:x')).isEmpty();
    });

    test('deleteChat annihilates earlier ops but keeps a delete for a '
        'server chat', () async {
      await enqueue(kind: OutboxKind.updateChat, chatId: 'srv1');
      await enqueue(
        kind: OutboxKind.requestCompletion,
        chatId: 'srv1',
        payload: {
          'assistantMessageId': 'a',
          'model': 'm',
          'toolIds': <String>[],
        },
      );
      final del = await enqueue(kind: OutboxKind.deleteChat, chatId: 'srv1');
      final pending = await dao.pendingForChat('srv1');
      check(pending).length.equals(1);
      check(pending.single.seq).equals(del);
      check(pending.single.kind).equals('deleteChat');
    });

    test('deleteChat collapses into an existing pending deleteChat', () async {
      final firstDelete = await enqueue(
        kind: OutboxKind.deleteChat,
        chatId: 'srv1',
      );
      await enqueue(
        kind: OutboxKind.requestCompletion,
        chatId: 'srv1',
        payload: {
          'assistantMessageId': 'a',
          'model': 'm',
          'toolIds': <String>[],
        },
      );
      final secondDelete = await enqueue(
        kind: OutboxKind.deleteChat,
        chatId: 'srv1',
      );

      check(secondDelete).equals(firstDelete);
      final pending = await dao.pendingForChat('srv1');
      check(pending).length.equals(1);
      check(pending.single.seq).equals(firstDelete);
      check(pending.single.kind).equals('deleteChat');
    });

    test('requestCompletion is never coalesced', () async {
      Map<String, dynamic> rc(String id) => {
        'assistantMessageId': id,
        'model': 'm',
        'toolIds': <String>[],
      };
      final a = await enqueue(
        kind: OutboxKind.requestCompletion,
        chatId: 'c1',
        payload: rc('a'),
      );
      final b = await enqueue(
        kind: OutboxKind.requestCompletion,
        chatId: 'c1',
        payload: rc('b'),
      );
      check(b).isGreaterThan(a);
      check(await dao.pendingForChat('c1')).length.equals(2);
    });

    test(
      'folderUpsert collapses to newest; folderDelete drops a local create',
      () async {
        Map<String, dynamic> up(String id, {bool create = true}) => {
          'folderId': id,
          'name': 'n',
          'parentId': null,
          'data': null,
          'meta': null,
          'createIfAbsent': create,
        };

        final first = await enqueue(
          kind: OutboxKind.folderUpsert,
          chatId: 'local:f',
          payload: up('local:f'),
        );
        final second = await enqueue(
          kind: OutboxKind.folderUpsert,
          chatId: 'local:f',
          payload: {
            ...up('local:f', create: false),
            'name': 'n2',
            'meta': {'color': 'red'},
          },
        );
        check(second).equals(first);
        final pendingUpserts = await dao.pendingForChat('local:f');
        check(pendingUpserts).length.equals(1);
        final mergedPayload =
            jsonDecode(pendingUpserts.single.payload) as Map<String, dynamic>;
        check(mergedPayload['name']).equals('n2');
        check(
          mergedPayload['meta'],
        ).isA<Map<String, dynamic>>().deepEquals({'color': 'red'});
        check(mergedPayload['createIfAbsent']).equals(true);

        // folderDelete over a brand-new local folder create drops both.
        final del = await enqueue(
          kind: OutboxKind.folderDelete,
          chatId: 'local:f',
          payload: {'folderId': 'local:f'},
        );
        check(del).equals(-1);
        check(await dao.pendingForChat('local:f')).isEmpty();
      },
    );

    test(
      'folderUpsert coalescing preserves explicit parent root moves',
      () async {
        final first = await enqueue(
          kind: OutboxKind.folderUpsert,
          chatId: 'srvf',
          payload: {'folderId': 'srvf', 'name': 'Old', 'createIfAbsent': false},
        );
        final second = await enqueue(
          kind: OutboxKind.folderUpsert,
          chatId: 'srvf',
          payload: {
            'folderId': 'srvf',
            'parentId': null,
            'createIfAbsent': false,
          },
        );

        check(second).equals(first);
        final pending = await dao.pendingForChat('srvf');
        check(pending).length.equals(1);
        final payload =
            jsonDecode(pending.single.payload) as Map<String, dynamic>;
        check(payload['name']).equals('Old');
        check(payload.containsKey('parentId')).isTrue();
        check(payload['parentId']).isNull();
      },
    );

    test('folderDelete over a server folder keeps the delete and drops '
        'pending upserts', () async {
      await enqueue(
        kind: OutboxKind.folderUpsert,
        chatId: 'srvf',
        payload: {
          'folderId': 'srvf',
          'name': 'n',
          'parentId': null,
          'data': null,
          'meta': null,
          'createIfAbsent': false,
        },
      );
      final del = await enqueue(
        kind: OutboxKind.folderDelete,
        chatId: 'srvf',
        payload: {'folderId': 'srvf'},
      );
      final pending = await dao.pendingForChat('srvf');
      check(pending).length.equals(1);
      check(pending.single.seq).equals(del);
      check(pending.single.kind).equals('folderDelete');
    });

    test(
      'folderDelete collapses into an existing pending folderDelete',
      () async {
        final firstDelete = await enqueue(
          kind: OutboxKind.folderDelete,
          chatId: 'srvf',
          payload: {'folderId': 'srvf'},
        );
        await enqueue(
          kind: OutboxKind.folderUpsert,
          chatId: 'srvf',
          payload: {
            'folderId': 'srvf',
            'name': 'n',
            'parentId': null,
            'data': null,
            'meta': null,
            'createIfAbsent': false,
          },
        );
        final secondDelete = await enqueue(
          kind: OutboxKind.folderDelete,
          chatId: 'srvf',
          payload: {'folderId': 'srvf'},
        );

        check(secondDelete).equals(firstDelete);
        final pending = await dao.pendingForChat('srvf');
        check(pending).length.equals(1);
        check(pending.single.seq).equals(firstDelete);
        check(pending.single.kind).equals('folderDelete');
      },
    );

    test('noteDelete collapses into an existing pending noteDelete', () async {
      await enqueue(
        kind: OutboxKind.noteUpdate,
        chatId: 'n1',
        payload: {'title': 'draft'},
      );
      final firstDelete = await enqueue(
        kind: OutboxKind.noteDelete,
        chatId: 'n1',
      );
      final secondDelete = await enqueue(
        kind: OutboxKind.noteDelete,
        chatId: 'n1',
      );

      check(secondDelete).equals(firstDelete);
      final pending = await dao.pendingForChat('n1');
      check(pending).length.equals(1);
      check(pending.single.seq).equals(firstDelete);
      check(pending.single.kind).equals('noteDelete');
    });
  });

  group('claimNextRunnable (A2)', () {
    test('per-chat FIFO: only the head of each chat is claimable', () async {
      // chat c1: seq1 update, seq2 requestCompletion (must wait for seq1).
      final s1 = await enqueue(kind: OutboxKind.updateChat, chatId: 'c1');
      await enqueue(
        kind: OutboxKind.requestCompletion,
        chatId: 'c1',
        payload: {
          'assistantMessageId': 'a',
          'model': 'm',
          'toolIds': <String>[],
        },
      );

      final first = await dao.claimNextRunnable(
        nowEpochSeconds: 100,
        busyChatIds: {},
      );
      check(first!.seq).equals(s1);
      check(first.status).equals('inFlight');

      // c1 head is now inFlight ⇒ nothing else claimable for c1.
      final none = await dao.claimNextRunnable(
        nowEpochSeconds: 100,
        busyChatIds: {},
      );
      check(none).isNull();

      // After the head completes, the requestCompletion becomes the head.
      await dao.markDone(s1);
      final second = await dao.claimNextRunnable(
        nowEpochSeconds: 100,
        busyChatIds: {},
      );
      check(second!.kind).equals('requestCompletion');
    });

    test(
      'busyChatIds excludes a chat already held by another worker',
      () async {
        await enqueue(kind: OutboxKind.updateChat, chatId: 'c1');
        final s2 = await enqueue(kind: OutboxKind.updateChat, chatId: 'c2');

        // c1 is busy ⇒ claim must skip to c2's head.
        final claimed = await dao.claimNextRunnable(
          nowEpochSeconds: 100,
          busyChatIds: {'c1'},
        );
        check(claimed!.seq).equals(s2);
        check(claimed.chatId).equals('c2');
      },
    );

    test('nextAttemptAt in the future is not runnable until due', () async {
      final seq = await enqueue(kind: OutboxKind.updateChat, chatId: 'c1');
      await dao.markFailedRetryable(seq, error: 'boom', nextAttemptAt: 200);

      check(
        await dao.claimNextRunnable(nowEpochSeconds: 150, busyChatIds: {}),
      ).isNull();

      final due = await dao.claimNextRunnable(
        nowEpochSeconds: 200,
        busyChatIds: {},
      );
      check(due!.seq).equals(seq);
      check(due.attempts).equals(1);
    });

    test('lowest seq across independent chats is claimed first', () async {
      final s1 = await enqueue(kind: OutboxKind.updateChat, chatId: 'cA');
      await enqueue(kind: OutboxKind.updateChat, chatId: 'cB');
      final claimed = await dao.claimNextRunnable(
        nowEpochSeconds: 100,
        busyChatIds: {},
      );
      check(claimed!.seq).equals(s1);
    });
  });

  group('mark* + requeue (A2)', () {
    test('markDone removes the op', () async {
      final seq = await enqueue(kind: OutboxKind.deleteChat, chatId: 'c1');
      await dao.markDone(seq);
      check(await dao.pendingForChat('c1')).isEmpty();
    });

    test('markFailedRetryable keeps it pending, bumps attempts', () async {
      final seq = await enqueue(kind: OutboxKind.updateChat, chatId: 'c1');
      await dao.markFailedRetryable(seq, error: 'e1', nextAttemptAt: 50);
      await dao.markFailedRetryable(seq, error: 'e2', nextAttemptAt: 60);
      final pending = await dao.pendingForChat('c1');
      check(pending.single.status).equals('pending');
      check(pending.single.attempts).equals(2);
      check(pending.single.lastError).equals('e2');
      check(pending.single.nextAttemptAt).equals(60);
    });

    test('markParked moves to failed, clears nextAttemptAt', () async {
      final seq = await enqueue(
        kind: OutboxKind.requestCompletion,
        chatId: 'c1',
        payload: {
          'assistantMessageId': 'a',
          'model': 'm',
          'toolIds': <String>[],
        },
      );
      await dao.markParked(seq, error: 'parked');
      check(await dao.pendingForChat('c1')).isEmpty();
      final parked = await db.outboxDao.watchParkedForChat('c1').first;
      check(parked).length.equals(1);
      check(parked.single.status).equals('failed');
      check(parked.single.nextAttemptAt).isNull();
    });

    test('requeueParked re-arms with attempts reset to 0', () async {
      final seq = await enqueue(
        kind: OutboxKind.requestCompletion,
        chatId: 'c1',
        payload: {
          'assistantMessageId': 'a',
          'model': 'm',
          'toolIds': <String>[],
        },
      );
      await dao.markParked(seq, error: 'p');
      await dao.markParked(seq, error: 'p2'); // attempts now 2
      await dao.requeueParked(seq, nowEpochSeconds: 999);
      final pending = await dao.pendingForChat('c1');
      check(pending.single.status).equals('pending');
      check(pending.single.attempts).equals(0);
      check(pending.single.nextAttemptAt).equals(999);
      check(pending.single.lastError).isNull();
    });

    test('resetBackoffForPending arms every pending op to now', () async {
      final a = await enqueue(kind: OutboxKind.updateChat, chatId: 'cA');
      final b = await enqueue(kind: OutboxKind.updateChat, chatId: 'cB');
      await dao.markFailedRetryable(a, error: 'e', nextAttemptAt: 9999);
      await dao.markFailedRetryable(b, error: 'e', nextAttemptAt: 9999);
      await dao.resetBackoffForPending(nowEpochSeconds: 42);
      final pa = await dao.pendingForChat('cA');
      final pb = await dao.pendingForChat('cB');
      check(pa.single.nextAttemptAt).equals(42);
      check(pb.single.nextAttemptAt).equals(42);
    });
  });

  group('rewriteChatId (§7.3)', () {
    test('rewrites pending ops from local to server id', () async {
      await enqueue(
        kind: OutboxKind.createChat,
        chatId: 'local:x',
        contentHash: 'h',
      );
      await enqueue(
        kind: OutboxKind.requestCompletion,
        chatId: 'local:x',
        payload: {
          'assistantMessageId': 'a',
          'model': 'm',
          'toolIds': <String>[],
        },
      );
      await dao.rewriteChatId(fromChatId: 'local:x', toChatId: 'srv-1');
      check(await dao.pendingForChat('local:x')).isEmpty();
      check(await dao.pendingForChat('srv-1')).length.equals(2);
    });
  });

  group('resetInFlightToPending (crash recovery §7.2/§11)', () {
    test(
      'reclaims a stranded inFlight op back to pending, attempts intact',
      () async {
        final seq = await enqueue(kind: OutboxKind.updateChat, chatId: 'c1');
        await dao.markFailedRetryable(seq, error: 'e', nextAttemptAt: 7);
        // Simulate a kill mid-push: the op was flipped to inFlight by a claim.
        final claimed = await dao.claimNextRunnable(
          nowEpochSeconds: 99,
          busyChatIds: {},
        );
        check(claimed!.status).equals('inFlight');

        final reclaimed = await dao.resetInFlightToPending();
        check(reclaimed).equals(1);
        final pending = await dao.pendingForChat('c1');
        check(pending.single.status).equals('pending');
        // attempts/nextAttemptAt preserved so backoff/N=5 survive process death.
        check(pending.single.attempts).equals(1);
        check(pending.single.nextAttemptAt).equals(7);
      },
    );

    test(
      'a stranded inFlight op no longer blocks its chat head after reset',
      () async {
        // createChat (will be stranded inFlight) then a dependent completion.
        await enqueue(
          kind: OutboxKind.createChat,
          chatId: 'local:c',
          contentHash: 'h',
        );
        await enqueue(
          kind: OutboxKind.requestCompletion,
          chatId: 'local:c',
          payload: {
            'assistantMessageId': 'a',
            'model': 'm',
            'toolIds': <String>[],
          },
        );
        // Claim the create -> inFlight. The completion is now blocked behind it.
        final create = await dao.claimNextRunnable(
          nowEpochSeconds: 1,
          busyChatIds: {},
        );
        check(OutboxKind.fromName(create!.kind)).equals(OutboxKind.createChat);
        // Without reset, the inFlight create blocks the completion forever.
        check(
          await dao.claimNextRunnable(nowEpochSeconds: 1, busyChatIds: {}),
        ).isNull();

        await dao.resetInFlightToPending();
        // Now the create is the claimable head again (not the completion).
        final head = await dao.claimNextRunnable(
          nowEpochSeconds: 1,
          busyChatIds: {},
        );
        check(OutboxKind.fromName(head!.kind)).equals(OutboxKind.createChat);
      },
    );
  });

  group('pendingCreateForHash (§7.3 crash heal)', () {
    test('matches a pending createChat op by contentHash', () async {
      await enqueue(
        kind: OutboxKind.createChat,
        chatId: 'local:c',
        contentHash: 'hash-A',
      );
      final hit = await dao.pendingCreateForHash('hash-A');
      check(hit!.chatId).equals('local:c');
      check(await dao.pendingCreateForHash('hash-B')).isNull();
    });

    test(
      'does NOT match an inFlight create (owned by a live worker)',
      () async {
        await enqueue(
          kind: OutboxKind.createChat,
          chatId: 'local:c',
          contentHash: 'hash-A',
        );
        await dao.claimNextRunnable(nowEpochSeconds: 1, busyChatIds: {});
        check(await dao.pendingCreateForHash('hash-A')).isNull();
      },
    );

    test('hasPendingCreateContentHashes is a cheap preflight', () async {
      check(await dao.hasPendingCreateContentHashes()).isFalse();
      await enqueue(
        kind: OutboxKind.createChat,
        chatId: 'local:c',
        contentHash: 'hash-A',
      );
      check(await dao.hasPendingCreateContentHashes()).isTrue();
      await dao.claimNextRunnable(nowEpochSeconds: 1, busyChatIds: {});
      check(await dao.hasPendingCreateContentHashes()).isFalse();
    });
  });

  group('markOfflineDeferred (Finding 7)', () {
    test('reschedules without bumping attempts', () async {
      final seq = await enqueue(kind: OutboxKind.updateChat, chatId: 'c1');
      await dao.markOfflineDeferred(seq, nextAttemptAt: 30);
      await dao.markOfflineDeferred(seq, nextAttemptAt: 40);
      final pending = await dao.pendingForChat('c1');
      check(pending.single.status).equals('pending');
      check(pending.single.attempts).equals(0);
      check(pending.single.lastError).equals('offline');
      check(pending.single.nextAttemptAt).equals(40);
    });
  });

  group('parked predecessor blocks dependents (§7.2, Finding 8)', () {
    test(
      'a failed (parked) create blocks its trailing requestCompletion',
      () async {
        final createSeq = await enqueue(
          kind: OutboxKind.createChat,
          chatId: 'local:c',
          contentHash: 'h',
        );
        await enqueue(
          kind: OutboxKind.requestCompletion,
          chatId: 'local:c',
          payload: {
            'assistantMessageId': 'a',
            'model': 'm',
            'toolIds': <String>[],
          },
        );
        // Park the create (terminal 401/403 in the real drainer).
        await dao.markParked(createSeq, error: '403');
        // The completion must NOT become claimable while its predecessor is parked.
        check(
          await dao.claimNextRunnable(nowEpochSeconds: 1, busyChatIds: {}),
        ).isNull();

        // Manual retry re-arms the create as the head; it (not the completion)
        // is claimed next.
        await dao.requeueParked(createSeq, nowEpochSeconds: 1);
        final head = await dao.claimNextRunnable(
          nowEpochSeconds: 1,
          busyChatIds: {},
        );
        check(OutboxKind.fromName(head!.kind)).equals(OutboxKind.createChat);
      },
    );
  });

  group('watchPendingCount', () {
    test('counts pending + inFlight only', () async {
      check(await dao.watchPendingCount().first).equals(0);
      await enqueue(kind: OutboxKind.updateChat, chatId: 'c1');
      check(await dao.watchPendingCount().first).equals(1);
      final seq = await dao.claimNextRunnable(
        nowEpochSeconds: 1,
        busyChatIds: {},
      );
      // inFlight still counted.
      check(await dao.watchPendingCount().first).equals(1);
      await dao.markDone(seq!.seq);
      check(await dao.watchPendingCount().first).equals(0);
    });
  });
}
