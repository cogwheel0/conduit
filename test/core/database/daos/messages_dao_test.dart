import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:collection/collection.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:drift/drift.dart';
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

  group('ordering (createdAt ASC, orderIndex ASC)', () {
    test('createdAt ties respect orderIndex (fixture 10)', () async {
      final fixture = loadChatBlobFixtures()
          .singleWhere((f) => f.name == '10_timestamp_ties_and_unmappable');
      final rows = rowsFromFixture(fixture);
      await db.chatsDao.upsertServerChat(rows: rows);

      final fetched = await db.messagesDao.getForChat(fixture.chatId);

      final expectedOrder = [...rows.messages]..sort((a, b) {
          final byCreatedAt = a.createdAt.compareTo(b.createdAt);
          if (byCreatedAt != 0) return byCreatedAt;
          return a.orderIndex.compareTo(b.orderIndex);
        });
      check(fetched.map((m) => m.id).toList())
          .deepEquals(expectedOrder.map((m) => m.id).toList());

      // The three regenerated siblings share one timestamp second; their
      // relative order must be their original map iteration order.
      final tiedIds = fetched
          .where((m) => m.id.startsWith('a'))
          .map((m) => m.id)
          .toList();
      check(tiedIds).deepEquals([
        'a1111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        'a2222222-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        'a3333333-cccc-4ccc-8ccc-cccccccccccc',
      ]);
    });

    test('watchForChat emits the same order as getForChat', () async {
      final fixture = loadChatBlobFixtures()
          .singleWhere((f) => f.name == '03_branched_regeneration');
      await db.chatsDao.upsertServerChat(rows: rowsFromFixture(fixture));

      final watched = await db.messagesDao.watchForChat(fixture.chatId).first;
      final fetched = await db.messagesDao.getForChat(fixture.chatId);
      check(watched.map((m) => m.id).toList())
          .deepEquals(fetched.map((m) => m.id).toList());
    });

    test('only returns rows of the requested chat', () async {
      final fixtures = loadChatBlobFixtures();
      final one = fixtures.singleWhere((f) => f.name == '02_linear_multi_turn');
      final two =
          fixtures.singleWhere((f) => f.name == '03_branched_regeneration');
      await db.chatsDao.upsertServerChat(rows: rowsFromFixture(one));
      await db.chatsDao.upsertServerChat(rows: rowsFromFixture(two));

      final fetched = await db.messagesDao.getForChat(one.chatId);
      check(fetched).isNotEmpty();
      for (final row in fetched) {
        check(row.chatId).equals(one.chatId);
      }
    });
  });

  group('upsertLocalEcho', () {
    MessageRowData echo({
      required String chatId,
      required String id,
      String? parentId,
      String role = 'assistant',
      String content = 'echoed',
      int createdAt = 1749700100,
      Map<String, dynamic>? payload,
    }) {
      return MessageRowData(
        id: id,
        chatId: chatId,
        parentId: parentId,
        role: role,
        content: content,
        model: 'llama3.1:8b',
        createdAt: createdAt,
        orderIndex: -1, // ignored: the DAO assigns/keeps orderIndex itself
        payload: payload ??
            {'id': id, 'role': role, 'content': content, 'timestamp': createdAt},
      );
    }

    test('is a no-op returning false when the chats row is absent', () async {
      final inserted = await db.messagesDao
          .upsertLocalEcho(echo(chatId: 'ghost-chat', id: 'm-1'));
      check(inserted).isFalse();
      check(await db.messagesDao.getForChat('ghost-chat')).isEmpty();
    });

    test('appends new rows with orderIndex = max(order_index) + 1', () async {
      final fixture = loadChatBlobFixtures()
          .singleWhere((f) => f.name == '02_linear_multi_turn');
      final rows = rowsFromFixture(fixture);
      await db.chatsDao.upsertServerChat(rows: rows);
      final maxExisting =
          rows.messages.map((m) => m.orderIndex).reduce((a, b) => a > b ? a : b);

      final inserted = await db.messagesDao
          .upsertLocalEcho(echo(chatId: fixture.chatId, id: 'local-echo-1'));
      check(inserted).isTrue();

      final fetched = await db.messagesDao.getForChat(fixture.chatId);
      final echoed = fetched.singleWhere((m) => m.id == 'local-echo-1');
      check(echoed.orderIndex).equals(maxExisting + 1);
      check(echoed.dirty).isFalse();
    });

    test('starts at orderIndex 0 in an empty chat', () async {
      await db.chatsDao.upsertEnvelopeStub(
        id: 'empty-chat',
        title: 'Empty',
        createdAt: 1,
        updatedAt: 1,
      );
      await db.messagesDao
          .upsertLocalEcho(echo(chatId: 'empty-chat', id: 'm-0'));
      final fetched = await db.messagesDao.getForChat('empty-chat');
      check(fetched.single.orderIndex).equals(0);
    });

    test('updates existing rows in place, keeping their orderIndex', () async {
      await db.chatsDao.upsertEnvelopeStub(
        id: 'chat-up',
        title: 'Up',
        createdAt: 1,
        updatedAt: 1,
      );
      await db.messagesDao
          .upsertLocalEcho(echo(chatId: 'chat-up', id: 'm-a', content: 'one'));
      await db.messagesDao
          .upsertLocalEcho(echo(chatId: 'chat-up', id: 'm-b', content: 'two'));

      final updated = await db.messagesDao.upsertLocalEcho(
        echo(chatId: 'chat-up', id: 'm-a', content: 'one, streamed further'),
      );
      check(updated).isTrue();

      final fetched = await db.messagesDao.getForChat('chat-up');
      check(fetched.length).equals(2);
      final rowA = fetched.singleWhere((m) => m.id == 'm-a');
      check(rowA.orderIndex).equals(0);
      check(rowA.content).equals('one, streamed further');
      check(fetched.singleWhere((m) => m.id == 'm-b').orderIndex).equals(1);
    });

    test('completed turn links to previous tip and advances currentMessageId',
        () async {
      await db.chatsDao.upsertEnvelopeStub(
        id: 'chat-turn',
        title: 'Turn',
        createdAt: 1,
        updatedAt: 1,
      );
      await db.messagesDao.upsertLocalEcho(
        echo(chatId: 'chat-turn', id: 'prev-a'),
      );
      await (db.update(db.chats)..where((t) => t.id.equals('chat-turn'))).write(
        const ChatsCompanion(currentMessageId: Value('prev-a')),
      );

      final wrote = await db.messagesDao.upsertLocalEchoTurn(
        chatId: 'chat-turn',
        user: echo(
          chatId: 'chat-turn',
          id: 'u-2',
          role: 'user',
          content: 'next question',
        ),
        assistant: echo(chatId: 'chat-turn', id: 'a-2', content: 'answer'),
      );

      check(wrote).isTrue();
      final rows = await db.messagesDao.getForChat('chat-turn');
      check(rows.singleWhere((m) => m.id == 'u-2').parentId).equals('prev-a');
      check(rows.singleWhere((m) => m.id == 'a-2').parentId).equals('u-2');
      check((await db.chatsDao.getChat('chat-turn'))!.currentMessageId).equals(
        'a-2',
      );
    });

    test('payload round-trips verbatim through jsonEncode/jsonDecode',
        () async {
      await db.chatsDao.upsertEnvelopeStub(
        id: 'chat-pl',
        title: 'Payload',
        createdAt: 1,
        updatedAt: 1,
      );
      final payload = {
        'id': 'm-pl',
        'role': 'assistant',
        'content': 'final answer',
        'timestamp': 1749700123,
        'usage': {'prompt_tokens': 12, 'completion_tokens': 34},
        'sources': [
          {'source': {'name': 'doc.pdf'}},
        ],
      };
      await db.messagesDao.upsertLocalEcho(
        echo(chatId: 'chat-pl', id: 'm-pl', payload: payload),
      );
      final row =
          (await db.messagesDao.getForChat('chat-pl')).single;
      check(_deepEq.equals(jsonDecode(row.payload), payload)).isTrue();
    });
  });
}
