import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/daos/outbox_dao.dart';
import 'package:conduit/core/persistence/hive_boxes.dart';
import 'package:conduit/core/sync/chat_locks.dart';
import 'package:conduit/core/sync/clock.dart';
import 'package:conduit/core/sync/outbox_task_queue_migrator.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

class _FixedClock implements SyncClock {
  _FixedClock(this.now);
  int now;
  @override
  int nowEpochSeconds() => now;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Box<dynamic> preferences;
  late Box<dynamic> caches;
  late Box<dynamic> attachmentQueue;
  late Box<dynamic> metadata;
  late AppDatabase db;
  late ConversationLocks chatLocks;

  HiveBoxes boxes() => HiveBoxes(
    preferences: preferences,
    caches: caches,
    attachmentQueue: attachmentQueue,
    metadata: metadata,
  );

  OutboxTaskQueueMigrator migrator({String model = 'default-model'}) {
    return OutboxTaskQueueMigrator(
      db: db,
      hiveBoxes: boxes(),
      chatLocks: chatLocks,
      clock: _FixedClock(7000),
      resolveDefaultModel: () => model,
    );
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('outbox-migrate-test');
    Hive.init(tempDir.path);
    preferences = await Hive.openBox<dynamic>('preferences_v1');
    caches = await Hive.openBox<dynamic>('caches_v1');
    attachmentQueue = await Hive.openBox<dynamic>('attachment_queue_v1');
    metadata = await Hive.openBox<dynamic>('metadata_v1');
    db = AppDatabase(NativeDatabase.memory());
    chatLocks = ConversationLocks();
  });

  tearDown(() async {
    await db.close();
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Map<String, dynamic> sendTextTask({
    required String id,
    String? conversationId,
    String text = 'Hello world',
    List<String> attachments = const [],
    List<String> toolIds = const [],
    String status = 'queued',
  }) {
    return <String, dynamic>{
      'runtimeType': 'sendTextMessage',
      'id': id,
      'conversationId': conversationId,
      'text': text,
      'attachments': attachments,
      'toolIds': toolIds,
      'status': status,
    };
  }

  group('new-chat conversion (acceptance D5)', () {
    test(
      'queued sendTextMessage -> local chat + createChat + completion ops',
      () async {
        await caches.put('outbound_task_queue_v1', [
          sendTextTask(id: 't1', text: 'first message', toolIds: ['tool-a']),
        ]);

        final report = await migrator().migrateIfNeeded();

        check(report.converted).equals(1);

        // Exactly one local chat row, dirty + not yet synced.
        final chats = await db.select(db.chats).get();
        check(chats.length).equals(1);
        final chat = chats.single;
        check(chat.id.startsWith('local:')).isTrue();
        check(chat.dirty).isTrue();
        check(chat.serverUpdatedAt).isNull();
        check(chat.bodySynced).isTrue();

        // user + assistant placeholder rows.
        final msgs = await db.messagesDao.getForChat(chat.id);
        check(msgs.length).equals(2);
        check(
          msgs.where((m) => m.role == 'user').single.content,
        ).equals('first message');

        // createChat (with contentHash) THEN requestCompletion.
        final ops = await db.outboxDao.pendingForChat(chat.id);
        check(ops.length).equals(2);
        check(ops[0].kind).equals('createChat');
        check(ops[0].contentHash).isNotNull();
        check(ops[1].kind).equals('requestCompletion');
        final payload = RequestCompletionPayload.fromJson(
          _decode(ops[1].payload),
        );
        check(payload.model).equals('default-model');
        check(payload.toolIds).deepEquals(['tool-a']);
        // Completion's assistantMessageId matches a real placeholder row.
        check(msgs.any((m) => m.id == payload.assistantMessageId)).isTrue();

        // Flag set + Hive key purged.
        check(
          await db.syncMetaDao.getValue(
            OutboxTaskQueueMigrator.migratedFlagKey,
          ),
        ).equals('1');
        check(caches.get('outbound_task_queue_v1')).isNull();
      },
    );

    test('running tasks are coerced to queued and converted', () async {
      await caches.put('outbound_task_queue_v1', [
        sendTextTask(id: 't1', status: 'running'),
      ]);
      final report = await migrator().migrateIfNeeded();
      check(report.converted).equals(1);
      check((await db.select(db.chats).get()).length).equals(1);
    });

    test('migrated file attachments preserve id as url', () async {
      await caches.put('outbound_task_queue_v1', [
        sendTextTask(id: 't1', attachments: ['file-1']),
      ]);

      await migrator().migrateIfNeeded();

      final chat = (await db.select(db.chats).get()).single;
      final user = (await db.messagesDao.getForChat(
        chat.id,
      )).where((m) => m.role == 'user').single;
      final payload = _decode(user.payload);
      final files = payload['files'] as List;
      final file = Map<String, dynamic>.from(files.single as Map);
      check(file).deepEquals({'type': 'file', 'id': 'file-1', 'url': 'file-1'});
    });

    test('non-queued/running tasks are skipped', () async {
      await caches.put('outbound_task_queue_v1', [
        sendTextTask(id: 't1', status: 'succeeded'),
        sendTextTask(id: 't2', status: 'failed'),
      ]);
      final report = await migrator().migrateIfNeeded();
      check(report.converted).equals(0);
      check((await db.select(db.chats).get())).isEmpty();
    });
  });

  group('existing-chat conversion', () {
    test(
      'server-id task enqueues requestCompletion ONLY (no createChat)',
      () async {
        await caches.put('outbound_task_queue_v1', [
          sendTextTask(id: 't1', conversationId: 'srv-1', text: 'hi'),
        ]);
        await migrator().migrateIfNeeded();

        final ops = await db.outboxDao.pendingForChat('srv-1');
        check(
          ops.map((o) => o.kind).toList(),
        ).deepEquals(['requestCompletion']);
        // A stub row was materialized for the unpulled server id.
        final chat = await db.chatsDao.getChat('srv-1');
        check(chat).isNotNull();
        check(chat!.dirty).isFalse();
        final messages = await db.messagesDao.getForChat('srv-1');
        check(messages.every((message) => !message.dirty)).isTrue();
      },
    );

    test('a "running" task whose turn ALREADY completed server-side is skipped '
        '(no duplicate turn, no second completion)', () async {
      // _runOnce pulls BEFORE migration; the completed turn is already stored
      // under the SERVER's own message ids (not the v5-derived ids).
      await db
          .into(db.chats)
          .insert(
            ChatsCompanion.insert(
              id: 'srv-2',
              title: 'T',
              createdAt: 1,
              updatedAt: 1,
              currentMessageId: const Value('srv-asst'), // active-branch tip
              bodySynced: const Value(true),
            ),
          );
      await db
          .into(db.messages)
          .insert(
            MessagesCompanion.insert(
              id: 'srv-user',
              chatId: 'srv-2',
              role: 'user',
              content: 'hi',
              createdAt: 1,
              orderIndex: 0,
              payload: '{}',
            ),
          );
      await db
          .into(db.messages)
          .insert(
            MessagesCompanion.insert(
              id: 'srv-asst',
              chatId: 'srv-2',
              role: 'assistant',
              content: 'hello there',
              parentId: const Value('srv-user'),
              createdAt: 2,
              orderIndex: 1,
              payload: '{}',
            ),
          );

      await caches.put('outbound_task_queue_v1', [
        sendTextTask(
          id: 't1',
          conversationId: 'srv-2',
          text: 'hi',
          status: 'running',
        ),
      ]);
      await migrator().migrateIfNeeded();

      // Nothing enqueued — no duplicate updateChat, no unwanted requestCompletion.
      check(await db.outboxDao.pendingForChat('srv-2')).isEmpty();
      // Still exactly the two original messages (no duplicate turn appended).
      check((await db.messagesDao.getForChat('srv-2')).length).equals(2);
    });

    test('a migrated turn LINKS to the prior conversation tip (not an orphan '
        'root) when the chat was already pulled', () async {
      // A pulled chat with a prior completed turn; current tip = prior-asst.
      await db
          .into(db.chats)
          .insert(
            ChatsCompanion.insert(
              id: 'srv-3',
              title: 'T',
              createdAt: 1,
              updatedAt: 1,
              currentMessageId: const Value('prior-asst'),
              bodySynced: const Value(true),
            ),
          );
      await db
          .into(db.messages)
          .insert(
            MessagesCompanion.insert(
              id: 'prior-user',
              chatId: 'srv-3',
              role: 'user',
              content: 'old question',
              createdAt: 1,
              orderIndex: 0,
              payload: '{}',
            ),
          );
      await db
          .into(db.messages)
          .insert(
            MessagesCompanion.insert(
              id: 'prior-asst',
              chatId: 'srv-3',
              role: 'assistant',
              content: 'old answer',
              parentId: const Value('prior-user'),
              createdAt: 2,
              orderIndex: 1,
              payload: '{}',
            ),
          );

      await caches.put('outbound_task_queue_v1', [
        sendTextTask(id: 't1', conversationId: 'srv-3', text: 'new question'),
      ]);
      await migrator().migrateIfNeeded();

      // The migrated user message hangs off the prior tip, not null.
      final msgs = await db.messagesDao.getForChat('srv-3');
      final migratedUser = msgs.firstWhere(
        (m) => m.role == 'user' && m.content == 'new question',
      );
      check(migratedUser.parentId).equals('prior-asst');
    });
  });

  group('dead/upload task variants', () {
    test('uploadMedia and dead variants are dropped with counts', () async {
      await caches.put('outbound_task_queue_v1', [
        <String, dynamic>{
          'runtimeType': 'uploadMedia',
          'id': 'u1',
          'filePath': '/x',
          'fileName': 'x.png',
          'status': 'queued',
        },
        <String, dynamic>{
          'runtimeType': 'generateImage',
          'id': 'g1',
          'prompt': 'cat',
          'status': 'queued',
        },
      ]);
      final report = await migrator().migrateIfNeeded();
      check(report.droppedUpload).equals(1);
      check(report.droppedDead).equals(1);
      check(report.converted).equals(0);
      check((await db.select(db.chats).get())).isEmpty();
      // Flag still set (all eligible processed) + key purged.
      check(caches.get('outbound_task_queue_v1')).isNull();
    });
  });

  group('idempotency (R7)', () {
    test('re-running after success is a no-op (flag short-circuit)', () async {
      await caches.put('outbound_task_queue_v1', [sendTextTask(id: 't1')]);
      await migrator().migrateIfNeeded();
      final firstCount = (await db.select(db.chats).get()).length;

      // Re-seed the same key (as if a stale write) and re-run: flag short-circuits.
      await caches.put('outbound_task_queue_v1', [sendTextTask(id: 't1')]);
      final report = await migrator().migrateIfNeeded();
      check(report.alreadyMigrated).isTrue();
      check((await db.select(db.chats).get()).length).equals(firstCount);
    });

    test(
      'contentHash dedupe prevents duplicate chats on re-run before flag',
      () async {
        // Two migrator runs WITHOUT the flag set in between (simulate a crash
        // after conversion but before the flag persisted) must not duplicate.
        final task = sendTextTask(id: 't1', text: 'dedupe me');
        await caches.put('outbound_task_queue_v1', [task]);

        // First run, but clear the flag afterward to simulate the flag-write
        // never landing.
        await migrator().migrateIfNeeded();
        await (db.delete(db.syncMeta)..where(
              (t) => t.key.equals(OutboxTaskQueueMigrator.migratedFlagKey),
            ))
            .go();
        // Re-seed the same task and run again: contentHash dedupe skips it.
        await caches.put('outbound_task_queue_v1', [task]);
        final report = await migrator().migrateIfNeeded();

        check(report.skippedDuplicate).equals(1);
        check(report.converted).equals(0);
        // Still exactly one local chat.
        check((await db.select(db.chats).get()).length).equals(1);
      },
    );

    test('contentHash dedupe survives wall-clock advance across re-runs', () async {
      // Regression: the new-chat blob's per-message timestamps must NOT depend
      // on the wall clock, or the contentHash drifts between a partial-failure
      // run and a re-run on a LATER app launch -> dedupe misses -> duplicate
      // chat POSTed. Use a shared advancing clock (7000 then 7050) across runs.
      final clock = _FixedClock(7000);
      OutboxTaskQueueMigrator migratorWith() => OutboxTaskQueueMigrator(
        db: db,
        hiveBoxes: boxes(),
        chatLocks: chatLocks,
        clock: clock,
        resolveDefaultModel: () => 'default-model',
      );

      final task = sendTextTask(id: 't1', text: 'dedupe me');
      await caches.put('outbound_task_queue_v1', [task]);

      await migratorWith().migrateIfNeeded();
      await (db.delete(db.syncMeta)..where(
            (t) => t.key.equals(OutboxTaskQueueMigrator.migratedFlagKey),
          ))
          .go();

      // Advance the wall clock before the re-run.
      clock.now = 7050;
      await caches.put('outbound_task_queue_v1', [task]);
      final report = await migratorWith().migrateIfNeeded();

      check(report.skippedDuplicate).equals(1);
      check(report.converted).equals(0);
      check((await db.select(db.chats).get()).length).equals(1);
    });

    test(
      'durable contentHash marker dedupes after the create op drained',
      () async {
        final task = sendTextTask(id: 't1', text: 'already posted');
        await caches.put('outbound_task_queue_v1', [task]);
        await migrator().migrateIfNeeded();

        // Simulate an abort before the migration flag persisted, followed by a
        // same-process drain that deleted the createChat/requestCompletion rows.
        await (db.delete(db.syncMeta)..where(
              (t) => t.key.equals(OutboxTaskQueueMigrator.migratedFlagKey),
            ))
            .go();
        await db.delete(db.outboxOps).go();

        await caches.put('outbound_task_queue_v1', [task]);
        final report = await migrator().migrateIfNeeded();

        check(report.skippedDuplicate).equals(1);
        check(report.converted).equals(0);
        check((await db.select(db.chats).get()).length).equals(1);
        check(await db.select(db.outboxOps).get()).isEmpty();
      },
    );

    test('absent key: no-op and sets the migrated flag', () async {
      final report = await migrator().migrateIfNeeded();
      check(report.converted).equals(0);
      check(report.alreadyMigrated).isFalse();
      check(
        await db.syncMetaDao.getValue(OutboxTaskQueueMigrator.migratedFlagKey),
      ).equals('1');
    });

    test(
      'existing-chat re-run is idempotent (Finding 6: no duplicate rows/ops)',
      () async {
        final task = sendTextTask(
          id: 't1',
          conversationId: 'srv-1',
          text: 'hi',
        );
        await caches.put('outbound_task_queue_v1', [task]);
        await migrator().migrateIfNeeded();
        final firstMsgs = await db.messagesDao.getForChat('srv-1');
        final firstOps = await db.outboxDao.pendingForChat('srv-1');
        check(firstMsgs).length.equals(2); // user + assistant
        check(
          firstOps.map((o) => o.kind).toList(),
        ).deepEquals(['requestCompletion']);

        // Simulate a partial-failure crash: flag never landed. Re-run.
        await (db.delete(db.syncMeta)..where(
              (t) => t.key.equals(OutboxTaskQueueMigrator.migratedFlagKey),
            ))
            .go();
        await caches.put('outbound_task_queue_v1', [task]);
        final report = await migrator().migrateIfNeeded();

        check(report.skippedDuplicate).equals(1);
        check(report.converted).equals(0);
        // Still exactly one user/assistant pair and ONE requestCompletion: the
        // deterministic ids + dedupe guard mean "running twice == once" (§9.2).
        check(await db.messagesDao.getForChat('srv-1')).length.equals(2);
        final ops = await db.outboxDao.pendingForChat('srv-1');
        check(ops.where((o) => o.kind == 'requestCompletion').length).equals(1);
      },
    );
  });

  group('String-form queue (Finding 5: data loss)', () {
    test('JSON-String-encoded queue is parsed, not dropped', () async {
      // A build that persisted the queue as a JSON-encoded String (as
      // task_queue._load tolerates). The migrator MUST decode + convert it,
      // not silently treat it as empty and discard every queued send.
      final encoded = jsonEncode([
        sendTextTask(id: 't1', text: 'queued via string'),
      ]);
      await caches.put('outbound_task_queue_v1', encoded);

      final report = await migrator().migrateIfNeeded();
      check(report.converted).equals(1);
      check((await db.select(db.chats).get()).length).equals(1);
      check(caches.get('outbound_task_queue_v1')).isNull();
    });

    test('unparseable String does NOT set the flag (awaits repair)', () async {
      await caches.put('outbound_task_queue_v1', 'not json {{{');
      final report = await migrator().migrateIfNeeded();
      check(report.converted).equals(0);
      check(report.alreadyMigrated).isFalse();
      // Flag NOT set and key NOT deleted: a future startup can retry.
      check(
        await db.syncMetaDao.getValue(OutboxTaskQueueMigrator.migratedFlagKey),
      ).isNull();
      check(caches.get('outbound_task_queue_v1')).isNotNull();
    });
  });
}

Map<String, dynamic> _decode(String raw) {
  if (raw.isEmpty) return <String, dynamic>{};
  return Map<String, dynamic>.from(jsonDecode(raw) as Map);
}
