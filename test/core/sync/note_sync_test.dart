/// CDT-RFC-001 Phase 5 note sync integration (through the real Drift DB):
/// nanosecond-watermark pull, the DB-level field-LWW conflict copy (a concurrent
/// data edit yields TWO surviving notes), and transactional *WithOutbox writes.
library;

import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/daos/outbox_dao.dart';
import 'package:conduit/core/database/mappers/note_mapper.dart';
import 'package:conduit/core/sync/chat_locks.dart';
import 'package:conduit/core/sync/id_remapper.dart';
import 'package:conduit/core/sync/note_adapter.dart';
import 'package:conduit/core/sync/note_conflict.dart';
import 'package:conduit/core/sync/note_sync.dart';
import 'package:conduit/core/sync/sync_api_client.dart';
import 'package:conduit/core/sync/sync_entity_adapter.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_open_webui_server.dart';
import '../../support/fake_sync_api_client.dart';

const int kT1 = 1718000000000000000; // ns
const int kT2 = kT1 + 60 * 1000 * 1000 * 1000; // +60s in ns, past the overlap

class _MalformedFirstPageNoteClient extends FakeSyncApiClient {
  _MalformedFirstPageNoteClient(super.server);

  @override
  Future<(List<Map<String, dynamic>>, bool)> getNoteListRaw({int? page}) async {
    final (items, enabled) = await super.getNoteListRaw(page: page);
    if (page != 1 || items.length < FakeOpenWebUiServer.notePageSize) {
      return (items, enabled);
    }
    final mutated = [for (final item in items) Map<String, dynamic>.from(item)];
    mutated.first.remove('updated_at');
    return (mutated, enabled);
  }
}

class _AllMalformedFirstPageNoteClient extends FakeSyncApiClient {
  _AllMalformedFirstPageNoteClient(super.server);

  @override
  Future<(List<Map<String, dynamic>>, bool)> getNoteListRaw({int? page}) async {
    if (page == 1) {
      noteListRequests++;
      noteListPages.add(page);
      return (
        [
          for (var i = 0; i < FakeOpenWebUiServer.notePageSize; i++)
            <String, dynamic>{'id': 'malformed-$i'},
        ],
        true,
      );
    }
    return super.getNoteListRaw(page: page);
  }
}

class _BlockingCreateNoteClient extends FakeSyncApiClient {
  _BlockingCreateNoteClient(super.server);

  final createStarted = Completer<void>();
  final releaseCreate = Completer<void>();

  @override
  Future<Map<String, dynamic>> createNote({
    required String title,
    required Map<String, dynamic> data,
    Map<String, dynamic>? meta,
  }) async {
    createStarted.complete();
    await releaseCreate.future;
    return super.createNote(title: title, data: data, meta: meta);
  }
}

void main() {
  late FakeOpenWebUiServer server;
  late FakeSyncApiClient client;
  late AppDatabase db;
  late NoteLocks locks;
  late IdRemapper syncRemapper;

  setUp(() {
    server = FakeOpenWebUiServer();
    client = FakeSyncApiClient(server);
    db = AppDatabase(NativeDatabase.memory());
    locks = NoteLocks();
    syncRemapper = IdRemapper(db);
  });
  tearDown(() async {
    await syncRemapper.dispose();
    await db.close();
  });

  /// Drives the LIVE production note-pull path: the generic [runPullFor] driver
  /// over a [NoteAdapter] — exactly what the sync engine wires (D-11, R-09).
  Future<AdapterPullResult> pull() {
    final adapter = NoteAdapter(
      pull: NotePullSync(
        client: client,
        db: db,
        locks: locks,
        remapper: syncRemapper,
      ),
      push: NotePushSync(
        client: client,
        db: db,
        noteLocks: locks,
        remapper: syncRemapper,
      ),
    );
    return runPullFor(adapter, db: db);
  }

  Future<List<NoteRow>> allNotes() => db.select(db.notes).get();

  test('pull populates the DB and advances the NANOSECOND watermark', () async {
    server.seedNote(
      id: 'n1',
      title: 'First',
      data: {
        'content': {'md': 'one'},
      },
      createdAt: kT1,
      updatedAt: kT1,
    );
    server.seedNote(
      id: 'n2',
      title: 'Second',
      data: {
        'content': {'md': 'two'},
      },
      createdAt: kT1,
      updatedAt: kT2,
    );

    final result = await pull();
    check(result.success).isTrue();
    check(client.noteListRequests).equals(1);
    check(client.noteFetchStarts).unorderedEquals(['n1', 'n2']);

    final notes = await allNotes();
    check(notes.map((n) => n.id).toList()).unorderedEquals(['n1', 'n2']);

    // The watermark is the MAX server note timestamp — and it is nanosecond
    // scale (≥ 1e18), never seconds.
    final wm = await db.syncMetaDao.getNotesPullWatermark();
    check(wm).equals(kT2);
    check(wm > 1000000000000000000).isTrue();
    // The chat watermark is untouched (separate domain, R-09).
    check(await db.syncMetaDao.getPullWatermark()).equals(0);
  });

  test('pull paginates note lists past the first server page', () async {
    for (var i = 0; i < FakeOpenWebUiServer.notePageSize + 1; i++) {
      server.seedNote(
        id: 'n-${i.toString().padLeft(2, '0')}',
        title: 'Note $i',
        data: {
          'content': {'md': 'body $i'},
        },
        createdAt: kT1 + i,
        updatedAt: kT1 + i,
      );
    }

    final result = await pull();

    check(result.success).isTrue();
    check(result.changed).equals(FakeOpenWebUiServer.notePageSize + 1);
    check(client.noteListPages).deepEquals([1, 2]);
    check(await allNotes()).length.equals(FakeOpenWebUiServer.notePageSize + 1);
  });

  test(
    'malformed note list items are skipped without shortening the page',
    () async {
      client = _MalformedFirstPageNoteClient(server);
      for (var i = 0; i < FakeOpenWebUiServer.notePageSize + 1; i++) {
        server.seedNote(
          id: 'n-${i.toString().padLeft(2, '0')}',
          title: 'Note $i',
          data: {
            'content': {'md': 'body $i'},
          },
          createdAt: kT1 + i,
          updatedAt: kT1 + i,
        );
      }

      final result = await pull();

      check(result.success).isTrue();
      check(result.changed).equals(FakeOpenWebUiServer.notePageSize);
      check(client.noteListPages).deepEquals([1, 2]);
      check(
        client.noteFetchStarts,
      ).length.equals(FakeOpenWebUiServer.notePageSize);
      final notes = await allNotes();
      check(notes).length.equals(FakeOpenWebUiServer.notePageSize);
      check(notes.map((note) => note.id)).not((ids) => ids.contains('n-60'));
      check(await db.syncMetaDao.getNotesPullWatermark()).equals(kT1 + 59);
    },
  );

  test('all-skip full note list page stops without pagination loop', () async {
    client = _AllMalformedFirstPageNoteClient(server);
    for (var i = 0; i < FakeOpenWebUiServer.notePageSize + 1; i++) {
      server.seedNote(
        id: 'n-${i.toString().padLeft(2, '0')}',
        title: 'Note $i',
        data: {
          'content': {'md': 'body $i'},
        },
        createdAt: kT1 + i,
        updatedAt: kT1 + i,
      );
    }

    final result = await pull();

    check(result.success).isTrue();
    check(result.changed).equals(0);
    check(client.noteListPages).deepEquals([1]);
    check(client.noteFetchStarts).isEmpty();
    final notes = await allNotes();
    check(notes).isEmpty();
    check(await db.syncMetaDao.getNotesPullWatermark()).equals(0);
  });

  test(
    'pull full-fetches note bodies instead of trusting truncated list data',
    () async {
      final longBody = List.filled(1200, 'x').join();
      server.seedNote(
        id: 'long-note',
        title: 'Long',
        data: {
          'content': {'md': longBody},
        },
        createdAt: kT1,
        updatedAt: kT1,
      );

      final result = await pull();
      check(result.success).isTrue();
      check(client.noteListRequests).equals(1);
      check(client.noteFetchStarts).deepEquals(['long-note']);

      final row = await db.notesDao.getNote('long-note');
      check(row).isNotNull();
      final data = jsonDecode(row!.data) as Map<String, dynamic>;
      final content = data['content'] as Map<String, dynamic>;
      check(content['md']).equals(longBody);
    },
  );

  test(
    'CONFLICT COPY: a concurrent data edit yields two surviving notes',
    () async {
      // 1. Sync n1.
      server.seedNote(
        id: 'n1',
        title: 'Doc',
        data: {
          'content': {'md': 'server v1'},
        },
        createdAt: kT1,
        updatedAt: kT1,
      );
      await pull();
      check((await allNotes()).length).equals(1);

      // 2. Local data edit (marks dirtyData), while the note is offline.
      await locks.runExclusive('n1', () async {
        await db.notesDao.updateNoteWithOutbox(
          'n1',
          data: Value(
            jsonEncode({
              'content': {'md': 'my LOCAL edit'},
            }),
          ),
          localUpdatedAtNs: kT1 + 1,
          enqueue: true,
        );
      });

      // 3. The server's copy of n1 also advanced (someone else edited the body).
      server.seedNote(
        id: 'n1',
        title: 'Doc',
        data: {
          'content': {'md': 'server v2'},
        },
        createdAt: kT1,
        updatedAt: kT2,
      );

      // 4. Pull → the field-LWW merge must spawn a conflict copy (D-11).
      await pull();

      final notes = await allNotes();
      check(notes.length).equals(2); // canonical + conflict copy, none lost

      final canonical = notes.firstWhere((n) => n.id == 'n1');
      final copy = notes.firstWhere((n) => n.id != 'n1');

      // Canonical adopted the server data and is clean on the data axis.
      check(canonical.data).contains('server v2');
      check(canonical.dirtyData).isFalse();
      // The conflict copy preserved the LOCAL edit (no silent loss) and is a
      // fresh local: note that will be pushed as a new note.
      check(copy.data).contains('my LOCAL edit');
      check(copy.id.startsWith('local:')).isTrue();
    },
  );

  test('field-LWW merge does not resurrect a clean tombstone', () async {
    await db
        .into(db.notes)
        .insert(
          NotesCompanion.insert(
            id: 'n1',
            title: 'Hidden local',
            data: Value(
              jsonEncode({
                'content': {'md': 'old'},
              }),
            ),
            createdAt: kT1,
            updatedAt: kT1,
            serverUpdatedAt: const Value(kT1),
            deleted: const Value(true),
          ),
        );

    await db.notesDao.mergeServerNote(
      serverRaw: <String, dynamic>{
        'id': 'n1',
        'title': 'Visible server',
        'data': {
          'content': {'md': 'new'},
        },
        'meta': <String, dynamic>{},
        'is_pinned': false,
        'created_at': kT1,
        'updated_at': kT2,
      },
    );

    final row = await db.notesDao.getNote('n1');
    check(row).isNotNull();
    check(row!.deleted).isTrue();
    check(row.title).equals('Hidden local');
    check(row.data).contains('old');
  });

  test('field-LWW does not spawn another copy from a conflict copy', () async {
    await db
        .into(db.notes)
        .insert(
          NotesCompanion.insert(
            id: 'copy-1',
            title: 'Copy',
            data: Value(
              jsonEncode({
                'content': {'md': 'local copy edit'},
              }),
            ),
            createdAt: kT1,
            updatedAt: kT1,
            serverUpdatedAt: const Value(kT1),
            dirtyData: const Value(true),
            isConflictCopy: const Value(true),
            conflictOf: const Value('n1'),
          ),
        );

    final result = await db.notesDao.mergeServerNote(
      serverRaw: <String, dynamic>{
        'id': 'copy-1',
        'title': 'Copy server',
        'data': {
          'content': {'md': 'remote copy edit'},
        },
        'meta': <String, dynamic>{},
        'is_pinned': false,
        'created_at': kT1,
        'updated_at': kT2,
      },
    );

    check(result.mustPush).isTrue();
    final notes = await allNotes();
    check(notes).length.equals(1);
    final row = notes.single;
    check(row.id).equals('copy-1');
    check(row.isConflictCopy).isTrue();
    check(row.dirtyData).isTrue();
    check(row.updatedAt).equals(kT2);
    check(row.serverUpdatedAt).equals(kT2);
    check(row.data).contains('local copy edit');
    final pending = await db.outboxDao.pendingForChat('copy-1');
    check(
      pending.map((op) => op.kind),
    ).deepEquals([OutboxKind.noteUpdate.name]);
  });

  test('fast-forward preserves conflict-copy metadata', () async {
    await db
        .into(db.notes)
        .insert(
          NotesCompanion.insert(
            id: 'copy-clean',
            title: 'Copy',
            data: Value(
              jsonEncode({
                'content': {'md': 'clean copy'},
              }),
            ),
            createdAt: kT1,
            updatedAt: kT1,
            serverUpdatedAt: const Value(kT1),
            isConflictCopy: const Value(true),
            conflictOf: const Value('n1'),
          ),
        );

    final result = await db.notesDao.mergeServerNote(
      serverRaw: <String, dynamic>{
        'id': 'copy-clean',
        'title': 'Copy echoed',
        'data': {
          'content': {'md': 'server echo'},
        },
        'meta': <String, dynamic>{},
        'is_pinned': false,
        'created_at': kT1,
        'updated_at': kT2,
      },
    );

    check(result.kind).equals(NoteMergeKind.fastForward);
    final row = await db.notesDao.getNote('copy-clean');
    check(row).isNotNull();
    check(row!.isConflictCopy).isTrue();
    check(row.conflictOf).equals('n1');
    check(row.title).equals('Copy echoed');
    check(row.data).contains('server echo');
  });

  test(
    'field-LWW does not enqueue duplicate update behind in-flight update',
    () async {
      const noteId = 'copy-inflight';
      await db
          .into(db.notes)
          .insert(
            NotesCompanion.insert(
              id: noteId,
              title: 'Copy',
              data: Value(
                jsonEncode({
                  'content': {'md': 'local copy edit'},
                }),
              ),
              createdAt: kT1,
              updatedAt: kT1,
              serverUpdatedAt: const Value(kT1),
              dirtyData: const Value(true),
              isConflictCopy: const Value(true),
              conflictOf: const Value('n1'),
            ),
          );
      await db.transaction(() {
        return db.outboxDao.enqueue(
          kind: OutboxKind.noteUpdate,
          chatId: noteId,
          payload: const {'title': 'Copy'},
        );
      });
      final claimed = await db.outboxDao.claimNextRunnable(
        nowEpochSeconds: 100,
        busyChatIds: const {},
      );
      check(claimed).isNotNull();
      check(claimed!.kind).equals(OutboxKind.noteUpdate.name);
      check(claimed.status).equals(OutboxStatus.inFlight);

      final result = await db.notesDao.mergeServerNote(
        serverRaw: <String, dynamic>{
          'id': noteId,
          'title': 'Copy server',
          'data': {
            'content': {'md': 'remote copy edit'},
          },
          'meta': <String, dynamic>{},
          'is_pinned': false,
          'created_at': kT1,
          'updated_at': kT2,
        },
      );

      check(result.mustPush).isTrue();
      check(await db.outboxDao.pendingForChat(noteId)).isEmpty();
      final active = await db.outboxDao.activeForChat(noteId);
      check(active).length.equals(1);
      check(active.single.status).equals(OutboxStatus.inFlight);
    },
  );

  test(
    'tombstoneWithOutbox drops a local note when create/delete annihilate',
    () async {
      const localId = 'local:drop-note';

      await locks.runExclusive(localId, () async {
        await db.notesDao.insertLocalNoteWithCreateOp(
          note: NotesCompanion.insert(
            id: localId,
            title: 'Draft',
            data: Value(
              jsonEncode({
                'content': {'md': 'draft'},
              }),
            ),
            createdAt: kT1,
            updatedAt: kT1,
          ),
        );
        check(await db.notesDao.getNote(localId)).isNotNull();
        check(
          (await db.outboxDao.pendingForChat(localId)).map((op) => op.kind),
        ).deepEquals(['noteCreate']);
        await db.notesDao.tombstoneWithOutbox(localId);
      });

      check(await db.notesDao.getNote(localId)).isNull();
      check(await db.outboxDao.pendingForChat(localId)).isEmpty();
    },
  );

  test('dropLocalNote removes local note remap metadata', () async {
    const localId = 'local:drop-remap';
    await db
        .into(db.notes)
        .insert(
          NotesCompanion.insert(
            id: localId,
            title: 'Draft',
            data: Value(
              jsonEncode({
                'content': {'md': 'draft'},
              }),
            ),
            createdAt: kT1,
            updatedAt: kT1,
          ),
        );
    await db.syncMetaDao.setNoteRemapTarget(localId, 'server-drop-remap');

    await db.notesDao.dropLocalNote(localId);

    check(await db.syncMetaDao.getNoteRemapTarget(localId)).isNull();
  });

  test('tombstoneWithOutbox clears dirty axes on tombstoned rows', () async {
    server.seedNote(
      id: 'n-delete',
      title: 'Server note',
      data: {
        'content': {'md': 'body'},
      },
      createdAt: kT1,
      updatedAt: kT1,
    );
    await pull();

    await locks.runExclusive('n-delete', () {
      return db.notesDao.tombstoneWithOutbox('n-delete');
    });

    final row = await db.notesDao.getNote('n-delete');
    check(row).isNotNull();
    check(row!.deleted).isTrue();
    check(row.dirtyTitle).isFalse();
    check(row.dirtyData).isFalse();
    check(row.dirtyPinned).isFalse();

    final pending = await db.outboxDao.pendingForChat('n-delete');
    check(
      pending.map((op) => op.kind),
    ).deepEquals([OutboxKind.noteDelete.name]);
  });

  test(
    'pushNoteDelete purges parked outbox ops for the deleted note',
    () async {
      server.seedNote(
        id: 'n-delete-parked',
        title: 'Server note',
        data: {
          'content': {'md': 'body'},
        },
        createdAt: kT1,
        updatedAt: kT1,
      );
      await pull();
      await db
          .into(db.outboxOps)
          .insert(
            OutboxOpsCompanion.insert(
              kind: OutboxKind.noteUpdate.name,
              chatId: const Value('n-delete-parked'),
              status: const Value(OutboxStatus.failed),
              attempts: const Value(5),
              lastError: const Value('parked update'),
            ),
          );
      final push = NotePushSync(
        client: client,
        db: db,
        noteLocks: locks,
        remapper: syncRemapper,
      );

      await push.pushNoteDelete('n-delete-parked');

      check(await db.notesDao.getNote('n-delete-parked')).isNull();
      final remaining = await (db.select(
        db.outboxOps,
      )..where((t) => t.chatId.equals('n-delete-parked'))).get();
      check(remaining).isEmpty();
    },
  );

  test('purgeReconciledNote removes server note remap metadata', () async {
    const localId = 'local:purge-remap';
    const serverId = 'server-purge-remap';
    await db
        .into(db.notes)
        .insert(
          NotesCompanion.insert(
            id: serverId,
            title: 'Server note',
            data: Value(
              jsonEncode({
                'content': {'md': 'body'},
              }),
            ),
            createdAt: kT1,
            updatedAt: kT1,
          ),
        );
    await db.syncMetaDao.setNoteRemapTarget(localId, serverId);

    await db.notesDao.purgeReconciledNote(serverId);

    check(await db.syncMetaDao.getNoteRemapTarget(localId)).isNull();
  });

  test('resolveNoteRemapTarget follows a local→server id remap', () async {
    const localId = 'local:read-remap';
    const serverId = 'server-read-remap';
    await db
        .into(db.notes)
        .insert(
          NotesCompanion.insert(
            id: serverId,
            title: 'Server note',
            data: Value(
              jsonEncode({
                'content': {'md': 'body'},
              }),
            ),
            createdAt: kT1,
            updatedAt: kT1,
          ),
        );
    await db.syncMetaDao.setNoteRemapTarget(localId, serverId);

    // The stale local id resolves to the server id it was remapped to, so a UI
    // mutation locks/writes/reads on the row the DAO actually mutates (and a
    // server id with no remap resolves to itself).
    check(await db.notesDao.resolveNoteRemapTarget(localId)).equals(serverId);
    check(await db.notesDao.resolveNoteRemapTarget(serverId)).equals(serverId);
    check(await db.notesDao.getNote(localId)).isNull();
  });

  test(
    'pull crash-heals a pending noteCreate with a matching server note',
    () async {
      const localId = 'local:n-crash';
      const serverId = 'server-n-crash';

      await locks.runExclusive(localId, () async {
        await db.notesDao.insertLocalNoteWithCreateOp(
          note: NotesCompanion.insert(
            id: localId,
            title: 'Draft',
            data: Value(
              jsonEncode({
                'content': {'md': 'body'},
              }),
            ),
            createdAt: kT1,
            updatedAt: kT1,
          ),
        );
      });

      final localOps = await db.outboxDao.pendingForChat(localId);
      check(localOps).length.equals(1);
      check(localOps.single.kind).equals(OutboxKind.noteCreate.name);
      check(localOps.single.contentHash).isNotNull();

      server.seedNote(
        id: serverId,
        title: 'Draft',
        data: {
          'content': {'md': 'body'},
        },
        createdAt: kT1,
        updatedAt: kT2,
      );

      final result = await pull();

      check(result.success).isTrue();
      check(await db.notesDao.getNote(localId)).isNull();
      final healed = await db.notesDao.getNote(serverId);
      check(healed).isNotNull();
      check(healed!.title).equals('Draft');
      check(healed.dirtyTitle).isFalse();
      check(healed.dirtyData).isFalse();
      check(healed.serverUpdatedAt).equals(kT2);
      check(await db.outboxDao.pendingForChat(localId)).isEmpty();
      check(await db.outboxDao.pendingForChat(serverId)).isEmpty();
      check(client.createNoteCalls).equals(0);
    },
  );

  test(
    'noteUpdate coalesced into noteCreate refreshes the create hash',
    () async {
      const localId = 'local:n-hash';

      await locks.runExclusive(localId, () async {
        await db.notesDao.insertLocalNoteWithCreateOp(
          note: NotesCompanion.insert(
            id: localId,
            title: 'Draft',
            data: Value(
              jsonEncode({
                'content': {'md': 'before'},
              }),
            ),
            createdAt: kT1,
            updatedAt: kT1,
          ),
        );
      });
      final originalHash = (await db.outboxDao.pendingForChat(
        localId,
      )).single.contentHash;

      await locks.runExclusive(localId, () async {
        await db.notesDao.updateNoteWithOutbox(
          localId,
          title: const Value('Edited'),
          data: Value(
            jsonEncode({
              'content': {'md': 'after'},
            }),
          ),
          localUpdatedAtNs: kT1 + 1,
          enqueue: true,
        );
      });

      final pending = await db.outboxDao.pendingForChat(localId);
      check(pending).length.equals(1);
      check(pending.single.kind).equals(OutboxKind.noteCreate.name);
      final row = await db.notesDao.getNote(localId);
      final expected = noteCreateContentHashFromRow(row!);
      check(pending.single.contentHash).equals(expected);
      check(pending.single.contentHash == originalHash).isFalse();
    },
  );

  test('pushNotePin PROBES live state and toggles only on a real delta '
      '(no blind toggle-first flip)', () async {
    // Note exists locally + on the server; server pin = false.
    server.seedNote(
      id: 'p1',
      title: 'P',
      data: {
        'content': {'md': 'x'},
      },
      createdAt: kT1,
      updatedAt: kT1,
      pinned: false,
    );
    await db.notesDao.mergeServerNote(
      serverRaw: <String, dynamic>{
        'id': 'p1',
        'title': 'P',
        'data': {
          'content': {'md': 'x'},
        },
        'meta': <String, dynamic>{},
        'is_pinned': false,
        'created_at': kT1,
        'updated_at': kT1,
      },
    );
    final remapper = IdRemapper(db);
    addTearDown(remapper.dispose);
    final push = NotePushSync(
      client: client,
      db: db,
      noteLocks: locks,
      remapper: remapper,
    );

    // desired == live (false) → NO toggle (the old toggle-first code would have
    // flipped the server and flipped back, leaving a transient wrong state).
    await push.pushNotePin('p1', desired: false);
    check(client.togglePinNoteCalls).equals(0);

    // desired != live → exactly one toggle.
    await push.pushNotePin('p1', desired: true);
    check(client.togglePinNoteCalls).equals(1);
  });

  test('NoteAdapter rejects malformed notePin payloads', () async {
    final adapter = NoteAdapter(
      pull: NotePullSync(
        client: client,
        db: db,
        locks: locks,
        remapper: syncRemapper,
      ),
      push: NotePushSync(
        client: client,
        db: db,
        noteLocks: locks,
        remapper: syncRemapper,
      ),
    );
    await db
        .into(db.outboxOps)
        .insert(
          OutboxOpsCompanion.insert(
            kind: OutboxKind.notePin.name,
            chatId: const Value('p-bad'),
            payload: const Value('{}'),
          ),
        );
    final op = (await db.outboxDao.pendingForChat('p-bad')).single;

    await check(adapter.pushOp(op)).throws<SyncTerminalException>();
    check(client.togglePinNoteCalls).equals(0);
  });

  test(
    'pushNotePin stores live state when post-toggle confirmation mismatches',
    () async {
      server.seedNote(
        id: 'p2',
        title: 'P',
        data: {
          'content': {'md': 'x'},
        },
        createdAt: kT1,
        updatedAt: kT1,
        pinned: false,
      );
      await db.notesDao.mergeServerNote(
        serverRaw: <String, dynamic>{
          'id': 'p2',
          'title': 'P',
          'data': {
            'content': {'md': 'x'},
          },
          'meta': <String, dynamic>{},
          'is_pinned': false,
          'created_at': kT1,
          'updated_at': kT1,
        },
      );
      await locks.runExclusive('p2', () {
        return db.notesDao.pinNoteWithOutbox('p2', desiredPinned: true);
      });
      client = _ConcurrentPinFlipClient(server);
      final push = NotePushSync(
        client: client,
        db: db,
        noteLocks: locks,
        remapper: syncRemapper,
      );

      await push.pushNotePin('p2', desired: true);

      check(client.togglePinNoteCalls).equals(1);
      check(server.getNoteById('p2')!['is_pinned']).equals(false);
      final row = await db.notesDao.getNote('p2');
      check(row!.isPinned).isFalse();
      check(row.dirtyPinned).isFalse();
    },
  );

  test(
    'pushNotePin clears dirtyPinned when post-toggle confirmation 404s',
    () async {
      server.seedNote(
        id: 'p-confirm-404',
        title: 'P',
        data: {
          'content': {'md': 'x'},
        },
        createdAt: kT1,
        updatedAt: kT1,
        pinned: false,
      );
      await db.notesDao.mergeServerNote(
        serverRaw: <String, dynamic>{
          'id': 'p-confirm-404',
          'title': 'P',
          'data': {
            'content': {'md': 'x'},
          },
          'meta': <String, dynamic>{},
          'is_pinned': false,
          'created_at': kT1,
          'updated_at': kT1,
        },
      );
      await locks.runExclusive('p-confirm-404', () {
        return db.notesDao.pinNoteWithOutbox(
          'p-confirm-404',
          desiredPinned: true,
        );
      });

      client = _PinConfirmation404Client(server);
      final push = NotePushSync(
        client: client,
        db: db,
        noteLocks: locks,
        remapper: syncRemapper,
      );

      await push.pushNotePin('p-confirm-404', desired: true);

      check(client.togglePinNoteCalls).equals(1);
      final row = await db.notesDao.getNote('p-confirm-404');
      check(row!.dirtyPinned).isFalse();
      check(server.getNoteById('p-confirm-404')!['is_pinned']).equals(true);
    },
  );

  test('pin coalescing keeps the newest desired payload', () async {
    server.seedNote(
      id: 'p3',
      title: 'P',
      data: {
        'content': {'md': 'x'},
      },
      createdAt: kT1,
      updatedAt: kT1,
      pinned: false,
    );
    await pull();

    await locks.runExclusive('p3', () async {
      await db.notesDao.pinNoteWithOutbox('p3', desiredPinned: true);
      await db.notesDao.pinNoteWithOutbox('p3', desiredPinned: false);
    });

    final pending = await db.outboxDao.pendingForChat('p3');
    check(pending).length.equals(1);
    check(pending.single.kind).equals(OutboxKind.notePin.name);
    final payload = jsonDecode(pending.single.payload) as Map<String, dynamic>;
    check(payload['desired']).equals(false);

    final push = NotePushSync(
      client: client,
      db: db,
      noteLocks: locks,
      remapper: syncRemapper,
    );
    await push.pushNotePin('p3', desired: payload['desired'] == true);

    check(client.togglePinNoteCalls).equals(0);
    check(server.getNoteById('p3')!['is_pinned']).equals(false);
    final row = await db.notesDao.getNote('p3');
    check(row!.dirtyPinned).isFalse();
  });

  test('pushNoteCreate remaps while the local-id lock is still held', () async {
    final recordingLocks = _RecordingNoteLocks();
    final remapper = IdRemapper(db);
    addTearDown(remapper.dispose);
    final push = NotePushSync(
      client: client,
      db: db,
      noteLocks: recordingLocks,
      remapper: remapper,
    );
    const localId = 'local:n-create';
    await db
        .into(db.notes)
        .insert(
          NotesCompanion.insert(
            id: localId,
            title: 'Draft',
            data: Value(
              jsonEncode({
                'content': {'md': 'body'},
              }),
            ),
            createdAt: kT1,
            updatedAt: kT1,
            dirtyTitle: const Value(true),
            dirtyData: const Value(true),
          ),
        );

    final serverId = await push.pushNoteCreate(localId);

    check(serverId).isNotNull();
    check(await db.notesDao.getNote(localId)).isNull();
    check(await db.notesDao.getNote(serverId!)).isNotNull();
    check(
      recordingLocks.activeSnapshots.any(
        (keys) => keys.contains(localId) && keys.contains(serverId),
      ),
    ).isTrue();
  });

  test(
    'pushNoteCreate preserves edits queued behind the local remap',
    () async {
      final blockingClient = _BlockingCreateNoteClient(server);
      final remapper = IdRemapper(db);
      addTearDown(remapper.dispose);
      final push = NotePushSync(
        client: blockingClient,
        db: db,
        noteLocks: locks,
        remapper: remapper,
      );
      const localId = 'local:n-create-edit-race';
      await db.notesDao.insertLocalNoteWithCreateOp(
        note: NotesCompanion.insert(
          id: localId,
          title: 'Draft',
          data: Value(
            jsonEncode({
              'content': {'md': 'body'},
            }),
          ),
          createdAt: kT1,
          updatedAt: kT1,
        ),
      );
      final claimed = await db.outboxDao.claimNextRunnable(
        nowEpochSeconds: 1,
        busyChatIds: <String>{},
      );
      check(claimed!.kind).equals(OutboxKind.noteCreate.name);

      final pushFuture = push.pushNoteCreate(localId);
      await blockingClient.createStarted.future;
      final editFuture = locks.runExclusive(localId, () {
        return db.notesDao.updateNoteWithOutbox(
          localId,
          title: const Value('Edited while create was in flight'),
          localUpdatedAtNs: kT2,
          enqueue: true,
        );
      });

      blockingClient.releaseCreate.complete();
      final serverId = await pushFuture;
      await editFuture;

      check(serverId).isNotNull();
      check(await db.syncMetaDao.getNoteRemapTarget(localId)).equals(serverId);
      check(await db.notesDao.getNote(localId)).isNull();
      final row = await db.notesDao.getNote(serverId!);
      check(row!.title).equals('Edited while create was in flight');
      check(row.dirtyTitle).isTrue();

      final pending = await db.outboxDao.pendingForChat(serverId);
      check(
        pending.map((op) => op.kind).toList(),
      ).deepEquals([OutboxKind.noteUpdate.name]);
    },
  );

  test('pushNoteCreate skips a tombstoned local note', () async {
    final remapper = IdRemapper(db);
    addTearDown(remapper.dispose);
    final push = NotePushSync(
      client: client,
      db: db,
      noteLocks: locks,
      remapper: remapper,
    );
    const localId = 'local:n-deleted';
    await db
        .into(db.notes)
        .insert(
          NotesCompanion.insert(
            id: localId,
            title: 'Deleted draft',
            data: Value(
              jsonEncode({
                'content': {'md': 'body'},
              }),
            ),
            createdAt: kT1,
            updatedAt: kT1,
            dirtyTitle: const Value(true),
            dirtyData: const Value(true),
            deleted: const Value(true),
          ),
        );

    final serverId = await push.pushNoteCreate(localId);

    check(serverId).isNull();
    check(client.createNoteCalls).equals(0);
    check(await db.notesDao.getNote(localId)).isNotNull();
  });

  test('pull does not enqueue noteUpdate for pin-only dirty notes', () async {
    server.seedNote(
      id: 'p1',
      title: 'Pinned',
      data: {
        'content': {'md': 'server v1'},
      },
      createdAt: kT1,
      updatedAt: kT1,
      pinned: false,
    );
    await pull();

    await locks.runExclusive('p1', () async {
      await db.notesDao.pinNoteWithOutbox('p1', desiredPinned: true);
    });

    server.seedNote(
      id: 'p1',
      title: 'Server rename',
      data: {
        'content': {'md': 'server v2'},
      },
      createdAt: kT1,
      updatedAt: kT2,
      pinned: false,
    );
    await pull();

    final row = await db.notesDao.getNote('p1');
    check(row).isNotNull();
    check(row!.title).equals('Server rename');
    check(row.dirtyTitle).isFalse();
    check(row.dirtyData).isFalse();
    check(row.dirtyPinned).isTrue();

    final pending = await db.outboxDao.pendingForChat('p1');
    check(
      pending.map((op) => op.kind).toList(),
    ).unorderedEquals([OutboxKind.notePin.name]);
  });

  test(
    'updateNoteWithOutbox writes the row AND a noteUpdate op in one tx',
    () async {
      server.seedNote(
        id: 'n1',
        title: 'Doc',
        data: {
          'content': {'md': 'v1'},
        },
        createdAt: kT1,
        updatedAt: kT1,
      );
      await pull();

      await locks.runExclusive('n1', () async {
        await db.notesDao.updateNoteWithOutbox(
          'n1',
          title: const Value('Renamed'),
          localUpdatedAtNs: kT1 + 1,
          enqueue: true,
        );
      });

      final row = await db.notesDao.getNote('n1');
      check(row!.title).equals('Renamed');
      check(row.dirtyTitle).isTrue();

      final ops = await db.outboxDao.pendingForChat('n1');
      check(
        ops.map((o) => o.kind).toList(),
      ).contains(OutboxKind.noteUpdate.name);
      // The patch always carries title (vendored NoteForm requires it).
      final payload = jsonDecode(ops.first.payload) as Map<String, dynamic>;
      check(payload['title']).equals('Renamed');
    },
  );
}

class _RecordingNoteLocks extends NoteLocks {
  final List<Set<String>> activeSnapshots = <Set<String>>[];
  final Set<String> _active = <String>{};

  @override
  Future<T> runExclusive<T>(String chatId, Future<T> Function() action) {
    return super.runExclusive(chatId, () async {
      _active.add(chatId);
      activeSnapshots.add(Set<String>.of(_active));
      try {
        return await action();
      } finally {
        _active.remove(chatId);
      }
    });
  }
}

class _ConcurrentPinFlipClient extends FakeSyncApiClient {
  _ConcurrentPinFlipClient(super.server);

  @override
  Future<Map<String, dynamic>?> togglePinNote(String id) async {
    final response = await super.togglePinNote(id);
    if (response != null) {
      server.togglePinNote(id);
    }
    return response;
  }
}

class _PinConfirmation404Client extends FakeSyncApiClient {
  _PinConfirmation404Client(super.server);

  int getNoteCalls = 0;

  @override
  Future<Map<String, dynamic>?> getNoteRaw(String id) async {
    getNoteCalls++;
    if (getNoteCalls > 1) return null;
    return super.getNoteRaw(id);
  }
}
