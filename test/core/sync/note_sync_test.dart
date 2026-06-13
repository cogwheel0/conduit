/// CDT-RFC-001 Phase 5 note sync integration (through the real Drift DB):
/// nanosecond-watermark pull, the DB-level field-LWW conflict copy (a concurrent
/// data edit yields TWO surviving notes), and transactional *WithOutbox writes.
library;

import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/daos/outbox_dao.dart';
import 'package:conduit/core/sync/chat_locks.dart';
import 'package:conduit/core/sync/id_remapper.dart';
import 'package:conduit/core/sync/note_adapter.dart';
import 'package:conduit/core/sync/note_sync.dart';
import 'package:conduit/core/sync/sync_entity_adapter.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_open_webui_server.dart';
import '../../support/fake_sync_api_client.dart';

const int kT1 = 1718000000000000000; // ns
const int kT2 = kT1 + 60 * 1000 * 1000 * 1000; // +60s in ns, past the overlap

void main() {
  late FakeOpenWebUiServer server;
  late FakeSyncApiClient client;
  late AppDatabase db;
  late ChatLocks locks;

  setUp(() {
    server = FakeOpenWebUiServer();
    client = FakeSyncApiClient(server);
    db = AppDatabase(NativeDatabase.memory());
    locks = ChatLocks();
  });
  tearDown(() => db.close());

  /// Drives the LIVE production note-pull path: the generic [runPullFor] driver
  /// over a [NoteAdapter] — exactly what the sync engine wires (D-11, R-09).
  Future<AdapterPullResult> pull() {
    final remapper = IdRemapper(db);
    final adapter = NoteAdapter(
      pull: NotePullSync(client: client, db: db, locks: locks),
      push: NotePushSync(
        client: client,
        db: db,
        noteLocks: locks,
        remapper: remapper,
      ),
      noteLocks: locks,
    );
    return runPullFor(adapter, db: db);
  }

  Future<List<NoteRow>> allNotes() => db.select(db.notes).get();

  test('pull populates the DB and advances the NANOSECOND watermark', () async {
    server.seedNote(
      id: 'n1',
      title: 'First',
      data: {'content': {'md': 'one'}},
      createdAt: kT1,
      updatedAt: kT1,
    );
    server.seedNote(
      id: 'n2',
      title: 'Second',
      data: {'content': {'md': 'two'}},
      createdAt: kT1,
      updatedAt: kT2,
    );

    final result = await pull();
    check(result.success).isTrue();

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

  test('CONFLICT COPY: a concurrent data edit yields two surviving notes',
      () async {
    // 1. Sync n1.
    server.seedNote(
      id: 'n1',
      title: 'Doc',
      data: {'content': {'md': 'server v1'}},
      createdAt: kT1,
      updatedAt: kT1,
    );
    await pull();
    check((await allNotes()).length).equals(1);

    // 2. Local data edit (marks dirtyData), while the note is offline.
    await locks.runExclusive('n1', () async {
      await db.notesDao.updateNoteWithOutbox(
        'n1',
        data: Value(jsonEncode({'content': {'md': 'my LOCAL edit'}})),
        localUpdatedAtNs: kT1 + 1,
        enqueue: true,
      );
    });

    // 3. The server's copy of n1 also advanced (someone else edited the body).
    server.seedNote(
      id: 'n1',
      title: 'Doc',
      data: {'content': {'md': 'server v2'}},
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
  });

  test('pushNotePin PROBES live state and toggles only on a real delta '
      '(no blind toggle-first flip)', () async {
    // Note exists locally + on the server; server pin = false.
    server.seedNote(
      id: 'p1',
      title: 'P',
      data: {'content': {'md': 'x'}},
      createdAt: kT1,
      updatedAt: kT1,
      pinned: false,
    );
    await db.notesDao.upsertServerNote(<String, dynamic>{
      'id': 'p1',
      'title': 'P',
      'data': {'content': {'md': 'x'}},
      'meta': <String, dynamic>{},
      'is_pinned': false,
      'created_at': kT1,
      'updated_at': kT1,
    });
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

  test('updateNoteWithOutbox writes the row AND a noteUpdate op in one tx',
      () async {
    server.seedNote(
      id: 'n1',
      title: 'Doc',
      data: {'content': {'md': 'v1'}},
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
    check(ops.map((o) => o.kind).toList()).contains(OutboxKind.noteUpdate.name);
    // The patch always carries title (vendored NoteForm requires it).
    final payload =
        jsonDecode(ops.first.payload) as Map<String, dynamic>;
    check(payload['title']).equals('Renamed');
  });
}
