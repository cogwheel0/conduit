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
/// `routers/notes.py:get_notes`, `limit = 60` only when `page` is present).
/// [NotePullSync] passes explicit pages so the early-stop watermark loop works
/// the same as chats and cannot silently depend on an unpaged full-list call.
const int kOpenWebUiNoteListPageSize = 60;

/// Raw int64 NANOSECONDS — NO unit conversion (R-09).
int? _asNs(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

/// Note-pull SEAM for the generic watermark-delta driver (CDT-RFC-001 D-11,
/// R-09). The list/early-stop/worker-pool/watermark-advance spine itself lives
/// in `runPullFor` over a [NoteAdapter]; this class supplies only the FLAT-doc
/// note specifics it drives through: the raw list page ([getListPageRaw]), the
/// full fetch ([fetchRaw]), and the field-LWW merge ([mergeNoteResponse]).
///
/// All timestamp comparisons are int-vs-int NANOSECONDS; `DateTime.now()` never
/// participates. The note watermark is NEVER read against the chat watermark.
class NotePullSync {
  NotePullSync({
    required SyncApiClient client,
    required AppDatabase db,
    required ChatLocks locks,
    IdRemapper? remapper,
  }) : _client = client,
       _db = db,
       _locks = locks,
       // ignore: prefer_initializing_formals
       _remapper = remapper;

  final SyncApiClient _client;
  final AppDatabase _db;
  final ChatLocks _locks;

  /// Used by pull-side note create crash-heal when a process crashed after the
  /// server minted a note but before the local `noteCreate` remap committed.
  final IdRemapper? _remapper;

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
      final healed = await _tryHealCreate(
        serverRaw: resp,
        serverId: id,
        serverCreatedAt: _asNs(resp['created_at']) ?? 0,
        serverUpdatedAt: _asNs(resp['updated_at']) ?? 0,
      );
      if (healed) return false;

      final write = await _db.notesDao.mergeServerNote(serverRaw: resp);
      return write.mustPush;
    });
  }

  /// Attempts the note-create content-hash crash-heal. Returns true when the
  /// pending local create was remapped to [serverId] and the caller must skip
  /// the normal server-row merge.
  Future<bool> _tryHealCreate({
    required Map<String, dynamic> serverRaw,
    required String serverId,
    required int serverCreatedAt,
    required int serverUpdatedAt,
  }) async {
    final remapper = _remapper;
    if (remapper == null) return false;

    final hasPendingCreate = await _db.outboxDao.hasPendingCreateContentHashes(
      kind: OutboxKind.noteCreate,
    );
    if (!hasPendingCreate) return false;

    final hash = noteCreateContentHashFromServer(serverRaw);
    final op = await _db.outboxDao.pendingCreateForHash(
      hash,
      kind: OutboxKind.noteCreate,
    );
    if (op == null) return false;

    final localId = op.chatId;
    if (localId == null || localId == serverId) return false;

    DebugLogger.log(
      'note-create-crash-heal',
      scope: 'sync/notes',
      data: {'from': localId, 'to': serverId, 'seq': op.seq},
    );

    await _locks.runExclusive(localId, () async {
      await remapper.remapNote(
        localId: localId,
        serverId: serverId,
        serverCreatedAt: serverCreatedAt,
        serverUpdatedAt: serverUpdatedAt,
      );
      // The server note exists, so the still-pending create is satisfied. Drop
      // it after remap so the drainer cannot POST a duplicate.
      await _db.outboxDao.markDone(op.seq);
    });
    return true;
  }

  /// Full server-shaped note fetch (`GET /notes/{id}`); null on 404/not-ours.
  /// Exposed for the [NoteAdapter] seam.
  Future<Map<String, dynamic>?> fetchRaw(String id) => _client.getNoteRaw(id);

  /// One explicit server page of raw note maps.
  /// Exposed for the [NoteAdapter] seam.
  Future<List<Map<String, dynamic>>> getListPageRaw(int page) =>
      _getNoteListPage(page);

  Future<List<Map<String, dynamic>>> _getNoteListPage(int page) async {
    // The vendored endpoint applies `limit = 60` only when `?page=N` is present.
    // Pull always uses explicit pages so large note libraries are enumerated
    // with the same early-stop semantics as chat pull.
    final (items, _) = await _client.getNoteListRaw(page: page);
    return items;
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
  }) : _client = client,
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

    return _noteLocks.runExclusive(localId, () async {
      final note = await _db.notesDao.getNote(localId);
      if (note == null || note.deleted) {
        // Annihilated, tombstoned, or already remapped.
        return null;
      }
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

      final serverCreatedAt = _asNs(resp['created_at']) ?? note.createdAt;
      final serverUpdatedAt = _asNs(resp['updated_at']) ?? note.updatedAt;

      // Keep the local-id lock while acquiring the server-id lock for remap.
      // Pull-side crash-heal can hold serverId then try localId, but it only
      // matches pending noteCreate ops. This push worker has already claimed the
      // op as inFlight, so crash-heal exits before taking localId and cannot
      // form an opposite-order cycle.
      await _noteLocks.runExclusive(
        serverId,
        () => _remapper.remapNote(
          localId: localId,
          serverId: serverId,
          serverCreatedAt: serverCreatedAt,
          serverUpdatedAt: serverUpdatedAt,
        ),
      );
      return serverId;
    });
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

  /// Drives the per-user pin to [desired] via the stateless toggle endpoint.
  /// PROBES the live state first (symmetric with the chat pin/archive paths)
  /// and toggles ONLY on a real delta, so a re-run never double-flips and no
  /// transient wrong-state window exists for a concurrent client to win. Clears
  /// the pin dirty axis on success. Does NOT touch the title/data/updated_at
  /// axes.
  Future<void> pushNotePin(String noteId, {required bool desired}) async {
    await _noteLocks.runExclusive(noteId, () async {
      final raw = await _client.getNoteRaw(noteId);
      if (raw == null) {
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
      var livePinned = raw['is_pinned'] == true;
      if (livePinned != desired) {
        await _client.togglePinNote(noteId);
        final confirmedRaw = await _client.getNoteRaw(noteId);
        if (confirmedRaw == null) {
          DebugLogger.warning(
            'pin-confirm-404',
            scope: 'sync/notes',
            data: {'noteId': noteId},
          );
          throw StateError('note pin confirmation missing ($noteId)');
        }
        livePinned = confirmedRaw['is_pinned'] == true;
      }
      if (livePinned != desired) {
        DebugLogger.warning(
          'pin-confirm-mismatch',
          scope: 'sync/notes',
          data: {'noteId': noteId, 'desired': desired, 'actual': livePinned},
        );
        throw StateError('note pin confirmation mismatch ($noteId)');
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
    return (_db.update(_db.notes)..where((t) => t.id.equals(noteId))).write(
      const NotesCompanion(dirtyPinned: Value(false)),
    );
  }
}
