import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/sync/chat_locks.dart';
import 'package:conduit/core/sync/id_remapper.dart';
import 'package:conduit/core/sync/pull_sync.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_open_webui_server.dart';
import '../../support/fake_sync_api_client.dart';

Map<String, dynamic> blobFor(String id, {int messageCount = 2}) {
  final messages = <String, dynamic>{};
  for (var i = 1; i <= messageCount; i++) {
    messages['$id-m$i'] = {
      'id': '$id-m$i',
      'parentId': i == 1 ? null : '$id-m${i - 1}',
      'childrenIds': i == messageCount ? <String>[] : ['$id-m${i + 1}'],
      'role': i.isOdd ? 'user' : 'assistant',
      'content': 'message $i of $id',
      'timestamp': 1000 + i,
      if (i.isEven) 'model': 'llama3',
    };
  }
  return {
    'title': 'Title $id',
    'models': ['llama3'],
    'history': {'messages': messages, 'currentId': '$id-m$messageCount'},
  };
}

class _MalformedFullMainListClient extends FakeSyncApiClient {
  _MalformedFullMainListClient(super.server);

  final pages = <int>[];

  @override
  Future<List<Map<String, dynamic>>> getChatListPage(int page) async {
    pages.add(page);
    if (page > 1) {
      throw StateError('main chat pagination did not stop');
    }
    return [
      for (var i = 0; i < kOpenWebUiChatListPageSize; i++)
        <String, dynamic>{'id': 'malformed-main-$i'},
    ];
  }
}

class _MalformedFullArchivedListClient extends FakeSyncApiClient {
  _MalformedFullArchivedListClient(super.server);

  final pages = <int>[];

  @override
  Future<List<Map<String, dynamic>>> getArchivedChatListPage(int page) async {
    pages.add(page);
    if (page > 1) {
      throw StateError('archived chat pagination did not stop');
    }
    return [
      for (var i = 0; i < kOpenWebUiChatListPageSize; i++)
        <String, dynamic>{'id': 'malformed-archived-$i'},
    ];
  }
}

void main() {
  late FakeOpenWebUiServer server;
  late FakeSyncApiClient client;
  late AppDatabase db;
  late ConversationLocks locks;
  late PullSync pull;

  setUp(() {
    server = FakeOpenWebUiServer();
    client = FakeSyncApiClient(server);
    db = AppDatabase(NativeDatabase.memory());
    locks = ConversationLocks();
    pull = PullSync(client: client, db: db, locks: locks);
  });

  tearDown(() async {
    await db.close();
  });

  // Deterministically ordered snapshots (physical row order changes when a
  // chat is delete-reinserted, which is not a semantic difference).
  Future<List<ChatRow>> allChats() async {
    final rows = await db.select(db.chats).get();
    return rows..sort((a, b) => a.id.compareTo(b.id));
  }

  Future<List<MessageRow>> allMessages() async {
    final rows = await db.select(db.messages).get();
    return rows..sort((a, b) {
      final byChat = a.chatId.compareTo(b.chatId);
      if (byChat != 0) return byChat;
      return a.id.compareTo(b.id);
    });
  }

  group('PullSync.run', () {
    test('first-run full pull (watermark 0) lands every chat', () async {
      server.seedChat(
        id: 'plain',
        blob: blobFor('plain'),
        createdAt: 100,
        updatedAt: 200,
      );
      server.seedChat(
        id: 'pinned',
        blob: blobFor('pinned'),
        createdAt: 100,
        updatedAt: 300,
        pinned: true,
      );
      server.seedChat(
        id: 'foldered',
        blob: blobFor('foldered'),
        createdAt: 100,
        updatedAt: 400,
        folderId: 'folder-1',
      );
      server.seedChat(
        id: 'archived',
        blob: blobFor('archived'),
        createdAt: 100,
        updatedAt: 500,
        archived: true,
      );

      final result = await pull.run();

      check(result.success).isTrue();
      check(result.failedFetches).equals(0);
      check(result.changedChats).equals(4);
      check(result.watermarkAdvanced).isTrue();
      check(result.foldersFeatureEnabled).equals(true);
      // Archived chats feed maxSeen too.
      check(await db.syncMetaDao.getPullWatermark()).equals(500);

      final rows = {for (final row in await allChats()) row.id: row};
      check(
        rows.keys,
      ).unorderedEquals(['plain', 'pinned', 'foldered', 'archived']);
      check(rows['pinned']!.pinned).isTrue();
      check(rows['foldered']!.folderId).equals('folder-1');
      check(rows['plain']!.bodySynced).isTrue();
      check(rows['plain']!.serverUpdatedAt).equals(200);

      // Q-03 default: archived arrives as an envelope-only stub.
      check(rows['archived']!.bodySynced).isFalse();
      check(rows['archived']!.archived).isTrue();

      final messages = await allMessages();
      check(messages.where((m) => m.chatId == 'plain').length).equals(2);
      check(messages.where((m) => m.chatId == 'archived')).isEmpty();

      // The seeded folder for the foldered chat replicated.
      check(
        (await db.foldersDao.watchFolders().first).map((f) => f.id),
      ).deepEquals(['folder-1']);
    });

    test('empty server: success without watermark movement', () async {
      final result = await pull.run();
      check(result.success).isTrue();
      check(result.changedChats).equals(0);
      check(result.watermarkAdvanced).isFalse();
      check(await db.syncMetaDao.getPullWatermark()).equals(0);
      check(await allChats()).isEmpty();
    });

    test(
      'incremental pull stops at the watermark inside the first page',
      () async {
        for (var i = 1; i <= 70; i++) {
          server.seedChat(
            id: 'chat-${i.toString().padLeft(3, '0')}',
            blob: blobFor('chat-$i'),
            createdAt: 2000 + i,
            updatedAt: 2000 + i,
          );
        }
        await db.syncMetaDao.setPullWatermark(2050);

        final result = await pull.run();

        // Threshold is 2050 - 5 = 2045: chats 2046..2070 are changed (the 5s
        // overlap deliberately re-pulls 2046..2050).
        check(result.success).isTrue();
        check(client.chatFetchStarts.length).equals(25);
        // Early-stop hit inside page 1 — page 2 must never be requested.
        check(client.chatListPageRequests).equals(1);
        check(await db.syncMetaDao.getPullWatermark()).equals(2070);
        check((await allChats()).length).equals(25);
      },
    );

    test(
      'same-second edits straddling a page boundary are all pulled',
      () async {
        // 61 chats sharing one updated_at second, watermark exactly there:
        // every item passes the overlap predicate, so pagination must continue
        // past the 60-item page boundary.
        for (var i = 1; i <= 61; i++) {
          server.seedChat(
            id: 'tie-${i.toString().padLeft(3, '0')}',
            blob: blobFor('tie-$i'),
            createdAt: 3000,
            updatedAt: 3000,
          );
        }
        await db.syncMetaDao.setPullWatermark(3000);

        final result = await pull.run();

        check(result.success).isTrue();
        check(client.chatListPageRequests).equals(2);
        check(result.changedChats).equals(61);
        check((await allChats()).length).equals(61);
        check(await db.syncMetaDao.getPullWatermark()).equals(3000);
      },
    );

    test(
      '5s-overlap re-merge is idempotent: run(); run() -> identical rows',
      () async {
        for (var i = 1; i <= 3; i++) {
          server.seedChat(
            id: 'chat-$i',
            blob: blobFor('chat-$i', messageCount: 3),
            createdAt: 100 * i,
            updatedAt: 100 * i,
          );
        }

        final first = await pull.run();
        check(first.success).isTrue();
        final chatsBefore = await allChats();
        final messagesBefore = await allMessages();

        final second = await pull.run();
        check(second.success).isTrue();
        // Watermark unchanged (300); only the chat inside the 5s overlap
        // window (updated_at 300 > 300 - 5) re-merges — harmlessly.
        check(second.changedChats).equals(1);
        check(second.watermarkAdvanced).isFalse();

        check(await allChats()).deepEquals(chatsBefore);
        check(await allMessages()).deepEquals(messagesBefore);
      },
    );

    test('partial failure: watermark frozen, successes still land, next run '
        'heals', () async {
      for (var i = 1; i <= 3; i++) {
        server.seedChat(
          id: 'chat-$i',
          blob: blobFor('chat-$i'),
          createdAt: 100 * i,
          updatedAt: 100 * i,
        );
      }
      client.failChatIds.add('chat-2');

      final result = await pull.run();

      check(result.success).isFalse();
      check(result.failedFetches).equals(1);
      check(result.watermarkAdvanced).isFalse();
      check(await db.syncMetaDao.getPullWatermark()).equals(0);
      check(
        (await allChats()).map((c) => c.id),
      ).unorderedEquals(['chat-1', 'chat-3']);

      client.failChatIds.clear();
      final healed = await pull.run();
      check(healed.success).isTrue();
      check(healed.watermarkAdvanced).isTrue();
      check(await db.syncMetaDao.getPullWatermark()).equals(300);
      check(
        (await allChats()).map((c) => c.id),
      ).unorderedEquals(['chat-1', 'chat-2', 'chat-3']);
    });

    test(
      'main list page failure aborts the cycle before any chat fetch',
      () async {
        server.seedChat(
          id: 'chat-1',
          blob: blobFor('chat-1'),
          createdAt: 100,
          updatedAt: 100,
        );
        client.failChatListPages.add(1);

        final result = await pull.run();

        check(result.success).isFalse();
        check(result.watermarkAdvanced).isFalse();
        check(result.changedChats).equals(0);
        check(client.chatFetchStarts).isEmpty();
        check(client.archivedListPageRequests).equals(0);
        check(await allChats()).isEmpty();
      },
    );

    test(
      'main list stops when a full malformed page makes no progress',
      () async {
        client = _MalformedFullMainListClient(server);
        pull = PullSync(client: client, db: db, locks: locks);

        final result = await pull.run();

        check(result.success).isTrue();
        check(result.changedChats).equals(0);
        check((client as _MalformedFullMainListClient).pages).deepEquals([1]);
        check(client.chatFetchStarts).isEmpty();
        check(await db.syncMetaDao.getPullWatermark()).equals(0);
      },
    );

    test('archived list failure freezes the watermark but already-collected '
        'chats still merge', () async {
      server.seedChat(
        id: 'chat-1',
        blob: blobFor('chat-1'),
        createdAt: 100,
        updatedAt: 100,
      );
      client.failArchivedListPages.add(1);

      final result = await pull.run();

      check(result.success).isFalse();
      check(result.watermarkAdvanced).isFalse();
      check(await db.syncMetaDao.getPullWatermark()).equals(0);
      check((await allChats()).map((c) => c.id)).deepEquals(['chat-1']);
    });

    test(
      'archived list stops when a full malformed page makes no progress',
      () async {
        client = _MalformedFullArchivedListClient(server);
        pull = PullSync(client: client, db: db, locks: locks);

        final result = await pull.run();

        check(result.success).isTrue();
        check(result.changedChats).equals(0);
        check(
          (client as _MalformedFullArchivedListClient).pages,
        ).deepEquals([1]);
        check(client.chatFetchStarts).isEmpty();
        check(await db.syncMetaDao.getPullWatermark()).equals(0);
      },
    );

    test('archived chat with a synced body is re-fetched in full '
        '(bodySynced promotion)', () async {
      server.seedChat(
        id: 'chat-1',
        blob: blobFor('chat-1'),
        createdAt: 100,
        updatedAt: 100,
      );
      final first = await pull.run();
      check(first.success).isTrue();
      check((await db.chatsDao.getChat('chat-1'))!.bodySynced).isTrue();

      // Archive + edit server-side.
      server.seedChat(
        id: 'chat-1',
        blob: blobFor('chat-1', messageCount: 4),
        createdAt: 100,
        updatedAt: 250,
        archived: true,
      );

      final second = await pull.run();
      check(second.success).isTrue();

      final row = (await db.chatsDao.getChat('chat-1'))!;
      // The synced body did not go stale: full fetch, not a stub.
      check(row.bodySynced).isTrue();
      check(row.archived).isTrue();
      check(row.updatedAt).equals(250);
      check((await db.messagesDao.getForChat('chat-1')).length).equals(4);
      check(await db.syncMetaDao.getPullWatermark()).equals(250);
    });

    test(
      'never-synced archived chat stays an envelope stub across pulls',
      () async {
        server.seedChat(
          id: 'arch-1',
          blob: blobFor('arch-1'),
          createdAt: 100,
          updatedAt: 100,
          archived: true,
        );

        final result = await pull.run();
        check(result.success).isTrue();

        final row = (await db.chatsDao.getChat('arch-1'))!;
        check(row.bodySynced).isFalse();
        check(row.archived).isTrue();
        check(row.title).equals('Title arch-1');
        check(row.updatedAt).equals(100);
        check(await db.messagesDao.getForChat('arch-1')).isEmpty();
        // Stubs never trigger a body fetch.
        check(client.chatFetchStarts).isEmpty();
      },
    );

    test(
      'folders 403 reports featureEnabled=false and chats are unaffected',
      () async {
        server.seedChat(
          id: 'chat-1',
          blob: blobFor('chat-1'),
          createdAt: 100,
          updatedAt: 100,
        );
        client.foldersFeatureEnabled = false;

        final result = await pull.run();

        check(result.success).isTrue();
        check(result.foldersFeatureEnabled).equals(false);
        check((await allChats()).map((c) => c.id)).deepEquals(['chat-1']);
        check(await db.syncMetaDao.getPullWatermark()).equals(100);
      },
    );

    test('folders fetch error never blocks the chat watermark', () async {
      server.seedChat(
        id: 'chat-1',
        blob: blobFor('chat-1'),
        createdAt: 100,
        updatedAt: 100,
      );
      client.failFolders = true;

      final result = await pull.run();

      check(result.success).isTrue();
      check(result.foldersFeatureEnabled).isNull();
      check(result.watermarkAdvanced).isTrue();
      check(await db.syncMetaDao.getPullWatermark()).equals(100);
    });

    test(
      'fetch pool: newest-first order with concurrency of exactly 4',
      () async {
        for (var i = 1; i <= 12; i++) {
          server.seedChat(
            id: 'chat-${i.toString().padLeft(2, '0')}',
            blob: blobFor('chat-$i'),
            createdAt: 1000 + i,
            updatedAt: 1000 + i,
          );
        }
        client.chatFetchDelay = const Duration(milliseconds: 15);

        final result = await pull.run();

        check(result.success).isTrue();
        check(client.maxConcurrentChatFetches).equals(kPullFetchConcurrency);
        // Fetches START in list order: updated_at DESC, id ASC.
        check(client.chatFetchStarts).deepEquals([
          for (var i = 12; i >= 1; i--) 'chat-${i.toString().padLeft(2, '0')}',
        ]);
      },
    );

    test('chat deleted between list and fetch counts as success', () async {
      server.seedChat(
        id: 'chat-1',
        blob: blobFor('chat-1'),
        createdAt: 100,
        updatedAt: 100,
      );
      server.seedChat(
        id: 'chat-2',
        blob: blobFor('chat-2'),
        createdAt: 100,
        updatedAt: 200,
      );
      // The fake serves lists from live state, so emulate the race (chat
      // deleted between the list fetch and the body fetch) with a client
      // hook that returns null for a listed id — a 404 in production.
      client.nullChatIds.add('chat-2');

      final result = await pull.run();

      // Null is success: no local change in Phase 1 (deletion reconcile is
      // Phase 3), and the watermark may advance.
      check(result.success).isTrue();
      check(result.failedFetches).equals(0);
      check(result.watermarkAdvanced).isTrue();
      check(await db.syncMetaDao.getPullWatermark()).equals(200);
      check((await allChats()).map((c) => c.id)).deepEquals(['chat-1']);
    });
  });

  group('PullSync.pullChat', () {
    test('404 returns null and leaves local state untouched', () async {
      check(await pull.pullChat('missing')).isNull();
      check(await allChats()).isEmpty();
    });

    test(
      'merges under the chat lock and returns the assembled conversation',
      () async {
        server.seedChat(
          id: 'chat-1',
          blob: blobFor('chat-1', messageCount: 3),
          createdAt: 100,
          updatedAt: 150,
        );

        final conversation = await pull.pullChat('chat-1');

        check(conversation).isNotNull();
        check(conversation!.id).equals('chat-1');
        check(conversation.title).equals('Title chat-1');
        check(conversation.messages.length).equals(3);
        check(
          conversation.updatedAt.millisecondsSinceEpoch ~/ 1000,
        ).equals(150);

        final row = (await db.chatsDao.getChat('chat-1'))!;
        check(row.bodySynced).isTrue();
        // Single-chat pull never advances the watermark.
        check(await db.syncMetaDao.getPullWatermark()).equals(0);
        check(locks.isIdle).isTrue();
      },
    );

    test(
      'listLastReadAt null preserves the local lastReadAt (max rule)',
      () async {
        server.seedChat(
          id: 'chat-1',
          blob: blobFor('chat-1'),
          createdAt: 100,
          updatedAt: 150,
        );
        await pull.pullChat('chat-1');
        await db.chatsDao.setLastReadAt('chat-1', 140);

        await pull.pullChat('chat-1');

        check((await db.chatsDao.getChat('chat-1'))!.lastReadAt).equals(140);
      },
    );
  });

  group('three-way merge on pull (§7.4)', () {
    // Helper: first pull lands chat-1 clean (serverUpdatedAt set), returning
    // the assembled server id ('chat-1' since we seed it).
    Future<void> seedAndPull(String id, {int messageCount = 2}) async {
      server.seedChat(
        id: id,
        blob: blobFor(id, messageCount: messageCount),
        createdAt: 100,
        updatedAt: 100,
      );
      final result = await pull.run();
      check(result.success).isTrue();
    }

    test(
      'fast-forward when local is NOT dirty: server rows replace local',
      () async {
        await seedAndPull('chat-1');
        // Server adds a message and bumps updated_at.
        server.seedChat(
          id: 'chat-1',
          blob: blobFor('chat-1', messageCount: 3),
          createdAt: 100,
          updatedAt: 200,
        );

        final second = await pull.run();
        check(second.success).isTrue();

        final row = (await db.chatsDao.getChat('chat-1'))!;
        check(row.dirty).isFalse();
        check(row.serverUpdatedAt).equals(200);
        check((await db.messagesDao.getForChat('chat-1')).length).equals(3);
        // Fast-forward never enqueues a push.
        check(await db.outboxDao.pendingForChat('chat-1')).isEmpty();
      },
    );

    test('three-way keeps a locally-dirty new message and enqueues an '
        'updateChat push', () async {
      await seedAndPull('chat-1');

      // Local edit: append a dirty assistant message + enqueue updateChat.
      await locks.runExclusive('chat-1', () async {
        await db.chatsDao.appendMessagesWithUpdateOp(
          chatId: 'chat-1',
          messages: [
            MessageRowData(
              id: 'chat-1-local',
              chatId: 'chat-1',
              parentId: 'chat-1-m2',
              role: 'user',
              content: 'local follow-up',
              createdAt: 1500,
              orderIndex: 99,
              payload: {
                'id': 'chat-1-local',
                'parentId': 'chat-1-m2',
                'childrenIds': <String>[],
                'role': 'user',
                'content': 'local follow-up',
                'timestamp': 1500,
              },
            ),
          ],
          currentMessageId: 'chat-1-local',
          updatedAt: 150,
          enqueueCompletion: false,
        );
      });
      check((await db.chatsDao.getChat('chat-1'))!.dirty).isTrue();
      final staleOps = await db.outboxDao.pendingForChat('chat-1');
      check(staleOps.single.kind).equals('updateChat');
      await db.outboxDao.markDone(staleOps.single.seq);
      check(await db.outboxDao.pendingForChat('chat-1')).isEmpty();

      // Server independently advances (adds its own m3) past the merge base.
      server.seedChat(
        id: 'chat-1',
        blob: blobFor('chat-1', messageCount: 3),
        createdAt: 100,
        updatedAt: 200,
      );

      final second = await pull.run();
      check(second.success).isTrue();

      final row = (await db.chatsDao.getChat('chat-1'))!;
      // Three-way: row stays dirty, serverUpdatedAt UNCHANGED at base (100).
      check(row.dirty).isTrue();
      check(row.serverUpdatedAt).equals(100);

      final ids = (await db.messagesDao.getForChat(
        'chat-1',
      )).map((m) => m.id).toList();
      // Server's m3 inserted AND the dirty local message kept.
      check(ids).contains('chat-1-local');
      check(ids).contains('chat-1-m3');

      // The local message row stays dirty; server-origin rows are clean.
      final localMsg = (await db.messagesDao.getForChat(
        'chat-1',
      )).firstWhere((m) => m.id == 'chat-1-local');
      check(localMsg.dirty).isTrue();

      // REQ 4: the divergent merge enqueued exactly one updateChat push.
      final pending = await db.outboxDao.pendingForChat('chat-1');
      check(pending.length).equals(1);
      check(pending.single.kind).equals('updateChat');
    });

    test('three-way does not duplicate an in-flight updateChat push', () async {
      await seedAndPull('chat-1');

      await locks.runExclusive('chat-1', () async {
        await db.chatsDao.appendMessagesWithUpdateOp(
          chatId: 'chat-1',
          messages: [
            MessageRowData(
              id: 'chat-1-local',
              chatId: 'chat-1',
              parentId: 'chat-1-m2',
              role: 'user',
              content: 'local follow-up',
              createdAt: 1500,
              orderIndex: 99,
              payload: {
                'id': 'chat-1-local',
                'parentId': 'chat-1-m2',
                'childrenIds': <String>[],
                'role': 'user',
                'content': 'local follow-up',
                'timestamp': 1500,
              },
            ),
          ],
          currentMessageId: 'chat-1-local',
          updatedAt: 150,
          enqueueCompletion: false,
        );
      });
      final claimed = await db.outboxDao.claimNextRunnable(
        nowEpochSeconds: 0,
        busyChatIds: const {},
      );
      check(claimed).isNotNull();
      check(claimed!.kind).equals('updateChat');
      check(claimed.status).equals('inFlight');
      check(await db.outboxDao.pendingForChat('chat-1')).isEmpty();

      server.seedChat(
        id: 'chat-1',
        blob: blobFor('chat-1', messageCount: 3),
        createdAt: 100,
        updatedAt: 200,
      );

      final second = await pull.run();
      check(second.success).isTrue();

      check(await db.outboxDao.pendingForChat('chat-1')).isEmpty();
      final active = await db.outboxDao.activeForChat('chat-1');
      check(active).length.equals(1);
      check(active.single.kind).equals('updateChat');
      check(active.single.status).equals('inFlight');
    });

    test('a dirty tombstone is NOT resurrected by a fast-forward', () async {
      await seedAndPull('chat-1');

      // Local delete → dirty tombstone + pending deleteChat.
      await locks.runExclusive('chat-1', () async {
        await db.chatsDao.tombstoneWithOutbox('chat-1');
      });

      // Server edits the chat (it still exists server-side).
      server.seedChat(
        id: 'chat-1',
        blob: blobFor('chat-1', messageCount: 4),
        createdAt: 100,
        updatedAt: 300,
      );

      final second = await pull.run();
      check(second.success).isTrue();

      final row = (await db.chatsDao.getChat('chat-1'))!;
      // Still tombstoned; merge skipped entirely so deleted stays true.
      check(row.deleted).isTrue();
      check(row.dirty).isTrue();
      // The pending deleteChat survives — it will purge on confirm.
      final pending = await db.outboxDao.pendingForChat('chat-1');
      check(pending.single.kind).equals('deleteChat');
    });

    test(
      'a dirty never-synced stub keeps migrated messages on first body pull',
      () async {
        const chatId = 'chat-1';
        await db.chatsDao.upsertEnvelopeStub(
          id: chatId,
          title: 'Migrated stub',
          createdAt: 100,
          updatedAt: 100,
        );
        await db.chatsDao.appendMessagesWithUpdateOp(
          chatId: chatId,
          messages: [
            MessageRowData(
              id: 'migrated-user',
              chatId: chatId,
              parentId: null,
              role: 'user',
              content: 'queued user text',
              createdAt: 101,
              orderIndex: 0,
              payload: const {
                'id': 'migrated-user',
                'role': 'user',
                'content': 'queued user text',
              },
            ),
            MessageRowData(
              id: 'migrated-assistant',
              chatId: chatId,
              parentId: 'migrated-user',
              role: 'assistant',
              content: '',
              createdAt: 102,
              orderIndex: 1,
              payload: const {
                'id': 'migrated-assistant',
                'parentId': 'migrated-user',
                'role': 'assistant',
                'content': '',
              },
            ),
          ],
          currentMessageId: 'migrated-assistant',
          updatedAt: 102,
          enqueueCompletion: false,
        );

        server.seedChat(
          id: chatId,
          blob: blobFor(chatId, messageCount: 1),
          createdAt: 100,
          updatedAt: 200,
        );

        final result = await pull.run();
        check(result.success).isTrue();

        final chat = (await db.chatsDao.getChat(chatId))!;
        check(chat.dirty).isTrue();
        check(chat.bodySynced).isTrue();
        final ids = (await db.messagesDao.getForChat(
          chatId,
        )).map((m) => m.id).toSet();
        check(ids).contains('migrated-user');
        check(ids).contains('migrated-assistant');
        check(ids).contains('$chatId-m1');
      },
    );

    test(
      '5s-overlap re-merge of a dirty chat is a no-op (idempotent)',
      () async {
        await seedAndPull('chat-1');
        // Make the chat dirty without changing serverUpdatedAt's relationship.
        await locks.runExclusive('chat-1', () async {
          await db.chatsDao.updateEnvelopeWithOutbox(
            'chat-1',
            title: const Value('Locally Renamed'),
            updatedAt: const Value(150),
            enqueue: true,
          );
        });
        // Server's updated_at stays at 100 (== base): a re-pull within the
        // overlap window hits the no-remote-change branch.
        final before = (await db.chatsDao.getChat('chat-1'))!;
        final msgsBefore = await db.messagesDao.getForChat('chat-1');

        final second = await pull.run();
        check(second.success).isTrue();

        final after = (await db.chatsDao.getChat('chat-1'))!;
        // Row untouched: title, dirty, serverUpdatedAt all preserved.
        check(after.title).equals('Locally Renamed');
        check(after.dirty).isTrue();
        check(after.serverUpdatedAt).equals(before.serverUpdatedAt);
        check(await db.messagesDao.getForChat('chat-1')).deepEquals(msgsBefore);
      },
    );
  });

  group('createChat crash-heal (§7.3, Finding 3)', () {
    test('pull folds the server chat into the pending local create instead of '
        'duplicating, and drops the op', () async {
      final remapper = IdRemapper(db);
      addTearDown(remapper.dispose);
      final healingPull = PullSync(
        client: client,
        db: db,
        locks: locks,
        remapper: remapper,
      );

      // 1. Local compose: a local: chat + createChat op carrying its content
      //    hash (exactly what insertLocalChatWithCreateOp records at enqueue).
      const localId = 'local:heal-me';
      final blob = blobFor('heal', messageCount: 2);
      final rows = ChatBlobMapper.blobToRows(
        chatId: localId,
        blob: blob,
        title: 'Title heal',
        createdAt: 100,
        updatedAt: 200,
      );
      final contentHash = createChatContentHash(rows);
      await db.chatsDao.insertLocalChatWithCreateOp(
        chat: rows.chat,
        messages: rows.messages,
        blobRows: rows,
        contentHash: contentHash,
      );

      // 2. Crash window: the server-create POST succeeded (server mints a real
      //    id) but the process died before the remap committed, so the local
      //    row is still local: and the createChat op is still pending.
      final serverResp = server.createChat({...blob, 'id': ''});
      final serverId = serverResp['id'] as String;
      check(serverId.startsWith('local:')).isFalse();

      // 3. A pull sees the new server chat. The heal must remap, not duplicate.
      final result = await healingPull.run();
      check(result.success).isTrue();

      // Exactly ONE chat row, at the server id; the local row is gone.
      check(await db.chatsDao.getChat(localId)).isNull();
      check(await db.chatsDao.getChat(serverId)).isNotNull();
      check((await db.select(db.chats).get()).length).equals(1);
      // The pending createChat op was completed (dropped) by the heal — no
      // re-POST will happen on the next drain.
      check(await db.outboxDao.pendingForChat(localId)).isEmpty();
      check(await db.outboxDao.pendingForChat(serverId)).isEmpty();
      // And only ONE chat exists server-side (no duplicate was minted).
      check(server.getChatById(serverId)).isNotNull();
    });

    test('a non-matching content hash does NOT heal (normal merge)', () async {
      final remapper = IdRemapper(db);
      addTearDown(remapper.dispose);
      final healingPull = PullSync(
        client: client,
        db: db,
        locks: locks,
        remapper: remapper,
      );

      // Pending create for a DIFFERENT chat content.
      const localId = 'local:other';
      final rows = ChatBlobMapper.blobToRows(
        chatId: localId,
        blob: blobFor('other'),
        title: 'Title other',
        createdAt: 100,
        updatedAt: 200,
      );
      await db.chatsDao.insertLocalChatWithCreateOp(
        chat: rows.chat,
        messages: rows.messages,
        blobRows: rows,
        contentHash: createChatContentHash(rows),
      );

      // An unrelated server chat arrives.
      server.seedChat(
        id: 'srv-unrelated',
        blob: blobFor('unrelated'),
        createdAt: 100,
        updatedAt: 300,
      );
      await healingPull.run();

      // Local create untouched (still pending), server chat merged separately.
      check(await db.chatsDao.getChat(localId)).isNotNull();
      check(await db.chatsDao.getChat('srv-unrelated')).isNotNull();
      check(await db.outboxDao.pendingForChat(localId)).length.equals(1);
    });
  });
}
