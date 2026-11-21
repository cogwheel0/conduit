import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart'
    show OutboxKind, kDeleteMessagesIdsKey;
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart'
    show
        kLocalConversationWorkerPayloadThreshold,
        kLocalConversationWorkerThreshold;
import 'package:conduit_core/services/conversation_parsing.dart'
    show parseFullConversationModel;
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/id_remapper.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:conduit_core/testing.dart';

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

class _ChecklistClient extends FakeSyncApiClient {
  _ChecklistClient(super.server);

  Map<String, dynamic> fields = {};
  Future<void> Function()? afterSnapshot;

  @override
  Future<Map<String, dynamic>?> getChatRaw(String id) async {
    final raw = await super.getChatRaw(id);
    if (raw == null) return null;
    final snapshot = {...raw, ...fields};
    if (!fields.containsKey('meta')) snapshot.remove('meta');
    await afterSnapshot?.call();
    return snapshot;
  }
}

/// Runs [whileListLoads] after the server answers the first main list page
/// and before the pull sees it, like a read made on this device meanwhile.
class _ListHookClient extends FakeSyncApiClient {
  _ListHookClient(super.server);

  Future<void> Function()? whileListLoads;

  @override
  Future<List<Map<String, dynamic>>> getChatListPage(int page) async {
    final items = await super.getChatListPage(page);
    final hook = whileListLoads;
    whileListLoads = null;
    await hook?.call();
    return items;
  }
}

/// Runs [whileChatLoads] after the server answers a chat download and before
/// the pull merges it, like a read made on this device meanwhile.
class _ChatHookClient extends FakeSyncApiClient {
  _ChatHookClient(super.server);

  Future<void> Function(String id)? whileChatLoads;

  @override
  Future<Map<String, dynamic>?> getChatRaw(String id) async {
    final raw = await super.getChatRaw(id);
    await whileChatLoads?.call(id);
    return raw;
  }
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
    test('large chat normalization uses the worker-offload seam', () async {
      var offloadCalls = 0;
      final workerManager = WorkerManager();
      addTearDown(workerManager.dispose);
      pull = PullSync(
        client: client,
        db: db,
        locks: locks,
        rowsParseOffload: (response) {
          offloadCalls++;
          return workerManager.schedule(
            parseChatRowsWorker,
            response,
            debugLabel: 'test.pull.normalizeChatRows',
          );
        },
      );
      server.seedChat(
        id: 'threshold',
        blob: blobFor(
          'threshold',
          messageCount: kLocalConversationWorkerThreshold,
        ),
        createdAt: 50,
        updatedAt: 100,
      );
      server.seedChat(
        id: 'large',
        blob: blobFor(
          'large',
          messageCount: kLocalConversationWorkerThreshold + 1,
        ),
        createdAt: 100,
        updatedAt: 200,
      );

      final result = await pull.run();

      check(result.success).isTrue();
      check(offloadCalls).equals(1);
      check((await db.messagesDao.getForChat('large')).length)
          .equals(kLocalConversationWorkerThreshold + 1);
      check((await db.messagesDao.getForChat('threshold')).length)
          .equals(kLocalConversationWorkerThreshold);
    });

    test(
      'a few messages carrying large inline data also use the worker',
      () async {
        var offloadCalls = 0;
        final workerManager = WorkerManager();
        addTearDown(workerManager.dispose);
        pull = PullSync(
          client: client,
          db: db,
          locks: locks,
          rowsParseOffload: (response) {
            offloadCalls++;
            return workerManager.schedule(
              parseChatRowsWorker,
              response,
              debugLabel: 'test.pull.normalizeChatRows',
            );
          },
        );
        final inline = blobFor('inline');
        final messages =
            (inline['history'] as Map<String, dynamic>)['messages']
                as Map<String, dynamic>;
        (messages['inline-m2'] as Map<String, dynamic>)['content'] =
            'x' * (kLocalConversationWorkerPayloadThreshold + 1);
        server.seedChat(
          id: 'inline',
          blob: inline,
          createdAt: 100,
          updatedAt: 200,
        );
        server.seedChat(
          id: 'small',
          blob: blobFor('small'),
          createdAt: 50,
          updatedAt: 100,
        );

        final result = await pull.run();

        check(result.success).isTrue();
        check(offloadCalls).equals(1);
        final stored = await db.messagesDao.getForChat('inline');
        check(stored.length).equals(2);
        check(stored.last.content.length)
            .equals(kLocalConversationWorkerPayloadThreshold + 1);
      },
    );

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
      check(rows.keys)
          .unorderedEquals(['plain', 'pinned', 'foldered', 'archived']);
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
      check((await db.foldersDao.watchFolders().first).map((f) => f.id))
          .deepEquals(['folder-1']);
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
      check((await allChats()).map((c) => c.id))
          .unorderedEquals(['chat-1', 'chat-3']);

      client.failChatIds.clear();
      final healed = await pull.run();
      check(healed.success).isTrue();
      check(healed.watermarkAdvanced).isTrue();
      check(await db.syncMetaDao.getPullWatermark()).equals(300);
      check((await allChats()).map((c) => c.id))
          .unorderedEquals(['chat-1', 'chat-2', 'chat-3']);
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
        check((client as _MalformedFullArchivedListClient).pages)
            .deepEquals([1]);
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

  test('an answer stored while a pull reads the chat stays', () async {
    final blob = blobFor('chat-1');
    server.seedChat(id: 'chat-1', blob: blob, createdAt: 100, updatedAt: 150);
    await pull.pullChat('chat-1');

    final late = _LateReadClient(server);
    final gate = Completer<void>();
    late.readGate = gate.future;
    pull = PullSync(client: late, db: db, locks: locks);
    final pulling = pull.pullChat('chat-1');
    await late.readTaken.future;
    // The answer failed meanwhile. The server saved its error and then told
    // this device, which stored the answer with it.
    final messages = (blob['history'] as Map)['messages'] as Map;
    final failed = <String, dynamic>{
      ...messages['chat-1-m2'] as Map<String, dynamic>,
      'error': {'content': 'Connection lost'},
    };
    server.seedChat(
      id: 'chat-1',
      blob: {
        ...blob,
        'history': {
          'messages': {...messages, 'chat-1-m2': failed},
          'currentId': 'chat-1-m2',
        },
      },
      createdAt: 100,
      updatedAt: 151,
    );
    await db.messagesDao.upsertLocalEchoTurn(
      chatId: 'chat-1',
      user: null,
      assistant: MessageRowData(
        id: 'chat-1-m2',
        chatId: 'chat-1',
        parentId: 'chat-1-m1',
        role: 'assistant',
        content: failed['content'] as String,
        model: 'llama3',
        createdAt: 1002,
        orderIndex: -1,
        payload: failed,
      ),
    );
    gate.complete();
    await pulling;

    final answer = (await db.messagesDao.getForChat('chat-1'))
        .singleWhere((row) => row.id == 'chat-1-m2');
    check((jsonDecode(answer.payload) as Map)['error'])
        .isA<Map<String, dynamic>>()['content']
        .equals('Connection lost');
  });

  group('a chat listed but never opened, so its body was never fetched', () {
    // The turn after `chat-1-m2`, as this device stores it.
    Future<void> storeTurn(String answer) => db.messagesDao.upsertLocalEchoTurn(
      chatId: 'chat-1',
      user: const MessageRowData(
        id: 'chat-1-m3',
        chatId: 'chat-1',
        parentId: null,
        role: 'user',
        content: 'message 3 of chat-1',
        createdAt: 1003,
        orderIndex: -1,
        payload: {
          'id': 'chat-1-m3',
          'role': 'user',
          'content': 'message 3 of chat-1',
        },
      ),
      assistant: MessageRowData(
        id: 'chat-1-m4',
        chatId: 'chat-1',
        parentId: 'chat-1-m3',
        role: 'assistant',
        content: answer,
        model: 'llama3',
        createdAt: 1004,
        orderIndex: -1,
        payload: {
          'id': 'chat-1-m4',
          'role': 'assistant',
          'content': answer,
          'model': 'llama3',
        },
      ),
    );

    setUp(() async {
      await db.chatsDao.upsertEnvelopeStub(
        id: 'chat-1',
        title: 'Title chat-1',
        createdAt: 100,
        updatedAt: 150,
      );
      server.seedChat(
        id: 'chat-1',
        blob: blobFor('chat-1'),
        createdAt: 100,
        updatedAt: 150,
      );
    });

    test('keeps an answer stored while a pull reads it', () async {
      final late = _LateReadClient(server);
      final gate = Completer<void>();
      late.readGate = gate.future;
      pull = PullSync(client: late, db: db, locks: locks);
      final pulling = pull.pullChat('chat-1');
      await late.readTaken.future;
      // The server stored the next answer, and then this device did.
      server.seedChat(
        id: 'chat-1',
        blob: blobFor('chat-1', messageCount: 4),
        createdAt: 100,
        updatedAt: 151,
      );
      await storeTurn('message 4 of chat-1');
      gate.complete();
      final pulled = await pulling;

      check((await db.messagesDao.getForChat('chat-1')).map((row) => row.id))
          .deepEquals(['chat-1-m1', 'chat-1-m2', 'chat-1-m3', 'chat-1-m4']);
      check((await db.chatsDao.getChat('chat-1'))!.bodySynced).isTrue();
      check(pulled!.messages.last.content).equals('message 4 of chat-1');
    });

    test('keeps a turn stored here while every read of it is made, and the '
        "pull answers with the server's copy", () async {
      final answers = ['Part of an answer', 'The whole answer'];
      final hooked = _ChatHookClient(server)
        ..whileChatLoads = (id) => storeTurn(answers.removeAt(0));
      pull = PullSync(client: hooked, db: db, locks: locks);

      final pulled = await pull.pullChat('chat-1');

      final stored = await db.messagesDao.getForChat('chat-1');
      check(stored.map((row) => row.id)).deepEquals(['chat-1-m3', 'chat-1-m4']);
      check(stored.last.content).equals('The whole answer');
      check((await db.chatsDao.getChat('chat-1'))!.bodySynced).isFalse();
      // The stored rows are only the turn stored here, not the chat.
      check(pulled!.messages.map((message) => message.id))
          .deepEquals(['chat-1-m1', 'chat-1-m2']);
    });

    // The copy shows `answer-b`, kept beside `answer-a`.
    void seedTwoAnswers() => server.seedChat(
      id: 'chat-1',
      blob: {
        'title': 'Title chat-1',
        'models': ['llama3'],
        'history': {
          'currentId': 'answer-b',
          'messages': {
            'chat-1-m1': {
              'id': 'chat-1-m1',
              'parentId': null,
              'childrenIds': ['answer-a', 'answer-b'],
              'role': 'user',
              'content': 'message 1 of chat-1',
              'timestamp': 1001,
            },
            for (final (id, content, timestamp) in [
              ('answer-a', 'The first answer', 1002),
              ('answer-b', 'The second answer', 1003),
            ])
              id: {
                'id': id,
                'parentId': 'chat-1-m1',
                'childrenIds': <String>[],
                'role': 'assistant',
                'content': content,
                'timestamp': timestamp,
                'model': 'llama3',
              },
          },
        },
      },
      createdAt: 100,
      updatedAt: 150,
    );

    for (final landed in [false, true]) {
      test(
        "answers with the server's copy, after every read of it predates a "
        'turn stored here, without an answer whose delete '
        '${landed ? 'landed while it was read' : 'has not landed'}',
        () async {
          seedTwoAnswers();
          if (!landed) {
            await db.outboxDao.enqueue(
              kind: OutboxKind.deleteMessages,
              chatId: 'chat-1',
              payload: {
                kDeleteMessagesIdsKey: ['answer-b'],
              },
            );
          }
          final answers = ['Part of an answer', 'The whole answer'];
          final hooked = _ChatHookClient(server)
            ..whileChatLoads = (id) async {
              await storeTurn(answers.removeAt(0));
              // After the last copy was read.
              if (landed && answers.isEmpty) {
                db.chatsDao.noteMessageDeletesLanded('chat-1', ['answer-b']);
              }
            };
          pull = PullSync(client: hooked, db: db, locks: locks);

          final pulled = await pull.pullChat('chat-1');

          check(pulled!.messages.map((message) => message.id))
              .deepEquals(['chat-1-m1', 'answer-a']);
          check(pulled.messages.last.versions).isEmpty();
          check(
            (await db.messagesDao.getForChat('chat-1')).map((row) => row.id),
          ).deepEquals(['chat-1-m3', 'chat-1-m4']);
        },
      );
    }

    test('answers with a copy it parsed before an account-wide change ran, '
        'never one it parsed after', () async {
      final order = <String>[];
      final parseTaken = Completer<void>();
      final parseGate = Completer<void>();
      final answers = ['Part of an answer', 'The whole answer'];
      final hooked = _ChatHookClient(server)
        ..whileChatLoads = (id) => storeTurn(answers.removeAt(0));
      pull = PullSync(
        client: hooked,
        db: db,
        locks: locks,
        parseOffload: (envelope) async {
          parseTaken.complete();
          await parseGate.future;
          order.add('parsed');
          return parseFullConversationModel(envelope);
        },
      );

      final opening = pull.pullChat('chat-1');
      await parseTaken.future;
      final change = locks.runBarrier(() async => order.add('change'));
      parseGate.complete();
      final pulled = await opening;
      await change;

      check(pulled).isNotNull();
      check(order).deepEquals(['parsed', 'change']);
    });

    test("answers without an answer whose delete lands while the server's "
        'copy is parsed', () async {
      seedTwoAnswers();
      final parseTaken = Completer<void>();
      final parseGate = Completer<void>();
      final answers = ['Part of an answer', 'The whole answer'];
      final hooked = _ChatHookClient(server)
        ..whileChatLoads = (id) => storeTurn(answers.removeAt(0));
      pull = PullSync(
        client: hooked,
        db: db,
        locks: locks,
        parseOffload: (envelope) async {
          if (!parseTaken.isCompleted) parseTaken.complete();
          await parseGate.future;
          return parseFullConversationModel(envelope);
        },
      );

      final opening = pull.pullChat('chat-1');
      await parseTaken.future;
      db.chatsDao.noteMessageDeletesLanded('chat-1', ['answer-b']);
      parseGate.complete();
      final pulled = await opening;

      check(pulled!.messages.map((message) => message.id))
          .deepEquals(['chat-1-m1', 'answer-a']);
    });

    test('parses the copy off this isolate twice at most while deletes keep '
        'landing', () async {
      seedTwoAnswers();
      var offloaded = 0;
      final answers = ['Part of an answer', 'The whole answer'];
      final hooked = _ChatHookClient(server)
        ..whileChatLoads = (id) => storeTurn(answers.removeAt(0));
      pull = PullSync(
        client: hooked,
        db: db,
        locks: locks,
        parseOffload: (envelope) async {
          offloaded++;
          // A delete lands during every parse off this isolate.
          db.chatsDao.noteMessageDeletesLanded('chat-1', [
            offloaded == 1 ? 'answer-b' : 'another-answer-$offloaded',
          ]);
          return parseFullConversationModel(envelope);
        },
      );

      final pulled = await pull.pullChat('chat-1');

      check(offloaded).equals(2);
      check(pulled!.messages.map((message) => message.id))
          .deepEquals(['chat-1-m1', 'answer-a']);
    });

    test('with a message of its own not sent yet, keeps a turn stored here '
        'while every read of it is made', () async {
      await db.chatsDao.appendMessagesWithUpdateOp(
        chatId: 'chat-1',
        messages: const [
          MessageRowData(
            id: 'unsent-user',
            chatId: 'chat-1',
            parentId: null,
            role: 'user',
            content: 'An unsent question',
            createdAt: 1001,
            orderIndex: 0,
            payload: {
              'id': 'unsent-user',
              'role': 'user',
              'content': 'An unsent question',
            },
          ),
        ],
        currentMessageId: 'unsent-user',
        updatedAt: 151,
        enqueueCompletion: false,
      );
      final answers = ['Part of an answer', 'The whole answer'];
      final hooked = _ChatHookClient(server)
        ..whileChatLoads = (id) => storeTurn(answers.removeAt(0));
      pull = PullSync(client: hooked, db: db, locks: locks);

      await pull.pullChat('chat-1');

      final stored = await db.messagesDao.getForChat('chat-1');
      check(stored.map((row) => row.id))
          .deepEquals(['unsent-user', 'chat-1-m3', 'chat-1-m4']);
      check(stored.last.content).equals('The whole answer');
      final chat = (await db.chatsDao.getChat('chat-1'))!;
      check(chat.dirty).isTrue();
      check(chat.bodySynced).isFalse();
    });
  });

  // A turn stored here doesn't stamp the server's copy as a push does, so
  // a newer chat can't be allowed to carry the watermark past this one.
  test('a chat every read of which predates a turn stored here holds the '
      'watermark until a later cycle stores it', () async {
    server.seedChat(
      id: 'chat-a',
      blob: blobFor('chat-a'),
      createdAt: 100,
      updatedAt: 100,
    );
    await pull.pullChat('chat-a');
    await db.syncMetaDao.setPullWatermark(100);
    server.seedChat(
      id: 'chat-a',
      blob: blobFor('chat-a'),
      createdAt: 100,
      updatedAt: 101,
    );
    server.seedChat(
      id: 'chat-b',
      blob: blobFor('chat-b'),
      createdAt: 100,
      updatedAt: 120,
    );
    final hooked = _ChatHookClient(server)
      ..whileChatLoads = (id) async {
        if (id == 'chat-a') db.chatsDao.noteLocalTurn('chat-a');
      };
    pull = PullSync(client: hooked, db: db, locks: locks);

    final first = await pull.run();

    check(first.watermarkAdvanced).isFalse();
    check(await db.syncMetaDao.getPullWatermark()).equals(100);

    hooked.whileChatLoads = null;
    await pull.run();

    check((await db.chatsDao.getChat('chat-a'))!.updatedAt).equals(101);
    check(await db.syncMetaDao.getPullWatermark()).equals(120);
  });

  group('a model picked while a pull reads the chat', () {
    Future<List<Object?>?> stored() => db.chatsDao.storedChatModels('chat-1');
    void seed(List<String> models) => server.seedChat(
      id: 'chat-1',
      blob: {...blobFor('chat-1'), 'models': models},
      createdAt: 100,
      updatedAt: 150,
    );

    test('stays over the list the pull read before it', () async {
      seed(['model-1']);
      await pull.pullChat('chat-1');
      check(await stored()).isNotNull().deepEquals(['model-1']);

      // A pull has read the chat, and waits to store it; meanwhile the user
      // picks a model, which is stored at once and sent to the server after.
      final late = _LateReadClient(server);
      final gate = Completer<void>();
      late.readGate = gate.future;
      pull = PullSync(client: late, db: db, locks: locks);
      final pulling = pull.pullChat('chat-1');
      await late.readTaken.future;
      await db.chatsDao.setChatModels('chat-1', const ['model-2']);
      gate.complete();
      await pulling;

      check(await stored()).isNotNull().deepEquals(['model-2']);

      // Once the server has taken it, a pull takes the server's list again.
      await db.chatsDao.setChatModels(
        'chat-1',
        const ['model-2'],
        confirmed: true,
      );
      seed(['model-3']);
      pull = PullSync(client: client, db: db, locks: locks);
      await pull.pullChat('chat-1');
      check(await stored()).isNotNull().deepEquals(['model-3']);
    });

    test('a chat with edits of its own, read by name, takes the server\'s '
        'list once a pick is given up, and keeps its edits', () async {
      seed(['model-1']);
      await pull.pullChat('chat-1');
      // A title edit here, not pushed yet, leaves the chat dirty.
      await (db.update(db.chats)..where((t) => t.id.equals('chat-1'))).write(
        const ChatsCompanion(dirty: Value(true), title: Value('Mine')),
      );

      // Picked and not taken yet: a read by name keeps it.
      await db.chatsDao.setChatModels('chat-1', const ['model-2']);
      await pull.pullChat('chat-1');
      check(await stored()).isNotNull().deepEquals(['model-2']);

      // Given up: a read by name, the server having changed nothing since,
      // takes the server's list, and only that.
      db.chatsDao.releaseUnconfirmedModelList('chat-1');
      await pull.pullChat('chat-1');
      check(await stored()).isNotNull().deepEquals(['model-1']);
      final row = (await db.chatsDao.getChat('chat-1'))!;
      check(row.title).equals('Mine');
      check(row.dirty).isTrue();
    });

    test('stays over a copy read after it, until the server has taken it',
        () async {
      seed(['model-1']);
      await pull.pullChat('chat-1');

      // Picked, not sent yet: the server still holds the earlier list.
      await db.chatsDao.setChatModels('chat-1', const ['model-2']);
      await pull.pullChat('chat-1');
      check(await stored()).isNotNull().deepEquals(['model-2']);
    });

    test('a turn sent with a list keeps it over a copy read before it',
        () async {
      seed(['model-1']);
      await pull.pullChat('chat-1');

      final late = _LateReadClient(server);
      final gate = Completer<void>();
      late.readGate = gate.future;
      pull = PullSync(client: late, db: db, locks: locks);
      final pulling = pull.pullChat('chat-1');
      await late.readTaken.future;
      await db.chatsDao.appendMessagesWithUpdateOp(
        chatId: 'chat-1',
        messages: const [],
        enqueueUpdate: false,
        enqueueCompletion: false,
        chatModels: const ['model-a', 'model-b'],
      );
      gate.complete();
      await pulling;

      check(await stored()).isNotNull().deepEquals(['model-a', 'model-b']);

      // A copy read after the turn, from before its update op landed, still
      // holds the old list: the turn's stays.
      await pull.pullChat('chat-1');
      check(await stored()).isNotNull().deepEquals(['model-a', 'model-b']);
      check(db.chatsDao.hasUnconfirmedModelList('chat-1')).isTrue();

      // Once a copy carries it, the server has it, and it is no longer held.
      seed(['model-a', 'model-b']);
      await pull.pullChat('chat-1');
      check(db.chatsDao.hasUnconfirmedModelList('chat-1')).isFalse();
      seed(['model-c']);
      await pull.pullChat('chat-1');
      check(await stored()).isNotNull().deepEquals(['model-c']);
    });

    test('a pick never stored holds nothing over the server', () async {
      await db.chatsDao.setChatModels('no-such-chat', const ['model-2']);
      check(db.chatsDao.hasUnconfirmedModelList('no-such-chat')).isFalse();
    });

    test('an envelope that cannot be read keeps no list', () async {
      seed(['model-1']);
      await pull.pullChat('chat-1');
      await (db.update(db.chats)..where((t) => t.id.equals('chat-1'))).write(
        const ChatsCompanion(rawExtra: Value('not json')),
      );
      check(await stored()).isNull();
    });
  });

  group('checklist persistence', () {
    const pending = [
      {'id': '1', 'content': 'Read references', 'status': 'pending'},
    ];
    const completed = [
      {'id': '1', 'content': 'Read references', 'status': 'completed'},
    ];

    Future<_ChecklistClient> setupChecklist({bool existing = true}) async {
      server.seedChat(
        id: 'chat-1',
        blob: blobFor('chat-1'),
        createdAt: 100,
        updatedAt: 150,
      );
      final checklistClient = _ChecklistClient(server)
        ..fields = {
          'meta': {
            'tags': ['old'],
          },
          'tasks': pending,
        };
      pull = PullSync(client: checklistClient, db: db, locks: locks);
      if (existing) await pull.pullChat('chat-1');
      return checklistClient;
    }

    test('explicit empty metadata removes tags while omitted metadata preserves them', () async {
      final checklistClient = await setupChecklist();
      checklistClient.fields = {'tasks': completed};
      await pull.pullChat('chat-1');
      expect(jsonDecode((await db.chatsDao.getChat('chat-1'))!.meta)['tags'], [
        'old',
      ]);
      checklistClient.fields = {
        'meta': <String, dynamic>{},
        'tasks': completed,
      };
      final reloaded = (await pull.pullChat('chat-1'))!;
      expect(reloaded.tags, isEmpty);
      expect(reloaded.metadata['openwebui_tasks'], completed);
      checklistClient.fields = {'meta': <String, dynamic>{}, 'updated_at': 151};
      final withoutTasks = (await pull.pullChat('chat-1'))!;
      expect(withoutTasks.tags, isEmpty);
      expect(withoutTasks.metadata['openwebui_tasks'], completed);
    });

    for (final existing in [true, false]) {
      for (final mode in ['single', 'cycle', 'adapter']) {
        test(
          '$mode pull with existing=$existing cannot overwrite task events received during its fetch',
          () async {
            final checklistClient = await setupChecklist(existing: existing);
            checklistClient.afterSnapshot = () => locks.runExclusive(
              'chat-1',
              () => db.chatsDao.updateServerTasks('chat-1', completed),
            );
            for (var attempt = 0; attempt < 2; attempt++) {
              if (mode == 'single') {
                await pull.pullChat('chat-1');
              } else if (mode == 'cycle') {
                await pull.run();
              } else {
                final snapshot = (await pull.fetchChatRaw('chat-1'))!;
                await pull.mergeChatResponseForAdapter(snapshot);
              }
              expect(
                jsonDecode(
                  (await db.chatsDao.getChat('chat-1'))!.meta,
                )['_conduit_tasks'],
                completed,
              );
            }
            // With no intervening event, an authoritative reset must still apply.
            checklistClient.afterSnapshot = null;
            checklistClient.fields = {'tasks': <Map<String, dynamic>>[]};
            expect(
              (await pull.pullChat('chat-1'))!.metadata['openwebui_tasks'],
              isEmpty,
            );
          },
        );
      }
    }
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
        check(conversation.updatedAt.millisecondsSinceEpoch ~/ 1000)
            .equals(150);

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

    test(
      'a response storeIf rejects comes back from its one download unstored',
      () async {
        server.seedChat(
          id: 'chat-1',
          blob: blobFor('chat-1', messageCount: 3),
          createdAt: 100,
          updatedAt: 150,
        );
        final owners = <Object?>[];

        final conversation = await pull.pullChat(
          'chat-1',
          storeIf: (response) {
            owners.add(response['user_id']);
            return false;
          },
        );

        check(conversation).isNotNull();
        check(conversation!.id).equals('chat-1');
        check(conversation.messages.length).equals(3);
        check(conversation.userId).equals(FakeOpenWebUiServer.userId);
        check(owners).deepEquals([FakeOpenWebUiServer.userId]);
        check(client.chatFetchStarts).deepEquals(['chat-1']);
        check(await allChats()).isEmpty();
        check(await allMessages()).isEmpty();
      },
    );

    test(
      'a response storeIf accepts is stored from its one download',
      () async {
        server.seedChat(
          id: 'chat-1',
          blob: blobFor('chat-1', messageCount: 3),
          createdAt: 100,
          updatedAt: 150,
        );

        final conversation = await pull.pullChat(
          'chat-1',
          storeIf: (_) => true,
        );

        check(conversation!.messages.length).equals(3);
        check((await db.chatsDao.getChat('chat-1'))!.bodySynced).isTrue();
        check(await allMessages()).length.equals(3);
        check(client.chatFetchStarts).deepEquals(['chat-1']);
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

      final ids = (await db.messagesDao.getForChat('chat-1'))
          .map((m) => m.id)
          .toList();
      // Server's m3 inserted AND the dirty local message kept.
      check(ids).contains('chat-1-local');
      check(ids).contains('chat-1-m3');

      // The local message row stays dirty; server-origin rows are clean.
      final localMsg = (await db.messagesDao.getForChat('chat-1'))
          .firstWhere((m) => m.id == 'chat-1-local');
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
        final ids = (await db.messagesDao.getForChat(chatId))
            .map((m) => m.id)
            .toSet();
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
      final checklistClient = _ChecklistClient(server)
        ..fields = {
          'meta': {
            'tags': ['recovered'],
          },
          'tasks': [
            {'id': '1', 'content': 'Check result', 'status': 'pending'},
          ],
        };
      final healingPull = PullSync(
        client: checklistClient,
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

      checklistClient.afterSnapshot = () => locks.runExclusive(
        serverId,
        () => db.chatsDao.updateServerTasks(serverId, [
          {'id': '1', 'content': 'Check result', 'status': 'completed'},
        ]),
      );

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
      final persistedMeta = jsonDecode(
        (await db.chatsDao.getChat(serverId))!.meta,
      );
      expect(persistedMeta['tags'], ['recovered']);
      expect(persistedMeta['_conduit_tasks'], [
        {'id': '1', 'content': 'Check result', 'status': 'completed'},
      ]);
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

    test('an orphaned matching create does not synthesize a remap', () async {
      final remapper = IdRemapper(db);
      addTearDown(remapper.dispose);
      final healingPull = PullSync(
        client: client,
        db: db,
        locks: locks,
        remapper: remapper,
      );
      const localId = 'local:orphaned-create';
      final blob = blobFor('orphaned', messageCount: 2);
      final rows = ChatBlobMapper.blobToRows(
        chatId: localId,
        blob: blob,
        title: 'Title orphaned',
        createdAt: 100,
        updatedAt: 200,
      );
      await db.chatsDao.insertLocalChatWithCreateOp(
        chat: rows.chat,
        messages: rows.messages,
        blobRows: rows,
        contentHash: createChatContentHash(rows),
      );
      // Simulate legacy/non-atomic loss of the source while its create op
      // remains. A raw delete intentionally leaves the outbox record behind.
      await (db.delete(db.chats)..where((t) => t.id.equals(localId))).go();
      final serverResponse = server.createChat({...blob, 'id': ''});
      final serverId = serverResponse['id'] as String;

      final result = await healingPull.run();

      check(result.success).isTrue();
      check(await db.chatsDao.getChat(serverId)).isNotNull();
      check(await db.syncMetaDao.getChatRemapTarget(localId)).isNull();
      check(await db.outboxDao.pendingForChat(localId)).isEmpty();
      check((await db.select(db.chats).get()).map((chat) => chat.id))
          .deepEquals([serverId]);
    });
  });

  group('overlap-window fetch memo', () {
    late int fakeElapsedMs;
    late PullFetchMemo memo;
    late PullSync memoPull;

    // Advances the memo's monotonic clock past the confirm spacing, as real
    // wall time between periodic pull cycles would.
    void advancePastConfirmSpacing() {
      fakeElapsedMs += kPullOverlapSeconds * 1000;
    }

    setUp(() {
      fakeElapsedMs = 0;
      memo = PullFetchMemo(elapsedMs: () => fakeElapsedMs);
      memoPull = PullSync(
        client: client,
        db: db,
        locks: locks,
        fetchMemo: memo,
      );
    });

    test('a chat pinned at the watermark stops being re-fetched after a '
        'confirming cycle', () async {
      // The newest chat's updatedAt IS the watermark after cycle 1, so it
      // sits inside the overlap window of every later cycle. Observed on
      // device: re-downloaded + re-merged on every pull, indefinitely.
      server.seedChat(
        id: 'at-watermark',
        blob: blobFor('at-watermark'),
        createdAt: 100,
        updatedAt: 200,
      );

      await memoPull.run(); // fetch 1: first sight
      advancePastConfirmSpacing();
      await memoPull.run(); // fetch 2: confirming re-fetch
      check(client.chatFetchStarts.where((id) => id == 'at-watermark').length)
          .equals(2);

      advancePastConfirmSpacing();
      await memoPull.run(); // skipped
      await memoPull.run(); // skipped
      check(client.chatFetchStarts.where((id) => id == 'at-watermark').length)
          .equals(2);

      // Local row is untouched by the skips.
      final row = await db.chatsDao.getChat('at-watermark');
      check(row!.bodySynced).isTrue();
      check(row.serverUpdatedAt).equals(200);
    });

    test('a server edit at a new stamp is always re-fetched', () async {
      server.seedChat(
        id: 'edited',
        blob: blobFor('edited'),
        createdAt: 100,
        updatedAt: 200,
      );
      await memoPull.run();
      advancePastConfirmSpacing();
      await memoPull.run();
      check(client.chatFetchStarts.where((id) => id == 'edited').length)
          .equals(2);

      // Same-id edit with a bumped stamp: memo entry no longer matches.
      server.seedChat(
        id: 'edited',
        blob: blobFor('edited', messageCount: 4),
        createdAt: 100,
        updatedAt: 300,
      );
      advancePastConfirmSpacing();
      await memoPull.run();
      check(client.chatFetchStarts.where((id) => id == 'edited').length)
          .equals(3);
      final row = await db.chatsDao.getChat('edited');
      check(row!.serverUpdatedAt).equals(300);
    });

    test(
      're-fetches inside the confirm spacing window never confirm a skip',
      () {
        // Two full cycles can run within the same server second (debounced
        // back-to-back triggers); updatedAt has one-second resolution, so
        // both fetches could predate a third same-second write. Only a
        // re-fetch spaced past the overlap window proves the stamped second
        // is over.
        var clock = 0;
        final spacedMemo = PullFetchMemo(elapsedMs: () => clock);
        spacedMemo.recordFetched('a', 100);
        clock += 10; // same-second back-to-back cycle
        spacedMemo.recordFetched('a', 100);
        check(spacedMemo.isConfirmed('a', 100)).isFalse();

        clock += kPullOverlapSeconds * 1000;
        spacedMemo.recordFetched('a', 100);
        check(spacedMemo.isConfirmed('a', 100)).isTrue();
        // A different stamp is never confirmed by the old one.
        check(spacedMemo.isConfirmed('a', 200)).isFalse();
        // And a new stamp restarts the spacing requirement.
        spacedMemo.recordFetched('a', 200);
        clock += 10;
        spacedMemo.recordFetched('a', 200);
        check(spacedMemo.isConfirmed('a', 200)).isFalse();
      },
    );

    test('a locally dirty row is fetched despite a confirmed memo', () async {
      server.seedChat(
        id: 'dirtied',
        blob: blobFor('dirtied'),
        createdAt: 100,
        updatedAt: 200,
      );
      await memoPull.run();
      advancePastConfirmSpacing();
      await memoPull.run();
      final fetchesBefore = client.chatFetchStarts
          .where((id) => id == 'dirtied')
          .length;

      // Local divergence invalidates the skip even though the memo matches.
      await (db.update(db.chats)..where((t) => t.id.equals('dirtied'))).write(
        const ChatsCompanion(dirty: Value(true)),
      );
      advancePastConfirmSpacing();
      await memoPull.run();
      check(client.chatFetchStarts.where((id) => id == 'dirtied').length)
          .equals(fetchesBefore + 1);
    });

    test('a server unread re-fetches a chat the memo would skip', () async {
      server.seedChat(
        id: 'unread-elsewhere',
        blob: blobFor('unread-elsewhere'),
        createdAt: 100,
        updatedAt: 200,
      );
      await memoPull.run();
      advancePastConfirmSpacing();
      await memoPull.run();
      await db.chatsDao.setLastReadAt('unread-elsewhere', 250);

      // Marking unread leaves updated_at alone, so only last_read_at moved.
      server.markChatUnread('unread-elsewhere');
      advancePastConfirmSpacing();
      await memoPull.run();

      check(
        client.chatFetchStarts.where((id) => id == 'unread-elsewhere').length,
      ).equals(3);
      check(
        (await db.chatsDao.getChat('unread-elsewhere'))!.lastReadAt,
      ).equals(0);
    });
  });

  group('read state on list rows', () {
    // 'older' sits below the watermark after the first cycle, so later
    // cycles see it on the list page without fetching it.
    Future<void> seedOlderAndNewer() async {
      server.seedChat(
        id: 'older',
        blob: blobFor('older'),
        createdAt: 100,
        updatedAt: 100,
      );
      server.seedChat(
        id: 'newer',
        blob: blobFor('newer'),
        createdAt: 500,
        updatedAt: 500,
      );
      await pull.run();
      await db.chatsDao.setLastReadAt('older', 300);
      client.chatFetchStarts.clear();
    }

    test('a chat marked unread elsewhere shows unread after a pull', () async {
      await seedOlderAndNewer();

      server.markChatUnread('older');
      await pull.run();

      check(client.chatFetchStarts).not((it) => it.contains('older'));
      check((await db.chatsDao.getChat('older'))!.lastReadAt).equals(0);
    });

    test('a chat read elsewhere moves its read time forward', () async {
      await seedOlderAndNewer();

      final previous = await db.chatsDao.markUnread('older');
      await db.chatsDao.finishUnread(
        'older',
        refused: false,
        previous: previous,
      );
      server.seedChat(
        id: 'older',
        blob: blobFor('older'),
        createdAt: 100,
        updatedAt: 100,
        lastReadAt: 400,
      );
      await pull.run();

      check((await db.chatsDao.getChat('older'))!.lastReadAt).equals(400);
    });

    test('a read made here while the list loads is kept', () async {
      final hookClient = _ListHookClient(server);
      pull = PullSync(client: hookClient, db: db, locks: locks);
      await seedOlderAndNewer();

      server.markChatUnread('older');
      hookClient.whileListLoads = () => db.chatsDao.setLastReadAt('older', 600);
      await pull.run();

      check((await db.chatsDao.getChat('older'))!.lastReadAt).equals(600);
    });

    test('an unread whose request lands after the list is kept', () async {
      final hookClient = _ListHookClient(server);
      pull = PullSync(client: hookClient, db: db, locks: locks);
      server.seedChat(
        id: 'older',
        blob: blobFor('older'),
        createdAt: 100,
        updatedAt: 100,
        lastReadAt: 300,
      );
      server.seedChat(
        id: 'newer',
        blob: blobFor('newer'),
        createdAt: 500,
        updatedAt: 500,
        lastReadAt: 500,
      );
      await pull.run();

      // Both marked unread here; the list is read before the server stores
      // either, and both requests succeed before the pull applies it.
      final olderBefore = await db.chatsDao.markUnread('older');
      final newerBefore = await db.chatsDao.markUnread('newer');
      hookClient.whileListLoads = () async {
        server
          ..markChatUnread('older')
          ..markChatUnread('newer');
        await db.chatsDao.finishUnread(
          'older',
          refused: false,
          previous: olderBefore,
        );
        await db.chatsDao.finishUnread(
          'newer',
          refused: false,
          previous: newerBefore,
        );
      };
      await pull.run();

      // 'newer' sits in the overlap window, so it went through the merge.
      check(hookClient.chatFetchStarts.where((id) => id == 'newer').length)
          .equals(2);
      check((await db.chatsDao.getChat('older'))!.lastReadAt).equals(0);
      check((await db.chatsDao.getChat('newer'))!.lastReadAt).equals(0);
    });

    test('a chat whose download fails still takes its read state', () async {
      await seedOlderAndNewer();
      await db.chatsDao.setLastReadAt('newer', 600);

      // 'newer' is in the overlap window, so the pull downloads it.
      server.markChatUnread('newer');
      client.failChatIds.add('newer');
      final result = await pull.run();

      check(result.success).isFalse();
      check((await db.chatsDao.getChat('newer'))!.lastReadAt).equals(0);
    });

    test('a read made here while a chat downloads is kept', () async {
      final hookClient = _ChatHookClient(server);
      pull = PullSync(client: hookClient, db: db, locks: locks);
      await seedOlderAndNewer();

      server.markChatUnread('newer');
      hookClient.whileChatLoads = (id) async {
        if (id == 'newer') await db.chatsDao.setLastReadAt('newer', 700);
      };
      await pull.run();

      check(hookClient.chatFetchStarts).contains('newer');
      check((await db.chatsDao.getChat('newer'))!.lastReadAt).equals(700);
    });
  });

  group('an account-wide change that ends while a read is in flight', () {
    // The server deletes the chat after the read was taken but before it is
    // stored, so the read still describes a chat that no longer exists.
    Future<void> deleteAllOnServer() => locks.runBarrier(() async {
      server.deleteChat('x');
    });

    test('a chat read before it is not stored after it, and the cycle is '
        'retried rather than called done', () async {
      server.seedChat(
        id: 'x',
        blob: blobFor('x'),
        createdAt: 100,
        updatedAt: 200,
      );
      final late = _LateReadClient(server);
      final latePull = PullSync(client: late, db: db, locks: locks);
      final gate = Completer<void>();
      late.readGate = gate.future;

      final running = latePull.run();
      await late.readTaken.future;
      await deleteAllOnServer();
      gate.complete();
      final result = await running;

      check(await db.chatsDao.getChat('x')).isNull();
      check(result.success).isFalse();
      check(result.failedFetches).equals(1);
      // The watermark stays where it was, so the next cycle reads again.
      check(await db.syncMetaDao.getPullWatermark()).equals(0);
    });

    test('an archived chat listed before it is not stubbed after it', () async {
      server.seedChat(
        id: 'x',
        blob: blobFor('x'),
        createdAt: 100,
        updatedAt: 200,
        archived: true,
      );
      final late = _LateReadClient(server);
      final latePull = PullSync(client: late, db: db, locks: locks);
      final gate = Completer<void>();
      late.listGate = gate.future;

      final running = latePull.run();
      await late.listTaken.future;
      await deleteAllOnServer();
      gate.complete();
      final result = await running;

      check(await db.chatsDao.getChat('x')).isNull();
      check(result.success).isFalse();
      check(await db.syncMetaDao.getPullWatermark()).equals(0);
    });

    test('a chat opened by name before it comes back as absent', () async {
      server.seedChat(
        id: 'x',
        blob: blobFor('x'),
        createdAt: 100,
        updatedAt: 200,
      );
      final late = _LateReadClient(server);
      final latePull = PullSync(client: late, db: db, locks: locks);
      final gate = Completer<void>();
      late.readGate = gate.future;

      final opening = latePull.pullChat('x');
      await late.readTaken.future;
      await deleteAllOnServer();
      gate.complete();

      check(await opening).isNull();
      check(await db.chatsDao.getChat('x')).isNull();
    });

    test(
      'a chat read before it comes back as absent even when not stored',
      () async {
        server.seedChat(
          id: 'x',
          blob: blobFor('x'),
          createdAt: 100,
          updatedAt: 200,
        );
        final late = _LateReadClient(server);
        final latePull = PullSync(client: late, db: db, locks: locks);
        final gate = Completer<void>();
        late.readGate = gate.future;

        final opening = latePull.pullChat('x', storeIf: (_) => false);
        await late.readTaken.future;
        await deleteAllOnServer();
        gate.complete();

        check(await opening).isNull();
        check(await db.chatsDao.getChat('x')).isNull();
      },
    );

    test('a read that begins after the change is stored as usual', () async {
      server.seedChat(
        id: 'y',
        blob: blobFor('y'),
        createdAt: 100,
        updatedAt: 200,
      );
      await deleteAllOnServer();

      final result = await pull.run();

      check(result.success).isTrue();
      check(await db.chatsDao.getChat('y')).isNotNull();
    });
  });

  // Open WebUI 0.13.4 pins and archives a chat without moving its
  // `updated_at`, as the fake's toggles do, so no list page above the
  // watermark shows either change.
  group('pins and archives made elsewhere', () {
    setUp(() {
      pull = PullSync(
        client: client,
        db: db,
        locks: locks,
        readerAccountId: () => FakeOpenWebUiServer.userId,
      );
    });

    void keepAcrossPulls() {
      pull = PullSync(
        client: client,
        db: db,
        locks: locks,
        readerAccountId: () => FakeOpenWebUiServer.userId,
        fetchMemo: PullFetchMemo(),
      );
    }

    // 'older' sits below the watermark after the first cycle.
    Future<void> seedOlderAndNewer({
      bool olderArchived = false,
      bool olderPinned = false,
    }) async {
      server.seedChat(
        id: 'older',
        blob: blobFor('older'),
        createdAt: 100,
        updatedAt: 100,
        archived: olderArchived,
        pinned: olderPinned,
      );
      server.seedChat(
        id: 'newer',
        blob: blobFor('newer'),
        createdAt: 500,
        updatedAt: 500,
      );
      await pull.run();
      client.chatFetchStarts.clear();
    }

    Future<ChatRow> older() async => (await db.chatsDao.getChat('older'))!;

    // Held here as archived after the first cycle, then deleted on the
    // server, which answers 401 for it: the deletion reconcile removes it,
    // and until then it keeps the archived counts apart.
    void seedDeletedWhileArchived() => server.seedChat(
      id: 'gone',
      blob: blobFor('gone'),
      createdAt: 100,
      updatedAt: 100,
      archived: true,
    );
    void deleteOnServer(String id) {
      server.deleteChat(id);
      client.failChatIds.add(id);
    }

    test('a chat pinned and then unpinned elsewhere follows', () async {
      await seedOlderAndNewer();

      server.togglePin('older');
      final pinned = await pull.run();
      check(pinned.success).isTrue();
      check((await older()).pinned).isTrue();

      server.togglePin('older');
      await pull.run();
      check((await older()).pinned).isFalse();
    });

    test('a chat archived elsewhere is archived, its body kept', () async {
      await seedOlderAndNewer();

      server.toggleArchive('older');
      final result = await pull.run();

      check(result.success).isTrue();
      check((await older()).archived).isTrue();
      check((await older()).bodySynced).isTrue();
    });

    test('a chat unarchived elsewhere comes back', () async {
      await seedOlderAndNewer(olderArchived: true);
      check((await older()).archived).isTrue();

      server.toggleArchive('older');
      await pull.run();

      check((await older()).archived).isFalse();
    });

    test('a pin made here while the pinned list loads is kept', () async {
      await seedOlderAndNewer();
      // The list is answered before this device's pin reaches the server.
      client.whilePinnedListLoads = () async {
        server.togglePin('older');
        await db.chatsDao.updateEnvelope('older', pinned: const Value(true));
      };

      await pull.run();

      check((await older()).pinned).isTrue();
    });

    test('a chat deleted while archived is read for once, not on every '
        'pull', () async {
      pull = PullSync(
        client: client,
        db: db,
        locks: locks,
        readerAccountId: () => FakeOpenWebUiServer.userId,
        fetchMemo: PullFetchMemo(),
      );
      await seedOlderAndNewer(olderArchived: true);
      server.deleteChat('older');
      // Open WebUI answers 401 for a chat it no longer has.
      client.failChatIds.add('older');

      final first = await pull.run();
      await pull.run();

      check(first.success).isTrue();
      check(client.chatFetchStarts.where((id) => id == 'older')).length
          .equals(1);
    });

    // Qodo #1206: an older shared chat, stored with no owner, lost its pin.
    test("another user's chat keeps its owner's pin, its owner stored or "
        'not', () async {
      await seedOlderAndNewer();
      // Reached through folders their owner shared; 'theirs-older' was
      // stored before rows kept their owner.
      for (final id in ['theirs', 'theirs-older']) {
        server.seedChat(
          id: id,
          blob: blobFor(id),
          createdAt: 100,
          updatedAt: 100,
          pinned: true,
          ownerId: 'another-user',
        );
        await db.chatsDao.upsertEnvelopeStub(
          id: id,
          title: 'Shared with this account',
          createdAt: 100,
          updatedAt: 100,
          pinned: true,
        );
      }
      await (db.update(db.chats)..where((t) => t.id.equals('theirs'))).write(
        const ChatsCompanion(userId: Value('another-user')),
      );

      await pull.run();

      check((await db.chatsDao.getChat('theirs'))!.pinned).isTrue();
      check((await db.chatsDao.getChat('theirs-older'))!.pinned).isTrue();
    });

    // Qodo #1206: absent from the pinned list, a chat archived elsewhere
    // was unpinned here when the archived counts happened to agree.
    test('a pinned chat archived elsewhere keeps its pin while the counts '
        'agree', () async {
      seedDeletedWhileArchived();
      await seedOlderAndNewer(olderPinned: true);
      deleteOnServer('gone');
      server.toggleArchive('older');

      await pull.run();

      check((await older()).pinned).isTrue();
      check((await older()).archived).isTrue();
    });

    // Pullfrog 4651751894, Greptile 4651759665: a failed read left the
    // counts apart, and the memo kept every later pull from trying again.
    test('a chat unarchived elsewhere comes back after reads that failed '
        'on the way', () async {
      keepAcrossPulls();
      await seedOlderAndNewer(olderArchived: true);
      server.toggleArchive('older');

      client.failArchivedListPages.add(1);
      await pull.run();
      client.failArchivedListPages.clear();
      // A timeout: the server still has the chat.
      client.failChatIds.add('older');
      await pull.run();
      client.failChatIds.clear();
      await pull.run();

      check((await older()).archived).isFalse();
    });

    // Pullfrog 4651751894: an archive held back for a change made here
    // meanwhile is taken on the next pull.
    test('an archive held back for a change made here meanwhile is taken on '
        'the next pull', () async {
      keepAcrossPulls();
      await seedOlderAndNewer();
      server.toggleArchive('older');
      client.whilePinnedListLoads = () => db.chatsDao.updateEnvelope(
        'older',
        title: const Value('Renamed here'),
      );

      await pull.run();
      await pull.run();

      check((await older()).archived).isTrue();
    });

    // Qodo #1206, CodeRabbit 4651783253: counts that moved and came back to
    // a pair a full read had left apart were never read for again.
    test('archived counts that move and come back are read again', () async {
      keepAcrossPulls();
      seedDeletedWhileArchived();
      await seedOlderAndNewer();
      deleteOnServer('gone');
      // Server 0, here 1: the read leaves them apart.
      await pull.run();
      // The deletion reconcile removes 'gone': 0 and 0.
      await db.chatsDao.purgeReconciledChat('gone');
      await pull.run();
      // 'older' archived here: 1 and 1.
      server.toggleArchive('older');
      await db.chatsDao.updateEnvelope('older', archived: const Value(true));
      await pull.run();
      // Unarchived elsewhere: 0 and 1 again.
      server.toggleArchive('older');

      await pull.run();

      check((await older()).archived).isFalse();
    });

    // Qodo #1206: a push that landed after the pinned list was read had its
    // pin put back to the list's.
    test('a pin pushed while the pinned list loads is kept', () async {
      await seedOlderAndNewer();
      await db.chatsDao.updateEnvelopeWithOutbox(
        'older',
        pinned: const Value(true),
        enqueue: false,
      );
      client.whilePinnedListLoads = () async {
        server.togglePin('older');
        db.chatsDao.notePushLanded('older');
      };

      await pull.run();

      check((await older()).pinned).isTrue();
    });

    // Macroscope 4651754450: pinned here before the list was read and
    // unpinned after, the chat was pinned again from the list.
    test('a pin and an unpin made here around the pinned list are '
        'kept', () async {
      await seedOlderAndNewer();
      client
        ..whileArchivedCountLoads = () async {
          server.togglePin('older');
          await db.chatsDao.updateEnvelope('older', pinned: const Value(true));
        }
        ..whilePinnedListLoads = () async {
          server.togglePin('older');
          await db.chatsDao.updateEnvelope('older', pinned: const Value(false));
        };

      await pull.run();

      check((await older()).pinned).isFalse();
    });

    // Greptile 4651759666: archived here after the count was read, the chat
    // was missing from the pinned list and lost its pin.
    test('a pinned chat archived here while the lists load keeps its '
        'pin', () async {
      await seedOlderAndNewer(olderPinned: true);
      client.whileArchivedCountLoads = () async {
        server.toggleArchive('older');
        await db.chatsDao.updateEnvelope('older', archived: const Value(true));
      };

      await pull.run();

      check((await older()).pinned).isTrue();
      check((await older()).archived).isTrue();
    });

    // Pullfrog 4651760471: the read of a chat unarchived elsewhere, answered
    // before a pin made here, put the pin back.
    test('a pin made here while an unarchived chat is read is kept', () async {
      final hooked = _ChatHookClient(server);
      client = hooked;
      pull = PullSync(
        client: client,
        db: db,
        locks: locks,
        readerAccountId: () => FakeOpenWebUiServer.userId,
      );
      await seedOlderAndNewer(olderArchived: true);
      server.toggleArchive('older');
      hooked.whileChatLoads = (id) async {
        if (id != 'older') return;
        hooked.whileChatLoads = null;
        server.togglePin('older');
        await db.chatsDao.updateEnvelope('older', pinned: const Value(true));
      };

      await pull.run();
      check((await older()).pinned).isTrue();
      await pull.run();

      check((await older()).pinned).isTrue();
      check((await older()).archived).isFalse();
    });

    test('a server that lists neither pulls as before', () async {
      await seedOlderAndNewer();
      client
        ..failPinnedList = true
        ..failArchivedCount = true;
      server.seedChat(
        id: 'newest',
        blob: blobFor('newest'),
        createdAt: 600,
        updatedAt: 600,
      );

      final result = await pull.run();

      check(result.success).isTrue();
      check(result.watermarkAdvanced).isTrue();
      check(await db.chatsDao.getChat('newest')).isNotNull();
    });
  });
}

/// A client whose answers are taken at once and delivered late, as a slow
/// network does: the snapshot reflects the server when the request began.
class _LateReadClient extends FakeSyncApiClient {
  _LateReadClient(super.server);

  /// Holds each chat body after it has been read.
  Future<void>? readGate;

  /// Holds the archived list page after it has been read.
  Future<void>? listGate;

  /// Complete once a chat body / the archived list has been read, so a test can
  /// change the server after that point and before the answer is delivered.
  final readTaken = Completer<void>();
  final listTaken = Completer<void>();

  @override
  Future<Map<String, dynamic>?> getChatRaw(String id) async {
    final snapshot = await super.getChatRaw(id);
    if (!readTaken.isCompleted) readTaken.complete();
    await readGate;
    return snapshot;
  }

  @override
  Future<List<Map<String, dynamic>>> getArchivedChatListPage(int page) async {
    final items = await super.getArchivedChatListPage(page);
    if (!listTaken.isCompleted) listTaken.complete();
    await listGate;
    return items;
  }
}
