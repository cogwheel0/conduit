import 'dart:convert';

import 'package:drift/drift.dart';

import '../app_database.dart';
import '../mappers/note_mapper.dart';
import '../tables/folders.dart';
import 'outbox_dao.dart';

part 'folders_dao.g.dart';

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
    return (select(folders)..where((t) => t.id.equals(folderId)))
        .getSingleOrNull();
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
        await into(folders).insertOnConflictUpdate(_companionFromRaw(raw));
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
      await into(folders).insertOnConflictUpdate(_companionFromRaw(rawFolder));
    });
  }

  Future<void> hardDelete(String folderId) {
    return (delete(folders)..where((t) => t.id.equals(folderId))).go();
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
    String? parentId,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
    required bool createIfAbsent,
  }) {
    return transaction(() async {
      final existing = await getFolder(id);
      if (existing == null) {
        // Brand-new local folder. rawExtra carries data/meta verbatim.
        final rawExtra = <String, dynamic>{
          'data': ?data,
          'meta': ?meta,
        };
        await into(folders).insert(
          FoldersCompanion.insert(
            id: id,
            name: name ?? '',
            parentId: Value(parentId),
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
          ...(_decodeMap(existing.rawExtra)),
          'data': ?data,
          'meta': ?meta,
        };
        await (update(folders)..where((t) => t.id.equals(id))).write(
          FoldersCompanion(
            name: name == null ? const Value.absent() : Value(name),
            parentId: Value(parentId),
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
          'parentId': ?parentId,
          'data': ?data,
          'meta': ?meta,
        },
      );
    });
  }

  /// Local folder delete: tombstones the row (`deleted=true, dirty=true`) and
  /// enqueues a `folderDelete` op in one transaction. The row is NOT
  /// hard-deleted here (tombstone discipline §7.6); the drainer's
  /// `pushFolderDelete` (delete_contents=false) purges after the server
  /// confirms. Caller holds the folder lock.
  Future<void> tombstoneFolderWithOutbox(String id) {
    return transaction(() async {
      await (update(folders)..where((t) => t.id.equals(id))).write(
        const FoldersCompanion(
          deleted: Value(true),
          dirty: Value(true),
        ),
      );
      await _outboxDao.enqueue(
        kind: OutboxKind.folderDelete,
        chatId: id,
        payload: <String, dynamic>{'folderId': id},
      );
    });
  }

  /// Pure-local drop of a `local:` folder whose create never reached the
  /// server: deletes every pending outbox op for it AND the row, in one
  /// transaction — no `folderDelete` op (the folder never existed
  /// server-side). Mirrors [ChatsDao.dropLocalChat]. Caller holds the folder
  /// lock.
  Future<void> dropLocalFolder(String localId) {
    return transaction(() async {
      await (delete(_outboxDao.outboxOps)
            ..where((t) => t.chatId.equals(localId)))
          .go();
      await (delete(folders)..where((t) => t.id.equals(localId))).go();
    });
  }

  /// Projects id/name/parent_id/created_at/updated_at (non-int timestamps ->
  /// 0); rawExtra carries all other keys verbatim (meta, is_expanded, data,
  /// items, unknown); serverUpdatedAt=updated_at; dirty=false, deleted=false.
  FoldersCompanion _companionFromRaw(Map<String, dynamic> raw) {
    final createdAt = raw['created_at'];
    final updatedAt = raw['updated_at'];
    final name = raw['name'];
    final parentId = raw['parent_id'];
    final rawExtra = <String, dynamic>{
      for (final entry in raw.entries)
        if (entry.key != 'id' &&
            entry.key != 'name' &&
            entry.key != 'parent_id' &&
            entry.key != 'created_at' &&
            entry.key != 'updated_at')
          entry.key: entry.value,
    };
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

  static Map<String, dynamic> _decodeMap(String raw) => decodeJsonMap(raw);
}
