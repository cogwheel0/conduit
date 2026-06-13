/// CDT-RFC-001 §7.5 NOTE deletion reconcile: a note absent from the server list
/// is purged ONLY after a probe confirms it gone; pagination/transient/feature
/// flaps never false-delete; a token-expiry storm trips the safety valve or the
/// session-liveness guard. Mirrors the chat reconcile contract over notes.
library;

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/sync/chat_locks.dart';
import 'package:conduit/core/sync/clock.dart';
import 'package:conduit/core/sync/deletion_reconcile.dart' show ReconcileReason;
import 'package:conduit/core/sync/note_deletion_reconcile.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_open_webui_server.dart';
import '../../support/fake_sync_api_client.dart';

class _Clock implements SyncClock {
  int now = 1000000;
  @override
  int nowEpochSeconds() => now;
}

/// A client whose note session dies the instant the probe loop starts:
/// enumeration succeeds, then the first probe injects a list failure so the
/// liveness re-check throws.
class _NoteSessionDyingClient extends FakeSyncApiClient {
  _NoteSessionDyingClient(super.server);
  @override
  Future<Map<String, dynamic>?> getNoteRaw(String id) {
    failNoteList = true;
    return super.getNoteRaw(id);
  }
}

Map<String, dynamic> serverNote(String id, int ns) => <String, dynamic>{
      'id': id,
      'title': 'Note $id',
      'data': {'content': {'md': 'body $id'}},
      'meta': <String, dynamic>{},
      'is_pinned': false,
      'created_at': ns,
      'updated_at': ns,
    };

void main() {
  late FakeOpenWebUiServer server;
  late AppDatabase db;
  late ChatLocks locks;
  late _Clock clock;

  setUp(() {
    server = FakeOpenWebUiServer();
    db = AppDatabase(NativeDatabase.memory());
    locks = ChatLocks();
    clock = _Clock();
  });
  tearDown(() => db.close());

  // Seeds a note both locally (server-keyed, clean) and on the fake server.
  Future<void> seedSyncedNote(String id) async {
    const ns = 1718000000000000000;
    await db.notesDao.upsertServerNote(serverNote(id, ns));
    server.seedNote(
      id: id,
      title: 'Note $id',
      data: {'content': {'md': 'body $id'}},
      createdAt: ns,
      updatedAt: ns,
    );
  }

  // Seeds a note locally only (absent from the server → a reconcile candidate).
  Future<void> seedLocalOnly(String id) async {
    const ns = 1718000000000000000;
    await db.notesDao.upsertServerNote(serverNote(id, ns));
  }

  NoteDeletionReconcile reconcileWith(FakeSyncApiClient client) =>
      NoteDeletionReconcile(client: client, db: db, locks: locks, clock: clock);

  test('a note still on the server is never purged (pagination/race gap)',
      () async {
    final client = FakeSyncApiClient(server);
    for (final id in ['a', 'b', 'c']) {
      await seedSyncedNote(id);
    }
    // 'a' is locally present AND on the server but we force the probe to still
    // see it as existing — it must NOT be purged just for being a candidate.
    final result = await reconcileWith(client).run(ReconcileReason.manualRefresh);
    check(result.purged).equals(0);
    check(result.candidates).equals(0); // all three are on the server list
  });

  test('a confirmed-gone note is purged after probe', () async {
    final client = FakeSyncApiClient(server);
    for (final id in ['s1', 's2', 's3']) {
      await seedSyncedNote(id);
    }
    await seedLocalOnly('ghost');
    client.nullNoteIds.add('ghost'); // probe → null → gone

    final result = await reconcileWith(client).run(ReconcileReason.manualRefresh);
    check(result.candidates).equals(1);
    check(result.purged).equals(1);
    check(await db.notesDao.getNote('ghost')).isNull();
    check(await db.notesDao.getNote('s1')).isNotNull();
  });

  test('a transient probe error SKIPS (does not purge)', () async {
    final client = FakeSyncApiClient(server);
    for (final id in ['s1', 's2', 's3']) {
      await seedSyncedNote(id);
    }
    await seedLocalOnly('flaky');
    client.failNoteIds.add('flaky'); // probe throws → skip

    final result = await reconcileWith(client).run(ReconcileReason.manualRefresh);
    check(result.purged).equals(0);
    check(result.skipped).equals(1);
    check(await db.notesDao.getNote('flaky')).isNotNull();
  });

  test('safety valve aborts when too many notes are candidates', () async {
    final client = FakeSyncApiClient(server);
    // Two local notes, both absent from the server → 100% candidates > 50%.
    await seedLocalOnly('x');
    await seedLocalOnly('y');
    client.nullNoteIds.addAll(['x', 'y']);

    final result = await reconcileWith(client).run(ReconcileReason.manualRefresh);
    check(result.aborted).isTrue();
    check(result.purged).equals(0);
    check(await db.notesDao.getNote('x')).isNotNull();
  });

  test('a dead session aborts without purging or advancing the throttle',
      () async {
    final client = _NoteSessionDyingClient(server);
    for (final id in ['s1', 's2', 's3']) {
      await seedSyncedNote(id);
    }
    await seedLocalOnly('ghost');
    client.nullNoteIds.add('ghost');

    final result = await reconcileWith(client).run(ReconcileReason.manualRefresh);
    check(result.aborted).isTrue();
    check(result.purged).equals(0);
    check(await db.notesDao.getNote('ghost')).isNotNull();
    check(await db.syncMetaDao.getNotesLastFullReconcileAt()).equals(0);
  });

  test('notes feature disabled is not a mass-delete signal', () async {
    final client = FakeSyncApiClient(server)..notesFeatureEnabled = false;
    await seedLocalOnly('ghost');
    final result = await reconcileWith(client).run(ReconcileReason.manualRefresh);
    check(result.ran).isFalse();
    check(await db.notesDao.getNote('ghost')).isNotNull();
  });

  test('background reason honors the 24h throttle', () async {
    final client = FakeSyncApiClient(server);
    await db.syncMetaDao.setNotesLastFullReconcileAt(clock.now - 100);
    final result = await reconcileWith(client).run(ReconcileReason.background);
    check(result.ran).isFalse();
  });
}
