import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/sync_meta.dart';

part 'sync_meta_dao.g.dart';

/// Key-value sync bookkeeping accessor (CDT-RFC-001 §6).
///
/// Reserved keys: `pull_watermark`, `last_full_reconcile_at`,
/// `schema_fixture_hash`, and Phase 1 adds `hive_cache_purged` ('1' once the
/// §9.3 cleanup ran).
@DriftAccessor(tables: [SyncMeta])
class SyncMetaDao extends DatabaseAccessor<AppDatabase> with _$SyncMetaDaoMixin {
  SyncMetaDao(super.db);

  Future<String?> getValue(String key) async {
    final row = await (select(
      syncMeta,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> setValue(String key, String value) {
    return into(
      syncMeta,
    ).insertOnConflictUpdate(SyncMetaCompanion.insert(key: key, value: value));
  }

  /// `int.tryParse(sync_meta['pull_watermark']) ?? 0` — epoch seconds,
  /// server clock.
  Future<int> getPullWatermark() async {
    final raw = await getValue('pull_watermark');
    return int.tryParse(raw ?? '') ?? 0;
  }

  Future<void> setPullWatermark(int epochSeconds) {
    return setValue('pull_watermark', '$epochSeconds');
  }
}
