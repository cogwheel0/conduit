/// CDT-RFC-001 D-07 (§11 Phase 1 deliverable): a completed stream echoes the
/// trailing user + assistant turn into the local database, so a just-streamed
/// turn survives an offline cold start. The DAO primitive (upsertLocalEcho) is
/// covered in messages_dao_test.dart; this exercises the seam through
/// ChatMessagesNotifier.finishStreaming() — the path that actually fires on a
/// real completion — including the temporary-chat and absent-row no-ops.
library;

import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/conversation_parsing.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'package:conduit_core/testing.dart';

class _TestActiveConversationNotifier extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

ChatMessage _user(String id, String content) => ChatMessage(
  id: id,
  role: 'user',
  content: content,
  timestamp: DateTime(2024, 1, 1),
);

ChatMessage _streamingAssistant(String id, String content) => ChatMessage(
  id: id,
  role: 'assistant',
  content: content,
  timestamp: DateTime(2024, 1, 1, 0, 0, 1),
  isStreaming: true,
);

Conversation _conversation(String id) => Conversation(
  id: id,
  title: 'Test chat',
  createdAt: DateTime(2024, 1, 1),
  updatedAt: DateTime(2024, 1, 1),
  messages: const [],
);

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  ProviderContainer buildContainer() {
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(database: db),
        activeConversationProvider.overrideWith(
          () => _TestActiveConversationNotifier(),
        ),
        apiServiceProvider.overrideWithValue(null),
        socketServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> settleUntil(
    Future<bool> Function() done, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await done()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Timed out waiting for async persistence to settle');
  }

  Future<void> seedChatRow(String id) => db.chatsDao.upsertEnvelopeStub(
    id: id,
    title: 'Test chat',
    createdAt: 1704067200,
    updatedAt: 1704067200,
  );

  Future<void> seedExistingTurn(String id) async {
    await seedChatRow(id);
    await db.messagesDao.upsertLocalEcho(
      MessageRowData(
        id: 'prev-a',
        chatId: id,
        role: 'assistant',
        content: 'Previous answer',
        createdAt: 1704067200,
        orderIndex: 0,
        payload: const {
          'id': 'prev-a',
          'parentId': null,
          'role': 'assistant',
          'content': 'Previous answer',
          'timestamp': 1704067200,
        },
      ),
    );
    await (db.update(db.chats)..where((t) => t.id.equals(id))).write(
      const ChatsCompanion(currentMessageId: Value('prev-a')),
    );
  }

  group('D-07 stream-completion persistence', () {
    test(
      'finishStreaming echoes the user+assistant turn with linked parentId',
      () async {
        await seedChatRow('d07-chat');
        final container = buildContainer();
        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('d07-chat'));

        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([
          _user('u-1', 'Question'),
          _streamingAssistant('a-1', 'Streamed answer'),
        ]);

        notifier.finishStreaming();
        await settleUntil(
          () async => (await db.messagesDao.getForChat('d07-chat')).length == 2,
        );

        final rows = await db.messagesDao.getForChat('d07-chat');
        check(rows.map((r) => r.id).toList()).deepEquals(['u-1', 'a-1']);
        final assistant = rows.firstWhere((r) => r.id == 'a-1');
        final user = rows.firstWhere((r) => r.id == 'u-1');
        check(user.parentId).isNull();
        check(assistant.parentId).equals('u-1');
        check(assistant.content).equals('Streamed answer');
        final assistantPayload =
            jsonDecode(assistant.payload) as Map<String, dynamic>;
        check(assistantPayload['isStreaming']).equals(false);
        // The in-state assistant is no longer streaming.
        check(container.read(chatMessagesProvider).last.isStreaming).isFalse();
      },
    );

    test(
      'finishStreaming links an existing chat turn to the previous tip',
      () async {
        await seedExistingTurn('d07-existing');
        final container = buildContainer();
        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('d07-existing'));

        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([
          _user('u-2', 'Follow-up'),
          _streamingAssistant('a-2', 'Follow-up answer'),
        ]);

        notifier.finishStreaming();
        await settleUntil(
          () async =>
              (await db.chatsDao.getChat('d07-existing'))?.currentMessageId ==
              'a-2',
        );

        final rows = await db.messagesDao.getForChat('d07-existing');
        check(rows.singleWhere((r) => r.id == 'u-2').parentId).equals('prev-a');
        check(rows.singleWhere((r) => r.id == 'a-2').parentId).equals('u-2');
        final chat = await db.chatsDao.getChat('d07-existing');
        check(chat!.currentMessageId).equals('a-2');
      },
    );

    test(
      'pause checkpoint preserves in-flight assistant streaming state',
      () async {
        await seedChatRow('d07-pause');
        final container = buildContainer();
        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('d07-pause'));

        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([
          _user('u-pause', 'Question'),
          _streamingAssistant('a-pause', 'Partial answer'),
        ]);

        await notifier.persistPauseCheckpoint();

        final rows = await db.messagesDao.getForChat('d07-pause');
        final assistant = rows.firstWhere((r) => r.id == 'a-pause');
        final assistantPayload =
            jsonDecode(assistant.payload) as Map<String, dynamic>;
        check(assistantPayload['isStreaming']).equals(true);
        check(assistantPayload.containsKey('done')).isFalse();
        check(container.read(chatMessagesProvider).last.isStreaming).isTrue();
        notifier.setMessages([
          _user('u-pause', 'Question'),
          _streamingAssistant(
            'a-pause',
            'Partial answer',
          ).copyWith(isStreaming: false),
        ]);
      },
    );

    test('finishStreaming keeps a parsed comparison turn\'s model list and '
        'identities in the rebuilt server chat', () async {
      // Open WebUI only draws a turn's answers as a comparison (and its saved
      // merge) while the parent user message still carries `models`.
      const models = ['model-b', 'model-a', 'model-b'];
      final raw = <String, dynamic>{
        'id': 'd07-comparison',
        'title': 'Test chat',
        'created_at': 1704067200,
        'updated_at': 1704067200,
        'chat': {
          'history': {
            'currentId': 'a-1',
            'messages': {
              'u-cmp': {
                'id': 'u-cmp',
                'parentId': null,
                'childrenIds': ['a-0', 'a-1', 'a-2'],
                'role': 'user',
                'content': 'Compare',
                'models': models,
                'timestamp': 1704067200,
              },
              for (var slot = 0; slot < 3; slot += 1)
                'a-$slot': {
                  'id': 'a-$slot',
                  'parentId': 'u-cmp',
                  'childrenIds': <String>[],
                  'role': 'assistant',
                  'content': 'Answer $slot',
                  'model': models[slot],
                  'modelIdx': slot,
                  'done': true,
                  'timestamp': 1704067201,
                  if (slot == 1)
                    'merged': {'status': true, 'content': 'Merged answer'},
                },
            },
          },
        },
      };
      // The chat as the server holds it, with the user's saved model list.
      await db.chatsDao.upsertServerChat(
        rows: ChatBlobMapper.blobToRows(
          chatId: 'd07-comparison',
          blob: raw['chat'] as Map<String, dynamic>,
          title: 'Test chat',
          createdAt: 1704067200,
          updatedAt: 1704067200,
        ),
      );
      final parsed = Conversation.fromJson(parseFullConversation(raw));
      final container = buildContainer();
      container.read(activeConversationProvider.notifier).set(parsed);

      final notifier = container.read(chatMessagesProvider.notifier);
      final shown = parsed.messages.last;
      check(shown.id).equals('a-1');
      notifier.setMessages([
        ...parsed.messages.take(parsed.messages.length - 1),
        shown.copyWith(isStreaming: true),
      ]);

      notifier.finishStreaming();
      // Only the echo writes `isStreaming`; the server copy above has none.
      await settleUntil(() async {
        final rows = await db.messagesDao.getForChat('d07-comparison');
        return rows.any(
          (row) =>
              row.id == 'a-1' &&
              (jsonDecode(row.payload) as Map<String, dynamic>).containsKey(
                'isStreaming',
              ),
        );
      });

      final chat = await db.chatsDao.getChat('d07-comparison');
      final rebuilt = buildChatResponseEnvelope(
        chat!,
        await db.messagesDao.getForChat('d07-comparison'),
      );
      final messages =
          ((rebuilt['chat'] as Map<String, dynamic>)['history']
                  as Map<String, dynamic>)['messages']
              as Map<String, dynamic>;
      final user = messages['u-cmp'] as Map<String, dynamic>;
      final answer = messages['a-1'] as Map<String, dynamic>;
      check(user['models']).isA<List<Object?>>().deepEquals(models);
      check(user['parentId']).isNull();
      check(user['childrenIds']).isA<List<Object?>>().contains('a-1');
      check(answer['parentId']).equals('u-cmp');
      check(answer['modelIdx']).equals(1);
      check(answer['merged'])
          .isA<Map<Object?, Object?>>()
          .deepEquals({'status': true, 'content': 'Merged answer'});
    });

    test('temporary (local:) chats persist nothing', () async {
      await seedChatRow('local:draft');
      final container = buildContainer();
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('local:draft'));

      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([
        _user('u-1', 'Question'),
        _streamingAssistant('a-1', 'Streamed answer'),
      ]);
      notifier.finishStreaming();
      await settleUntil(
        () async => (await db.messagesDao.getForChat('local:draft')).isEmpty,
      );

      check(await db.messagesDao.getForChat('local:draft')).isEmpty();
    });

    // The absent-chats-row no-op (upsertLocalEcho returns false) is a DAO-level
    // guarantee covered in messages_dao_test.dart. It is not reachable through
    // finishStreaming(): the completion path first runs
    // _syncConversationStateAfterStreamingUpdate(), which writes the active
    // conversation's chats row, so by the time the echo runs the row exists.
  });
}
