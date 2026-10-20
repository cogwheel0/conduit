import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';

import 'package:conduit_core/models/folder.dart';

import '../app_database.dart';
import '../mappers/conversation_assembler.dart';
import '../mappers/note_mapper.dart';
import '../tables/folders.dart';
import 'outbox_dao.dart';

part 'folders_dao.g.dart';

/// Top-level server keys that map to TYPED columns; every OTHER key is
/// preserved verbatim in [Folders.rawExtra].
const Set<String> _typedFolderKeys = <String>{
  'id',
  'name',
  'parent_id',
  'created_at',
  'updated_at',
};

/// Folder row accessor (CDT-RFC-001 §6, §7.6).
@DriftAccessor(tables: [Folders])
class FoldersDao extends DatabaseAccessor<AppDatabase> with _$FoldersDaoMixin {
  FoldersDao(super.db);

  OutboxDao get _outboxDao => attachedDatabase.outboxDao;

  /// WHERE deleted=false ORDER BY name ASC (existing provider sort still
  /// applies downstream).
  Stream<List<FolderRow>> watchFolders() {
    return (select(folders)
          ..where((t) => t.deleted.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .watch();
  }

  /// Full row, one-shot.
  Future<FolderRow?> getFolder(String folderId) {
    return (select(
      folders,
    )..where((t) => t.id.equals(folderId))).getSingleOrNull();
  }

  /// DIRTY-AWARE LWW replace of the full server folder set (RFC §7.6). The
  /// folders list endpoint returns ALL folders, so genuine absence from the
  /// payload = a server delete. Unlike the Phase-1 full-replace this respects
  /// local pending state so a not-yet-pushed local edit/create/tombstone is
  /// never clobbered:
  ///   * a folder row with `dirty=true` (local edit/create pending push) is
  ///     SKIPPED — local wins until the push confirms (the cheap-correct gate,
  ///     mirroring chats).
  ///   * a folder row with `deleted=true` (local tombstone pending
  ///     folderDelete) is SKIPPED — never resurrected; the drainer purges on
  ///     confirm.
  ///   * a server folder NOT covered by a dirty/deleted local row is
  ///     upserted server-origin (`dirty=false, deleted=false`).
  ///   * a local row ABSENT from the payload is purged ONLY when it is neither
  ///     dirty nor deleted (a dirty/absent row is a local-create not yet
  ///     pushed and must survive).
  /// One transaction.
  Future<void> replaceServerFolders(List<Map<String, dynamic>> rawFolders) {
    return transaction(() async {
      // Local rows whose pending state must win over the server payload.
      final localById = {
        for (final row in await select(folders).get()) row.id: row,
      };

      final serverIds = <String>{};
      for (final raw in rawFolders) {
        final id = raw['id'];
        if (id is! String || id.isEmpty) continue;
        serverIds.add(id);
        final local = localById[id];
        if (local != null && (local.dirty || local.deleted)) {
          // Local pending edit/create/tombstone wins; leave the row untouched.
          continue;
        }
        await into(folders)
            .insertOnConflictUpdate(_companionFromRaw(raw, local));
      }

      // Purge server-absent rows EXCEPT local pending ones (dirty/deleted).
      for (final local in localById.values) {
        if (serverIds.contains(local.id)) continue;
        if (local.dirty || local.deleted) continue;
        await (delete(folders)..where((t) => t.id.equals(local.id))).go();
      }
    });
  }

  /// Single-row variant, one tx (server-origin, dirty=false).
  Future<void> upsertServerFolder(Map<String, dynamic> rawFolder) {
    return transaction(() async {
      final id = rawFolder['id'];
      if (id is! String || id.isEmpty) return;
      await into(folders).insertOnConflictUpdate(
        _companionFromRaw(rawFolder, await getFolder(id)),
      );
    });
  }

  Future<void> hardDelete(String folderId) {
    return (delete(folders)..where((t) => t.id.equals(folderId))).go();
  }

  /// Server-confirmed folder removal: delete the row and every pending/parked
  /// outbox op for it in one transaction. Caller holds the folder lock.
  Future<void> purgeReconciledFolder(String folderId) {
    return transaction(() async {
      await (delete(
        _outboxDao.outboxOps,
      )..where((t) => t.chatId.equals(folderId))).go();
      await (delete(folders)..where((t) => t.id.equals(folderId))).go();
    });
  }

  // ---- local-mutation variants (CDT-RFC-001 §7.6, mirror chats_dao) -------
  //
  // Each writes its folder row AND enqueues its outbox op in ONE drift
  // transaction so an op can never exist without its row (REQ §7.2.1). The
  // CALLER holds folderLock.runExclusive(folderId); these NEVER lock
  // internally. The enqueue joins the SAME transaction via [OutboxDao.enqueue]
  // (which opens no transaction of its own).

  /// Local folder create-or-edit: writes the folder row `dirty=true` and
  /// enqueues a `folderUpsert` op in one transaction. `serverUpdatedAt` is left
  /// untouched for an existing row; a brand-new `local:` folder inserts with
  /// `serverUpdatedAt = null`. The enqueued payload is exactly the shape
  /// [PushSync.pushFolderUpsert] reads. Caller holds the folder lock.
  ///
  /// [createIfAbsent] drives the push handler's create-vs-update branch (a
  /// `local:` id + createIfAbsent → server create + remap).
  Future<void> upsertFolderWithOutbox({
    required String id,
    String? name,
    Value<String?> parentId = const Value.absent(),
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
    required bool createIfAbsent,
  }) {
    return transaction(() async {
      final existing = await getFolder(id);
      if (existing == null) {
        // Brand-new local folder. rawExtra carries data/meta verbatim.
        final rawExtra = <String, dynamic>{'data': ?data, 'meta': ?meta};
        await into(folders).insert(
          FoldersCompanion.insert(
            id: id,
            name: name ?? '',
            parentId: parentId,
            createdAt: 0,
            updatedAt: 0,
            serverUpdatedAt: const Value(null),
            dirty: const Value(true),
            deleted: const Value(false),
            rawExtra: Value(jsonEncode(rawExtra)),
          ),
        );
      } else {
        // Existing folder edit: overlay provided fields, mark dirty, keep
        // serverUpdatedAt as-is (LWW pull gate keys off dirty).
        final mergedExtra = <String, dynamic>{
          ...decodeJsonMap(existing.rawExtra),
          'data': ?data,
          'meta': ?meta,
        };
        await (update(folders)..where((t) => t.id.equals(id))).write(
          FoldersCompanion(
            name: name == null ? const Value.absent() : Value(name),
            parentId: parentId,
            rawExtra: Value(jsonEncode(mergedExtra)),
            dirty: const Value(true),
          ),
        );
      }

      await _outboxDao.enqueue(
        kind: OutboxKind.folderUpsert,
        chatId: id,
        payload: <String, dynamic>{
          'folderId': id,
          'createIfAbsent': createIfAbsent,
          'name': ?name,
          if (parentId.present) 'parentId': parentId.value,
          'data': ?data,
          'meta': ?meta,
        },
      );
    });
  }

  /// Local edit of some keys of a folder's `data` (project defaults such as
  /// `files` and `model_ids`): overlays [dataPatch] on the row's CURRENT `data`,
  /// marks the row dirty and queues a `folderUpsert` in one transaction. Every
  /// other `data` key, `meta`, `items` and unknown top-level key is left as
  /// stored, so a form opened on an older copy of the folder cannot write its
  /// stale values back.
  ///
  /// The queued body carries ONLY [dataPatch]. The server merges `data` key by
  /// key, so sending the whole map would overwrite what another client changed
  /// in the meantime; the outbox merges two pending patches the same way.
  ///
  /// Access is judged here, on the row as it is when the write commits: a
  /// pull that arrived while the editor was open can have removed the folder or
  /// downgraded a write grant to read. Caller holds the folder lock.
  Future<void> patchFolderDataWithOutbox({
    required String id,
    required Map<String, dynamic> dataPatch,
  }) {
    return transaction(() async {
      final existing = await getFolder(id);
      if (existing == null || existing.deleted) {
        throw const FolderProjectWriteException(
          FolderProjectWriteFailure.unavailable,
        );
      }
      if (!folderFromRow(existing).canWrite) {
        throw const FolderProjectWriteException(
          FolderProjectWriteFailure.readOnly,
        );
      }

      final extra = decodeJsonMap(existing.rawExtra);
      final stored = extra['data'];
      extra['data'] = <String, dynamic>{
        if (stored is Map) ...Map<String, dynamic>.from(stored),
        ...dataPatch,
      };
      await (update(folders)..where((t) => t.id.equals(id))).write(
        FoldersCompanion(
          rawExtra: Value(jsonEncode(extra)),
          dirty: const Value(true),
        ),
      );

      await _outboxDao.enqueue(
        kind: OutboxKind.folderUpsert,
        chatId: id,
        payload: <String, dynamic>{
          'folderId': id,
          'createIfAbsent': false,
          'data': dataPatch,
        },
      );
    });
  }

  /// Notes the server's verdict on this account's write access, read from the
  /// folder's own detail, in the row's `rawExtra` so [patchFolderDataWithOutbox]
  /// judges the next edit by it. A cached `write` grant that the server says no
  /// longer holds therefore refuses the edit.
  ///
  /// Touches only that one key: unsent `data`, `dirty` and the outbox stay as
  /// they are, and the next folder list pull, which carries the grant itself,
  /// replaces it. Caller holds the folder lock.
  Future<void> recordWriteAccess({
    required String id,
    required bool writeAccess,
  }) {
    return transaction(() async {
      final existing = await getFolder(id);
      if (existing == null || existing.deleted) return;
      final extra = decodeJsonMap(existing.rawExtra);
      if (writeAccess) {
        if (extra['write_access'] != false) return;
        extra.remove('write_access');
      } else {
        if (extra['write_access'] == false) return;
        extra['write_access'] = false;
      }
      await (update(folders)..where((t) => t.id.equals(id))).write(
        FoldersCompanion(rawExtra: Value(jsonEncode(extra))),
      );
    });
  }

  /// Keeps the project `data` the server's own copy of a folder holds, which
  /// the folder list never carries (it is the lean listing), so a row filled by
  /// a pull has none until a folder read by id supplies it. [data] is absent
  /// when that answer had no `data` key, which says nothing and changes
  /// nothing; a present null or empty map is the server saying the defaults are
  /// cleared, and replaces what was cached.
  ///
  /// Only `data` of the row is written, server-origin: `dirty`, the outbox,
  /// annotations and every other key stay as they are. [requestedFor] is the
  /// row as it was when the read began, and [serverUpdatedAt] the answer's own
  /// `updated_at`. A row that is gone, deleted, has unsent edits, has had its
  /// `data` changed since [requestedFor], or already knows a newer server copy
  /// than the answer, keeps what it has: a reply that was held up must not
  /// replace a newer edit. Caller holds the folder lock.
  Future<void> recordServerFolderData({
    required FolderRow requestedFor,
    required Value<Map<String, dynamic>?> data,
    required int? serverUpdatedAt,
  }) {
    return transaction(() async {
      if (!data.present) return;
      final current = await getFolder(requestedFor.id);
      if (current == null || current.deleted || current.dirty) return;
      final extra = decodeJsonMap(current.rawExtra);
      const equality = DeepCollectionEquality();
      final atRequest = decodeJsonMap(requestedFor.rawExtra)['data'];
      if (!equality.equals(extra['data'], atRequest)) return;
      final known = current.serverUpdatedAt;
      if (serverUpdatedAt != null && known != null && serverUpdatedAt < known) {
        return;
      }
      if (extra.containsKey('data') &&
          equality.equals(extra['data'], data.value)) {
        return;
      }
      extra['data'] = data.value;
      await (update(folders)..where((t) => t.id.equals(current.id))).write(
        FoldersCompanion(rawExtra: Value(jsonEncode(extra))),
      );
    });
  }

  /// Local folder delete: tombstones the row (`deleted=true, dirty=true`) and
  /// enqueues a `folderDelete` op in one transaction. The row is normally NOT
  /// hard-deleted here (tombstone discipline §7.6); the drainer's
  /// `pushFolderDelete` (delete_contents=false) purges after the server
  /// confirms. The exception is a pure-local create/delete pair that coalesces
  /// to no outbox survivor. Caller holds the folder lock.
  Future<void> tombstoneFolderWithOutbox(String id) {
    return transaction(() async {
      await (update(folders)..where((t) => t.id.equals(id))).write(
        const FoldersCompanion(deleted: Value(true), dirty: Value(true)),
      );
      final deleteSeq = await _outboxDao.enqueue(
        kind: OutboxKind.folderDelete,
        chatId: id,
        payload: <String, dynamic>{'folderId': id},
      );
      if (deleteSeq == -1) {
        // folderUpsert(createIfAbsent) + folderDelete coalesced away: the
        // folder never reached the server, so no tombstone should remain.
        await (delete(folders)..where((t) => t.id.equals(id))).go();
      }
    });
  }

  /// Pure-local drop of a `local:` folder whose create never reached the
  /// server: deletes every pending outbox op for it AND the row, in one
  /// transaction — no `folderDelete` op (the folder never existed
  /// server-side). Mirrors [ChatsDao.dropLocalChat]. Caller holds the folder
  /// lock.
  Future<void> dropLocalFolder(String localId) {
    return transaction(() async {
      await (delete(
        _outboxDao.outboxOps,
      )..where((t) => t.chatId.equals(localId))).go();
      await (delete(folders)..where((t) => t.id.equals(localId))).go();
    });
  }

  /// Projects id/name/parent_id/created_at/updated_at (non-int timestamps ->
  /// 0); rawExtra carries all other keys verbatim (meta, is_expanded, data,
  /// items, unknown); serverUpdatedAt=updated_at; dirty=false, deleted=false.
  ///
  /// The server's folder list is lean: it has no `data` key at all. A raw
  /// folder without one keeps the `data` already cached on [existing] (the
  /// project defaults a read by id or a save put there); an explicit `data`,
  /// null included, replaces it.
  FoldersCompanion _companionFromRaw(
    Map<String, dynamic> raw, [
    FolderRow? existing,
  ]) {
    final createdAt = raw['created_at'];
    final updatedAt = raw['updated_at'];
    final name = raw['name'];
    final parentId = raw['parent_id'];
    final rawExtra = <String, dynamic>{
      for (final entry in raw.entries)
        if (!_typedFolderKeys.contains(entry.key)) entry.key: entry.value,
    };
    if (existing != null && !raw.containsKey('data')) {
      final cached = decodeJsonMap(existing.rawExtra);
      if (cached.containsKey('data')) rawExtra['data'] = cached['data'];
    }
    final updatedAtSeconds = updatedAt is int ? updatedAt : 0;
    return FoldersCompanion.insert(
      id: raw['id'] as String,
      name: name is String ? name : '',
      parentId: Value(parentId is String ? parentId : null),
      createdAt: createdAt is int ? createdAt : 0,
      updatedAt: updatedAtSeconds,
      serverUpdatedAt: Value(updatedAtSeconds),
      dirty: const Value(false),
      deleted: const Value(false),
      rawExtra: Value(jsonEncode(rawExtra)),
    );
  }
}
