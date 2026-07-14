import 'dart:async';

import 'package:checks/checks.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/daos/outbox_dao.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/connectivity_service.dart';
import 'package:conduit/features/chat/providers/queued_completion_provider.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/hermes/services/hermes_session_provenance.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> enqueueCompletion(String chatId, String assistantMessageId) {
    return db.transaction(
      () => db.outboxDao.enqueue(
        kind: OutboxKind.requestCompletion,
        chatId: chatId,
        payload: {
          'assistantMessageId': assistantMessageId,
          'model': 'm',
          'toolIds': <String>[],
          'filterIds': null,
          'systemPrompt': null,
          'sessionIdOverride': null,
        },
      ),
    );
  }

  Conversation conv(String id) => Conversation(
    id: id,
    title: 'C',
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    messages: const [],
  );

  ProviderContainer makeContainer({
    required bool online,
    required String chatId,
  }) {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => db),
        isOnlineProvider.overrideWith((ref) => online),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeConversationProvider.notifier).set(conv(chatId));
    return container;
  }

  // Awaits the first resolved (hasValue) emission of the autoDispose stream
  // provider, keeping it alive via the listen subscription.
  Future<QueuedCompletionInfo?> firstInfo(
    ProviderContainer container,
    String assistantId,
  ) async {
    final completer = Completer<QueuedCompletionInfo?>();
    final sub = container.listen(
      queuedCompletionInfoForMessageProvider(assistantId),
      (_, next) {
        if (next.hasValue && !completer.isCompleted) {
          completer.complete(next.value);
        }
      },
      fireImmediately: true,
    );
    addTearDown(sub.close);
    return completer.future.timeout(const Duration(seconds: 5));
  }

  test('a fresh pending completion is hidden even when offline '
      '(no premature retry/cancel banner on first send)', () async {
    const chatId = 'c1';
    const assistantId = 'a1';
    await enqueueCompletion(chatId, assistantId);

    // Offline (or connectivity still resolving): a brand-new, never-attempted
    // op must NOT surface the queued banner — it is "sending", not "queued".
    final container = makeContainer(online: false, chatId: chatId);
    check(await firstInfo(container, assistantId)).isNull();
  });

  test('an offline-deferred completion surfaces the banner', () async {
    const chatId = 'c1';
    const assistantId = 'a1';
    final seq = await enqueueCompletion(chatId, assistantId);
    // The drainer attempted it and found the device offline.
    await db.outboxDao.markOfflineDeferred(seq, nextAttemptAt: 0);

    final container = makeContainer(online: false, chatId: chatId);
    final info = await firstInfo(container, assistantId);
    check(info).isNotNull().has((i) => i.isOffline, 'isOffline').isTrue();
    check(info)
        .isNotNull()
        .has((i) => i.phase, 'phase')
        .equals(QueuedCompletionPhase.pending);
  });

  test(
    'a parked (failed) completion surfaces the banner even online',
    () async {
      const chatId = 'c1';
      const assistantId = 'a1';
      final seq = await enqueueCompletion(chatId, assistantId);
      await db.outboxDao.markParked(seq, error: 'boom');

      final container = makeContainer(online: true, chatId: chatId);
      final info = await firstInfo(container, assistantId);
      check(info)
          .isNotNull()
          .has((i) => i.phase, 'phase')
          .equals(QueuedCompletionPhase.failed);
    },
  );

  test('a single transient retry (attempts=1) stays hidden — no flash on the '
      'cold-connection first send', () async {
    const chatId = 'c1';
    const assistantId = 'a1';
    final seq = await enqueueCompletion(chatId, assistantId);
    // First attempt failed transiently (e.g. cold connection); auto-retry
    // scheduled with backoff. attempts -> 1, non-offline error.
    await db.outboxDao.markFailedRetryable(
      seq,
      error: 'Connection closed',
      nextAttemptAt: 1,
    );

    final container = makeContainer(online: true, chatId: chatId);
    check(await firstInfo(container, assistantId)).isNull();
  });

  test('a stalled completion (attempts >= 2) surfaces the banner', () async {
    const chatId = 'c1';
    const assistantId = 'a1';
    final seq = await enqueueCompletion(chatId, assistantId);
    await db.outboxDao.markFailedRetryable(
      seq,
      error: 'Connection closed',
      nextAttemptAt: 1,
    );
    await db.outboxDao.markFailedRetryable(
      seq,
      error: 'Connection closed',
      nextAttemptAt: 1,
    );

    final container = makeContainer(online: true, chatId: chatId);
    check(await firstInfo(container, assistantId)).isNotNull();
  });

  test(
    'a colliding native Hermes shell never surfaces an OWUI queue',
    () async {
      const chatId = 'local:hermes_queued-collision';
      const assistantId = 'assistant-collision';
      final seq = await enqueueCompletion(chatId, assistantId);
      await db.outboxDao.markOfflineDeferred(seq, nextAttemptAt: 0);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          isOnlineProvider.overrideWith((ref) => false),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(activeConversationProvider.notifier)
          .set(markNativeHermesConversation(conv(chatId)));

      check(await firstInfo(container, assistantId)).isNull();
    },
  );

  test(
    'stale OWUI cancel cannot mutate a colliding native Hermes shell',
    () async {
      const chatId = 'local:hermes_stale-queued-collision';
      const assistantId = 'assistant-collision';
      final seq = await enqueueCompletion(chatId, assistantId);
      await db.outboxDao.markOfflineDeferred(seq, nextAttemptAt: 0);
      final container = makeContainer(online: false, chatId: chatId);
      final info = await firstInfo(container, assistantId);
      check(info).isNotNull();
      final assistant = ChatMessage(
        id: assistantId,
        role: 'assistant',
        content: 'Native answer',
        timestamp: DateTime.now(),
      );
      final native = markNativeHermesConversation(
        conv(chatId).copyWith(messages: <ChatMessage>[assistant]),
      );
      container.read(activeConversationProvider.notifier).set(native);
      container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
        assistant,
      ]);

      final removed = await container
          .read(queuedCompletionActionsProvider)
          .cancel(info!);

      check(removed).equals(1);
      check(
        identical(container.read(activeConversationProvider), native),
      ).isTrue();
      check(
        isNativeHermesConversation(container.read(activeConversationProvider)),
      ).isTrue();
      check(
        container.read(chatMessagesProvider),
      ).single.has((message) => message.id, 'id').equals(assistantId);
    },
  );
}
