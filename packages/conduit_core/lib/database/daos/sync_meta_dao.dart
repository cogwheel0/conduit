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
class SyncMetaDao extends DatabaseAccessor<AppDatabase>
    with _$SyncMetaDaoMixin {
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

  /// Durable proof that a locally-created chat id was committed as
  /// [serverId]. Unlike a message-id lookup, this relation cannot be inferred
  /// from an unrelated chat that happens to contain the same message id.
  ///
  /// A local id is write-once. Replaying the same remap is idempotent, while a
  /// different destination is an integrity violation: silently overwriting it
  /// would let delayed work for the first chat jump to a newer destination.
  static String chatRemapKey(String localId) => 'chat_remap:$localId';

  Future<String?> getChatRemapTarget(String localId) {
    return getValue(chatRemapKey(localId));
  }

  Future<void> setChatRemapTarget(String localId, String serverId) async {
    await into(syncMeta).insert(
      SyncMetaCompanion.insert(key: chatRemapKey(localId), value: serverId),
      mode: InsertMode.insertOrIgnore,
    );
    final committed = await getChatRemapTarget(localId);
    if (committed == serverId) return;
    throw StateError(
      'Chat remap target is immutable once committed: '
      '$localId -> $committed',
    );
  }

  Future<void> deleteChatRemapTarget(String localId) {
    return (delete(
      syncMeta,
    )..where((t) => t.key.equals(chatRemapKey(localId)))).go();
  }

  Future<void> deleteChatRemapTargetsForServer(String serverId) {
    return (delete(syncMeta)..where(
          (t) =>
              t.key.like(r'chat\_remap:%', escapeChar: '\\') &
              t.value.equals(serverId),
        ))
        .go();
  }

  Future<bool> hasChatRemapTargetForServer(String serverId) async {
    final row =
        await (select(syncMeta)
              ..where(
                (t) =>
                    t.key.like(r'chat\_remap:%', escapeChar: '\\') &
                    t.value.equals(serverId),
              )
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  static String noteRemapKey(String localId) => 'note_remap:$localId';

  Future<String?> getNoteRemapTarget(String localId) {
    return getValue(noteRemapKey(localId));
  }

  Future<void> setNoteRemapTarget(String localId, String serverId) {
    return setValue(noteRemapKey(localId), serverId);
  }

  Future<void> deleteNoteRemapTarget(String localId) {
    return (delete(
      syncMeta,
    )..where((t) => t.key.equals(noteRemapKey(localId)))).go();
  }

  Future<void> deleteNoteRemapTargetsForServer(String serverId) {
    return (delete(syncMeta)
          ..where((t) => t.key.like('note_remap:%') & t.value.equals(serverId)))
        .go();
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
  // never read against each other and never unit-converted (R-09). The
  // seconds-vs-nanoseconds separation is guaranteed by the dedicated
  // [kNotesPullWatermarkKey] constant — used both by these typed accessors and
  // by `NoteAdapter.watermarkKey` on the generic adapter read/write path — so a
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

  /// Last note deletion-reconcile time (§7.5 throttle), SECONDS device clock —
  /// a SCHEDULING gate only, distinct from the chat reconcile gate and from the
  /// nanosecond note watermark (it never feeds merge math, so the unit here is
  /// device-wall-clock seconds, matching [getLastFullReconcileAt]).
  Future<int> getNotesLastFullReconcileAt() async {
    final raw = await getValue('notes_last_full_reconcile_at');
    return int.tryParse(raw ?? '') ?? 0;
  }

  Future<void> setNotesLastFullReconcileAt(int epochSeconds) {
    return setValue('notes_last_full_reconcile_at', '$epochSeconds');
  }
}
