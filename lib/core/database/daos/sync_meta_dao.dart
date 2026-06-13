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

  /// Last full-ID deletion reconcile time (§7.5 throttle). `0` when never run.
  /// This is a SCHEDULING gate (device clock acceptable per the reconcile
  /// contract); it never feeds `serverUpdatedAt` or any merge timestamp.
  Future<int> getLastFullReconcileAt() async {
    final raw = await getValue('last_full_reconcile_at');
    return int.tryParse(raw ?? '') ?? 0;
  }

  Future<void> setLastFullReconcileAt(int epochSeconds) {
    return setValue('last_full_reconcile_at', '$epochSeconds');
  }

  // ---- Phase 5 NOTES watermark (CDT-RFC-001 D-11, R-09) ----
  //
  // The note watermark is stored under a DEDICATED key and is in NANOSECONDS
  // (`time.time_ns()`, vendored `models/notes.py`), NEVER seconds. It is a
  // SEPARATE clock domain from [getPullWatermark] (chats, seconds): the two are
  // never read against each other and never unit-converted (R-09). These typed
  // accessors are the only sanctioned way to touch the note watermark so a
  // caller cannot accidentally feed it the chat watermark.

  /// Reserved `sync_meta` key for the note pull watermark (nanoseconds). Public
  /// so a test can assert it differs from the chat `pull_watermark` key (R-09:
  /// per-entity-type watermarks, never cross-compared).
  static const String kNotesPullWatermarkKey = 'notes_pull_watermark';

  /// `int.tryParse(sync_meta['notes_pull_watermark']) ?? 0` — server
  /// NANOSECONDS. NEVER comparable to [getPullWatermark] (seconds).
  Future<int> getNotesPullWatermark() async {
    final raw = await getValue(kNotesPullWatermarkKey);
    return int.tryParse(raw ?? '') ?? 0;
  }

  /// Stores the note pull watermark in NANOSECONDS (R-09: no unit conversion).
  Future<void> setNotesPullWatermark(int nanoseconds) {
    return setValue(kNotesPullWatermarkKey, '$nanoseconds');
  }
}
