import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/sync/id_remapper.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Inserts a `local:` chat with [messageCount] messages straight into the db,
/// bypassing the pull path (these rows are local-only, pre-remap).
Future<void> seedLocalChat(
  AppDatabase db, {
  required String id,
  int messageCount = 2,
  String? folderId,
  bool dirty = true,
}) async {
  await db.into(db.chats).insert(
        ChatsCompanion.insert(
          id: id,
          title: 'Title $id',
          folderId: Value(folderId),
          currentMessageId: Value('$id-m$messageCount'),
          createdAt: 100,
          updatedAt: 200,
          dirty: Value(dirty),
          bodySynced: const Value(false),
          blobMeta: Value(
            jsonEncode(<String, dynamic>{
              'v': 1,
              'blobHadTitle': true,
              'blobTitleValue': 'Title $id',
              'blobHadHistory': true,
              'historyHadMessages': true,
              'historyHadCurrentId': true,
              'historyExtra': <String, dynamic>{},
              'unmappableMessages': <String, dynamic>{},
            }),
          ),
        ),
      );
  for (var i = 1; i <= messageCount; i++) {
    await db.into(db.messages).insert(
          MessagesCompanion.insert(
            id: '$id-m$i',
            chatId: id,
            parentId: Value(i == 1 ? null : '$id-m${i - 1}'),
            role: i.isOdd ? 'user' : 'assistant',
            content: 'message $i of $id',
            createdAt: 1000 + i,
            orderIndex: i - 1,
            payload: jsonEncode(<String, dynamic>{
              'id': '$id-m$i',
              'role': i.isOdd ? 'user' : 'assistant',
              'content': 'message $i of $id',
            }),
            dirty: Value(dirty),
          ),
        );
  }
}

/// Inserts a raw outbox op (the OutboxDao is built concurrently; the remapper
/// only rewrites the `chat_id` column via raw SQL, so tests seed rows the same
/// way).
Future<int> seedOutbox(
  AppDatabase db, {
  required String kind,
  required String chatId,
  String status = 'pending',
  String? contentHash,
}) async {
  return db.into(db.outboxOps).insert(
        OutboxOpsCompanion.insert(
          kind: kind,
          chatId: Value(chatId),
          status: Value(status),
          contentHash: Value(contentHash),
        ),
      );
}

Future<List<MessageRow>> messagesFor(AppDatabase db, String chatId) {
  return (db.select(db.messages)..where((t) => t.chatId.equals(chatId))).get();
}

Future<List<OutboxOp>> allOutbox(AppDatabase db) {
  return db.select(db.outboxOps).get();
}

void main() {
  late AppDatabase db;
  late IdRemapper remapper;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    remapper = IdRemapper(db);
  });

  tearDown(() async {
    await remapper.dispose();
    await db.close();
  });

  group('IdRemapper.remapChat', () {
    test('rewrites chats.id, messages.chatId, and pending outbox.chatId in '
        'one tx', () async {
      const localId = 'local:abc';
      const serverId = 'srv-123';
      await seedLocalChat(db, id: localId, messageCount: 3);
      final createSeq = await seedOutbox(
        db,
        kind: 'createChat',
        chatId: localId,
        status: 'inFlight',
        contentHash: 'hash-1',
      );
      final updateSeq =
          await seedOutbox(db, kind: 'updateChat', chatId: localId);

      await remapper.remapChat(
        localId: localId,
        serverId: serverId,
        serverCreatedAt: 500,
        serverUpdatedAt: 600,
      );

      // Exactly one chat row, now at serverId, with server timestamps.
      final chat = await db.chatsDao.getChat(serverId);
      check(chat).isNotNull();
      check(chat!.createdAt).equals(500);
      check(chat.updatedAt).equals(600);
      check(chat.serverUpdatedAt).equals(600);
      check(await db.chatsDao.getChat(localId)).isNull();

      // Messages repointed to serverId; none left at localId.
      check((await messagesFor(db, serverId)).length).equals(3);
      check(await messagesFor(db, localId)).isEmpty();

      // Both outbox ops repointed.
      final ops = await allOutbox(db);
      check(ops.map((o) => o.chatId).toSet()).deepEquals({serverId});
      check(ops.firstWhere((o) => o.seq == createSeq).chatId).equals(serverId);
      check(ops.firstWhere((o) => o.seq == updateSeq).chatId).equals(serverId);
    });

    test('emits a RemapEvent after commit', () async {
      const localId = 'local:evt';
      const serverId = 'srv-evt';
      await seedLocalChat(db, id: localId);
      final events = <RemapEvent>[];
      final sub = remapper.remapEvents.listen(events.add);

      await remapper.remapChat(
        localId: localId,
        serverId: serverId,
        serverCreatedAt: 1,
        serverUpdatedAt: 2,
      );
      // Let the broadcast deliver.
      await Future<void>.delayed(Duration.zero);

      check(events).length.equals(1);
      check(events.single.fromId).equals(localId);
      check(events.single.toId).equals(serverId);
      check(events.single.entityKind).equals('chat');
      await sub.cancel();
    });

    test('crash-heal: server stub already present (0 messages) -> local rows '
        'win, no duplicate', () async {
      const localId = 'local:heal';
      const serverId = 'srv-heal';
      // A prior pull inserted a bodiless stub at serverId.
      await db.into(db.chats).insert(
            ChatsCompanion.insert(
              id: serverId,
              title: 'stub',
              createdAt: 10,
              updatedAt: 20,
              bodySynced: const Value(false),
            ),
          );
      await seedLocalChat(db, id: localId, messageCount: 2);

      await remapper.remapChat(
        localId: localId,
        serverId: serverId,
        serverCreatedAt: 500,
        serverUpdatedAt: 600,
      );

      // Exactly one row at serverId, carrying the local messages.
      final allChats = await db.select(db.chats).get();
      check(allChats.map((c) => c.id)).deepEquals([serverId]);
      check((await messagesFor(db, serverId)).length).equals(2);
      check(allChats.single.title).equals('Title $localId');
    });

    test('crash-heal: server row already has the body -> local duplicate '
        'discarded, ops repointed', () async {
      const localId = 'local:dup';
      const serverId = 'srv-dup';
      // Server row already merged with messages (the authoritative copy).
      await db.into(db.chats).insert(
            ChatsCompanion.insert(
              id: serverId,
              title: 'server',
              createdAt: 10,
              updatedAt: 20,
              bodySynced: const Value(true),
            ),
          );
      await db.into(db.messages).insert(
            MessagesCompanion.insert(
              id: 'srv-m1',
              chatId: serverId,
              role: 'user',
              content: 'server msg',
              createdAt: 5,
              orderIndex: 0,
              payload: '{}',
            ),
          );
      await seedLocalChat(db, id: localId, messageCount: 2);
      await seedOutbox(db, kind: 'createChat', chatId: localId);

      await remapper.remapChat(
        localId: localId,
        serverId: serverId,
        serverCreatedAt: 500,
        serverUpdatedAt: 600,
      );

      // The server body survives; the local duplicate is gone.
      final allChats = await db.select(db.chats).get();
      check(allChats.map((c) => c.id)).deepEquals([serverId]);
      check(allChats.single.bodySynced).isTrue();
      check((await messagesFor(db, serverId)).map((m) => m.id))
          .deepEquals(['srv-m1']);
      check(await messagesFor(db, localId)).isEmpty();
      // Ops still repointed to serverId.
      check((await allOutbox(db)).map((o) => o.chatId).toSet())
          .deepEquals({serverId});
    });

    test('createChatContentHash heals: server blob hashes to the pending '
        'op contentHash', () async {
      // The pull builds rows from the SAME blob the create op fingerprinted;
      // both must hash identically so the pull adopts the remap, not a dup.
      final blob = <String, dynamic>{
        'title': 'Hashed',
        'models': ['llama3'],
        'history': {
          'messages': {
            'm1': {'id': 'm1', 'parentId': null, 'role': 'user', 'content': 'hi'},
          },
          'currentId': 'm1',
        },
        // A volatile key the server rewrites: excluded from the hash.
        'timestamp': 111,
      };
      final localRows = ChatBlobMapper.blobToRows(
        chatId: 'local:hash',
        blob: blob,
        title: 'Hashed',
        createdAt: 1,
        updatedAt: 2,
      );
      // Same blob with a DIFFERENT timestamp, as the server would return.
      final serverRows = ChatBlobMapper.blobToRows(
        chatId: 'srv-hash',
        blob: {...blob, 'timestamp': 999},
        title: 'Hashed',
        createdAt: 50,
        updatedAt: 60,
      );

      check(createChatContentHash(localRows))
          .equals(createChatContentHash(serverRows));
    });

    test('localId == serverId is an idempotent no-op', () async {
      const id = 'srv-same';
      await seedLocalChat(db, id: id);
      await remapper.remapChat(
        localId: id,
        serverId: id,
        serverCreatedAt: 1,
        serverUpdatedAt: 2,
      );
      // Untouched (timestamps NOT overwritten to 1/2).
      final chat = await db.chatsDao.getChat(id);
      check(chat!.updatedAt).equals(200);
    });

    test('does not repoint terminal (failed) outbox ops', () async {
      const localId = 'local:term';
      const serverId = 'srv-term';
      await seedLocalChat(db, id: localId);
      final parkedSeq = await seedOutbox(
        db,
        kind: 'requestCompletion',
        chatId: localId,
        status: 'failed',
      );

      await remapper.remapChat(
        localId: localId,
        serverId: serverId,
        serverCreatedAt: 1,
        serverUpdatedAt: 2,
      );

      final parked =
          (await allOutbox(db)).firstWhere((o) => o.seq == parkedSeq);
      // Parked ops keep their (now stale) local chatId — drainer ignores them
      // until manual retry.
      check(parked.chatId).equals(localId);
    });
  });

  group('IdRemapper.remapFolder', () {
    test('rewrites folders.id, chats.folderId, and pending outbox.chatId',
        () async {
      const localId = 'local:fold';
      const serverId = 'srv-fold';
      await db.into(db.folders).insert(
            FoldersCompanion.insert(
              id: localId,
              name: 'Work',
              createdAt: 100,
              updatedAt: 200,
              dirty: const Value(true),
            ),
          );
      // A chat lives in the local folder.
      await seedLocalChat(db, id: 'local:c1', folderId: localId);
      final upsertSeq =
          await seedOutbox(db, kind: 'folderUpsert', chatId: localId);

      await remapper.remapFolder(
        localId: localId,
        serverId: serverId,
        serverUpdatedAt: 600,
      );

      check(await db.foldersDao.watchFolders().first)
          .which((it) => it.length.equals(1));
      final folders = await db.select(db.folders).get();
      check(folders.map((f) => f.id)).deepEquals([serverId]);
      check(folders.single.updatedAt).equals(600);

      // The chat's folderId repointed.
      final chat = await db.chatsDao.getChat('local:c1');
      check(chat!.folderId).equals(serverId);

      // Folder op repointed (chatId column holds folderId).
      final op = (await allOutbox(db)).firstWhere((o) => o.seq == upsertSeq);
      check(op.chatId).equals(serverId);
    });

    test('emits a folder RemapEvent', () async {
      const localId = 'local:fe';
      const serverId = 'srv-fe';
      await db.into(db.folders).insert(
            FoldersCompanion.insert(
              id: localId,
              name: 'F',
              createdAt: 1,
              updatedAt: 2,
            ),
          );
      final events = <RemapEvent>[];
      final sub = remapper.remapEvents.listen(events.add);

      await remapper.remapFolder(
        localId: localId,
        serverId: serverId,
        serverUpdatedAt: 3,
      );
      await Future<void>.delayed(Duration.zero);

      check(events.single.entityKind).equals('folder');
      check(events.single.toId).equals(serverId);
      await sub.cancel();
    });
  });
}
