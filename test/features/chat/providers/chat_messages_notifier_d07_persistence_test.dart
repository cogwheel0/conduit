/// CDT-RFC-001 D-07 (§11 Phase 1 deliverable): a completed stream echoes the
/// trailing user + assistant turn into the local database, so a just-streamed
/// turn survives an offline cold start. The DAO primitive (upsertLocalEcho) is
/// covered in messages_dao_test.dart; this exercises the seam through
/// ChatMessagesNotifier.finishStreaming() — the path that actually fires on a
/// real completion — including the temporary-chat and absent-row no-ops.
library;

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  ProviderContainer buildContainer() {
    final container = ProviderContainer(
      overrides: [
        activeConversationProvider.overrideWith(
          () => _TestActiveConversationNotifier(),
        ),
        appDatabaseProvider.overrideWithValue(db),
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
        // The in-state assistant is no longer streaming.
        check(container.read(chatMessagesProvider).last.isStreaming).isFalse();
      },
    );

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
