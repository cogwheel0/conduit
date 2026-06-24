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
import 'package:conduit/core/sync/sync_api_client.dart';
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
/// enumeration succeeds, then the first probe sees a terminal auth failure.
class _NoteSessionDyingClient extends FakeSyncApiClient {
  _NoteSessionDyingClient(super.server);
  @override
  Future<Map<String, dynamic>?> getNoteRaw(String id) {
    throw const SyncTerminalException(statusCode: 401, message: 'expired');
  }
}

/// A client whose first gone-note probe succeeds, then whose session dies
/// before the second gone-note probe.
class _NoteSessionDiesAfterFirstPurgeClient extends FakeSyncApiClient {
  _NoteSessionDiesAfterFirstPurgeClient(super.server);

  var rawFetches = 0;

  @override
  Future<Map<String, dynamic>?> getNoteRaw(String id) {
    rawFetches++;
    if (rawFetches > 1) {
      throw const SyncTerminalException(statusCode: 401, message: 'expired');
    }
    return super.getNoteRaw(id);
  }
}

class _TerminalNoteProbeClient extends FakeSyncApiClient {
  _TerminalNoteProbeClient(super.server);

  @override
  Future<Map<String, dynamic>?> getNoteRaw(String id) {
    throw const SyncTerminalException(statusCode: 403, message: 'forbidden');
  }
}

class _FeatureDisabledExpiredSessionClient extends FakeSyncApiClient {
  _FeatureDisabledExpiredSessionClient(super.server);

  @override
  Future<(List<Map<String, dynamic>>, bool)> getNoteListRaw({int? page}) async {
    return (const <Map<String, dynamic>>[], false);
  }

  @override
  Future<List<Map<String, dynamic>>> getChatListPage(int page) {
    throw const SyncTerminalException(statusCode: 401, message: 'expired');
  }
}

Map<String, dynamic> serverNote(String id, int ns) => <String, dynamic>{
  'id': id,
  'title': 'Note $id',
  'data': {
    'content': {'md': 'body $id'},
  },
  'meta': <String, dynamic>{},
  'is_pinned': false,
  'created_at': ns,
  'updated_at': ns,
};

void main() {
  late FakeOpenWebUiServer server;
  late AppDatabase db;
  late NoteLocks locks;
  late _Clock clock;

  setUp(() {
    server = FakeOpenWebUiServer();
    db = AppDatabase(NativeDatabase.memory());
    locks = NoteLocks();
    clock = _Clock();
  });
  tearDown(() => db.close());

  // Seeds a note both locally (server-keyed, clean) and on the fake server.
  Future<void> seedSyncedNote(String id) async {
    const ns = 1718000000000000000;
    await db.notesDao.mergeServerNote(serverRaw: serverNote(id, ns));
    server.seedNote(
      id: id,
      title: 'Note $id',
      data: {
        'content': {'md': 'body $id'},
      },
      createdAt: ns,
      updatedAt: ns,
    );
  }

  // Seeds a note locally only (absent from the server → a reconcile candidate).
  Future<void> seedLocalOnly(String id) async {
    const ns = 1718000000000000000;
    await db.notesDao.mergeServerNote(serverRaw: serverNote(id, ns));
  }

  NoteDeletionReconcile reconcileWith(FakeSyncApiClient client) =>
      NoteDeletionReconcile(client: client, db: db, locks: locks, clock: clock);

  test(
    'a note still on the server is never purged (pagination/race gap)',
    () async {
      final client = FakeSyncApiClient(server);
      for (final id in ['a', 'b', 'c']) {
        await seedSyncedNote(id);
      }
      // 'a' is locally present AND on the server but we force the probe to still
      // see it as existing — it must NOT be purged just for being a candidate.
      final result = await reconcileWith(
        client,
      ).run(ReconcileReason.manualRefresh);
      check(result.purged).equals(0);
      check(result.candidates).equals(0); // all three are on the server list
    },
  );

  test('a confirmed-gone note is purged after probe', () async {
    final client = FakeSyncApiClient(server);
    for (final id in ['s1', 's2', 's3']) {
      await seedSyncedNote(id);
    }
    await seedLocalOnly('ghost');
    client.nullNoteIds.add('ghost'); // probe → null → gone

    final result = await reconcileWith(
      client,
    ).run(ReconcileReason.manualRefresh);
    check(result.candidates).equals(1);
    check(result.purged).equals(1);
    check(await db.notesDao.getNote('ghost')).isNull();
    check(await db.notesDao.getNote('s1')).isNotNull();
  });

  test(
    'confirmed-gone candidates reuse the initial note list liveness check',
    () async {
      final client = FakeSyncApiClient(server);
      await seedLocalOnly('ghost-1');
      await seedLocalOnly('ghost-2');
      await seedLocalOnly('ghost-3');
      client.nullNoteIds.addAll(['ghost-1', 'ghost-2', 'ghost-3']);

      final result = await reconcileWith(
        client,
      ).run(ReconcileReason.manualRefresh);

      check(result.purged).equals(3);
      check(client.noteListRequests).equals(1);
    },
  );

  test('a transient probe error SKIPS (does not purge)', () async {
    final client = FakeSyncApiClient(server);
    for (final id in ['s1', 's2', 's3']) {
      await seedSyncedNote(id);
    }
    await seedLocalOnly('flaky');
    client.failNoteIds.add('flaky'); // probe throws → skip

    final result = await reconcileWith(
      client,
    ).run(ReconcileReason.manualRefresh);
    check(result.purged).equals(0);
    check(result.skipped).equals(1);
    check(await db.notesDao.getNote('flaky')).isNotNull();
  });

  test(
    'safety valve aborts when candidates exceed the floor AND half the set',
    () async {
      final client = FakeSyncApiClient(server);
      // 8 local notes, all absent from the server → above the absolute floor (5)
      // and 50% → abort without purging.
      final ids = List.generate(8, (i) => 'n$i');
      for (final id in ids) {
        await seedLocalOnly(id);
      }
      client.nullNoteIds.addAll(ids);

      final result = await reconcileWith(
        client,
      ).run(ReconcileReason.manualRefresh);
      check(result.aborted).isTrue();
      check(result.purged).equals(0);
      check(await db.notesDao.getNote('n0')).isNotNull();
    },
  );

  test('a SMALL library is NOT blocked: a single deleted note is purged '
      '(regression — fraction valve must not trip below the floor)', () async {
    final client = FakeSyncApiClient(server);
    await seedLocalOnly('only');
    client.nullNoteIds.add('only'); // probe -> gone

    final result = await reconcileWith(
      client,
    ).run(ReconcileReason.manualRefresh);
    check(result.aborted).isFalse();
    check(result.purged).equals(1);
    check(await db.notesDao.getNote('only')).isNull();
  });

  test(
    'a dead session aborts without purging or advancing the throttle',
    () async {
      final client = _NoteSessionDyingClient(server);
      for (final id in ['s1', 's2', 's3']) {
        await seedSyncedNote(id);
      }
      await seedLocalOnly('ghost');
      client.nullNoteIds.add('ghost');

      final result = await reconcileWith(
        client,
      ).run(ReconcileReason.manualRefresh);
      check(result.aborted).isTrue();
      check(result.purged).equals(0);
      check(await db.notesDao.getNote('ghost')).isNotNull();
      check(await db.syncMetaDao.getNotesLastFullReconcileAt()).equals(0);
    },
  );

  test(
    'a session that dies mid-loop does not purge later null probes',
    () async {
      final client = _NoteSessionDiesAfterFirstPurgeClient(server);
      await seedLocalOnly('ghost-1');
      await seedLocalOnly('ghost-2');
      client.nullNoteIds.addAll(['ghost-1', 'ghost-2']);

      final result = await reconcileWith(
        client,
      ).run(ReconcileReason.manualRefresh);

      check(result.aborted).isTrue();
      check(result.purged).equals(1);
      check(result.skipped).equals(1);
      final remaining = [
        await db.notesDao.getNote('ghost-1'),
        await db.notesDao.getNote('ghost-2'),
      ].whereType<NoteRow>().toList();
      check(remaining.length).equals(1);
      check(await db.syncMetaDao.getNotesLastFullReconcileAt()).equals(0);
    },
  );

  test('a terminal probe aborts without advancing the throttle', () async {
    final client = _TerminalNoteProbeClient(server);
    await seedLocalOnly('forbidden');

    final result = await reconcileWith(
      client,
    ).run(ReconcileReason.manualRefresh);

    check(result.aborted).isTrue();
    check(result.purged).equals(0);
    check(result.skipped).equals(1);
    check(await db.notesDao.getNote('forbidden')).isNotNull();
    check(await db.syncMetaDao.getNotesLastFullReconcileAt()).equals(0);
  });

  test(
    'notes feature disabled is a throttled no-op, not a mass-delete signal',
    () async {
      final client = FakeSyncApiClient(server)..notesFeatureEnabled = false;
      await seedLocalOnly('ghost');
      final result = await reconcileWith(
        client,
      ).run(ReconcileReason.manualRefresh);
      check(result.ran).isTrue();
      check(await db.notesDao.getNote('ghost')).isNotNull();
      check(
        await db.syncMetaDao.getNotesLastFullReconcileAt(),
      ).equals(clock.now);
    },
  );

  test(
    'feature-disabled note list does not throttle when session is dead',
    () async {
      final client = _FeatureDisabledExpiredSessionClient(server);
      await seedLocalOnly('ghost');

      final result = await reconcileWith(
        client,
      ).run(ReconcileReason.manualRefresh);

      check(result.ran).isFalse();
      check(await db.notesDao.getNote('ghost')).isNotNull();
      check(await db.syncMetaDao.getNotesLastFullReconcileAt()).equals(0);
    },
  );

  test('background reason honors the 24h throttle', () async {
    final client = FakeSyncApiClient(server);
    await db.syncMetaDao.setNotesLastFullReconcileAt(clock.now - 100);
    final result = await reconcileWith(client).run(ReconcileReason.background);
    check(result.ran).isFalse();
  });
}
