import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/app_cache.dart';

part 'app_cache_dao.g.dart';

/// Accessor for the per-server [AppCache] key-value table (offline-fallback
/// caches: local user, avatar, backend config, tools, default model, models).
@DriftAccessor(tables: [AppCache])
class AppCacheDao extends DatabaseAccessor<AppDatabase> with _$AppCacheDaoMixin {
  AppCacheDao(super.db);

  Future<String?> getValue(String key) async {
    final row = await (select(
      appCache,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> setValue(String key, String value, {int updatedAt = 0}) {
    return into(appCache).insertOnConflictUpdate(
      AppCacheCompanion.insert(key: key, value: value, updatedAt: Value(updatedAt)),
    );
  }

  Future<void> deleteKey(String key) {
    return (delete(appCache)..where((t) => t.key.equals(key))).go();
  }

  Future<void> deleteKeys(Iterable<String> keys) {
    return (delete(appCache)..where((t) => t.key.isIn(keys))).go();
  }
}
