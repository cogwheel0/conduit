import 'dart:async';

import 'package:checks/checks.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
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
import 'package:conduit/core/sync/sync_engine.dart';
import 'package:conduit/features/chat/providers/queued_completion_provider.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/hermes/services/hermes_session_provenance.dart';

class _DatabaseOwnedDrainBarrier extends SyncEngine {
  _DatabaseOwnedDrainBarrier(this._currentDatabase);

  final AppDatabase? Function() _currentDatabase;
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();
  int genericDrainCalls = 0;
  int databaseOwnedDrainCalls = 0;
  AppDatabase? expectedDatabase;

  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<void> drainNow() async {
    genericDrainCalls += 1;
    if (!entered.isCompleted) entered.complete();
    await release.future;
    final activeDatabase = _currentDatabase();
    if (activeDatabase != null) {
      await activeDatabase.outboxDao.requeueParked(1, nowEpochSeconds: 123);
    }
  }

  @override
  Future<void> drainNowForDatabase(AppDatabase database) async {
    databaseOwnedDrainCalls += 1;
    expectedDatabase = database;
    if (!entered.isCompleted) entered.complete();
    await release.future;
    if (!identical(_currentDatabase(), database)) return;
  }
}

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> enqueueCompletionIn(
    AppDatabase database,
    String chatId,
    String assistantMessageId,
  ) {
    return database.transaction(
      () => database.outboxDao.enqueue(
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

  Future<int> enqueueCompletion(String chatId, String assistantMessageId) =>
      enqueueCompletionIn(db, chatId, assistantMessageId);

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

  Future<Map<String, QueuedCompletionInfo>> firstInfoMap(
    ProviderContainer container,
  ) async {
    final completer = Completer<Map<String, QueuedCompletionInfo>>();
    final sub = container.listen(queuedCompletionInfoByMessageProvider, (
      _,
      next,
    ) {
      if (next.hasValue && !completer.isCompleted) {
        completer.complete(next.value);
      }
    }, fireImmediately: true);
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
    'one chat-scoped emission includes only its queued assistants',
    () async {
      const chatId = 'c1';
      final firstSeq = await enqueueCompletion(chatId, 'a1');
      final secondSeq = await enqueueCompletion(chatId, 'a2');
      final otherChatSeq = await enqueueCompletion(
        'c2',
        'other-chat-assistant',
      );
      await db.outboxDao.markOfflineDeferred(firstSeq, nextAttemptAt: 0);
      await db.outboxDao.markOfflineDeferred(secondSeq, nextAttemptAt: 0);
      await db.outboxDao.markOfflineDeferred(otherChatSeq, nextAttemptAt: 0);

      final container = makeContainer(online: false, chatId: chatId);
      final infos = await firstInfoMap(container);

      check(infos.keys.toSet()).deepEquals(<String>{'a1', 'a2'});
      check(infos['a1']?.seq).equals(firstSeq);
      check(infos['a2']?.seq).equals(secondSeq);
      check(infos.containsKey('other-chat-assistant')).isFalse();
    },
  );

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

  test(
    'stale database A retry and cancel cannot mutate colliding database B',
    () async {
      const chatId = 'same-chat';
      const assistantId = 'same-assistant';
      final previousWarningSetting =
          driftRuntimeOptions.dontWarnAboutMultipleDatabases;
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      addTearDown(() {
        driftRuntimeOptions.dontWarnAboutMultipleDatabases =
            previousWarningSetting;
      });
      final databaseB = AppDatabase(NativeDatabase.memory());
      addTearDown(databaseB.close);

      final seqA = await enqueueCompletionIn(db, chatId, assistantId);
      final seqB = await enqueueCompletionIn(databaseB, chatId, assistantId);
      check(seqA).equals(1);
      check(seqB).equals(1);
      await db.outboxDao.markParked(seqA, error: 'database-a');
      await databaseB.outboxDao.markParked(seqB, error: 'database-b');

      var currentDatabase = db;
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => currentDatabase),
          isOnlineProvider.overrideWith((ref) => true),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeConversationProvider.notifier).set(conv(chatId));

      final staleInfo = await firstInfo(container, assistantId);
      check(staleInfo).isNotNull();
      final actions = container.read(queuedCompletionActionsProvider);
      final beforeA = (await db.select(db.outboxOps).get()).single;
      final beforeB =
          (await databaseB.select(databaseB.outboxOps).get()).single;

      currentDatabase = databaseB;
      container.invalidate(appDatabaseProvider);
      check(container.read(appDatabaseProvider)).identicalTo(databaseB);

      await actions.retry(staleInfo!);
      check(await actions.cancel(staleInfo)).equals(0);

      check((await db.select(db.outboxOps).get()).single).equals(beforeA);
      check(
        (await databaseB.select(databaseB.outboxOps).get()).single,
      ).equals(beforeB);
    },
  );

  test(
    'same-database auth-session switch invalidates queued actions',
    () async {
      const chatId = 'same-chat';
      const assistantId = 'same-assistant';
      final seq = await enqueueCompletion(chatId, assistantId);
      await db.outboxDao.markParked(seq, error: 'account-a');
      var authSessionEpoch = Object();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          isOnlineProvider.overrideWith((ref) => true),
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => authSessionEpoch,
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeConversationProvider.notifier).set(conv(chatId));

      final staleInfo = await firstInfo(container, assistantId);
      check(staleInfo).isNotNull();
      final before = (await db.select(db.outboxOps).get()).single;
      final actions = container.read(queuedCompletionActionsProvider);

      authSessionEpoch = Object();
      container.invalidate(openWebUiAuthSessionEpochProvider);

      await actions.retry(staleInfo!);
      check(await actions.cancel(staleInfo)).equals(0);
      check((await db.select(db.outboxOps).get()).single).equals(before);
    },
  );

  test(
    'auth-session switch at retry admission rolls the DAO write back',
    () async {
      const chatId = 'same-chat';
      const assistantId = 'same-assistant';
      final seq = await enqueueCompletion(chatId, assistantId);
      await db.outboxDao.markParked(seq, error: 'account-a');
      var authSessionEpoch = Object();
      final entered = Completer<void>();
      final release = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          isOnlineProvider.overrideWith((ref) => true),
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => authSessionEpoch,
          ),
          queuedCompletionMutationAdmissionProvider.overrideWithValue(() async {
            if (!entered.isCompleted) entered.complete();
            await release.future;
          }),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeConversationProvider.notifier).set(conv(chatId));
      final info = await firstInfo(container, assistantId);
      check(info).isNotNull();
      final before = (await db.select(db.outboxOps).get()).single;

      final retry = container
          .read(queuedCompletionActionsProvider)
          .retry(info!);
      await entered.future.timeout(const Duration(seconds: 5));
      authSessionEpoch = Object();
      container.invalidate(openWebUiAuthSessionEpochProvider);
      release.complete();
      await retry;

      check((await db.select(db.outboxOps).get()).single).equals(before);
    },
  );

  test(
    'auth-session switch at cancel admission rolls the DAO write back',
    () async {
      const chatId = 'same-chat';
      const assistantId = 'same-assistant';
      final seq = await enqueueCompletion(chatId, assistantId);
      await db.outboxDao.markParked(seq, error: 'account-a');
      var authSessionEpoch = Object();
      final entered = Completer<void>();
      final release = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          isOnlineProvider.overrideWith((ref) => true),
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => authSessionEpoch,
          ),
          queuedCompletionMutationAdmissionProvider.overrideWithValue(() async {
            if (!entered.isCompleted) entered.complete();
            await release.future;
          }),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeConversationProvider.notifier).set(conv(chatId));
      final info = await firstInfo(container, assistantId);
      check(info).isNotNull();
      final before = (await db.select(db.outboxOps).get()).single;

      final cancel = container
          .read(queuedCompletionActionsProvider)
          .cancel(info!);
      await entered.future.timeout(const Duration(seconds: 5));
      authSessionEpoch = Object();
      container.invalidate(openWebUiAuthSessionEpochProvider);
      release.complete();

      check(await cancel).equals(0);
      check((await db.select(db.outboxOps).get()).single).equals(before);
    },
  );

  test('retry cannot drain the new database after a switch at the drain '
      'barrier', () async {
    const chatId = 'same-chat';
    const assistantId = 'same-assistant';
    final previousWarningSetting =
        driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    addTearDown(() {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases =
          previousWarningSetting;
    });
    final databaseB = AppDatabase(NativeDatabase.memory());
    addTearDown(databaseB.close);

    final seqA = await enqueueCompletionIn(db, chatId, assistantId);
    final seqB = await enqueueCompletionIn(databaseB, chatId, assistantId);
    check(seqA).equals(1);
    check(seqB).equals(1);
    await db.outboxDao.markParked(seqA, error: 'database-a');
    await databaseB.outboxDao.markParked(seqB, error: 'database-b');
    final beforeB = (await databaseB.select(databaseB.outboxOps).get()).single;

    var currentDatabase = db;
    final drainBarrier = _DatabaseOwnedDrainBarrier(() => currentDatabase);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => currentDatabase),
        isOnlineProvider.overrideWith((ref) => true),
        syncEngineProvider.overrideWith(() => drainBarrier),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeConversationProvider.notifier).set(conv(chatId));
    final info = await firstInfo(container, assistantId);
    check(info).isNotNull();

    final retry = container.read(queuedCompletionActionsProvider).retry(info!);
    await drainBarrier.entered.future.timeout(const Duration(seconds: 5));

    currentDatabase = databaseB;
    container.invalidate(appDatabaseProvider);
    check(container.read(appDatabaseProvider)).identicalTo(databaseB);
    drainBarrier.release.complete();
    await retry;

    check(drainBarrier.databaseOwnedDrainCalls).equals(1);
    check(drainBarrier.genericDrainCalls).equals(0);
    check(drainBarrier.expectedDatabase).identicalTo(db);
    check(
      (await databaseB.select(databaseB.outboxOps).get()).single,
    ).equals(beforeB);
  });

  test('queued actions retain their Ref across an async boundary', () async {
    final container = makeContainer(online: true, chatId: 'c1');
    final actions = container.read(queuedCompletionActionsProvider);

    await Future<void>.delayed(Duration.zero);

    check(container.read(queuedCompletionActionsProvider)).identicalTo(actions);
  });
}
