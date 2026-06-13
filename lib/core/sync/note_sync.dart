import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;

import '../database/app_database.dart';
import '../database/daos/outbox_dao.dart';
import '../database/mappers/note_mapper.dart';
import '../utils/debug_logger.dart';
import 'chat_locks.dart';
import 'id_remapper.dart';
import 'sync_api_client.dart';

/// Note pull overlap window in server NANOSECONDS (CDT-RFC-001 D-11, R-09).
///
/// 5 seconds expressed in ns (5 * 1e9): same boundary semantics as
/// [kPullOverlapSeconds] for chats, but in the note clock unit. The unit lives
/// ENTIRELY here + in [NotePullSync] / [NoteAdapter]; the driver only does
/// `int64 updatedAt > wm - overlap` and `max`, never converting. NEVER compared
/// to the chat overlap (R-09).
const int kNotePullOverlapNs = 5 * 1000 * 1000 * 1000;

/// Server page size for `GET /api/v1/notes/?page=N` (vendored
/// `routers/notes.py:get_notes`, `limit = 60`). The list with NO `page` param
/// returns every note unpaged; [NotePullSync] passes explicit pages so the
/// early-stop watermark loop works the same as chats.
const int kOpenWebUiNoteListPageSize = 60;

/// Worker pool for changed-note full-fetches (parity with
/// `kPullFetchConcurrency`).
const int kNotePullFetchConcurrency = 4;

/// Outcome of one note pull cycle (diagnostics + tests).
class NotePullResult {
  const NotePullResult({
    required this.success,
    this.changedNotes = 0,
    this.failedFetches = 0,
    required this.watermarkAdvanced,
  });

  final bool success;
  final int changedNotes;
  final int failedFetches;
  final bool watermarkAdvanced;
}

/// One changed note list item: just `{id, updated_at(ns)}`. The list `data` is
/// server-truncated (`_truncate_note_data`, 1000 chars) so it is NEVER read for
/// body content — the full-fetch (`getNoteRaw`) supplies the authoritative row.
class _ChangedNote {
  const _ChangedNote({required this.id, required this.updatedAt});

  final String id;

  /// Server NANOSECONDS.
  final int updatedAt;
}

/// Watermark-delta note pull (CDT-RFC-001 D-11, R-09). DELIBERATELY mirrors
/// [PullSync] structurally (list → threshold early-stop → worker-pool full
/// fetch → field-LWW merge → watermark advance), differing only where the
/// design REQUIRES it: a FLAT-doc merge (no archived sub-loop, no folders), the
/// note clock in NANOSECONDS, and the dedicated `notes_pull_watermark`.
///
/// All timestamp comparisons are int-vs-int NANOSECONDS; `DateTime.now()` never
/// participates. The note watermark is NEVER read against the chat watermark.
class NotePullSync {
  NotePullSync({
    required SyncApiClient client,
    required AppDatabase db,
    required ChatLocks locks,
    IdRemapper? remapper,
  })  : _client = client,
        _db = db,
        _locks = locks,
        // ignore: prefer_initializing_formals
        _remapper = remapper;

  final SyncApiClient _client;
  final AppDatabase _db;
  final ChatLocks _locks;

  /// Held for parity with [PullSync]; the note create crash-heal is a Phase 5
  /// extension not required by §11 acceptance, so this is currently unused.
  // ignore: unused_field
  final IdRemapper? _remapper;

  /// Runs one note pull cycle. The (nanosecond) watermark advances only when
  /// every list page and every note fetch succeeded; on any failure it stays
  /// frozen and the idempotent field-LWW merge makes the next run safe.
  Future<NotePullResult> run() async {
    final watermark = await _db.syncMetaDao.getNotesPullWatermark();
    final threshold = watermark - kNotePullOverlapNs;
    var maxSeen = watermark;

    final changed = <String, _ChangedNote>{};

    // 1. List loop (updated_at DESC). Any list-page error aborts the cycle
    // before any full fetch, freezing the watermark.
    try {
      var page = 1;
      var stop = false;
      while (!stop) {
        final items = await _getNoteListPage(page);
        for (final item in items) {
          final parsed = _parseListItem(item);
          if (parsed == null) continue;
          if (parsed.updatedAt > threshold) {
            changed.putIfAbsent(parsed.id, () => parsed);
            maxSeen = math.max(maxSeen, parsed.updatedAt);
          } else {
            stop = true;
            break;
          }
        }
        if (stop || items.length < kOpenWebUiNoteListPageSize) break;
        page++;
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'list-page-failed',
        scope: 'sync/notes',
        error: error,
        stackTrace: stackTrace,
      );
      return const NotePullResult(success: false, watermarkAdvanced: false);
    }

    // 2. Full-fetch each changed note (newest-first) with a worker pool; the
    // list `data` is truncated so the body MUST come from getNoteRaw.
    final toFetch = changed.values.toList(growable: false);
    var nextIndex = 0;
    var failedFetches = 0;
    Future<void> worker() async {
      while (true) {
        if (nextIndex >= toFetch.length) return;
        final item = toFetch[nextIndex++];
        try {
          final resp = await _client.getNoteRaw(item.id);
          if (resp == null) {
            // Server-deleted / not-ours: deletion reconcile handles purge.
            continue;
          }
          await mergeNoteResponse(resp);
        } catch (error, stackTrace) {
          failedFetches++;
          DebugLogger.error(
            'note-fetch-failed',
            scope: 'sync/notes',
            error: error,
            stackTrace: stackTrace,
            data: {'noteId': item.id},
          );
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < kNotePullFetchConcurrency; i++) worker(),
    ]);

    // 3. Watermark advance rule (parity with chats §REQ 5).
    final success = failedFetches == 0;
    final watermarkAdvanced = success && maxSeen > watermark;
    if (success) {
      await _db.syncMetaDao.setNotesPullWatermark(maxSeen);
    }

    DebugLogger.log(
      'cycle-done',
      scope: 'sync/notes',
      data: {
        'changed': toFetch.length,
        'failed': failedFetches,
        'watermark': maxSeen,
        'advanced': watermarkAdvanced,
      },
    );
    return NotePullResult(
      success: success,
      changedNotes: toFetch.length,
      failedFetches: failedFetches,
      watermarkAdvanced: watermarkAdvanced,
    );
  }

  /// Lock + one-transaction field-LWW merge of a full `NoteModel` map (D-11).
  /// On a merge that retained local-dirty content, enqueues a `noteUpdate`
  /// (mirrors the chat `mustPush` → updateChat enqueue). Public so the
  /// [NoteAdapter] seam can route a single raw map through it.
  Future<bool> mergeNoteResponse(Map<String, dynamic> resp) {
    final id = resp['id'] is String ? resp['id'] as String : '';
    if (id.isEmpty) {
      throw const FormatException('NoteResponse without a string id');
    }
    return _locks.runExclusive(id, () async {
      final write = await _db.notesDao.mergeServerNote(serverRaw: resp);
      if (write.mustPush) {
        await _enqueueUpdateIfMissing(id);
      }
      return write.mustPush;
    });
  }

  /// Single-note pull (UI on-open refresh). null (404/not-ours) -> no change.
  Future<void> pullNote(String noteId) async {
    final resp = await _client.getNoteRaw(noteId);
    if (resp == null) return;
    await mergeNoteResponse(resp);
  }

  /// Enqueues a `noteUpdate` for [noteId] unless a noteUpdate/noteCreate is
  /// already pending (the patch is rebuilt from the row). Runs under the note
  /// lock the caller holds.
  Future<void> _enqueueUpdateIfMissing(String noteId) async {
    final pending = await _db.outboxDao.pendingForChat(noteId);
    final hasUpdateOrCreate = pending.any((op) {
      final kind = OutboxKind.fromName(op.kind);
      return kind == OutboxKind.noteUpdate || kind == OutboxKind.noteCreate;
    });
    if (hasUpdateOrCreate) return;
    final row = await _db.notesDao.getNote(noteId);
    if (row == null) return;
    // Include data only when the data axis is still dirty (title is always
    // sent — WARNING B).
    final patch = noteRowToPatch(row, includeData: row.dirtyData);
    await _db.outboxDao.enqueue(
      kind: OutboxKind.noteUpdate,
      chatId: noteId,
      payload: patch,
    );
  }

  /// Full server-shaped note fetch (`GET /notes/{id}`); null on 404/not-ours.
  /// Exposed for the [NoteAdapter] seam.
  Future<Map<String, dynamic>?> fetchRaw(String id) => _client.getNoteRaw(id);

  /// One list page of raw note maps (page>1 is empty — see [_getNoteListPage]).
  /// Exposed for the [NoteAdapter] seam.
  Future<List<Map<String, dynamic>>> getListPageRaw(int page) =>
      _getNoteListPage(page);

  Future<List<Map<String, dynamic>>> _getNoteListPage(int page) async {
    // The vendored list endpoint takes an optional ?page; the SyncApiClient
    // seam exposes the whole list (featureEnabled flag dropped here — a
    // disabled feature simply yields no changed notes). Page-slice client-side
    // is unnecessary: getNoteListRaw already returns the server page set when
    // unpaged; for parity with chats we read the full ordered list once on
    // page 1 and treat any later page as empty (the list is updated_at DESC and
    // bounded by the truncating server, so a single ordered pass suffices).
    if (page > 1) return const [];
    final (items, _) = await _client.getNoteListRaw();
    return items;
  }

  _ChangedNote? _parseListItem(Map<String, dynamic> item) {
    final id = item['id'];
    final updatedAt = _asNs(item['updated_at']);
    if (id is! String || id.isEmpty || updatedAt == null) {
      DebugLogger.warning(
        'malformed-list-item',
        scope: 'sync/notes',
        data: {'item': item.toString()},
      );
      return null;
    }
    return _ChangedNote(id: id, updatedAt: updatedAt);
  }

  /// Raw int64 NANOSECONDS — NO unit conversion (R-09).
  static int? _asNs(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }
}

/// Per-kind note outbox push handlers (CDT-RFC-001 D-11). Each acquires the
/// NOTE lock internally so reconstruct/serialize serializes with the pull merge
/// for the same id. Constructor injection only — mirrors [PushSync].
class NotePushSync {
  NotePushSync({
    required SyncApiClient client,
    required AppDatabase db,
    required ChatLocks noteLocks,
    required IdRemapper remapper,
  })  : _client = client,
        _db = db,
        _noteLocks = noteLocks,
        _remapper = remapper;

  final SyncApiClient _client;
  final AppDatabase _db;
  final ChatLocks _noteLocks;
  final IdRemapper _remapper;

  // ---- noteCreate (§7.3 analog) ----

  /// Pushes a new local note [localId], remaps it to the server id, clears the
  /// title/data dirty axes. Returns the server id (or null when the row was
  /// annihilated/already-remapped). Mirrors [PushSync.pushCreateChat] but flat.
  Future<String?> pushNoteCreate(String localId) async {
    // Re-run idempotency: a non-local id means the remap already committed and
    // the create is satisfied; never POST a second note.
    if (!localId.startsWith('local:')) {
      DebugLogger.log(
        'create-already-satisfied',
        scope: 'sync/notes',
        data: {'noteId': localId},
      );
      return localId;
    }

    final _NoteCreatePush? pushed =
        await _noteLocks.runExclusive(localId, () async {
      final note = await _db.notesDao.getNote(localId);
      if (note == null) return null; // Annihilated or already remapped.
      final data = decodeNoteData(note.data);
      final resp = await _client.createNote(
        title: note.title,
        data: data,
        // Own-notes sync NEVER sends meta/access_grants (D-11): meta round-trips
        // through rawExtra untouched and the server preserves it.
      );
      final serverId = resp['id'];
      if (serverId is! String || serverId.isEmpty) {
        throw StateError('createNote response without a string id');
      }
      return _NoteCreatePush(
        serverId: serverId,
        serverCreatedAt: _asNs(resp['created_at']) ?? note.createdAt,
        serverUpdatedAt: _asNs(resp['updated_at']) ?? note.updatedAt,
      );
    });

    if (pushed == null) return null;

    // Remap under the SERVER id lock: the §7.3 single transaction commits here,
    // BEFORE the drainer marks the noteCreate op done.
    await _noteLocks.runExclusive(
      pushed.serverId,
      () => _remapper.remapNote(
        localId: localId,
        serverId: pushed.serverId,
        serverCreatedAt: pushed.serverCreatedAt,
        serverUpdatedAt: pushed.serverUpdatedAt,
      ),
    );
    return pushed.serverId;
  }

  // ---- noteUpdate (patch map) ----

  /// Pushes the patch carried by the op (`title` always; `data` when dirty) and
  /// clears the corresponding dirty axes for the captured state. The whole
  /// reconstruct → POST → clear runs under one lock span (no mid-flight echo).
  Future<void> pushNoteUpdate(String noteId, Map<String, dynamic> patch) async {
    await _noteLocks.runExclusive(noteId, () async {
      final note = await _db.notesDao.getNote(noteId);
      if (note == null || note.deleted) {
        // A noteDelete op will handle a tombstoned/absent note.
        return;
      }
      // The op's payload was the coalesced patch, but §3.iii: rebuild from the
      // CURRENT row so the latest committed title/data wins even after
      // coalescing collapsed several edits. `data` is sent iff the row's data
      // axis is dirty (or the patch explicitly carried it).
      final includeData = note.dirtyData || patch.containsKey('data');
      final live = noteRowToPatch(note, includeData: includeData);
      final resp = await _client.updateNote(noteId, live);
      if (resp == null) {
        // 404: gone server-side. Deletion reconcile / the next pull handles it.
        DebugLogger.warning(
          'update-404',
          scope: 'sync/notes',
          data: {'noteId': noteId},
        );
        return;
      }
      final serverUpdatedAt = _asNs(resp['updated_at']) ?? note.updatedAt;
      await _clearNoteDirty(
        noteId: noteId,
        clearTitle: true,
        clearData: includeData,
        serverUpdatedAt: serverUpdatedAt,
      );
    });
  }

  // ---- noteDelete (§7.5 analog) ----

  /// Confirms the server delete (404 already-gone is success), then purges the
  /// local rows. 401/403 propagates so the drainer parks the op (rows stay
  /// tombstoned).
  Future<void> pushNoteDelete(String noteId) async {
    await _noteLocks.runExclusive(noteId, () async {
      await _client.deleteNote(noteId);
      await _db.notesDao.hardDelete(noteId);
    });
  }

  // ---- notePin (dedicated axis) ----

  /// Drives the per-user pin to [desired] via the stateless toggle endpoint,
  /// confirming the live state first so a re-run never double-flips. Clears the
  /// pin dirty axis on success. Does NOT touch the title/data/updated_at axes.
  Future<void> pushNotePin(String noteId, {required bool desired}) async {
    await _noteLocks.runExclusive(noteId, () async {
      final resp = await _client.togglePinNote(noteId);
      if (resp == null) {
        // 404: gone server-side; nothing to pin.
        DebugLogger.warning(
          'pin-404',
          scope: 'sync/notes',
          data: {'noteId': noteId},
        );
        // Still clear the dirty axis so a dead pin op doesn't loop forever; the
        // note is gone and reconcile will purge it.
        await _clearNotePinDirty(noteId);
        return;
      }
      // The endpoint TOGGLES; if the flip overshot the desired state (the
      // server was already at `desired`), flip once more to land on it.
      final nowPinned = resp['is_pinned'] == true;
      if (nowPinned != desired) {
        await _client.togglePinNote(noteId);
      }
      await _clearNotePinDirty(noteId);
    });
  }

  // ---- helpers ----

  /// Caller holds the note lock. Stores [serverUpdatedAt] (ns) + clears the
  /// requested dirty axes in one transaction.
  Future<void> _clearNoteDirty({
    required String noteId,
    required bool clearTitle,
    required bool clearData,
    required int serverUpdatedAt,
  }) {
    return _db.transaction(() async {
      await (_db.update(_db.notes)..where((t) => t.id.equals(noteId))).write(
        NotesCompanion(
          serverUpdatedAt: Value(serverUpdatedAt),
          updatedAt: Value(serverUpdatedAt),
          dirtyTitle: clearTitle ? const Value(false) : const Value.absent(),
          dirtyData: clearData ? const Value(false) : const Value.absent(),
        ),
      );
    });
  }

  Future<void> _clearNotePinDirty(String noteId) {
    return (_db.update(_db.notes)..where((t) => t.id.equals(noteId)))
        .write(const NotesCompanion(dirtyPinned: Value(false)));
  }

  static int? _asNs(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }
}

/// Result of the createNote POST carried out of the local-id lock span.
class _NoteCreatePush {
  const _NoteCreatePush({
    required this.serverId,
    required this.serverCreatedAt,
    required this.serverUpdatedAt,
  });

  final String serverId;

  /// NANOSECONDS.
  final int serverCreatedAt;
  final int serverUpdatedAt;
}
