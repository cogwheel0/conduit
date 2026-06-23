import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/daos/outbox_dao.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/sync/backoff.dart';
import 'package:conduit/core/sync/chat_locks.dart';
import 'package:conduit/core/sync/clock.dart';
import 'package:conduit/core/sync/id_remapper.dart';
import 'package:conduit/core/sync/chat_adapter.dart';
import 'package:conduit/core/sync/note_adapter.dart';
import 'package:conduit/core/sync/note_sync.dart';
import 'package:conduit/core/sync/outbox_drainer.dart';
import 'package:conduit/core/sync/pull_sync.dart';
import 'package:conduit/core/sync/push_sync.dart';
import 'package:conduit/core/sync/sync_api_client.dart';
import 'package:conduit/core/sync/sync_entity_adapter.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_open_webui_server.dart';

/// Mutable epoch-seconds clock for deterministic backoff scheduling.
class FakeSyncClock implements SyncClock {
  FakeSyncClock(this.now);
  int now;
  @override
  int nowEpochSeconds() => now;
}

/// Recording [SyncApiClient] over [FakeOpenWebUiServer] exercising only the
/// write surface the drainer drives through [PushSync]. Pull reads throw —
/// the drainer never pulls.
class RecordingSyncApiClient implements SyncApiClient {
  RecordingSyncApiClient(this.server);
  final FakeOpenWebUiServer server;

  final List<String> calls = <String>[];
  final List<String> events = <String>[];

  /// chatIds whose next write throws the given error (transient unless a
  /// [SyncTerminalException]). Consumed once per failure scheduled.
  final Map<String, List<Object>> failuresByChat = <String, List<Object>>{};

  /// Records the wall-order in which createChat/updateChat/deleteChat STARTED
  /// (id as passed), to assert per-chat FIFO + pool interleave.
  final List<String> writeStarts = <String>[];
  int _active = 0;
  int maxConcurrent = 0;

  Object? _nextFailure(String chatId) {
    final list = failuresByChat[chatId];
    if (list == null || list.isEmpty) return null;
    return list.removeAt(0);
  }

  Future<T> _track<T>(String chatId, Future<T> Function() body) async {
    writeStarts.add(chatId);
    _active++;
    maxConcurrent = _active > maxConcurrent ? _active : maxConcurrent;
    try {
      await Future<void>.delayed(Duration.zero);
      final failure = _nextFailure(chatId);
      if (failure != null) throw failure;
      return await body();
    } finally {
      _active--;
    }
  }

  @override
  Future<Map<String, dynamic>> createChat(
    Map<String, dynamic> chatBlob, {
    String? folderId,
  }) {
    calls.add('createChat');
    final localId = chatBlob['__localId'] as String? ?? 'create';
    events.add('createChat:$localId');
    return _track(
      localId,
      () async => server.createChat(chatBlob, folderId: folderId),
    );
  }

  @override
  Future<Map<String, dynamic>?> updateChat(
    String id,
    Map<String, dynamic> fullBlob,
  ) {
    calls.add('updateChat:$id');
    events.add('updateChat:$id');
    return _track(id, () async => server.updateChat(id, fullBlob));
  }

  @override
  Future<bool> deleteChat(String id) {
    calls.add('deleteChat:$id');
    events.add('deleteChat:$id');
    return _track(id, () async => server.deleteChat(id));
  }

  @override
  Future<bool> getChatPinned(String id) async => false;
  @override
  Future<Map<String, dynamic>?> togglePin(String id) async => null;
  // Note write surface: the chat-op drainer tests never drive note kinds, so
  // these are unreachable here.
  @override
  Future<(List<Map<String, dynamic>>, bool)> getNoteListRaw({int? page}) =>
      throw UnsupportedError('notes not exercised by chat-op drainer tests');
  @override
  Future<Map<String, dynamic>?> getNoteRaw(String id) =>
      throw UnsupportedError('notes');
  @override
  Future<Map<String, dynamic>> createNote({
    required String title,
    required Map<String, dynamic> data,
    Map<String, dynamic>? meta,
  }) => throw UnsupportedError('notes');
  @override
  Future<Map<String, dynamic>?> updateNote(
    String id,
    Map<String, dynamic> patch,
  ) => throw UnsupportedError('notes');
  @override
  Future<bool> deleteNote(String id) => throw UnsupportedError('notes');
  @override
  Future<Map<String, dynamic>?> togglePinNote(String id) =>
      throw UnsupportedError('notes');
  @override
  Future<Map<String, dynamic>?> toggleArchive(String id) async => null;
  @override
  Future<Map<String, dynamic>?> moveChatToFolder(String id, String? f) async =>
      null;

  // ---- unused pull / folder surface ----
  @override
  Future<List<Map<String, dynamic>>> getChatListPage(int page) async =>
      throw UnimplementedError();
  @override
  Future<List<Map<String, dynamic>>> getArchivedChatListPage(int page) async =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>?> getChatRaw(String id) async =>
      throw UnimplementedError();
  @override
  Future<bool> probeChatExists(String id) async => throw UnimplementedError();
  @override
  Future<(List<Map<String, dynamic>>, bool)> getFoldersRaw() async =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> createFolder({
    required String name,
    String? parentId,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
  }) async {
    calls.add('createFolder');
    events.add('createFolder:$name');
    await Future<void>.delayed(Duration.zero);
    return server.createFolder(
      name: name,
      parentId: parentId,
      data: data,
      meta: meta,
    );
  }

  @override
  Future<Map<String, dynamic>?> updateFolder(
    String id, {
    String? name,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
  }) async {
    calls.add('updateFolder:$id');
    events.add('updateFolder:$id');
    await Future<void>.delayed(Duration.zero);
    final exists = server.getFolders().any((folder) => folder['id'] == id);
    if (!exists) return null;
    server.updateFolder(id, name: name, data: data, meta: meta);
    return server.getFolders().firstWhere((folder) => folder['id'] == id);
  }

  @override
  Future<bool> updateFolderParent(String id, String? parentId) async {
    calls.add('updateFolderParent:$id');
    events.add('updateFolderParent:$id');
    await Future<void>.delayed(Duration.zero);
    final exists = server.getFolders().any((folder) => folder['id'] == id);
    if (!exists) return false;
    server.updateFolderParent(id, parentId);
    return true;
  }

  @override
  Future<bool> deleteFolder(String id, {bool deleteContents = false}) async {
    calls.add('deleteFolder:$id');
    events.add('deleteFolder:$id');
    await Future<void>.delayed(Duration.zero);
    return server.deleteFolder(id, deleteContents: deleteContents);
  }
}

/// Programmable completion seam: counts runs per chat and can fail a fixed
/// number of times.
class FakeCompletionRunner implements RequestCompletionRunner {
  int runs = 0;
  final List<String> ranChats = <String>[];
  List<String>? events;

  /// Number of times [run] should throw before succeeding (per the whole
  /// runner, not per chat — tests use a single completion op).
  int failuresRemaining = 0;
  Object error = StateError('completion boom');

  @override
  Future<void> run({
    required String chatId,
    required Map<String, dynamic> payload,
  }) async {
    runs++;
    ranChats.add(chatId);
    events?.add('completion:$chatId');
    await Future<void>.delayed(Duration.zero);
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw error;
    }
  }
}

void main() {
  late AppDatabase db;
  late OutboxDao dao;
  late FakeOpenWebUiServer server;
  late RecordingSyncApiClient client;
  late ConversationLocks chatLocks;
  late FolderLocks folderLocks;
  late NoteLocks noteLocks;
  late IdRemapper remapper;
  late PushSync push;
  late FakeSyncClock clock;
  late FakeCompletionRunner completion;
  var online = true;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    dao = db.outboxDao;
    server = FakeOpenWebUiServer();
    client = RecordingSyncApiClient(server);
    chatLocks = ConversationLocks();
    folderLocks = FolderLocks();
    noteLocks = NoteLocks();
    clock = FakeSyncClock(1000);
    remapper = IdRemapper(db);
    push = PushSync(
      client: client,
      db: db,
      chatLocks: chatLocks,
      folderLocks: folderLocks,
      clock: clock,
      remapper: remapper,
    );
    completion = FakeCompletionRunner();
    completion.events = client.events;
    online = true;
  });

  tearDown(() async {
    await remapper.dispose();
    await db.close();
  });

  OutboxDrainer buildDrainer({
    Backoff? backoff,
    TerminalErrorClassifier? terminal,
    List<SyncEntityAdapter>? adapters,
  }) {
    return OutboxDrainer(
      db: db,
      clock: clock,
      backoff: backoff ?? Backoff(jitter: () => 0.0),
      isOnline: () => online,
      completion: completion,
      terminalClassifier: terminal,
      adapters:
          adapters ??
          [
            ChatAdapter(
              pull: PullSync(
                client: client,
                db: db,
                locks: chatLocks,
                remapper: remapper,
              ),
              push: push,
            ),
            NoteAdapter(
              pull: NotePullSync(
                client: client,
                db: db,
                locks: noteLocks,
                remapper: remapper,
              ),
              push: NotePushSync(
                client: client,
                db: db,
                noteLocks: noteLocks,
                remapper: remapper,
              ),
            ),
          ],
    );
  }

  Future<void> seedServerChat(String id) async {
    await db.chatsDao.upsertServerChat(rows: _serverChatRows(id));
  }

  Future<int> enqueue({
    required OutboxKind kind,
    String? chatId,
    Map<String, dynamic> payload = const {},
    String? contentHash,
  }) {
    return db.transaction(
      () => dao.enqueue(
        kind: kind,
        chatId: chatId,
        payload: payload,
        contentHash: contentHash,
      ),
    );
  }

  group('drain dispatch', () {
    test('updateChat op pushes then is removed', () async {
      await seedServerChat('c1');
      await enqueue(kind: OutboxKind.updateChat, chatId: 'c1');

      await buildDrainer().drain();

      check(client.calls).contains('updateChat:c1');
      check(await dao.pendingForChat('c1')).isEmpty();
    });

    test('deleteChat op deletes server-side and removes the op', () async {
      await seedServerChat('c1');
      server.seedChat(
        id: 'c1',
        blob: const {'title': 'x'},
        createdAt: 1,
        updatedAt: 1,
      );
      await enqueue(kind: OutboxKind.deleteChat, chatId: 'c1');

      await buildDrainer().drain();

      check(server.getChatById('c1')).isNull();
      check(await dao.pendingForChat('c1')).isEmpty();
    });

    test(
      'malformed note op without a noteId parks instead of disappearing',
      () async {
        final seq = await enqueue(
          kind: OutboxKind.noteUpdate,
          payload: {'title': 'orphan'},
        );

        await buildDrainer().drain();

        final row = await (db.select(
          db.outboxOps,
        )..where((t) => t.seq.equals(seq))).getSingle();
        check(row.status).equals(OutboxStatus.failed);
        check(row.attempts).equals(1);
        check(row.lastError!).contains('missing noteId');
        check(client.calls).isEmpty();
      },
    );

    test(
      'kind with no owning adapter parks without being marked done',
      () async {
        await seedServerChat('c1');
        final seq = await enqueue(kind: OutboxKind.updateChat, chatId: 'c1');

        await buildDrainer(adapters: const []).drain();

        final row = await (db.select(
          db.outboxOps,
        )..where((t) => t.seq.equals(seq))).getSingle();
        check(row.status).equals(OutboxStatus.failed);
        check(row.lastError!).contains('no adapter for updateChat');
        check(client.calls).isEmpty();
      },
    );

    test(
      'folderUpsert uses remapped op chatId over stale payload folderId',
      () async {
        const localId = 'local:folder';
        const serverId = 'server-folder';
        server.seedFolderRaw({
          'id': serverId,
          'name': 'Old',
          'parent_id': null,
          'created_at': 1,
          'updated_at': 1,
        });
        await db
            .into(db.folders)
            .insert(
              FoldersCompanion.insert(
                id: serverId,
                name: 'Renamed',
                createdAt: 1,
                updatedAt: 2,
                serverUpdatedAt: const Value(1),
                dirty: const Value(true),
              ),
            );
        await enqueue(
          kind: OutboxKind.folderUpsert,
          chatId: serverId,
          payload: {
            'folderId': localId,
            'createIfAbsent': false,
            'name': 'Renamed',
          },
        );

        await buildDrainer().drain();

        check(client.calls).contains('updateFolder:$serverId');
        check(
          client.calls,
        ).not((calls) => calls.contains('updateFolder:$localId'));
        check(server.getFolders().single['name']).equals('Renamed');
        check((await db.foldersDao.getFolder(serverId))!.dirty).isFalse();
        check(await dao.pendingForChat(serverId)).isEmpty();
      },
    );

    test(
      'folderDelete uses remapped op chatId over stale payload folderId',
      () async {
        const localId = 'local:folder';
        const serverId = 'server-folder';
        server.seedFolderRaw({
          'id': serverId,
          'name': 'Delete Me',
          'parent_id': null,
          'created_at': 1,
          'updated_at': 1,
        });
        await db
            .into(db.folders)
            .insert(
              FoldersCompanion.insert(
                id: serverId,
                name: 'Delete Me',
                createdAt: 1,
                updatedAt: 2,
                serverUpdatedAt: const Value(1),
                dirty: const Value(true),
                deleted: const Value(true),
              ),
            );
        await enqueue(
          kind: OutboxKind.folderDelete,
          chatId: serverId,
          payload: {'folderId': localId},
        );

        await buildDrainer().drain();

        check(client.calls).contains('deleteFolder:$serverId');
        check(
          client.calls,
        ).not((calls) => calls.contains('deleteFolder:$localId'));
        check(server.getFolders()).isEmpty();
        check(await db.foldersDao.getFolder(serverId)).isNull();
        check(await dao.pendingForChat(serverId)).isEmpty();
      },
    );
  });

  group('per-chat FIFO + pool of 2', () {
    test('a chat\'s ops run strictly in seq order', () async {
      await seedServerChat('c1');
      await enqueue(kind: OutboxKind.updateChat, chatId: 'c1');
      await enqueue(
        kind: OutboxKind.requestCompletion,
        chatId: 'c1',
        payload: const RequestCompletionPayload(
          assistantMessageId: 'a1',
          model: 'm',
        ).toJson(),
      );

      await buildDrainer().drain();
      check(client.events).deepEquals(['updateChat:c1', 'completion:c1']);
      check(await dao.pendingForChat('c1')).isEmpty();
    });

    test('two independent chats run concurrently (pool of 2)', () async {
      await seedServerChat('cA');
      await seedServerChat('cB');
      await enqueue(kind: OutboxKind.updateChat, chatId: 'cA');
      await enqueue(kind: OutboxKind.updateChat, chatId: 'cB');

      await buildDrainer().drain();

      check(client.maxConcurrent).equals(2);
      check(await dao.pendingForChat('cA')).isEmpty();
      check(await dao.pendingForChat('cB')).isEmpty();
    });

    test('pool of 2 caps concurrency even with 3 ready chats', () async {
      await seedServerChat('c1');
      await seedServerChat('c2');
      await seedServerChat('c3');
      await enqueue(kind: OutboxKind.updateChat, chatId: 'c1');
      await enqueue(kind: OutboxKind.updateChat, chatId: 'c2');
      await enqueue(kind: OutboxKind.updateChat, chatId: 'c3');

      await buildDrainer().drain();
      // pool of 2 caps concurrency at 2 even with 3 ready chats.
      check(client.maxConcurrent).isLessOrEqual(2);
      check(client.maxConcurrent).equals(2);
    });
  });

  group('requestCompletion parking (N=5)', () {
    test('parks after exactly 5 failed attempts', () async {
      await seedServerChat('c1');
      completion.failuresRemaining = 100; // always fail
      final seq = await enqueue(
        kind: OutboxKind.requestCompletion,
        chatId: 'c1',
        payload: {
          'assistantMessageId': 'a1',
          'model': 'm',
          'toolIds': <String>[],
        },
      );
      final drainer = buildDrainer();

      // Each drain pass runs the op once (then it backs off to nextAttemptAt).
      // Advance the clock past the backoff each pass so it is re-claimable.
      for (var i = 0; i < 5; i++) {
        await drainer.drain();
        clock.now += 10000; // jump well past any backoff window
      }

      check(completion.runs).equals(5);
      // Op is parked, not pending.
      check(await dao.pendingForChat('c1')).isEmpty();
      final parked = await dao.watchParkedForChat('c1').first;
      check(parked).length.equals(1);
      check(parked.single.seq).equals(seq);
      check(parked.single.attempts).equals(5);
    });

    test(
      'a parked op is no longer claimed; requeue re-arms a fresh N=5',
      () async {
        await seedServerChat('c1');
        completion.failuresRemaining = 100;
        final seq = await enqueue(
          kind: OutboxKind.requestCompletion,
          chatId: 'c1',
          payload: {
            'assistantMessageId': 'a1',
            'model': 'm',
            'toolIds': <String>[],
          },
        );
        final drainer = buildDrainer();
        for (var i = 0; i < 5; i++) {
          await drainer.drain();
          clock.now += 10000;
        }
        check(completion.runs).equals(5);

        // Parked: another drain does nothing.
        await drainer.drain();
        check(completion.runs).equals(5);

        // Manual retry: fresh N=5 budget.
        await dao.requeueParked(seq, nowEpochSeconds: clock.now);
        for (var i = 0; i < 5; i++) {
          await drainer.drain();
          clock.now += 10000;
        }
        check(completion.runs).equals(10);
      },
    );

    test(
      'malformed requestCompletion without chatId parks immediately',
      () async {
        final seq = await db
            .into(db.outboxOps)
            .insert(
              OutboxOpsCompanion.insert(
                kind: OutboxKind.requestCompletion.name,
                payload: const Value(
                  '{"assistantMessageId":"a1","model":"m","toolIds":[]}',
                ),
              ),
            );
        final drainer = buildDrainer();

        await drainer.drain();

        check(completion.runs).equals(0);
        final row = await (db.select(
          db.outboxOps,
        )..where((t) => t.seq.equals(seq))).getSingle();
        check(row.status).equals(OutboxStatus.failed);
        check(row.attempts).equals(1);
        check(
          row.lastError!,
        ).contains('malformed requestCompletion op: missing chatId');
      },
    );
  });

  group('backoff scheduling honored', () {
    test(
      'a transient failure schedules nextAttemptAt and is skipped early',
      () async {
        await seedServerChat('c1');
        await enqueue(kind: OutboxKind.updateChat, chatId: 'c1');
        client.failuresByChat['c1'] = [StateError('transient')];
        // base 2000ms, jitter ~1.0 -> ~2s delay -> nextAttemptAt = now + 2.
        final drainer = buildDrainer(backoff: Backoff(jitter: () => 0.999999));

        await drainer.drain();
        final afterFail = await dao.pendingForChat('c1');
        check(afterFail.single.attempts).equals(1);
        check(afterFail.single.status).equals('pending');
        // delay window for attempt 0 is [0,2000) -> 1999ms -> ceil(1.999)=2s.
        check(afterFail.single.nextAttemptAt).equals(clock.now + 2);

        // Before the backoff elapses, the op is not claimed (no new write).
        final callsBefore = client.calls.length;
        await drainer.drain();
        check(client.calls.length).equals(callsBefore);

        // After the backoff window, it succeeds and is removed.
        clock.now += 2;
        await drainer.drain();
        check(await dao.pendingForChat('c1')).isEmpty();
      },
    );

    test('connectivity regained resets backoff to now and drains', () async {
      await seedServerChat('c1');
      await enqueue(kind: OutboxKind.updateChat, chatId: 'c1');
      client.failuresByChat['c1'] = [StateError('transient')];
      final drainer = buildDrainer(backoff: Backoff(jitter: () => 0.999999));

      await drainer.drain();
      check(
        (await dao.pendingForChat('c1')).single.nextAttemptAt,
      ).equals(clock.now + 2);

      // Regain connectivity WITHOUT advancing the clock: backoff is reset to
      // now so the op runs immediately and (no more failures) completes.
      await drainer.onConnectivityRegained();
      check(await dao.pendingForChat('c1')).isEmpty();
    });
  });

  group('offline handling', () {
    test('sync op offline never parks; retries with short backoff', () async {
      await seedServerChat('c1');
      online = false;
      await enqueue(kind: OutboxKind.updateChat, chatId: 'c1');
      final drainer = buildDrainer();

      await drainer.drain();
      final pending = await dao.pendingForChat('c1');
      check(pending.single.status).equals('pending');
      // Offline is a no-op, not a real send attempt: it must NOT bump attempts
      // (so it cannot burn the requestCompletion N=5 budget — §7.2, Finding 7).
      check(pending.single.attempts).equals(0);
      check(pending.single.lastError).equals('offline');
      // No server write happened.
      check(client.calls).isEmpty();

      // Back online + due: it runs.
      online = true;
      clock.now += 10;
      await drainer.drain();
      check(await dao.pendingForChat('c1')).isEmpty();
    });

    test('requestCompletion offline does NOT count toward N=5', () async {
      await seedServerChat('c1');
      online = false;
      await enqueue(
        kind: OutboxKind.requestCompletion,
        chatId: 'c1',
        payload: {
          'assistantMessageId': 'a1',
          'model': 'm',
          'toolIds': <String>[],
        },
      );
      final drainer = buildDrainer();
      for (var i = 0; i < 8; i++) {
        await drainer.drain();
        clock.now += 100;
      }
      // Never ran (offline) and never parked.
      check(completion.runs).equals(0);
      check(await dao.watchParkedForChat('c1').first).isEmpty();
      check((await dao.pendingForChat('c1')).single.status).equals('pending');
    });
  });

  group('terminal server errors', () {
    test('updateChat terminal (401) parks the op', () async {
      await seedServerChat('c1');
      await enqueue(kind: OutboxKind.updateChat, chatId: 'c1');
      client.failuresByChat['c1'] = [
        const SyncTerminalException(statusCode: 401, message: 'not owner'),
      ];
      final drainer = buildDrainer();
      await drainer.drain();
      check(await dao.pendingForChat('c1')).isEmpty();
      final parked = await dao.watchParkedForChat('c1').first;
      check(parked).length.equals(1);
      check(parked.single.kind).equals('updateChat');
    });

    test('deleteChat 404 is treated as success (markDone)', () async {
      await seedServerChat('c1');
      // No server-side chat ⇒ deleteChat returns false; PushSync treats false
      // as already-gone success, so the op completes without a terminal park.
      await enqueue(kind: OutboxKind.deleteChat, chatId: 'c1');
      final drainer = buildDrainer();
      await drainer.drain();
      check(await dao.pendingForChat('c1')).isEmpty();
      check(await dao.watchParkedForChat('c1').first).isEmpty();
    });

    test('malformed folderDelete payload parks without retrying', () async {
      final seq = await db
          .into(db.outboxOps)
          .insert(
            OutboxOpsCompanion.insert(
              kind: OutboxKind.folderDelete.name,
              payload: const Value('{}'),
            ),
          );
      final drainer = buildDrainer();

      await drainer.drain();

      final row = await (db.select(
        db.outboxOps,
      )..where((t) => t.seq.equals(seq))).getSingle();
      check(row.status).equals(OutboxStatus.failed);
      check(row.lastError!).contains('malformed folderDelete payload');
    });
  });

  group('single-flight', () {
    test('overlapping drains collapse to one queued rerun', () async {
      await seedServerChat('cA');
      await seedServerChat('cB');
      await enqueue(kind: OutboxKind.updateChat, chatId: 'cA');
      await enqueue(kind: OutboxKind.updateChat, chatId: 'cB');
      final drainer = buildDrainer();

      // Fire two drains without awaiting the first; the second must collapse.
      final f1 = drainer.drain();
      final f2 = drainer.drain();
      await Future.wait([f1, f2]);

      check(await dao.pendingForChat('cA')).isEmpty();
      check(await dao.pendingForChat('cB')).isEmpty();
    });
  });
}

/// A one-message server chat whose blob round-trips cleanly so
/// `upsertServerChat` persists it and `PushSync` can reconstruct it.
ChatRows _serverChatRows(String id) {
  return ChatBlobMapper.blobToRows(
    chatId: id,
    title: 'Chat $id',
    createdAt: 1,
    updatedAt: 1,
    blob: <String, dynamic>{
      'title': 'Chat $id',
      'history': <String, dynamic>{
        'currentId': 'm1',
        'messages': <String, dynamic>{
          'm1': <String, dynamic>{
            'id': 'm1',
            'parentId': null,
            'childrenIds': <String>[],
            'role': 'user',
            'content': 'hello $id',
            'timestamp': 1,
          },
        },
      },
    },
  );
}
