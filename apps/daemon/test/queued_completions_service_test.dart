@TestOn('vm')
library;

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:conduitd/src/queued_completions_service.dart';
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// Whether the connection is up, as the test sets it.
final class _Online extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool value) => state = value;
}

final _online = NotifierProvider<_Online, bool>(_Online.new);

/// Answers waiting in the outbox, as the daemon shows them: what each
/// shows on `chats.get`, and when a chat's queued answers change.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late EventBus events;
  late List<EventEnvelope> seen;
  late QueuedCompletionsService queued;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => db),
        isOnlineProvider.overrideWith((ref) => ref.watch(_online)),
      ],
    );
    events = EventBus();
    seen = <EventEnvelope>[];
    events.attach('w1', seen.add);
    events.subscribe('w1', const EventSubscription());
    queued = QueuedCompletionsService(container, events);
  });

  tearDown(() async {
    queued.dispose();
    container.dispose();
    await db.close();
  });

  Future<int> enqueue(OutboxKind kind, {Map<String, dynamic>? payload}) =>
      db.transaction(
        () => db.outboxDao.enqueue(
          kind: kind,
          chatId: 'c1',
          payload: payload ?? const <String, dynamic>{},
        ),
      );

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  List<String?> changedChats() => <String?>[
    for (final e in seen)
      if (e.event == ConduitEvents.chatsChanged)
        ChatsChanged.fromJson(e.payload).chatId,
  ];

  test(
    'an answer held up by its chat\'s update shows queued until it goes out',
    () async {
      final update = await enqueue(OutboxKind.updateChat);
      final completion = await enqueue(
        OutboxKind.requestCompletion,
        payload: const RequestCompletionPayload(
          assistantMessageId: 'a1',
          model: 'gpt',
        ).toJson(),
      );
      await settle();
      // Not tried yet: nothing shows, as a send normally goes out at once.
      expect(await queued.forChat('c1'), isEmpty);
      expect(queued.isQueued('c1', 'a1'), isFalse);

      // The chat's update could not go out: the server is out of reach.
      await db.outboxDao.markOfflineDeferred(update, nextAttemptAt: 0);
      await settle();
      expect(await queued.forChat('c1'), <String, QueuedCompletionDto>{
        'a1': const QueuedCompletionDto(offline: true),
      });
      expect(queued.isQueued('c1', 'a1'), isTrue);
      expect(changedChats(), contains('c1'));

      // Back online: the update goes, then the answer's request.
      await db.outboxDao.markDone(update);
      await db.outboxDao.claimNextRunnable(
        nowEpochSeconds: 1 << 40,
        busyChatIds: const <String>{},
      );
      await settle();
      expect(queued.isQueued('c1', 'a1'), isFalse);
      expect(queued.wasQueued('c1', 'a1'), isTrue);
      expect(queued.hasQueued('c1'), isFalse);
      await db.outboxDao.markDone(completion);
    },
  );

  test('an answer behind its chat\'s update shows queued once the update waits '
      'for the connection', () async {
    final update = await enqueue(OutboxKind.updateChat);
    await enqueue(
      OutboxKind.requestCompletion,
      payload: const RequestCompletionPayload(
        assistantMessageId: 'a1',
        model: 'gpt',
      ).toJson(),
    );
    // Tried once: a retry follows, and nothing shows for it.
    await db.outboxDao.markFailedRetryable(
      update,
      error: 'connection error',
      nextAttemptAt: 0,
    );
    await settle();
    expect(await queued.forChat('c1'), isEmpty);

    // The connection goes: the outbox tries nothing more until it is back,
    // so the update waits for it, and the answer behind it shows waiting
    // (the phone's rule).
    container.read(_online.notifier).set(false);
    await settle();
    expect(await queued.forChat('c1'), <String, QueuedCompletionDto>{
      'a1': const QueuedCompletionDto(offline: true, error: 'connection error'),
    });
    expect(queued.isQueued('c1', 'a1'), isTrue);
    await db.outboxDao.markOfflineDeferred(update, nextAttemptAt: 0);
    await settle();
    expect(await queued.forChat('c1'), <String, QueuedCompletionDto>{
      'a1': const QueuedCompletionDto(offline: true),
    });
    expect(queued.isQueued('c1', 'a1'), isTrue);

    // Back online, the outbox sends the update, and nothing waits.
    container.read(_online.notifier).set(true);
    await db.outboxDao.markDone(update);
    await settle();
    expect(queued.isQueued('c1', 'a1'), isFalse);
  });
}
