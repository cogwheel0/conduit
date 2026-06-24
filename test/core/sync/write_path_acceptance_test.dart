import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/daos/outbox_dao.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/sync/backoff.dart';
import 'package:conduit/core/sync/chat_adapter.dart';
import 'package:conduit/core/sync/chat_locks.dart';
import 'package:conduit/core/sync/clock.dart';
import 'package:conduit/core/sync/id_remapper.dart';
import 'package:conduit/core/sync/outbox_drainer.dart';
import 'package:conduit/core/sync/outbox_task_queue_migrator.dart';
import 'package:conduit/core/sync/pull_sync.dart';
import 'package:conduit/core/sync/push_sync.dart';
import 'package:conduit/core/persistence/hive_boxes.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import '../../support/fake_open_webui_server.dart';
import '../../support/fake_sync_api_client.dart';

class _Clock implements SyncClock {
  _Clock(this.now);
  int now;
  @override
  int nowEpochSeconds() => now;
}

/// Completion seam that, when run, lands the assistant message body into the
/// DB rows under the chat lock (mirroring the real D-07 echo write) so the
/// acceptance can assert the turn completed.
class StubCompletionRunner implements RequestCompletionRunner {
  StubCompletionRunner(this.db, this.locks);
  final AppDatabase db;
  final ConversationLocks locks;
  final List<String> ranForChats = <String>[];

  @override
  Future<void> run({
    required String chatId,
    required Map<String, dynamic> payload,
  }) async {
    ranForChats.add(chatId);
    final p = RequestCompletionPayload.fromJson(payload);
    // chatId is ALWAYS a server id here (createChat ran + remap repointed it).
    await locks.runExclusive(chatId, () async {
      final existingMessages = await db.messagesDao.getForChat(chatId);
      MessageRow? existingAssistant;
      for (final message in existingMessages) {
        if (message.id == p.assistantMessageId) {
          existingAssistant = message;
          break;
        }
      }
      final payload = <String, dynamic>{
        ..._payloadOf(existingAssistant),
        'id': p.assistantMessageId,
        'role': 'assistant',
        'content': 'assistant reply',
      };
      final parentId = existingAssistant?.parentId;
      if (parentId != null) {
        payload['parentId'] = parentId;
      }

      await db.messagesDao.upsertLocalEcho(
        MessageRowData(
          id: p.assistantMessageId,
          chatId: chatId,
          parentId: parentId,
          role: 'assistant',
          content: 'assistant reply',
          createdAt: existingAssistant?.createdAt ?? 7001,
          orderIndex: existingAssistant?.orderIndex ?? 99,
          payload: payload,
        ),
      );
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Box<dynamic> caches;
  late AppDatabase db;
  late FakeOpenWebUiServer server;
  late FakeSyncApiClient client;
  late ConversationLocks chatLocks;
  late FolderLocks folderLocks;
  late IdRemapper remapper;
  late PushSync push;
  late _Clock clock;
  late StubCompletionRunner completion;

  HiveBoxes boxes() => HiveBoxes(
    preferences: caches,
    caches: caches,
    attachmentQueue: caches,
    metadata: caches,
  );

  OutboxDrainer drainer() => OutboxDrainer(
    db: db,
    clock: clock,
    backoff: Backoff(jitter: () => 0.0),
    isOnline: () => true,
    completion: completion,
    adapters: [
      ChatAdapter(
        pull: PullSync(
          client: client,
          db: db,
          locks: chatLocks,
          remapper: remapper,
        ),
        push: push,
      ),
    ],
  );

  void wire() {
    chatLocks = ConversationLocks();
    folderLocks = FolderLocks();
    remapper = IdRemapper(db);
    clock = _Clock(7000);
    push = PushSync(
      client: client,
      db: db,
      chatLocks: chatLocks,
      folderLocks: folderLocks,
      clock: clock,
      remapper: remapper,
    );
    completion = StubCompletionRunner(db, chatLocks);
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('write-path-acceptance');
    Hive.init(tempDir.path);
    caches = await Hive.openBox<dynamic>('caches_v1');
    server = FakeOpenWebUiServer(nowEpochSeconds: () => 7000);
    client = FakeSyncApiClient(server);
    db = AppDatabase(NativeDatabase.memory());
    wire();
  });

  tearDown(() async {
    await remapper.dispose();
    await db.close();
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test(
    'D5: pre-upgrade queued Hive task migrates, then drains — '
    'chat created server-side, message sent, completion runs, id remapped',
    () async {
      // Seed a pre-upgrade queued sendTextMessage (new chat).
      await caches.put('outbound_task_queue_v1', [
        <String, dynamic>{
          'runtimeType': 'sendTextMessage',
          'id': 'legacy-1',
          'conversationId': null,
          'text': 'migrate and send me',
          'attachments': <String>[],
          'toolIds': <String>[],
          'status': 'queued',
        },
      ]);

      // Migrate into the outbox.
      final migrator = OutboxTaskQueueMigrator(
        db: db,
        hiveBoxes: boxes(),
        chatLocks: chatLocks,
        clock: clock,
        resolveDefaultModel: () => 'gpt-test',
      );
      await migrator.migrateIfNeeded();

      final localChat = (await db.select(db.chats).get()).single;
      final localId = localChat.id;
      check(localId.startsWith('local:')).isTrue();

      // Drain: createChat -> remap -> requestCompletion against the server id.
      await drainer().drain();

      // Local id is gone; a server-id row exists with the body.
      check(await db.chatsDao.getChat(localId)).isNull();
      final serverChats = (await db.select(db.chats).get()).where(
        (c) => !c.id.startsWith('local:'),
      );
      check(serverChats.length).equals(1);
      final serverId = serverChats.single.id;

      // The chat exists server-side with the user message.
      final stored = server.getChatById(serverId);
      check(stored).isNotNull();
      final history = (stored!['chat'] as Map)['history'] as Map;
      final messages = history['messages'] as Map;
      final userMsg =
          messages.values.firstWhere((m) => (m as Map)['role'] == 'user')
              as Map;
      check(userMsg['content']).equals('migrate and send me');

      // The completion ran against the SERVER id (remap repointed it, §B2.4).
      check(completion.ranForChats).deepEquals([serverId]);

      // Assistant reply landed in DB rows.
      final dbMsgs = await db.messagesDao.getForChat(serverId);
      check(dbMsgs.any((m) => m.content == 'assistant reply')).isTrue();

      // Outbox drained empty.
      check(await db.outboxDao.pendingForChat(serverId)).isEmpty();
    },
  );

  test('compose-offline -> force-quit (fresh container, same db file) -> '
      'message survives -> reconnect sends and remaps', () async {
    // Use a FILE-backed db so a "force quit" (new AppDatabase over the same
    // file) preserves the rows + outbox ops.
    await db.close();
    final dbFile = File('${tempDir.path}/server.sqlite');
    db = AppDatabase(NativeDatabase(dbFile));
    wire();

    const localId = 'local:offline-compose';
    // OFFLINE compose: write rows + createChat + requestCompletion in one txn.
    final blobRows = _composeRows(localId, 'offline hello');
    await chatLocks.runExclusive(localId, () async {
      await db.chatsDao.insertLocalChatWithCreateOp(
        chat: blobRows.chat,
        messages: blobRows.messages,
        blobRows: blobRows,
        contentHash: 'offline-hash',
        completion: const RequestCompletionPayload(
          assistantMessageId: 'a-off',
          model: 'gpt-test',
        ),
      );
    });

    // --- FORCE QUIT: drop the in-memory app state, reopen the same file. ---
    await db.close();
    await remapper.dispose();
    db = AppDatabase(NativeDatabase(dbFile));
    wire();

    // The composed chat is still visible after relaunch.
    final survived = await db.chatsDao.getChat(localId);
    check(survived).isNotNull();
    check(survived!.dirty).isTrue();
    final msgs = await db.messagesDao.getForChat(localId);
    check(
      msgs.where((m) => m.role == 'user').single.content,
    ).equals('offline hello');
    // Both ops survived.
    check(
      (await db.outboxDao.pendingForChat(localId)).map((o) => o.kind),
    ).deepEquals(['createChat', 'requestCompletion']);

    // --- RECONNECT: drain sends + remaps. ---
    await drainer().drain();

    check(await db.chatsDao.getChat(localId)).isNull();
    final serverChats = (await db.select(db.chats).get()).where(
      (c) => !c.id.startsWith('local:'),
    );
    check(serverChats.length).equals(1);
    final serverId = serverChats.single.id;
    check(server.getChatById(serverId)).isNotNull();
    check(completion.ranForChats).deepEquals([serverId]);

    // R8: EXACTLY ONE assistant row for the turn (the placeholder id, the DB
    // row, and the completion echo all share `a-off`, so upsertLocalEcho keyed
    // on {chatId,id} updated the one row instead of writing a duplicate).
    final finalMsgs = await db.messagesDao.getForChat(serverId);
    check(
      finalMsgs.where((m) => m.role == 'assistant').toList(),
    ).length.equals(1);
    final assistant = finalMsgs.where((m) => m.id == 'a-off').single;
    check(assistant.content).equals('assistant reply');
    check(assistant.parentId).equals('u-off');

    await db.close();
    // Reset db to in-memory so tearDown's close is harmless.
    db = AppDatabase(NativeDatabase.memory());
    wire();
  });

  test('crash between createChat and remap-commit heals without duplicating the '
      'chat or the assistant row', () async {
    const localId = 'local:crash-heal';
    final blobRows = _composeRows(localId, 'heal me');
    final contentHash = createChatContentHash(blobRows);
    await chatLocks.runExclusive(localId, () async {
      await db.chatsDao.insertLocalChatWithCreateOp(
        chat: blobRows.chat,
        messages: blobRows.messages,
        blobRows: blobRows,
        contentHash: contentHash,
        completion: const RequestCompletionPayload(
          assistantMessageId: 'a-off',
          model: 'gpt-test',
        ),
      );
    });

    // Simulate a crash AFTER the server minted the chat but BEFORE the local
    // remap committed: POST the chat to the fake server directly and adopt the
    // server id by completing the remap (idempotent: re-running remap or push
    // must not create a second chat).
    final blob = ChatBlobMapper.rowsToBlob(blobRows)..['id'] = '';
    final resp = await client.createChat(blob, folderId: null);
    final serverId = resp['id'] as String;

    // Heal: complete the remap that the crash interrupted.
    await chatLocks.runExclusive(serverId, () async {
      await remapper.remapChat(
        localId: localId,
        serverId: serverId,
        serverCreatedAt: 7000,
        serverUpdatedAt: 7000,
      );
    });

    // Now drain. pushCreateChat re-runs against the NON-local (already
    // remapped) id, recognizes the create is already satisfied, and does NOT
    // POST a second chat; the requestCompletion then runs against serverId.
    await drainer().drain();

    // Exactly one server chat, no local leftover.
    check(await db.chatsDao.getChat(localId)).isNull();
    final serverChats = (await db.select(db.chats).get())
        .where((c) => !c.id.startsWith('local:'))
        .toList();
    check(serverChats.length).equals(1);
    check(serverChats.single.id).equals(serverId);

    // The server has exactly one chat for this id (no duplicate POST).
    check(server.getChatById(serverId)).isNotNull();

    // Exactly one assistant row, with the completed body (R8).
    final healedChat = await db.chatsDao.getChat(serverId);
    check(healedChat!.dirty).isFalse();
    check(healedChat.serverUpdatedAt).equals(7000);
    final msgs = await db.messagesDao.getForChat(serverId);
    check(msgs.every((m) => !m.dirty)).isTrue();
    check(msgs.where((m) => m.role == 'assistant').toList()).length.equals(1);
    final assistant = msgs.where((m) => m.id == 'a-off').single;
    check(assistant.content).equals('assistant reply');
    check(assistant.parentId).equals('u-off');
    check(completion.ranForChats).deepEquals([serverId]);
  });
}

/// Builds canonical ChatRows for a brand-new local compose (user + assistant
/// placeholder), matching what the migrator/send path produces.
ChatRows _composeRows(String localId, String text) {
  return ChatBlobMapper.blobToRows(
    chatId: localId,
    title: text,
    createdAt: 7000,
    updatedAt: 7000,
    blob: <String, dynamic>{
      'title': text,
      'history': <String, dynamic>{
        'currentId': 'a-off',
        'messages': <String, dynamic>{
          'u-off': <String, dynamic>{
            'id': 'u-off',
            'parentId': null,
            'childrenIds': <String>['a-off'],
            'role': 'user',
            'content': text,
            'timestamp': 7000,
          },
          'a-off': <String, dynamic>{
            'id': 'a-off',
            'parentId': 'u-off',
            'childrenIds': <String>[],
            'role': 'assistant',
            'content': '',
            'timestamp': 7000,
          },
        },
      },
    },
  );
}

Map<String, dynamic> _payloadOf(MessageRow? row) {
  if (row == null || row.payload.isEmpty) {
    return <String, dynamic>{};
  }
  final decoded = jsonDecode(row.payload);
  if (decoded is Map<String, dynamic>) {
    return Map<String, dynamic>.from(decoded);
  }
  if (decoded is Map) {
    return <String, dynamic>{
      for (final entry in decoded.entries) entry.key.toString(): entry.value,
    };
  }
  return <String, dynamic>{};
}
