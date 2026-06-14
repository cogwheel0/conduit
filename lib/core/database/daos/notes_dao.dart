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

/// Exactly the fields the notes-list UI uses (REQ §10.2 parity — NEVER `data`,
/// note bodies can be large).
class NoteListEntry {
  const NoteListEntry({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.isPinned,
    required this.isConflictCopy,
  });

  final String id;
  final String title;

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

  OutboxDao get _outboxDao => attachedDatabase.outboxDao;

  // ---- list / read ----

  /// NARROW projection (REQ §10.2): never selects `data`. WHERE deleted=false,
  /// ORDER BY updatedAt DESC, id ASC.
  Stream<List<NoteListEntry>> watchNotes() {
    final query = _listProjection()
      ..where(notes.deleted.equals(false))
      ..orderBy([
        OrderingTerm.desc(notes.updatedAt),
        OrderingTerm.asc(notes.id),
      ]);
    return query.watch().map(
      (rows) => rows.map(_entryFromProjection).toList(growable: false),
    );
  }

  /// Full row, one-shot.
  Future<NoteRow?> getNote(String id) {
    return (select(notes)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Every non-tombstoned note carrying a SERVER id (`id NOT LIKE 'local:%'`) —
  /// the §7.5 deletion reconcile diff source.
  Future<List<String>> allServerNoteIds() async {
    final query = selectOnly(notes)
      ..addColumns([notes.id])
      ..where(notes.deleted.equals(false) & notes.id.like('local:%').not());
    final rows = await query.get();
    return rows.map((row) => row.read(notes.id)!).toList(growable: false);
  }

  // ---- server-origin (NO outbox) ----

  /// Plain server upsert (fast-forward), all dirty flags false. One tx.
  Future<void> upsertServerNote(Map<String, dynamic> serverRaw) {
    return transaction(() async {
      await into(notes).insertOnConflictUpdate(serverToNoteRow(serverRaw));
    });
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
    final serverUpdatedAt = _asNs(serverRaw['updated_at']) ?? 0;
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
          // Rows untouched; only re-assert push.
          return NoteMergeWriteResult(
            kind: decision.kind,
            mustPush: decision.mustPush,
          );

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
            ),
          );
          return NoteMergeWriteResult(
            kind: decision.kind,
            mustPush: decision.mustPush,
          );

        case NoteMergeKind.fieldLww:
          await _writeFieldLww(
            existing: existing!,
            serverRaw: serverRaw,
            serverUpdatedAt: serverUpdatedAt,
            decision: decision,
          );
          return NoteMergeWriteResult(
            kind: decision.kind,
            mustPush: decision.mustPush,
          );
      }
    });
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
          rawExtra: const Value('{}'),
          isConflictCopy: const Value(true),
          conflictOf: Value(existing.id),
        ),
      );
      await _outboxDao.enqueue(kind: OutboxKind.noteCreate, chatId: copyId);
    }

    // Canonical row: server data adopted (takeServerData is always true on the
    // fieldLww branch); title from server unless the local title won.
    final serverRow = serverToNoteRow(serverRaw);
    await (update(notes)..where((t) => t.id.equals(existing.id))).write(
      NotesCompanion(
        title: decision.takeServerTitle
            ? serverRow.title
            : Value(existing.title),
        data: decision.takeServerData ? serverRow.data : Value(existing.data),
        meta: serverRow.meta,
        // Pin mirror is never touched by the title/data merge (WARNING A).
        updatedAt: Value(serverUpdatedAt),
        serverUpdatedAt: decision.advanceServerUpdatedAt
            ? Value(serverUpdatedAt)
            : const Value.absent(),
        dirtyTitle: Value(decision.canonicalDirtyTitle),
        dirtyData: Value(decision.canonicalDirtyData),
        // Defensive: skipDirtyTombstone catches normal pending deletes before
        // this branch, but an abnormal clean tombstone should not stay hidden
        // after adopting a newer server note.
        deleted: const Value(false),
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
      await _outboxDao.enqueue(kind: OutboxKind.noteCreate, chatId: id);
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
    Value<String> meta = const Value.absent(),
    required int localUpdatedAtNs,
    required bool enqueue,
  }) {
    return transaction(() async {
      await (update(notes)..where((t) => t.id.equals(id))).write(
        NotesCompanion(
          title: title,
          data: data,
          meta: meta,
          updatedAt: Value(localUpdatedAtNs),
          dirtyTitle: title.present ? const Value(true) : const Value.absent(),
          dirtyData: data.present ? const Value(true) : const Value.absent(),
        ),
      );
      if (enqueue) {
        // Reconstruct the patch from the just-written row so coalescing sees
        // the latest committed state.
        final row = await getNote(id);
        if (row == null) return;
        final patch = noteRowToPatch(row, includeData: data.present);
        await _outboxDao.enqueue(
          kind: OutboxKind.noteUpdate,
          chatId: id,
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
      await (update(notes)..where((t) => t.id.equals(id))).write(
        NotesCompanion(
          isPinned: Value(desiredPinned),
          dirtyPinned: const Value(true),
        ),
      );
      await _outboxDao.enqueue(
        kind: OutboxKind.notePin,
        chatId: id,
        payload: <String, dynamic>{'desired': desiredPinned},
      );
    });
  }

  /// Local delete: tombstones the note (`deleted=true` + a dirty flag) and
  /// enqueues a `noteDelete` op. Rows are NOT hard-deleted here (tombstone
  /// discipline); the drainer purges on confirm. Caller holds the note lock.
  Future<void> tombstoneWithOutbox(String id) {
    return transaction(() async {
      await (update(notes)..where((t) => t.id.equals(id))).write(
        const NotesCompanion(deleted: Value(true), dirtyData: Value(true)),
      );
      await _outboxDao.enqueue(kind: OutboxKind.noteDelete, chatId: id);
    });
  }

  /// Pure-local drop of a `local:` note whose create never reached the server:
  /// delete the row + every pending outbox op for it, NO `noteDelete` op.
  /// Caller holds the note lock.
  Future<void> dropLocalNote(String localId) {
    return transaction(() async {
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
      await (delete(
        _outboxDao.outboxOps,
      )..where((t) => t.chatId.equals(id))).go();
      await (delete(notes)..where((t) => t.id.equals(id))).go();
    });
  }

  /// Hard delete (used on delete-confirm by `pushNoteDelete`).
  Future<void> hardDelete(String id) {
    return (delete(notes)..where((t) => t.id.equals(id))).go();
  }

  // ---- helpers ----

  JoinedSelectStatement<HasResultSet, dynamic> _listProjection() {
    return selectOnly(notes)..addColumns([
      notes.id,
      notes.title,
      notes.createdAt,
      notes.updatedAt,
      notes.isPinned,
      notes.isConflictCopy,
    ]);
  }

  NoteListEntry _entryFromProjection(TypedResult row) {
    return NoteListEntry(
      id: row.read(notes.id)!,
      title: row.read(notes.title)!,
      createdAt: row.read(notes.createdAt)!,
      updatedAt: row.read(notes.updatedAt)!,
      isPinned: row.read(notes.isPinned)!,
      isConflictCopy: row.read(notes.isConflictCopy)!,
    );
  }

  static int? _asNs(Object? value) => asNs(value);
}

/// Decodes an outbox `noteUpdate` patch payload (used by the push handler /
/// coalescer). Tolerant of corrupt JSON.
Map<String, dynamic> decodeNotePatch(String raw) => decodeJsonMap(raw);
