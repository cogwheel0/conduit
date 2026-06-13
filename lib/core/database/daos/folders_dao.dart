import 'dart:convert';

import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/folders.dart';

part 'folders_dao.g.dart';

/// Folder row accessor (CDT-RFC-001 §6, §7.6).
@DriftAccessor(tables: [Folders])
class FoldersDao extends DatabaseAccessor<AppDatabase> with _$FoldersDaoMixin {
  FoldersDao(super.db);

  /// WHERE deleted=false ORDER BY name ASC (existing provider sort still
  /// applies downstream).
  Stream<List<FolderRow>> watchFolders() {
    return (select(folders)
          ..where((t) => t.deleted.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .watch();
  }

  /// Fast-forward LWW replace of the full server folder set (RFC §7.6). One
  /// tx; the folders list endpoint returns ALL folders and no dirty rows
  /// exist in Phase 1, so rows absent from the payload are hard-deleted.
  Future<void> replaceServerFolders(List<Map<String, dynamic>> rawFolders) {
    return transaction(() async {
      final keepIds = <String>{};
      for (final raw in rawFolders) {
        final id = raw['id'];
        if (id is! String || id.isEmpty) continue;
        keepIds.add(id);
        await into(folders).insertOnConflictUpdate(_companionFromRaw(raw));
      }
      if (keepIds.isEmpty) {
        await delete(folders).go();
      } else {
        await (delete(folders)..where((t) => t.id.isNotIn(keepIds))).go();
      }
    });
  }

  /// Single-row variant, one tx.
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
}
