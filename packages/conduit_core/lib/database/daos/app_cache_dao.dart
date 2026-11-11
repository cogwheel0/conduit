import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/app_cache.dart';

part 'app_cache_dao.g.dart';

/// Accessor for the per-server [AppCache] key-value table (offline-fallback
/// caches: local user, avatar, backend config, tools, default model, models).
@DriftAccessor(tables: [AppCache])
class AppCacheDao extends DatabaseAccessor<AppDatabase>
    with _$AppCacheDaoMixin {
  AppCacheDao(super.db);

  Future<String?> getValue(String key) async {
    final row = await (select(
      appCache,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> setValue(String key, String value, {int updatedAt = 0}) {
    return into(appCache).insertOnConflictUpdate(
      AppCacheCompanion.insert(
        key: key,
        value: value,
        updatedAt: Value(updatedAt),
      ),
    );
  }

  Future<void> deleteKey(String key) {
    return (delete(appCache)..where((t) => t.key.equals(key))).go();
  }

  Future<void> deleteKeys(Iterable<String> keys) {
    return (delete(appCache)..where((t) => t.key.isIn(keys))).go();
  }

  /// Sets [key]'s write time without rewriting its value.
  Future<void> touch(String key, {required int updatedAt}) {
    return (update(appCache)..where((t) => t.key.equals(key))).write(
      AppCacheCompanion(updatedAt: Value(updatedAt)),
    );
  }

  /// Keys that start with [prefix], most recently written first. Values are
  /// not read.
  Future<List<String>> keysWithPrefix(String prefix) async {
    final query = selectOnly(appCache)
      ..addColumns([appCache.key])
      ..where(_startsWith(prefix))
      ..orderBy([
        OrderingTerm.desc(appCache.updatedAt),
        OrderingTerm.desc(appCache.key),
      ]);
    return [
      for (final row in await query.get())
        if (row.read(appCache.key) case final String key) key,
    ];
  }

  Future<void> deleteKeysWithPrefix(String prefix) {
    return (delete(appCache)..where((_) => _startsWith(prefix))).go();
  }

  // An exact, case-sensitive prefix match; LIKE would treat `_` and `%` in
  // [prefix] as wildcards and ignore ASCII case.
  Expression<bool> _startsWith(String prefix) =>
      appCache.key.substr(1, prefix.length).equals(prefix);
}
