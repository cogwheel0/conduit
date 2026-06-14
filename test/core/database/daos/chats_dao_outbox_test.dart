import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/daos/outbox_dao.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// W1 — local-mutation ChatsDao methods that write rows AND their outbox op in
/// ONE transaction (REQ §7.2.1, R2).
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> seedServerChat(String id, {String? folderId}) async {
    final rows = ChatBlobMapper.blobToRows(
      chatId: id,
      title: 'Title $id',
      folderId: folderId,
      createdAt: 1,
      updatedAt: 1,
      blob: <String, dynamic>{
        'title': 'Title $id',
        'history': <String, dynamic>{
          'currentId': 'm1',
          'messages': <String, dynamic>{
            'm1': <String, dynamic>{
              'id': 'm1',
              'parentId': null,
              'childrenIds': <String>[],
              'role': 'user',
              'content': 'hello',
              'timestamp': 1,
            },
          },
        },
      },
    );
    await db.chatsDao.upsertServerChat(rows: rows);
  }

  ChatRows newLocalRows(String localId) {
    return ChatBlobMapper.blobToRows(
      chatId: localId,
      title: 'Hello there',
      createdAt: 100,
      updatedAt: 100,
      blob: <String, dynamic>{
        'title': 'Hello there',
        'history': <String, dynamic>{
          'currentId': 'a1',
          'messages': <String, dynamic>{
            'u1': <String, dynamic>{
              'id': 'u1',
              'parentId': null,
              'childrenIds': <String>['a1'],
              'role': 'user',
              'content': 'Hello there',
              'timestamp': 100,
            },
            'a1': <String, dynamic>{
              'id': 'a1',
              'parentId': 'u1',
              'childrenIds': <String>[],
              'role': 'assistant',
              'content': '',
              'timestamp': 100,
            },
          },
        },
      },
    );
  }

  group('updateEnvelopeWithOutbox', () {
    test('local edit sets dirty and enqueues an updateChat op', () async {
      await seedServerChat('c1');
      await db.chatsDao.updateEnvelopeWithOutbox(
        'c1',
        title: const Value('Renamed'),
        enqueue: true,
      );

      final chat = await db.chatsDao.getChat('c1');
      check(chat!.title).equals('Renamed');
      check(chat.dirty).isTrue();
      final ops = await db.outboxDao.pendingForChat('c1');
      check(ops).length.equals(1);
      check(ops.single.kind).equals('updateChat');
    });

    test('enqueue:false (server-origin) writes rows but no op', () async {
      await seedServerChat('c1');
      await db.chatsDao.updateEnvelopeWithOutbox(
        'c1',
        pinned: const Value(true),
        enqueue: false,
      );
      check((await db.chatsDao.getChat('c1'))!.pinned).isTrue();
      check(await db.outboxDao.pendingForChat('c1')).isEmpty();
    });

    test('consecutive local updates coalesce to one op', () async {
      await seedServerChat('c1');
      await db.chatsDao.updateEnvelopeWithOutbox(
        'c1',
        title: const Value('A'),
        enqueue: true,
      );
      await db.chatsDao.updateEnvelopeWithOutbox(
        'c1',
        title: const Value('B'),
        enqueue: true,
      );
      check(await db.outboxDao.pendingForChat('c1')).length.equals(1);
    });
  });

  group('tombstoneWithOutbox', () {
    test('tombstones (not hard-delete) and enqueues deleteChat', () async {
      await seedServerChat('c1');
      await db.chatsDao.tombstoneWithOutbox('c1');

      final chat = await db.chatsDao.getChat('c1');
      check(chat).isNotNull();
      check(chat!.deleted).isTrue();
      check(chat.dirty).isTrue();
      // Rows survive (drainer purges after server confirm).
      check(await db.messagesDao.getForChat('c1')).isNotEmpty();
      final ops = await db.outboxDao.pendingForChat('c1');
      check(ops.single.kind).equals('deleteChat');
    });

    test('hard-deletes a local create when create/delete annihilate', () async {
      const localId = 'local:delete-me';
      final rows = newLocalRows(localId);
      await db.chatsDao.insertLocalChatWithCreateOp(
        chat: rows.chat,
        messages: rows.messages,
        blobRows: rows,
        contentHash: 'hash-delete-me',
        completion: const RequestCompletionPayload(
          assistantMessageId: 'a1',
          model: 'gpt',
          toolIds: <String>[],
        ),
      );
      check(
        (await db.outboxDao.pendingForChat(localId)).map((op) => op.kind),
      ).deepEquals(['createChat', 'requestCompletion']);
      check(await db.messagesDao.getForChat(localId)).isNotEmpty();

      await db.chatsDao.tombstoneWithOutbox(localId);

      check(await db.chatsDao.getChat(localId)).isNull();
      check(await db.messagesDao.getForChat(localId)).isEmpty();
      check(await db.outboxDao.pendingForChat(localId)).isEmpty();
    });
  });

  group('dropLocalChat', () {
    test(
      'hard-deletes the row and its pending ops, no deleteChat op',
      () async {
        const localId = 'local:x';
        final rows = newLocalRows(localId);
        await db.chatsDao.insertLocalChatWithCreateOp(
          chat: rows.chat,
          messages: rows.messages,
          blobRows: rows,
          contentHash: 'h',
        );
        check(await db.outboxDao.pendingForChat(localId)).isNotEmpty();

        await db.chatsDao.dropLocalChat(localId);

        check(await db.chatsDao.getChat(localId)).isNull();
        check(await db.messagesDao.getForChat(localId)).isEmpty();
        check(await db.outboxDao.pendingForChat(localId)).isEmpty();
      },
    );
  });

  group('insertLocalChatWithCreateOp', () {
    test(
      'writes local chat + messages dirty, createChat then completion op',
      () async {
        const localId = 'local:new';
        final rows = newLocalRows(localId);
        await db.chatsDao.insertLocalChatWithCreateOp(
          chat: rows.chat,
          messages: rows.messages,
          blobRows: rows,
          contentHash: 'hash-1',
          completion: const RequestCompletionPayload(
            assistantMessageId: 'a1',
            model: 'gpt',
            toolIds: <String>['tool-a'],
            filterIds: <String>['filter-a'],
            terminalId: 'terminal-a',
            enableWebSearch: true,
            enableImageGeneration: true,
          ),
        );

        final chat = await db.chatsDao.getChat(localId);
        check(chat!.dirty).isTrue();
        check(chat.bodySynced).isTrue();
        check(chat.serverUpdatedAt).isNull();
        final msgs = await db.messagesDao.getForChat(localId);
        check(msgs.length).equals(2);
        check(msgs.every((m) => m.dirty)).isTrue();

        final ops = await db.outboxDao.pendingForChat(localId);
        check(ops.length).equals(2);
        // createChat seq < requestCompletion seq (drainer creates+remaps first).
        check(ops[0].kind).equals('createChat');
        check(ops[0].contentHash).equals('hash-1');
        check(ops[1].kind).equals('requestCompletion');
        check(ops[1].seq).isGreaterThan(ops[0].seq);
        final completionPayload = RequestCompletionPayload.fromJson(
          jsonDecode(ops[1].payload) as Map<String, dynamic>,
        );
        check(completionPayload.toolIds).deepEquals(['tool-a']);
        check(completionPayload.filterIds).deepEquals(['filter-a']);
        check(completionPayload.terminalId).equals('terminal-a');
        check(completionPayload.enableWebSearch).isTrue();
        check(completionPayload.enableImageGeneration).isTrue();
      },
    );

    test('no completion payload enqueues only createChat', () async {
      const localId = 'local:nocomp';
      final rows = newLocalRows(localId);
      await db.chatsDao.insertLocalChatWithCreateOp(
        chat: rows.chat,
        messages: rows.messages,
        blobRows: rows,
        contentHash: 'h2',
      );
      final ops = await db.outboxDao.pendingForChat(localId);
      check(ops.length).equals(1);
      check(ops.single.kind).equals('createChat');
    });
  });

  group('appendMessagesWithUpdateOp', () {
    test(
      'appends rows dirty, updates envelope, enqueues update + completion',
      () async {
        await seedServerChat('c1');
        await db.chatsDao.appendMessagesWithUpdateOp(
          chatId: 'c1',
          currentMessageId: 'a2',
          updatedAt: 500,
          messages: <MessageRowData>[
            MessageRowData(
              id: 'u2',
              chatId: 'c1',
              parentId: 'm1',
              role: 'user',
              content: 'next',
              createdAt: 400,
              orderIndex: 0,
              payload: const {'id': 'u2', 'role': 'user', 'content': 'next'},
            ),
            MessageRowData(
              id: 'a2',
              chatId: 'c1',
              parentId: 'u2',
              role: 'assistant',
              content: '',
              createdAt: 401,
              orderIndex: 0,
              payload: const {'id': 'a2', 'role': 'assistant', 'content': ''},
            ),
          ],
          enqueueCompletion: true,
          completion: const RequestCompletionPayload(
            assistantMessageId: 'a2',
            model: 'gpt',
          ),
        );

        final chat = await db.chatsDao.getChat('c1');
        check(chat!.dirty).isTrue();
        check(chat.currentMessageId).equals('a2');
        check(chat.updatedAt).equals(500);

        final msgs = await db.messagesDao.getForChat('c1');
        check(msgs.map((m) => m.id).toSet()).deepEquals({'m1', 'u2', 'a2'});
        // New rows got distinct orderIndex above the existing max (0 -> 1, 2).
        final u2 = msgs.firstWhere((m) => m.id == 'u2');
        final a2 = msgs.firstWhere((m) => m.id == 'a2');
        check(u2.orderIndex).not((it) => it.equals(a2.orderIndex));
        check(u2.dirty).isTrue();
        check(a2.dirty).isTrue();

        final ops = await db.outboxDao.pendingForChat('c1');
        check(
          ops.map((o) => o.kind).toList(),
        ).deepEquals(['updateChat', 'requestCompletion']);
      },
    );
  });

  group('R2: rollback leaves NEITHER rows nor op', () {
    test(
      'a throw inside insertLocalChatWithCreateOp rolls back rows + op',
      () async {
        const localId = 'local:dup';
        final rows = newLocalRows(localId);
        // Pre-insert the chat row so the in-txn insert hits a PK conflict and
        // throws — AFTER which the op enqueue must never persist (txn rollback).
        await db
            .into(db.chats)
            .insert(
              ChatsCompanion.insert(
                id: localId,
                title: 'pre',
                createdAt: 1,
                updatedAt: 1,
              ),
            );

        await check(
          db.chatsDao.insertLocalChatWithCreateOp(
            chat: rows.chat,
            messages: rows.messages,
            blobRows: rows,
            contentHash: 'h',
          ),
        ).throws<Object>();

        // No messages inserted, no outbox op — both rolled back.
        check(await db.messagesDao.getForChat(localId)).isEmpty();
        check(await db.outboxDao.pendingForChat(localId)).isEmpty();
        // The pre-existing stub row is untouched (title still 'pre').
        check((await db.chatsDao.getChat(localId))!.title).equals('pre');
      },
    );
  });
}
