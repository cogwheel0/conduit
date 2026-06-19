import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:collection/collection.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/daos/chats_dao.dart';
import 'package:conduit/core/database/mappers/conversation_assembler.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/chat_blob_fixtures.dart';

const _deepEq = DeepCollectionEquality();

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('buildChatResponseEnvelope', () {
    test('rebuilds the exact ChatResponse-shaped map (ints stay seconds)',
        () async {
      final fixture = loadChatBlobFixtures()
          .singleWhere((f) => f.name == '02_linear_multi_turn');
      await db.chatsDao.upsertServerChat(
        rows: rowsFromFixture(fixture),
        shareId: 'share-abc',
        meta: const {
          'tags': ['work'],
        },
        listLastReadAt: 1749700123,
      );

      final chatRow = (await db.chatsDao.getChat(fixture.chatId))!;
      final messageRows = await db.messagesDao.getForChat(fixture.chatId);
      final envelope = buildChatResponseEnvelope(chatRow, messageRows);

      final expected = <String, dynamic>{
        'id': fixture.chatId,
        'title': fixture.envelope['title'],
        'chat': fixture.blob,
        'updated_at': fixture.envelope['updated_at'],
        'created_at': fixture.envelope['created_at'],
        'last_read_at': 1749700123,
        'pinned': fixture.envelope['pinned'] ?? false,
        'archived': fixture.envelope['archived'] ?? false,
        'folder_id': fixture.envelope['folder_id'],
        'share_id': 'share-abc',
        'meta': {
          'tags': ['work'],
        },
      };
      check(
        _deepEq.equals(envelope, expected),
        because: 'envelope must match what /api/v1/chats/{id} returns today\n'
            'got: ${jsonEncode(envelope)}',
      ).isTrue();
    });
  });

  group('assembleConversation', () {
    test('parses a full conversation through parseFullConversationModel',
        () async {
      final fixture = loadChatBlobFixtures()
          .singleWhere((f) => f.name == '02_linear_multi_turn');
      await db.chatsDao.upsertServerChat(rows: rowsFromFixture(fixture));

      final chatRow = (await db.chatsDao.getChat(fixture.chatId))!;
      final messageRows = await db.messagesDao.getForChat(fixture.chatId);
      final conversation = assembleConversation(chatRow, messageRows);

      check(conversation.id).equals(fixture.chatId);
      check(conversation.title).equals(fixture.envelope['title'] as String);
      check(conversation.messages).isNotEmpty();
      check(conversation.createdAt).equals(
        DateTime.fromMillisecondsSinceEpoch(
          (fixture.envelope['created_at'] as int) * 1000,
        ),
      );
      check(conversation.updatedAt).equals(
        DateTime.fromMillisecondsSinceEpoch(
          (fixture.envelope['updated_at'] as int) * 1000,
        ),
      );
    });
  });

  group('conversationFromListEntry', () {
    test('maps every field; messages/tags/metadata stay empty', () {
      const entry = ChatListEntry(
        id: 'c-1',
        title: 'List chat',
        createdAt: 1749700000,
        updatedAt: 1749700050,
        pinned: true,
        archived: false,
        folderId: 'f-1',
        lastReadAt: 1749700025,
      );
      final conversation = conversationFromListEntry(entry);
      check(conversation.id).equals('c-1');
      check(conversation.title).equals('List chat');
      check(conversation.createdAt)
          .equals(DateTime.fromMillisecondsSinceEpoch(1749700000 * 1000));
      check(conversation.updatedAt)
          .equals(DateTime.fromMillisecondsSinceEpoch(1749700050 * 1000));
      check(conversation.lastReadAt)
          .equals(DateTime.fromMillisecondsSinceEpoch(1749700025 * 1000));
      check(conversation.pinned).isTrue();
      check(conversation.archived).isFalse();
      check(conversation.folderId).equals('f-1');
      check(conversation.messages).isEmpty();
      check(conversation.tags).isEmpty();
      check(conversation.metadata).isEmpty();
    });

    test('keeps a null lastReadAt null', () {
      const entry = ChatListEntry(
        id: 'c-2',
        title: 'No reads',
        createdAt: 1,
        updatedAt: 2,
        pinned: false,
        archived: true,
      );
      final conversation = conversationFromListEntry(entry);
      check(conversation.lastReadAt).isNull();
      check(conversation.archived).isTrue();
      check(conversation.folderId).isNull();
    });
  });

  group('folderFromRow', () {
    test('feeds projected columns plus rawExtra into Folder.fromJson', () {
      final row = FolderRow(
        id: 'f-1',
        name: 'Work',
        parentId: 'f-root',
        createdAt: 1749700000,
        updatedAt: 1749700050,
        serverUpdatedAt: 1749700050,
        dirty: false,
        deleted: false,
        rawExtra: jsonEncode({
          'is_expanded': true,
          'meta': {'color': '#00ff00'},
          'data': {'note': 'hi'},
        }),
      );
      final folder = folderFromRow(row);
      check(folder.id).equals('f-1');
      check(folder.name).equals('Work');
      check(folder.parentId).equals('f-root');
      check(folder.createdAt)
          .equals(DateTime.fromMillisecondsSinceEpoch(1749700000 * 1000));
      check(folder.updatedAt)
          .equals(DateTime.fromMillisecondsSinceEpoch(1749700050 * 1000));
      check(folder.isExpanded).isTrue();
      check(folder.meta).isNotNull();
      check(folder.meta!['color']).equals('#00ff00');
      check(
        folder.conversationIds,
        because: 'Phase 1 must not synthesize conversationIds',
      ).isEmpty();
    });
  });
}
