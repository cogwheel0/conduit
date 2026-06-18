import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../sync/note_conflict.dart';
import '../app_database.dart';
import '../mappers/note_mapper.dart';
import '../tables/notes.dart';
import 'outbox_dao.dart';

part 'notes_dao.g.dart';

/// Suffix appended to a conflict-copy note's title (D-11). Kept here as a
/// constant rather than l10n so the PURE merge logic + tests stay
/// localization-free; the UI can re-derive/badge from `isConflictCopy`.
const String kNoteConflictCopySuffix = ' (conflict copy)';

/// Exactly the fields the notes-list UI uses (REQ §10.2 parity): metadata plus
/// a bounded markdown preview. The full `data` blob can be large and is not
/// materialized into Dart for list rows.
class NoteListEntry {
  const NoteListEntry({
    required this.id,
    required this.userId,
    required this.title,
    required this.previewMarkdown,
    required this.createdAt,
    required this.updatedAt,
    required this.isPinned,
    required this.isConflictCopy,
  });

  final String id;
  final String userId;
  final String title;
  final String previewMarkdown;

  /// NANOSECONDS.
  final int createdAt;
  final int updatedAt;
  final bool isPinned;
  final bool isConflictCopy;
}

/// Result of [NotesDao.mergeServerNote]: `mustPush` tells the pull path whether
/// to enqueue a `noteUpdate` (mirrors `ChatMergeWriteResult`).
class NoteMergeWriteResult {
  const NoteMergeWriteResult({required this.kind, required this.mustPush});

  final NoteMergeKind kind;
  final bool mustPush;
}

/// Note row accessor (CDT-RFC-001 Phase 5). Mirrors `ChatsDao` 1:1 minus the
/// message machinery (notes are flat docs).
///
/// NON-NEG 3: every LOCAL mutation writes the row + its outbox op in ONE
/// transaction; the CALLER holds the NOTE lock; the DAO never locks; it uses
/// `attachedDatabase.outboxDao` whose `enqueue` opens no transaction of its own.
@DriftAccessor(tables: [Notes])
class NotesDao extends DatabaseAccessor<AppDatabase> with _$NotesDaoMixin {
  NotesDao(super.db);

  static const Uuid _uuid = Uuid();
  static const int _listPreviewMaxChars = 1000;
  static const String _ownerPredicate = '''
json_valid(raw_extra)
AND (
  CAST(json_extract(raw_extra, '\$.user_id') AS TEXT) = ?
  OR CAST(json_extract(raw_extra, '\$.user.id') AS TEXT) = ?
)
''';

  OutboxDao get _outboxDao => attachedDatabase.outboxDao;

  // ---- list / read ----

  /// NARROW projection (REQ §10.2): returns only list fields plus a bounded
  /// markdown preview. WHERE deleted=false, ORDER BY updatedAt DESC, id ASC.
  Stream<List<NoteListEntry>> watchNotes({required String userId}) {
    final query = customSelect(
      '''
SELECT
  id,
  CAST(
    COALESCE(
      json_extract(raw_extra, '\$.user_id'),
      json_extract(raw_extra, '\$.user.id'),
      ''
    ) AS TEXT
  ) AS note_user_id,
  title,
  created_at,
  updated_at,
  is_pinned,
  is_conflict_copy,
  substr(
    CASE
      WHEN json_valid(data) THEN COALESCE(json_extract(data, '\$.content.md'), '')
      ELSE ''
    END,
    1,
    $_listPreviewMaxChars
  ) AS preview_markdown
FROM notes
WHERE deleted = 0
  AND $_ownerPredicate
ORDER BY updated_at DESC, id ASC
''',
      variables: _ownerVariables(userId),
      readsFrom: {notes},
    );
    return query.watch().map(
      (rows) => rows.map(_entryFromListRow).toList(growable: false),
    );
  }

  /// Full-body note search for the notes screen. Unlike [watchNotes], this is
  /// only used after the user enters a query, so returning full rows for the
  /// bounded result set is acceptable and keeps search from being limited to
  /// the list preview.
  Future<List<NoteRow>> searchNotesByQuery(
    String query, {
    required String userId,
    int limit = 250,
  }) async {
    final trimmed = query.trim().toLowerCase();
    if (trimmed.isEmpty || limit <= 0) return const <NoteRow>[];
    final pattern = '%${_escapeLikePattern(trimmed)}%';

    final rows = await customSelect(
      '''
SELECT *
FROM notes
WHERE deleted = 0
  AND $_ownerPredicate
  AND (
    LOWER(title) LIKE ? ESCAPE '\\'
    OR (
      json_valid(data)
      AND LOWER(COALESCE(json_extract(data, '\$.content.md'), '')) LIKE ? ESCAPE '\\'
    )
  )
ORDER BY updated_at DESC, id ASC
LIMIT ?
''',
      variables: [
        ..._ownerVariables(userId),
        Variable.withString(pattern),
        Variable.withString(pattern),
        Variable.withInt(limit),
      ],
      readsFrom: {notes},
    ).get();

    return rows.map((row) => notes.map(row.data)).toList(growable: false);
  }

  /// Full row, one-shot.
  Future<NoteRow?> getNote(String id) {
    return (select(notes)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Full row, one-shot, restricted to the current authenticated user.
  Future<NoteRow?> getNoteForUser(String id, {required String userId}) async {
    final row = await customSelect(
      '''
SELECT *
FROM notes
WHERE id = ?
  AND deleted = 0
  AND $_ownerPredicate
LIMIT 1
''',
      variables: [Variable.withString(id), ..._ownerVariables(userId)],
      readsFrom: {notes},
    ).getSingleOrNull();
    return row == null ? null : notes.map(row.data);
  }

  /// Resolve a possibly-stale `local:` id to the server id it was remapped to
  /// (or [id] when there is no remap / the target row is absent). Callers take
  /// the note lock on the RESOLVED id — and write/read back with it — so a UI
  /// mutation serializes on the SAME key as concurrent pull/push for the row
  /// (the `*WithOutbox` writers resolve internally too, so a lock taken on the
  /// stale id would otherwise guard a different key than the row it mutates).
  Future<String> resolveNoteRemapTarget(String id) =>
      _resolveLocalRemapTarget(id);

  /// Every non-tombstoned note carrying a SERVER id (`id NOT LIKE 'local:%'`) —
  /// the §7.5 deletion reconcile diff source.
  Future<List<String>> allServerNoteIds() async {
    final query = selectOnly(notes)
      ..addColumns([notes.id])
      ..where(notes.deleted.equals(false) & notes.id.like('local:%').not());
    final rows = await query.get();
    return rows.map((row) => row.read(notes.id)!).toList(growable: false);
  }

  /// Field-LWW pull merge (D-11, non-neg 4) in ONE transaction. Caller holds
  /// the NOTE lock for `serverRaw['id']`.
  ///
  /// Resolution lives in the pure [resolveNoteMerge]; this method performs the
  /// row writes the decision dictates and (on a concurrent data edit) spawns a
  /// conflict-copy note + its `noteCreate` op in the SAME tx — NEVER silently
  /// dropping the local data.
  Future<NoteMergeWriteResult> mergeServerNote({
    required Map<String, dynamic> serverRaw,
  }) {
    final serverId = serverRaw['id'] as String;
    final serverUpdatedAt = asNs(serverRaw['updated_at']) ?? 0;
    return transaction(() async {
      final existing = await getNote(serverId);
      final decision = resolveNoteMerge(
        serverUpdatedAt: serverUpdatedAt,
        local: existing == null
            ? null
            : NoteMergeLocal(
                serverUpdatedAt: existing.serverUpdatedAt,
                deleted: existing.deleted,
                dirtyTitle: existing.dirtyTitle,
                dirtyData: existing.dirtyData,
                dirtyPinned: existing.dirtyPinned,
                isConflictCopy: existing.isConflictCopy,
              ),
      );

      switch (decision.kind) {
        case NoteMergeKind.skipDirtyTombstone:
        case NoteMergeKind.noRemoteChange:
          // Rows untouched; only re-assert push below when needed.
          break;

        case NoteMergeKind.fastForward:
          // Plain server write; preserve the local pin mirror if present (pin
          // is reconciled out-of-band, never via this watermark merge).
          await into(notes).insertOnConflictUpdate(
            serverToNoteRow(serverRaw).copyWith(
              isPinned: existing == null
                  ? const Value.absent()
                  : Value(existing.isPinned),
              dirtyPinned: existing == null
                  ? const Value.absent()
                  : Value(existing.dirtyPinned),
              isConflictCopy: existing == null
                  ? const Value.absent()
                  : Value(existing.isConflictCopy),
              conflictOf: existing == null
                  ? const Value.absent()
                  : Value(existing.conflictOf),
            ),
          );
          break;

        case NoteMergeKind.fieldLww:
          await _writeFieldLww(
            existing: existing!,
            serverRaw: serverRaw,
            serverUpdatedAt: serverUpdatedAt,
            decision: decision,
          );
          break;
      }

      if (decision.mustPush) {
        await _enqueueUpdateIfMissing(serverId);
      }
      return NoteMergeWriteResult(
        kind: decision.kind,
        mustPush: decision.mustPush,
      );
    });
  }

  /// Caller is inside [mergeServerNote]'s transaction. Reasserts a pending
  /// noteUpdate atomically with dirty-flag writes when title/data still owe a
  /// push, unless a noteUpdate/noteCreate already covers this note.
  Future<void> _enqueueUpdateIfMissing(String noteId) async {
    final row = await getNote(noteId);
    if (row == null) return;
    if (!row.dirtyTitle && !row.dirtyData) return;

    final active = await _outboxDao.activeForChat(
      noteId,
      domainKind: OutboxKind.noteUpdate,
    );
    final hasUpdateOrCreate = active.any((op) {
      final kind = OutboxKind.fromName(op.kind);
      return kind == OutboxKind.noteUpdate || kind == OutboxKind.noteCreate;
    });
    if (hasUpdateOrCreate) return;

    await _outboxDao.enqueue(
      kind: OutboxKind.noteUpdate,
      chatId: noteId,
      payload: noteRowToPatch(row, includeData: row.dirtyData),
    );
  }

  /// Writes the canonical row per [decision] and (when concurrent data edit)
  /// spawns the conflict copy + its noteCreate op. Caller's transaction.
  Future<void> _writeFieldLww({
    required NoteRow existing,
    required Map<String, dynamic> serverRaw,
    required int serverUpdatedAt,
    required NoteMergeDecision decision,
  }) async {
    // Spawn the conflict copy BEFORE overwriting the canonical row's local
    // data, so the LOCAL data is captured intact.
    if (decision.spawnConflictCopy) {
      final copyId = 'local:${_uuid.v4()}';
      await into(notes).insert(
        NotesCompanion.insert(
          id: copyId,
          // Local title (+ suffix) preserved on the copy.
          title: existing.title + kNoteConflictCopySuffix,
          data: Value(existing.data),
          meta: Value(existing.meta),
          isPinned: const Value(false),
          createdAt: existing.createdAt,
          updatedAt: existing.updatedAt,
          serverUpdatedAt: const Value(null),
          dirtyTitle: const Value(true),
          dirtyData: const Value(true),
          dirtyPinned: const Value(false),
          deleted: const Value(false),
          rawExtra: Value(existing.rawExtra),
          isConflictCopy: const Value(true),
          conflictOf: Value(existing.id),
        ),
      );
      final copy = await getNote(copyId);
      await _outboxDao.enqueue(
        kind: OutboxKind.noteCreate,
        chatId: copyId,
        contentHash: noteCreateContentHashFromRow(copy!),
      );
    }

    // Canonical row: title/data each follow the field-LWW decision. Conflict
    // copies with dirty data keep their local body instead of forking again.
    final serverRow = serverToNoteRow(serverRaw);
    final mergedUpdatedAt = decision.advanceServerUpdatedAt
        ? serverUpdatedAt
        : existing.updatedAt;
    await (update(notes)..where((t) => t.id.equals(existing.id))).write(
      NotesCompanion(
        title: decision.takeServerTitle
            ? serverRow.title
            : Value(existing.title),
        data: decision.takeServerData ? serverRow.data : Value(existing.data),
        meta: serverRow.meta,
        // Pin mirror is never touched by the title/data merge (WARNING A).
        updatedAt: Value(mergedUpdatedAt),
        serverUpdatedAt: decision.advanceServerUpdatedAt
            ? Value(serverUpdatedAt)
            : const Value.absent(),
        dirtyTitle: Value(decision.canonicalDirtyTitle),
        dirtyData: Value(decision.canonicalDirtyData),
        // rawExtra refreshes from the server (access_grants etc. round-trip).
        rawExtra: serverRow.rawExtra,
      ),
    );
  }

  // ---- local-mutation *WithOutbox (row + op in one tx; caller holds lock) ----

  /// Offline/local create: inserts a `local:<uuid>` row dirty(all)=true,
  /// `serverUpdatedAt=null`, enqueues a `noteCreate` op (empty payload;
  /// title+data reconstructed from the row at push). Caller holds the note
  /// lock for `note` (the new id is on `note`).
  Future<void> insertLocalNoteWithCreateOp({required NotesCompanion note}) {
    if (!note.id.present) {
      throw ArgumentError.value(
        note.id,
        'note.id',
        'insertLocalNoteWithCreateOp requires an explicit id',
      );
    }
    final id = note.id.value;
    return transaction(() async {
      await into(notes).insert(
        note.copyWith(
          serverUpdatedAt: const Value(null),
          dirtyTitle: const Value(true),
          dirtyData: const Value(true),
          dirtyPinned: const Value(false),
          deleted: const Value(false),
        ),
      );
      final row = await getNote(id);
      await _outboxDao.enqueue(
        kind: OutboxKind.noteCreate,
        chatId: id,
        contentHash: noteCreateContentHashFromRow(row!),
      );
    });
  }

  /// Local title/data edit: writes the changed columns, sets `dirtyTitle`/
  /// `dirtyData` per which field changed, bumps `updatedAt` to a LOCAL ns stamp
  /// for list ordering (PROVISIONAL — the server overwrites it on push), and
  /// (when [enqueue]) enqueues a `noteUpdate` carrying the PATCH MAP. Caller
  /// holds the note lock.
  Future<void> updateNoteWithOutbox(
    String id, {
    Value<String> title = const Value.absent(),
    Value<String> data = const Value.absent(),
    required int localUpdatedAtNs,
    required bool enqueue,
  }) {
    return transaction(() async {
      final noteId = await _resolveLocalRemapTarget(id);
      final changed = await (update(notes)..where((t) => t.id.equals(noteId)))
          .write(
            NotesCompanion(
              title: title,
              data: data,
              updatedAt: Value(localUpdatedAtNs),
              dirtyTitle: title.present
                  ? const Value(true)
                  : const Value.absent(),
              dirtyData: data.present
                  ? const Value(true)
                  : const Value.absent(),
            ),
          );
      if (changed == 0) return;
      if (enqueue) {
        // Reconstruct the patch from the just-written row so coalescing sees
        // the latest committed state.
        final row = await getNote(noteId);
        if (row == null) return;
        final patch = noteRowToPatch(row, includeData: data.present);
        await _outboxDao.enqueue(
          kind: OutboxKind.noteUpdate,
          chatId: noteId,
          payload: patch,
        );
      }
    });
  }

  /// Local pin toggle: sets `isPinned`, `dirtyPinned=true`, enqueues a
  /// `notePin` op `{desired: bool}`. Does NOT bump `updatedAt` (the server pin
  /// does not bump it, WARNING A). Caller holds the note lock.
  Future<void> pinNoteWithOutbox(String id, {required bool desiredPinned}) {
    return transaction(() async {
      final noteId = await _resolveLocalRemapTarget(id);
      final changed = await (update(notes)..where((t) => t.id.equals(noteId)))
          .write(
            NotesCompanion(
              isPinned: Value(desiredPinned),
              dirtyPinned: const Value(true),
            ),
          );
      if (changed == 0) return;
      await _outboxDao.enqueue(
        kind: OutboxKind.notePin,
        chatId: noteId,
        payload: <String, dynamic>{'desired': desiredPinned},
      );
    });
  }

  /// Server-confirmed pin mirror write: stores the current per-user pin state
  /// without enqueuing an outbox op or touching title/data watermarks.
  Future<void> storeNotePinMirror(String id, {required bool isPinned}) async {
    final noteId = await _resolveLocalRemapTarget(id);
    await (update(notes)..where((t) => t.id.equals(noteId))).write(
      NotesCompanion(
        isPinned: Value(isPinned),
        dirtyPinned: const Value(false),
      ),
    );
  }

  /// Local delete: tombstones the note (`deleted=true`) and enqueues a
  /// `noteDelete` op. Rows are normally NOT hard-deleted here (tombstone
  /// discipline); the drainer purges on confirm. The exception is a pure-local
  /// create/delete pair that coalesces to no outbox survivor. Caller holds the
  /// note lock.
  Future<void> tombstoneWithOutbox(String id) {
    return transaction(() async {
      final noteId = await _resolveLocalRemapTarget(id);
      final changed = await (update(notes)..where((t) => t.id.equals(noteId)))
          .write(
            const NotesCompanion(
              deleted: Value(true),
              dirtyTitle: Value(false),
              dirtyData: Value(false),
              dirtyPinned: Value(false),
            ),
          );
      if (changed == 0) return;
      final deleteSeq = await _outboxDao.enqueue(
        kind: OutboxKind.noteDelete,
        chatId: noteId,
      );
      if (deleteSeq == -1) {
        // noteCreate + noteDelete coalesced away: the note never reached the
        // server, so no tombstone should remain for reconcile/drain to find.
        await (delete(notes)..where((t) => t.id.equals(noteId))).go();
      }
    });
  }

  /// Pure-local drop of a `local:` note whose create never reached the server:
  /// delete the row + every pending outbox op for it, NO `noteDelete` op.
  /// Caller holds the note lock.
  Future<void> dropLocalNote(String localId) {
    return transaction(() async {
      await attachedDatabase.syncMetaDao.deleteNoteRemapTarget(localId);
      await (delete(
        _outboxDao.outboxOps,
      )..where((t) => t.chatId.equals(localId))).go();
      await (delete(notes)..where((t) => t.id.equals(localId))).go();
    });
  }

  /// §7.5 reconcile purge of a CONFIRMED server-side delete: hard-delete the
  /// row + drop every pending outbox op for it. Caller holds the note lock.
  Future<void> purgeReconciledNote(String id) {
    return transaction(() async {
      await attachedDatabase.syncMetaDao.deleteNoteRemapTarget(id);
      await attachedDatabase.syncMetaDao.deleteNoteRemapTargetsForServer(id);
      await (delete(
        _outboxDao.outboxOps,
      )..where((t) => t.chatId.equals(id))).go();
      await (delete(notes)..where((t) => t.id.equals(id))).go();
    });
  }

  // ---- helpers ----

  Future<String> _resolveLocalRemapTarget(String id) async {
    if (!id.startsWith('local:')) return id;
    final target = await attachedDatabase.syncMetaDao.getNoteRemapTarget(id);
    if (target == null || target.isEmpty) return id;
    final row = await getNote(target);
    return row == null ? id : target;
  }

  NoteListEntry _entryFromListRow(QueryRow row) {
    return NoteListEntry(
      id: row.read<String>('id'),
      userId: row.read<String>('note_user_id'),
      title: row.read<String>('title'),
      previewMarkdown: row.read<String>('preview_markdown'),
      createdAt: row.read<int>('created_at'),
      updatedAt: row.read<int>('updated_at'),
      isPinned: row.read<int>('is_pinned') != 0,
      isConflictCopy: row.read<int>('is_conflict_copy') != 0,
    );
  }

  String _escapeLikePattern(String value) {
    return value
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
  }

  List<Variable<String>> _ownerVariables(String userId) {
    return [Variable.withString(userId), Variable.withString(userId)];
  }

}

/// Decodes an outbox `noteUpdate` patch payload (used by the push handler /
/// coalescer). Tolerant of corrupt JSON.
Map<String, dynamic> decodeNotePatch(String raw) => decodeJsonMap(raw);
