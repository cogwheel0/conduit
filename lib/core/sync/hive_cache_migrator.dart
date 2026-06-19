import 'dart:convert';

import '../database/app_database.dart';
import '../persistence/hive_boxes.dart';
import '../utils/debug_logger.dart';

/// One-time, per-server migration of the structured caches in the Hive `caches`
/// box (local user, avatar, backend config, tools, default model, models) into
/// the active server's Drift `app_cache` table — PR-2 of the Hive removal.
///
/// Gated by the per-server `sync_meta` flag `hive_caches_migrated` and mirrors
/// [OutboxTaskQueueMigrator]'s idempotency: copy → set flag → delete the Hive
/// keys, abort (flag unset) on any error so the next sync cycle retries.
///
/// Only the ACTIVE server's scoped values migrate (the Hive box is global with
/// per-value `{data, serverId}` wrappers, but only the active server's Drift DB
/// is open). Other servers' caches are dropped — they are re-fetchable
/// offline-fallback caches (CDT-RFC-001 / plan D4). User/avatar were stored
/// unwrapped (global) and migrate into the active server's DB.
class HiveCacheMigrator {
  HiveCacheMigrator({
    required AppDatabase db,
    required HiveBoxes hiveBoxes,
    required Future<String?> Function() resolveActiveServerId,
  }) : _db = db,
       _boxes = hiveBoxes,
       _resolveActiveServerId = resolveActiveServerId;

  final AppDatabase _db;
  final HiveBoxes _boxes;
  final Future<String?> Function() _resolveActiveServerId;

  static const String _flagKey = 'hive_caches_migrated';

  static const List<String> _keys = [
    HiveStoreKeys.localUser,
    HiveStoreKeys.localUserAvatar,
    HiveStoreKeys.localBackendConfig,
    HiveStoreKeys.localTools,
    HiveStoreKeys.localDefaultModel,
    HiveStoreKeys.localModels,
  ];

  Future<void> migrateIfNeeded() async {
    if (await _db.syncMetaDao.getValue(_flagKey) == '1') return;

    final activeServerId = _normalize(await _resolveActiveServerId());
    final box = _boxes.caches;

    for (final key in _keys) {
      final raw = box.get(key);
      if (raw == null) continue;
      final json = _toCacheJson(raw, activeServerId);
      if (json == null) continue;
      await _db.appCacheDao.setValue(key, json);
    }

    // Flag last (idempotency), then delete the migrated Hive keys.
    await _db.syncMetaDao.setValue(_flagKey, '1');
    await Future.wait(_keys.map(box.delete));

    DebugLogger.log(
      'Hive caches → Drift migration completed',
      scope: 'persistence/migration',
    );
  }

  /// Converts a stored Hive caches value into the JSON string `app_cache`
  /// expects, or null to skip (a different server's scoped value, or empty).
  String? _toCacheJson(Object raw, String? activeServerId) {
    Object? data = raw;
    if (raw is Map && raw.containsKey('data')) {
      final owner = raw['serverId'];
      final ownerId = _normalize(owner is String ? owner : null);
      if (ownerId != activeServerId) return null; // other server's cache
      data = raw['data'];
    }
    if (data == null) return null;
    // user/avatar were stored as a plain string (JSON or URL); the wrapped
    // caches' `data` is a Map/List that needs encoding.
    return data is String ? data : jsonEncode(data);
  }

  String? _normalize(String? id) => (id == null || id.isEmpty) ? null : id;
}
