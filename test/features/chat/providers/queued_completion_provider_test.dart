import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/daos/outbox_dao.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/connectivity_service.dart';
import 'package:conduit/features/chat/providers/queued_completion_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

  test(
    'a fresh pending completion is hidden even when offline '
    '(no premature retry/cancel banner on first send)',
    () async {
      const chatId = 'c1';
      const assistantId = 'a1';
      await enqueueCompletion(chatId, assistantId);

      // Offline (or connectivity still resolving): a brand-new, never-attempted
      // op must NOT surface the queued banner — it is "sending", not "queued".
      final container = makeContainer(online: false, chatId: chatId);
      check(await firstInfo(container, assistantId)).isNull();
    },
  );

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

  test('a parked (failed) completion surfaces the banner even online', () async {
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
  });
}
