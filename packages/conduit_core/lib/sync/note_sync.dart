import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/mappers/note_mapper.dart';
import 'package:conduit_core/features/notes/utils/note_access.dart';
import 'package:conduit_core/features/notes/utils/note_page_data.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_core/sync/chat_locks.dart';

import 'package:conduit_core/sync/id_remapper.dart';

import 'package:conduit_core/sync/sync_api_client.dart';

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
    required NoteLocks locks,
    IdRemapper? remapper,
    void Function(bool enabled)? onFeatureEnabled,
    String? Function()? readerAccountId,
  }) : _client = client,
       _db = db,
       _locks = locks,
       // ignore: prefer_initializing_formals
       _remapper = remapper,
       _onFeatureEnabled = onFeatureEnabled,
       _readerAccountId = readerAccountId;

  final SyncApiClient _client;
  final AppDatabase _db;
  final NoteLocks _locks;

  /// The account this pull was built for, or null once the session it belonged
  /// to has ended. A response is read evidence only for the account that
  /// received it.
  final String? Function()? _readerAccountId;

  /// Used by pull-side note create crash-heal when a process crashed after the
  /// server minted a note but before the local `noteCreate` remap committed.
  final IdRemapper? _remapper;
  final void Function(bool enabled)? _onFeatureEnabled;

  /// Lock + one-transaction field-LWW merge of a full `NoteModel` map (D-11).
  /// On a merge that retained local-dirty content, enqueues a `noteUpdate`
  /// (mirrors the chat `mustPush` → updateChat enqueue). Public so the
  /// [NoteAdapter] seam can route a single raw map through it.
  Future<bool> mergeNoteResponse(
    Map<String, dynamic> resp, {
    bool? hasPendingCreateHashes,
  }) {
    final id = resp['id'] is String ? resp['id'] as String : '';
    if (id.isEmpty) {
      throw const FormatException('NoteResponse without a string id');
    }
    return _locks.runExclusive(id, () async {
      final healed = await _tryHealCreate(
        serverRaw: resp,
        serverId: id,
        serverCreatedAt: asNs(resp['created_at']) ?? 0,
        serverUpdatedAt: asNs(resp['updated_at']) ?? 0,
        hasPendingCreateHashes: hasPendingCreateHashes,
      );
      if (healed) return false;

      final write = await _db.notesDao.mergeServerNote(
        serverRaw: resp,
        readerId: _readerAccountId?.call(),
      );
      return write.mustPush;
    });
  }

  Future<bool> hasPendingCreateContentHashes() {
    return _db.outboxDao.hasPendingCreateContentHashes(
      kind: OutboxKind.noteCreate,
    );
  }

  /// Attempts the note-create content-hash crash-heal. Returns true when the
  /// pending local create was remapped to [serverId] and the caller must skip
  /// the normal server-row merge.
  Future<bool> _tryHealCreate({
    required Map<String, dynamic> serverRaw,
    required String serverId,
    required int serverCreatedAt,
    required int serverUpdatedAt,
    bool? hasPendingCreateHashes,
  }) async {
    final remapper = _remapper;
    if (remapper == null) return false;

    final hasPendingCreate =
        hasPendingCreateHashes ?? await hasPendingCreateContentHashes();
    if (!hasPendingCreate) return false;

    OutboxOp? claimed;
    for (final hash in noteCreateContentHashesFromServer(serverRaw)) {
      claimed = await _db.outboxDao.claimPendingCreateForHash(
        hash,
        kind: OutboxKind.noteCreate,
      );
      if (claimed != null) break;
    }
    if (claimed == null) return false;
    final op = claimed;

    final localId = op.chatId;
    if (localId == null) {
      await _db.outboxDao.markDeferred(
        op.seq,
        error: 'malformed note create crash-heal op',
        nextAttemptAt: 0,
      );
      return false;
    }
    if (localId == serverId) {
      await _db.outboxDao.markDone(op.seq);
      return false;
    }

    DebugLogger.log(
      'note-create-crash-heal',
      scope: 'sync/notes',
      data: {'from': localId, 'to': serverId, 'seq': op.seq},
    );

    try {
      await _locks.runExclusive(localId, () async {
        await remapper.remapNote(
          localId: localId,
          serverId: serverId,
          serverCreatedAt: serverCreatedAt,
          serverUpdatedAt: serverUpdatedAt,
        );
        // Alias the lock key so an edit/pin/delete already queued on the stale
        // local id reroutes to the server-id lock (the DAO resolves the remap
        // internally and mutates the server row) — mirrors the create-push
        // path so a queued mutation can't run on a different key than pull/push.
        _locks.remapKeyInPlace(fromId: localId, toId: serverId);
        // The server note exists, so the claimed create is satisfied. Drop it
        // after remap so the drainer cannot POST a duplicate.
        await _db.outboxDao.markDone(op.seq);
      });
    } catch (error, stackTrace) {
      DebugLogger.error(
        'note-create-crash-heal-failed',
        scope: 'sync/notes',
        error: error,
        stackTrace: stackTrace,
        data: {'from': localId, 'to': serverId, 'seq': op.seq},
      );
      await _db.outboxDao.markDeferred(
        op.seq,
        error: 'note create crash-heal failed: $error',
        nextAttemptAt: 0,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
    return true;
  }

  /// Full server-shaped note fetch (`GET /notes/{id}`); null on 404/not-ours.
  /// Exposed for the [NoteAdapter] seam.
  Future<Map<String, dynamic>?> fetchRaw(String id) => _client.getNoteRaw(id);

  /// One explicit server page of raw note maps.
  /// Exposed for the [NoteAdapter] seam.
  Future<List<Map<String, dynamic>>> getListPageRaw(int page) async {
    // The vendored endpoint applies `limit = 60` only when `?page=N` is present.
    // Pull always uses explicit pages so large note libraries are enumerated
    // with the same early-stop semantics as chat pull.
    final (items, featureEnabled) = await _client.getNoteListRaw(page: page);
    _onFeatureEnabled?.call(featureEnabled);
    await _recordListedReadEvidence(items);
    return items;
  }

  /// The list is the server's answer to which notes this account may read, so
  /// a listed note already cached (before read evidence was recorded, say, and
  /// unchanged since) becomes visible to the account without a refetch.
  Future<void> _recordListedReadEvidence(
    List<Map<String, dynamic>> items,
  ) async {
    for (final item in items) {
      final id = item['id'];
      if (id is! String || id.isEmpty) continue;
      await _locks.runExclusive(id, () async {
        // The account is read inside the lock, immediately before the write.
        final readerId = _readerAccountId?.call();
        if (readerId == null || readerId.isEmpty) return;
        await _db.notesDao.storeNoteAccessProjection(id, readerId: readerId);
      });
    }
  }
}

/// Per-kind note outbox push handlers (CDT-RFC-001 D-11). Each acquires the
/// NOTE lock internally so reconstruct/serialize serializes with the pull merge
/// for the same id. Constructor injection only — mirrors [PushSync].
class NotePushSync {
  NotePushSync({
    required SyncApiClient client,
    required AppDatabase db,
    required NoteLocks noteLocks,
    required IdRemapper remapper,
    String? Function()? currentAccountId,
    bool? Function()? notePagesServer,
  }) : _client = client,
       _db = db,
       _noteLocks = noteLocks,
       _remapper = remapper,
       _currentAccountId = currentAccountId,
       _notePagesServer = notePagesServer;

  final SyncApiClient _client;
  final AppDatabase _db;
  final NoteLocks _noteLocks;
  final IdRemapper _remapper;

  /// The signed-in account, read when an op replays rather than when the
  /// handler was built, because the drainer outlives an account switch.
  final String? Function()? _currentAccountId;

  /// Whether the server stores notes as pages (Open WebUI 0.12.5+), null when
  /// unknown; read when an op replays, as the server can change meanwhile.
  final bool? Function()? _notePagesServer;

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
      // A conflict copy of a note read from a 0.12.5 server carries its
      // pages; the server refuses those in a create and rebuilds them anyway.
      final data = noteDataForCreate(decodeNoteData(note.data));
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

      final serverCreatedAt = asNs(resp['created_at']) ?? note.createdAt;
      final serverUpdatedAt = asNs(resp['updated_at']) ?? note.updatedAt;

      // Keep the local-id lock while acquiring the server-id lock for remap.
      // Pull-side crash-heal claims a pending noteCreate before trying localId;
      // once this push worker owns the op as inFlight, crash-heal exits before
      // taking localId and cannot form an opposite-order cycle.
      await _noteLocks.runExclusive(serverId, () async {
        await _remapper.remapNote(
          localId: localId,
          serverId: serverId,
          serverCreatedAt: serverCreatedAt,
          serverUpdatedAt: serverUpdatedAt,
        );
        _noteLocks.remapKeyInPlace(fromId: localId, toId: serverId);
      });
      return serverId;
    });
  }

  // ---- noteUpdate (patch map) ----

  /// Pushes the patch carried by the op (`title` always; `data` when dirty) and
  /// clears the corresponding dirty axes for the captured state. The whole
  /// reconstruct → POST → clear runs under one lock span (no mid-flight echo).
  ///
  /// `data` carries only what Conduit edits, the content, and goes to the
  /// page it was edited on by `page_id`, which servers before 0.12.5 ignore.
  /// A paged note sends each page edited here ([kNoteDirtyPagesKey]) in turn,
  /// and never its pages, which 0.12.5 refuses. A note in the older shape
  /// sends its content to the main page, with its file list for a server
  /// before 0.12.5; a 0.12.5 server refuses the list, so there the files are
  /// written into the content as links instead, as the server itself moves
  /// them. When the server version is unknown the list goes first, and the
  /// links follow if the server refuses it. Once a 0.12.5 server answers, the
  /// row takes the server's paged data, so the next edit goes out in that
  /// shape. A note with several pages whose combined view was edited as a
  /// whole, as builds before page-aware edits did, has that edit kept as a
  /// conflict copy.
  Future<void> pushNoteUpdate(String noteId, Map<String, dynamic> patch) async {
    await _noteLocks.runExclusive(noteId, () async {
      final note = await _db.notesDao.getNote(noteId);
      if (note == null || note.deleted) {
        // A noteDelete op will handle a tombstoned/absent note.
        return;
      }
      if (!await _mayReplayEdit(note)) {
        // The draft stays in the row, dirty. Parking is the same outcome the
        // server's own 403 produces, reached without sending the edit.
        throw SyncTerminalException(
          statusCode: 403,
          message: 'updateNote $noteId is read-only for this account',
        );
      }
      // The op's payload was the coalesced patch, but §3.iii: rebuild from the
      // CURRENT row so the latest committed title/data wins even after
      // coalescing collapsed several edits. `data` is sent iff the row's data
      // axis is dirty (or the patch explicitly carried it).
      final includeData = note.dirtyData || patch.containsKey('data');
      var data = decodeNoteData(note.data);
      if (includeData &&
          noteDataIsMultiPage(data) &&
          noteCombinedContentEdited(data)) {
        // A build before page-aware edits changed the combined view of every
        // page, which belongs to no page: it is kept as a note of its own, and
        // the pages edited here are sent as usual.
        data = await _db.notesDao.keepCombinedEditAsCopy(note);
      }
      final saves = includeData
          ? _contentSaves(noteId, data)
          : const <_NoteContentSave>[];
      Map<String, dynamic>? resp;
      if (saves.isEmpty) {
        resp = await _client.updateNote(noteId, {'title': note.title});
      }
      for (final save in saves) {
        // A retry after a later page failed sends the earlier ones again,
        // which leaves them as they are.
        resp = await _sendContentSave(noteId, note.title, save);
        if (resp == null) break;
      }
      if (resp == null) {
        // 404: gone server-side. Deletion reconcile / the next pull handles it.
        DebugLogger.warning(
          'update-404',
          scope: 'sync/notes',
          data: {'noteId': noteId},
        );
        return;
      }
      final serverUpdatedAt = asNs(resp['updated_at']) ?? note.updatedAt;
      final serverData = resp['data'];
      await _clearNoteDirty(
        noteId: noteId,
        clearTitle: true,
        clearData: includeData,
        serverUpdatedAt: serverUpdatedAt,
        // The answer holds what was just sent, as the server stores it. The
        // lock keeps any local edit out until the row is written.
        serverData:
            includeData &&
                serverData is Map<String, dynamic> &&
                noteDataHasPages(serverData)
            ? serverData
            : null,
      );
    });
  }

  /// The content saves that send the edits stored in [data].
  List<_NoteContentSave> _contentSaves(
    String noteId,
    Map<String, dynamic> data,
  ) {
    if (noteDataHasPages(data)) {
      var pageIds = noteDirtyPageIds(data);
      // An earlier build attached recordings to the file list of a note
      // already in this shape; 0.12.5 refuses the list, so they are written
      // into the main page as links, as the server moves them.
      final Object? rawFiles = data['files'];
      final Map<String, dynamic>? linkedMain =
          rawFiles is List && rawFiles.isNotEmpty
          ? noteContentWithLinkedFiles(
              notePageContent(data, kNoteMainPageId) ??
                  noteContentWithMarkdown(null, ''),
              rawFiles,
            )
          : null;
      if (linkedMain != null && !pageIds.contains(kNoteMainPageId)) {
        pageIds = <String>[kNoteMainPageId, ...pageIds];
      }
      if (pageIds.isEmpty) {
        final single = noteSinglePageId(data);
        if (single == null) {
          // No page was edited; an edit of the combined view went to a copy.
          DebugLogger.log(
            'update-no-page-edited',
            scope: 'sync/notes',
            data: {'noteId': noteId},
          );
          return const <_NoteContentSave>[];
        }
        pageIds = <String>[single];
      }
      return <_NoteContentSave>[
        for (final pageId in pageIds)
          _NoteContentSave(
            noteContentUpdateBody(
              pageId == kNoteMainPageId && linkedMain != null
                  ? linkedMain
                  : notePageContent(data, pageId),
              pageId: pageId,
            ),
          ),
      ];
    }
    final Object? rawContent = data['content'];
    final Object? rawFiles = data['files'];
    final files = rawFiles is List ? rawFiles : null;
    // A note with no text that gained a recording has only its file list.
    if (rawContent is! Map && files == null) {
      return const <_NoteContentSave>[];
    }
    final Map<String, dynamic>? content = rawContent is Map
        ? Map<String, dynamic>.from(rawContent)
        : null;
    final pagesServer = _notePagesServer?.call();
    final linked = files == null
        ? null
        : noteContentUpdateBody(
            noteContentWithLinkedFiles(
              content ?? noteContentWithMarkdown(null, ''),
              files,
            ),
            pageId: kNoteMainPageId,
          );
    if (pagesServer == true) {
      return <_NoteContentSave>[
        _NoteContentSave(
          linked ??
              noteContentUpdateBody(content, pageId: kNoteMainPageId),
        ),
      ];
    }
    return <_NoteContentSave>[
      _NoteContentSave(
        noteContentUpdateBody(content, pageId: kNoteMainPageId, files: files),
        // A server whose version is unknown may be a 0.12.5 one.
        ifRejected: pagesServer == null ? linked : null,
      ),
    ];
  }

  Future<Map<String, dynamic>?> _sendContentSave(
    String noteId,
    String title,
    _NoteContentSave save,
  ) async {
    try {
      return await _client.updateNote(noteId, {'title': title, ...save.body});
    } on SyncRejectedException catch (error) {
      final fallback = save.ifRejected;
      if (fallback == null) rethrow;
      DebugLogger.log(
        'update-files-moved-into-content',
        scope: 'sync/notes',
        data: {'noteId': noteId, 'status': error.statusCode},
      );
      return _client.updateNote(noteId, {'title': title, ...fallback});
    }
  }

  /// Whether a queued edit may still be sent. A note shared with the account
  /// is read again first, because the grant that allowed the edit when it was
  /// queued may be gone; an account's own note skips the extra request. Caller
  /// holds the note lock. A 404 reads as "may send" so the update's own 404
  /// handling stays the single place for it.
  Future<bool> _mayReplayEdit(NoteRow note) async {
    final accountId = _currentAccountId?.call();
    if (noteRowIsOwnedBy(note, accountId: accountId)) {
      return noteRowWriteAccess(note, accountId: accountId) !=
          NoteWriteAccess.denied;
    }
    // A stored `false` is not final for a shared note: a grant restored since
    // must be seen, so shared notes always ask.
    final Map<String, dynamic>? detail;
    try {
      detail = await _client.getNoteRaw(note.id);
    } on SyncTerminalException catch (error) {
      if (error.statusCode == 403) {
        await _db.notesDao.storeNoteAccessProjection(
          note.id,
          writeAccess: false,
        );
        // The server refused the read as well: the account no longer sees it.
        if (accountId != null && accountId.isNotEmpty) {
          await _db.notesDao.retireNoteReadEvidence(
            note.id,
            accountId: accountId,
          );
        }
        return false;
      }
      rethrow;
    }
    if (detail == null) return true;
    await _db.notesDao.storeNoteAccessProjection(
      note.id,
      writeAccess: detail['write_access'],
      accessGrants: detail['access_grants'],
      readerId: accountId,
    );
    return detail['write_access'] == true;
  }

  // ---- noteDelete (§7.5 analog) ----

  /// Confirms the server delete (404 already-gone is success), then purges the
  /// local rows. 401/403 propagates so the drainer parks the op (rows stay
  /// tombstoned).
  Future<void> pushNoteDelete(String noteId) async {
    await _noteLocks.runExclusive(noteId, () async {
      await _client.deleteNote(noteId);
      await _db.notesDao.purgeReconciledNote(noteId);
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
          // The toggle request already completed. If the follow-up read races
          // a delete or transient 404, do not park a now-stale pin op forever;
          // reconcile will purge a genuinely missing note.
          await _clearNotePinDirty(noteId);
          return;
        }
        livePinned = confirmedRaw['is_pinned'] == true;
      }
      if (livePinned != desired) {
        DebugLogger.warning(
          'pin-confirm-mismatch',
          scope: 'sync/notes',
          data: {'noteId': noteId, 'desired': desired, 'actual': livePinned},
        );
        await _storeNotePinMirror(noteId, livePinned);
        return;
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
    Map<String, dynamic>? serverData,
  }) {
    return _db.transaction(() async {
      await (_db.update(_db.notes)..where((t) => t.id.equals(noteId))).write(
        NotesCompanion(
          serverUpdatedAt: Value(serverUpdatedAt),
          updatedAt: Value(serverUpdatedAt),
          dirtyTitle: clearTitle ? const Value(false) : const Value.absent(),
          dirtyData: clearData ? const Value(false) : const Value.absent(),
          data: serverData == null
              ? const Value.absent()
              : Value(jsonEncode(serverData)),
        ),
      );
    });
  }

  Future<void> _clearNotePinDirty(String noteId) {
    return (_db.update(_db.notes)..where((t) => t.id.equals(noteId))).write(
      const NotesCompanion(dirtyPinned: Value(false)),
    );
  }

  Future<void> _storeNotePinMirror(String noteId, bool isPinned) {
    return (_db.update(_db.notes)..where((t) => t.id.equals(noteId))).write(
      NotesCompanion(
        isPinned: Value(isPinned),
        dirtyPinned: const Value(false),
      ),
    );
  }
}

/// One content save of a note: the update body, and the body to send instead
/// if the server refuses this one.
class _NoteContentSave {
  const _NoteContentSave(this.body, {this.ifRejected});

  final Map<String, dynamic> body;
  final Map<String, dynamic>? ifRejected;
}
