import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:collection/collection.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/database/models/chat_transcript_window.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/chat_blob_fixtures.dart';
import '../support/transcript_chain_fixture.dart';

const _deepEq = DeepCollectionEquality();

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('active branch windowing', () {
    Future<void> seedChain({
      required String chatId,
      required int count,
      List<MessageRowData> extras = const [],
    }) {
      return db.chatsDao.upsertServerChat(
        rows: buildLinearChatRows(chatId: chatId, count: count, extras: extras),
      );
    }

    test('loads chronological pages without gaps or duplicates', () async {
      await seedChain(chatId: 'window-120', count: 120);

      final newest = await db.messagesDao.getActiveBranchPage('window-120');
      check(newest.primaryRows.length).equals(50);
      check(newest.primaryRows.first.id).equals('m70');
      check(newest.primaryRows.last.id).equals('m119');
      check(newest.hasOlder).isTrue();

      final middle = await db.messagesDao.getActiveBranchPage(
        'window-120',
        before: newest.olderCursor,
      );
      check(middle.primaryRows.first.id).equals('m20');
      check(middle.primaryRows.last.id).equals('m69');
      check(middle.hasOlder).isTrue();

      final oldest = await db.messagesDao.getActiveBranchPage(
        'window-120',
        before: middle.olderCursor,
      );
      check(
        oldest.primaryRows.map((row) => row.id).toList(),
      ).deepEquals([for (var index = 0; index < 20; index += 1) 'm$index']);
      check(oldest.hasOlder).isFalse();

      final allIds = [
        ...oldest.primaryRows,
        ...middle.primaryRows,
        ...newest.primaryRows,
      ].map((row) => row.id).toList();
      check(allIds.toSet().length).equals(120);
      check(
        allIds,
      ).deepEquals([for (var index = 0; index < 120; index += 1) 'm$index']);
    });

    test(
      'siblings do not consume page capacity or replace chain order',
      () async {
        await seedChain(
          chatId: 'window-sibling',
          count: 60,
          extras: const [
            MessageRowData(
              id: 'm58-alt',
              chatId: 'window-sibling',
              parentId: 'm57',
              role: 'user',
              content: 'alternate response version',
              createdAt: 100,
              orderIndex: 1000,
              payload: {
                'id': 'm58-alt',
                'parentId': 'm57',
                'role': 'user',
                'content': 'alternate response version',
                'timestamp': 100,
              },
            ),
          ],
        );

        final page = await db.messagesDao.getActiveBranchPage('window-sibling');
        check(page.primaryRows.length).equals(50);
        check(page.primaryRows.first.id).equals('m10');
        check(page.primaryRows.last.id).equals('m59');
        check(page.rows.map((row) => row.id)).contains('m58-alt');
      },
    );

    test('pathological sibling groups are bounded and reported', () async {
      await seedChain(
        chatId: 'window-pathological',
        count: 2,
        extras: [
          for (var index = 0; index < 220; index += 1)
            MessageRowData(
              id: 'alternate-$index',
              chatId: 'window-pathological',
              parentId: 'm0',
              role: 'assistant',
              content: 'alternate $index',
              createdAt: 100,
              orderIndex: index + 10,
              payload: {
                'id': 'alternate-$index',
                'parentId': 'm0',
                'role': 'assistant',
                'content': 'alternate $index',
                'timestamp': 100,
              },
            ),
        ],
      );

      final page = await db.messagesDao.getActiveBranchPage(
        'window-pathological',
      );
      check(page.semanticBoundaryTruncated).isTrue();
      check(page.primaryRows.length).equals(2);
      check(page.rows.length).isLessOrEqual(202);
    });

    test('missing parents and cycles terminate safely', () async {
      await seedChain(chatId: 'window-cycle', count: 3);
      await (db.update(db.messages)..where(
            (row) => row.chatId.equals('window-cycle') & row.id.equals('m1'),
          ))
          .write(const MessagesCompanion(parentId: Value('m2')));

      final cycle = await db.messagesDao.getActiveBranchPage('window-cycle');
      check(cycle.primaryRows.length).equals(2);
      check(
        cycle.primaryRows.map((row) => row.id).toSet(),
      ).deepEquals({'m1', 'm2'});

      await (db.update(db.messages)..where(
            (row) => row.chatId.equals('window-cycle') & row.id.equals('m1'),
          ))
          .write(const MessagesCompanion(parentId: Value('missing')));
      final missing = await db.messagesDao.getActiveBranchPage('window-cycle');
      check(
        missing.primaryRows.map((row) => row.id).toList(),
      ).deepEquals(['m1', 'm2']);
    });

    test('cursor rooted at the oldest row returns an empty page', () async {
      await seedChain(chatId: 'window-root', count: 2);
      final page = await db.messagesDao.getActiveBranchPage(
        'window-root',
        before: const MessageWindowCursor('m0'),
      );
      check(page.primaryRows).isEmpty();
      check(page.hasOlder).isFalse();
    });

    test(
      'missing current tip falls back to the newest deterministic row',
      () async {
        await seedChain(chatId: 'window-null-tip', count: 75);
        await (db.update(db.chats)
              ..where((row) => row.id.equals('window-null-tip')))
            .write(const ChatsCompanion(currentMessageId: Value(null)));

        final page = await db.messagesDao.getActiveBranchPage(
          'window-null-tip',
        );

        check(page.primaryRows.length).equals(50);
        check(page.primaryRows.first.id).equals('m25');
        check(page.primaryRows.last.id).equals('m74');
        check(page.hasOlder).isTrue();
      },
    );

    test(
      'complete reads chunk sibling predicates below SQLite limits',
      () async {
        await seedChain(chatId: 'window-large-chain', count: 1200);

        final rows = await db.messagesDao.getCompleteActiveBranchRows(
          'window-large-chain',
        );

        check(rows.length).equals(1200);
        check(rows.first.id).equals('m0');
        check(rows.last.id).equals('m1199');
      },
    );
  });

  group('ordering (createdAt ASC, orderIndex ASC)', () {
    test('createdAt ties respect orderIndex (fixture 10)', () async {
      final fixture = loadChatBlobFixtures().singleWhere(
        (f) => f.name == '10_timestamp_ties_and_unmappable',
      );
      final rows = rowsFromFixture(fixture);
      await db.chatsDao.upsertServerChat(rows: rows);

      final fetched = await db.messagesDao.getForChat(fixture.chatId);

      final expectedOrder = [...rows.messages]
        ..sort((a, b) {
          final byCreatedAt = a.createdAt.compareTo(b.createdAt);
          if (byCreatedAt != 0) return byCreatedAt;
          return a.orderIndex.compareTo(b.orderIndex);
        });
      check(
        fetched.map((m) => m.id).toList(),
      ).deepEquals(expectedOrder.map((m) => m.id).toList());

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
      final fixture = loadChatBlobFixtures().singleWhere(
        (f) => f.name == '03_branched_regeneration',
      );
      await db.chatsDao.upsertServerChat(rows: rowsFromFixture(fixture));

      final watched = await db.messagesDao.watchForChat(fixture.chatId).first;
      final fetched = await db.messagesDao.getForChat(fixture.chatId);
      check(
        watched.map((m) => m.id).toList(),
      ).deepEquals(fetched.map((m) => m.id).toList());
    });

    test('only returns rows of the requested chat', () async {
      final fixtures = loadChatBlobFixtures();
      final one = fixtures.singleWhere((f) => f.name == '02_linear_multi_turn');
      final two = fixtures.singleWhere(
        (f) => f.name == '03_branched_regeneration',
      );
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
        payload:
            payload ??
            {
              'id': id,
              'role': role,
              'content': content,
              'timestamp': createdAt,
            },
      );
    }

    test('is a no-op returning false when the chats row is absent', () async {
      final inserted = await db.messagesDao.upsertLocalEcho(
        echo(chatId: 'ghost-chat', id: 'm-1'),
      );
      check(inserted).isFalse();
      check(await db.messagesDao.getForChat('ghost-chat')).isEmpty();
    });

    test('appends new rows with orderIndex = max(order_index) + 1', () async {
      final fixture = loadChatBlobFixtures().singleWhere(
        (f) => f.name == '02_linear_multi_turn',
      );
      final rows = rowsFromFixture(fixture);
      await db.chatsDao.upsertServerChat(rows: rows);
      final maxExisting = rows.messages
          .map((m) => m.orderIndex)
          .reduce((a, b) => a > b ? a : b);

      final inserted = await db.messagesDao.upsertLocalEcho(
        echo(chatId: fixture.chatId, id: 'local-echo-1'),
      );
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
      await db.messagesDao.upsertLocalEcho(
        echo(chatId: 'empty-chat', id: 'm-0'),
      );
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
      await db.messagesDao.upsertLocalEcho(
        echo(chatId: 'chat-up', id: 'm-a', content: 'one'),
      );
      await db.messagesDao.upsertLocalEcho(
        echo(chatId: 'chat-up', id: 'm-b', content: 'two'),
      );

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

    test(
      'completed turn links to previous tip and advances currentMessageId',
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
        await (db.update(db.chats)..where((t) => t.id.equals('chat-turn')))
            .write(const ChatsCompanion(currentMessageId: Value('prev-a')));

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
        check(
          (await db.chatsDao.getChat('chat-turn'))!.currentMessageId,
        ).equals('a-2');
      },
    );

    test(
      'replaying a completed turn preserves the original parent chain',
      () async {
        await db.chatsDao.upsertEnvelopeStub(
          id: 'chat-replay',
          title: 'Replay',
          createdAt: 1,
          updatedAt: 1,
        );
        await db.messagesDao.upsertLocalEcho(
          echo(chatId: 'chat-replay', id: 'prev-a'),
        );
        await (db.update(db.chats)..where((t) => t.id.equals('chat-replay')))
            .write(const ChatsCompanion(currentMessageId: Value('prev-a')));

        final user = echo(
          chatId: 'chat-replay',
          id: 'u-2',
          role: 'user',
          content: 'next question',
        );
        await db.messagesDao.upsertLocalEchoTurn(
          chatId: 'chat-replay',
          user: user,
          assistant: echo(
            chatId: 'chat-replay',
            id: 'a-2',
            content: 'partial answer',
          ),
        );

        final replayed = await db.messagesDao.upsertLocalEchoTurn(
          chatId: 'chat-replay',
          user: user,
          assistant: echo(
            chatId: 'chat-replay',
            id: 'a-2',
            content: 'final answer',
          ),
        );

        check(replayed).isTrue();
        final rows = await db.messagesDao.getForChat('chat-replay');
        check(rows.singleWhere((m) => m.id == 'u-2').parentId).equals('prev-a');
        final assistantRow = rows.singleWhere((m) => m.id == 'a-2');
        check(assistantRow.parentId).equals('u-2');
        check(assistantRow.content).equals('final answer');
        check(
          (await db.chatsDao.getChat('chat-replay'))!.currentMessageId,
        ).equals('a-2');
      },
    );

    test(
      'payload round-trips verbatim through jsonEncode/jsonDecode',
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
            {
              'source': {'name': 'doc.pdf'},
            },
          ],
        };
        await db.messagesDao.upsertLocalEcho(
          echo(chatId: 'chat-pl', id: 'm-pl', payload: payload),
        );
        final row = (await db.messagesDao.getForChat('chat-pl')).single;
        check(_deepEq.equals(jsonDecode(row.payload), payload)).isTrue();
      },
    );

    test(
      'markAssistantResponseDone marks replay-safe completion metadata',
      () async {
        await db.chatsDao.upsertEnvelopeStub(
          id: 'chat-headless',
          title: 'Headless',
          createdAt: 1,
          updatedAt: 1,
        );
        await db.messagesDao.upsertLocalEcho(
          echo(
            chatId: 'chat-headless',
            id: 'assistant-headless',
            content: '',
            payload: const {
              'id': 'assistant-headless',
              'role': 'assistant',
              'content': '',
              'error': {'content': 'stale recovery failure'},
              'metadata': {'checkpoint': true},
            },
          ),
        );

        final marked = await db.messagesDao.markAssistantResponseDone(
          chatId: 'chat-headless',
          messageId: 'assistant-headless',
        );

        check(marked).isTrue();
        final row = (await db.messagesDao.getForChat('chat-headless')).single;
        final payload = jsonDecode(row.payload) as Map<String, dynamic>;
        check(payload['isStreaming']).equals(false);
        check(payload['done']).equals(true);
        check(
          (payload['metadata'] as Map<String, dynamic>)['responseDone'],
        ).equals(true);
        check(
          (payload['metadata'] as Map<String, dynamic>)['checkpoint'],
        ).equals(true);
        check(payload.containsKey('error')).isFalse();
        check(row.content).equals('');
        check(row.dirty).isFalse();
      },
    );

    test(
      'completion resubmission clears stale terminal failure state',
      () async {
        await db.chatsDao.upsertEnvelopeStub(
          id: 'chat-retry',
          title: 'Retry',
          createdAt: 1,
          updatedAt: 1,
        );
        await db.messagesDao.upsertLocalEcho(
          echo(
            chatId: 'chat-retry',
            id: 'assistant-retry',
            content: 'partial',
            payload: const {
              'id': 'assistant-retry',
              'role': 'assistant',
              'content': 'partial',
              'isStreaming': false,
              'done': true,
              'error': {'content': 'previous attempt failed'},
              'metadata': {
                'checkpoint': true,
                'completionSubmitted': true,
                'responseDone': true,
              },
            },
          ),
        );

        final marked = await db.messagesDao.markAssistantCompletionSubmitted(
          chatId: 'chat-retry',
          messageId: 'assistant-retry',
        );

        check(marked).isTrue();
        final row = (await db.messagesDao.getForChat('chat-retry')).single;
        final payload = jsonDecode(row.payload) as Map<String, dynamic>;
        final metadata = payload['metadata'] as Map<String, dynamic>;
        check(payload['isStreaming']).equals(true);
        check(payload.containsKey('done')).isFalse();
        check(payload.containsKey('error')).isFalse();
        check(metadata['completionSubmitted']).equals(true);
        check(metadata.containsKey('responseDone')).isFalse();
        check(metadata['checkpoint']).equals(true);
        check(row.dirty).isFalse();
      },
    );
  });
}
