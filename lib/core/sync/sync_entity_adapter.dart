import 'dart:convert';
import 'dart:math' as math;

import '../database/app_database.dart';
import '../database/daos/outbox_dao.dart';
import '../utils/debug_logger.dart';
import 'chat_locks.dart';

/// Decodes a JSON outbox-op `payload` string to a `Map<String, dynamic>`,
/// returning an empty map when the payload is absent or not a JSON object.
/// Shared by the sync-package adapters/drainer (CDT-RFC-001 Phase 5).
Map<String, dynamic> decodeOutboxPayload(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is Map<String, dynamic>) return decoded;
  if (decoded is Map) return decoded.cast<String, dynamic>();
  return <String, dynamic>{};
}

/// One changed list item in an entity's OWN clock unit (CDT-RFC-001 Phase 5
/// seam). Deliberately MINIMAL: `{id, updatedAt int64}` plus an opaque
/// [envelope] passthrough so a chat list item can carry its archived/lastRead
/// fields without those leaking into the interface (anti-over-abstraction: no
/// requestCompletion, no archived/folders branches here).
class SyncListItem {
  const SyncListItem({
    required this.id,
    required this.updatedAt,
    this.envelope,
  });

  final String id;

  /// THIS entity's clock unit (chat = epoch seconds; note = nanoseconds). The
  /// driver only does `updatedAt > wm - overlap` and `max`; it NEVER converts.
  final int updatedAt;

  /// Opaque per-entity passthrough (e.g. the raw chat list map). The generic
  /// driver never inspects it; only the owning adapter does.
  final Map<String, dynamic>? envelope;
}

/// The honest shared surface of the two real sync entities — chats and notes
/// (CDT-RFC-001 Phase 5). Extracted AFTER both concrete impls existed, per the
/// design's "lift from the two real adapters, never speculatively" rule.
///
/// What is DELIBERATELY absent (each impl owns it, no contortion):
///   * the blob-vs-flat-doc mapper (ChatBlobMapper.blobToRows vs note_mapper) —
///     [mergeServer]/[fetchRaw]/[pushOp] take/return RAW MAPS;
///   * the merge strategy (three-way vs field-LWW+conflict-copy) — both return
///     `bool mustPush` from [mergeServer]; NO mergeStrategy enum;
///   * the clock unit — [pullOverlap] and each [SyncListItem.updatedAt] carry it
///     IMPLICITLY; the driver reads each adapter's OWN [watermarkKey] so the
///     seconds-vs-ns domains never meet (R-09);
///   * chat-only axes (archived sub-loop, folders, requestCompletion) — those
///     stay in a chat-only pre/post path the chat orchestrator runs around
///     [runPullFor], NOT in this interface.
abstract interface class SyncEntityAdapter {
  /// `sync_meta` key for THIS entity's pull watermark. R-09: per-entity-type,
  /// NEVER cross-read (chat `pull_watermark` seconds; note
  /// `notes_pull_watermark` nanoseconds).
  String get watermarkKey;

  /// Overlap window in THIS entity's clock unit (chat: kPullOverlapSeconds;
  /// note: kNotePullOverlapNs). The unit lives ENTIRELY here.
  int get pullOverlap;

  /// THIS entity's lock domain (chatLocks | noteLocks). Separate instances so a
  /// note op never contends a chat op.
  ChatLocks get locks;

  /// True when [kind] is one this adapter executes. The drainer routes by
  /// ownership instead of a hardcoded switch.
  bool ownsKind(OutboxKind kind);

  /// One list page in THIS entity's clock unit, newest-first.
  Future<List<SyncListItem>> getListPage(int page);

  /// The list page size; the driver stops paging when a page returns fewer.
  int get listPageSize;

  /// Full fetch of one entity; null on 404 (or not-ours, treated as gone).
  Future<Map<String, dynamic>?> fetchRaw(String id);

  /// Lock + one-tx merge of one raw server map. Returns `mustPush` (the merge
  /// retained local-dirty content that still owes a push) — exactly
  /// `ChatMergeWriteResult.mustPush` / `NoteMergeWriteResult.mustPush`. The
  /// strategy (three-way vs field-LWW+conflict-copy) lives entirely inside.
  Future<bool> mergeServer(Map<String, dynamic> raw);

  /// Executes one owned outbox op (replaces the drainer's hardcoded per-kind
  /// switch for this adapter's kinds).
  Future<void> pushOp(OutboxOp op);
}

/// Outcome of one generic pull pass over a single adapter's MAIN list.
class AdapterPullResult {
  const AdapterPullResult({
    required this.success,
    required this.changed,
    required this.failedFetches,
    required this.watermarkAdvanced,
    required this.maxSeen,
  });

  final bool success;
  final int changed;
  final int failedFetches;
  final bool watermarkAdvanced;

  /// The highest `updatedAt` observed this pass, in the adapter's clock unit
  /// (the new watermark value when it advanced).
  final int maxSeen;
}

/// Worker-pool fan-out for the generic pull (parity with the chat
/// `kPullFetchConcurrency`).
const int kAdapterPullFetchConcurrency = 4;

/// The GENERIC watermark-delta pull driver, lifted verbatim from
/// `PullSync.run`'s main loop (CDT-RFC-001 §7.1) and parameterized over a
/// [SyncEntityAdapter]. It does ONLY the entity-agnostic spine:
///   list → `updatedAt > watermark - overlap` early-stop → newest-first
///   worker-pool full-fetch → `mergeServer` → watermark advance.
///
/// It reads + writes the adapter's OWN [SyncEntityAdapter.watermarkKey] via the
/// generic `sync_meta` get/setValue, so the chat (seconds) and note
/// (nanoseconds) clocks NEVER meet — seconds-vs-ns is structurally impossible
/// here (R-09). Chat-only axes (archived, folders, crash-heal) are NOT here;
/// the chat orchestrator wraps this call with those as pre/post hooks.
Future<AdapterPullResult> runPullFor(
  SyncEntityAdapter adapter, {
  required AppDatabase db,
}) async {
  final watermark = await _readWatermark(db, adapter.watermarkKey);
  final threshold = watermark - adapter.pullOverlap;
  var maxSeen = watermark;

  // Keyed by id; first occurrence wins (list order is newest-first).
  final changed = <String, SyncListItem>{};

  try {
    var page = 1;
    var stop = false;
    while (!stop) {
      final items = await adapter.getListPage(page);
      for (final item in items) {
        if (item.updatedAt > threshold) {
          changed.putIfAbsent(item.id, () => item);
          maxSeen = math.max(maxSeen, item.updatedAt);
        } else {
          stop = true;
          break;
        }
      }
      if (stop || items.length < adapter.listPageSize) break;
      page++;
    }
  } catch (error, stackTrace) {
    DebugLogger.error(
      'list-page-failed',
      scope: 'sync/pull',
      error: error,
      stackTrace: stackTrace,
      data: {'watermarkKey': adapter.watermarkKey},
    );
    return AdapterPullResult(
      success: false,
      changed: 0,
      failedFetches: 0,
      watermarkAdvanced: false,
      maxSeen: watermark,
    );
  }

  final toFetch = changed.values.toList(growable: false);
  var nextIndex = 0;
  var failedFetches = 0;
  Future<void> worker() async {
    while (true) {
      if (nextIndex >= toFetch.length) return;
      final item = toFetch[nextIndex++];
      try {
        final resp = await adapter.fetchRaw(item.id);
        if (resp == null) continue; // server-deleted: reconcile handles purge.
        await adapter.mergeServer(resp);
      } catch (error, stackTrace) {
        failedFetches++;
        DebugLogger.error(
          'fetch-failed',
          scope: 'sync/pull',
          error: error,
          stackTrace: stackTrace,
          data: {'id': item.id, 'watermarkKey': adapter.watermarkKey},
        );
      }
    }
  }

  await Future.wait([
    for (var i = 0; i < kAdapterPullFetchConcurrency; i++) worker(),
  ]);

  final success = failedFetches == 0;
  final watermarkAdvanced = success && maxSeen > watermark;
  if (success) {
    await _writeWatermark(db, adapter.watermarkKey, maxSeen);
  }
  return AdapterPullResult(
    success: success,
    changed: toFetch.length,
    failedFetches: failedFetches,
    watermarkAdvanced: watermarkAdvanced,
    maxSeen: maxSeen,
  );
}

Future<int> _readWatermark(AppDatabase db, String key) async {
  final raw = await db.syncMetaDao.getValue(key);
  return int.tryParse(raw ?? '') ?? 0;
}

Future<void> _writeWatermark(AppDatabase db, String key, int value) {
  return db.syncMetaDao.setValue(key, '$value');
}
