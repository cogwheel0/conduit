import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../database/app_database.dart';
import '../utils/debug_logger.dart';
import 'chat_locks.dart';
import 'clock.dart';
import 'pull_sync.dart' show kOpenWebUiChatListPageSize;
import 'sync_api_client.dart';

/// Why a reconcile was requested (CDT-RFC-001 §7.5 throttle).
enum ReconcileReason {
  /// User pulled-to-refresh: always runs, bypassing the 24h throttle.
  manualRefresh,

  /// Background/engine trigger: runs at most once per [kReconcileMinIntervalSeconds].
  background,
}

/// ≤ once / 24h (§7.5) for the background reason.
const int kReconcileMinIntervalSeconds = 86400;

/// Safety valve (§7.5): if more than this fraction of the local server-keyed
/// chats come back as reconcile candidates, abort the whole run rather than
/// risk a mass purge from a server returning 401 for everything (e.g. a
/// token-expiry storm slipping past the auth gate). A genuine bulk
/// server-delete still reconciles on a later run once the set is smaller.
const double kReconcileMaxPurgeFraction = 0.5;

/// Absolute floor below which the fraction valve NEVER trips: a high candidate
/// fraction is only implausible when the candidate COUNT is also meaningful.
/// Without this, a user with one server chat that is genuinely deleted hits
/// `1 > 0.5` and the valve aborts forever — the phantom row would never purge.
/// Small candidate sets are safe to process: the per-candidate confirmed-gone
/// probe + the session-liveness guard are the real token-expiry protection; the
/// fraction valve is only a coarse backstop against an implausibly-large set.
const int kReconcileMinCandidatesForValve = 5;

/// Outcome of one reconcile run (diagnostics + tests).
class ReconcileResult {
  const ReconcileResult({
    required this.ran,
    this.candidates = 0,
    this.purged = 0,
    this.skipped = 0,
    this.aborted = false,
  });

  /// False when the throttle skipped this run entirely (no enumeration done).
  final bool ran;

  /// Local server-keyed chats absent from the complete server id set.
  final int candidates;

  /// Candidates confirmed gone (404/401) and hard-deleted this run.
  final int purged;

  /// Candidates that still existed (pagination gap) or whose probe threw
  /// (transient) — left untouched this run.
  final int skipped;

  /// Safety valve or session-liveness guard tripped. Depending on when the
  /// guard tripped, some earlier confirmed-gone candidates may have purged.
  final bool aborted;
}

/// §7.5 full-ID deletion reconcile.
///
/// Absence from a watermark pull is NOT a delete signal (the watermark loop
/// early-stops). This enumerates the COMPLETE server id set (paged to
/// exhaustion, no `updated_at` cutoff), diffs it against the local
/// server-keyed non-tombstoned chats, and purges a candidate ONLY after a
/// per-chat existence probe confirms a 404/401. Throttled to once per 24h
/// (background) or on demand (manual pull-to-refresh).
///
/// Construction parity with [PullSync]/[PushSync]: constructor injection only,
/// no Riverpod.
class DeletionReconcile {
  DeletionReconcile({
    required SyncApiClient client,
    required AppDatabase db,
    required ConversationLocks locks,
    required SyncClock clock,
  }) : _client = client,
       _db = db,
       _locks = locks,
       _clock = clock;

  final SyncApiClient _client;
  final AppDatabase _db;
  final ConversationLocks _locks;
  final SyncClock _clock;

  /// Runs the reconcile subject to the throttle. On a completed run (not
  /// throttle-skipped, not aborted by the safety valve) the
  /// `last_full_reconcile_at` gate is advanced.
  Future<ReconcileResult> run(ReconcileReason reason) async {
    final now = _clock.nowEpochSeconds();
    if (reason == ReconcileReason.background) {
      final last = await _db.syncMetaDao.getLastFullReconcileAt();
      if (now - last < kReconcileMinIntervalSeconds) {
        DebugLogger.log(
          'reconcile-throttled',
          scope: 'sync/reconcile',
          data: {'last': last, 'now': now},
        );
        return const ReconcileResult(ran: false);
      }
    }

    // 1. Enumerate the COMPLETE server id set: both the main list (pinned +
    //    folders + root, archived excluded server-side) and the archived list,
    //    each paged to EXHAUSTION with NO updated_at cutoff.
    final Set<String> completeServerIds;
    try {
      completeServerIds = await _enumerateCompleteServerIds();
    } catch (error, stackTrace) {
      // A list-page failure makes the id set incomplete; purging against it
      // would false-delete. Abort WITHOUT advancing the throttle so the next
      // trigger retries.
      DebugLogger.error(
        'reconcile-enumerate-failed',
        scope: 'sync/reconcile',
        error: error,
        stackTrace: stackTrace,
      );
      return const ReconcileResult(ran: false);
    }

    // 2. Diff against local server-keyed, non-tombstoned chats.
    final localServerIds = await _db.chatsDao.allServerChatIds();
    final candidates = [
      for (final id in localServerIds)
        if (!completeServerIds.contains(id)) id,
    ];

    if (candidates.isEmpty) {
      await _db.syncMetaDao.setLastFullReconcileAt(now);
      return const ReconcileResult(ran: true);
    }

    // 3. Safety valve against a token-expiry mass-delete: if an implausibly
    //    LARGE candidate set appears (both above an absolute floor AND a large
    //    fraction), abort without purging. The floor keeps a legitimate
    //    small-library deletion (e.g. a user's only chat) from being mistaken
    //    for a mass-delete and blocked forever.
    if (candidates.length >
        math.max(
          kReconcileMinCandidatesForValve,
          localServerIds.length * kReconcileMaxPurgeFraction,
        )) {
      DebugLogger.warning(
        'reconcile-aborted-safety-valve',
        scope: 'sync/reconcile',
        data: {'candidates': candidates.length, 'local': localServerIds.length},
      );
      // Do NOT advance the throttle: this is an abnormal condition that should
      // be retried, not suppressed for 24h.
      return ReconcileResult(
        ran: true,
        candidates: candidates.length,
        aborted: true,
      );
    }

    // 4. Verify the session once before the purge phase, then probe + purge
    //    each candidate under its chat lock. If a probe observes an auth /
    //    terminal failure after the preflight check, stop trusting absence for
    //    the rest of the run and leave the throttle untouched.
    var purged = 0;
    var skipped = 0;
    var sessionDead = false;
    // The vendored GET /chats/{id} returns 401 (not 404) for a genuinely
    // missing/not-owned chat (routers/chats.py:957), so probeChatExists must
    // treat 401 as gone — but a 401 is ALSO what an expired token yields. To
    // keep a token expiry from purging live chats, verify the session is alive
    // once immediately before the purge phase. If it is dead, abort the run
    // without purging or advancing the throttle.
    try {
      await _client.getChatListPage(1);
    } catch (error, stackTrace) {
      DebugLogger.warning(
        'reconcile-aborted-session-dead',
        scope: 'sync/reconcile',
        data: {'candidates': candidates.length},
      );
      DebugLogger.error(
        'reconcile-preflight-failed',
        scope: 'sync/reconcile',
        error: error,
        stackTrace: stackTrace,
      );
      return ReconcileResult(
        ran: true,
        candidates: candidates.length,
        skipped: candidates.length,
        aborted: true,
      );
    }
    for (final id in candidates) {
      if (sessionDead) {
        skipped++;
        continue;
      }
      await _locks.runExclusive(id, () async {
        bool gone;
        try {
          gone = !await _client.probeChatExists(id);
        } catch (error, stackTrace) {
          if (_isTerminalProbeError(error)) {
            DebugLogger.warning(
              'reconcile-aborted-terminal-probe',
              scope: 'sync/reconcile',
              data: {'chatId': id, 'status': _probeStatusCode(error)},
            );
            DebugLogger.error(
              'reconcile-probe-terminal',
              scope: 'sync/reconcile',
              error: error,
              stackTrace: stackTrace,
              data: {'chatId': id},
            );
            sessionDead = true;
            skipped++;
            return;
          }
          // Transient (network/5xx): skip this candidate this run.
          DebugLogger.error(
            'reconcile-probe-error',
            scope: 'sync/reconcile',
            error: error,
            stackTrace: stackTrace,
            data: {'chatId': id},
          );
          skipped++;
          return;
        }
        if (!gone) {
          // Still exists: it was merely absent from pagination (a race/gap).
          skipped++;
          return;
        }
        // Confirmed gone with a verified-live session: purge rows + drop ops.
        await _db.chatsDao.purgeReconciledChat(id);
        purged++;
        DebugLogger.log(
          'reconcile-purged',
          scope: 'sync/reconcile',
          data: {'chatId': id},
        );
      });
    }

    if (sessionDead) {
      return ReconcileResult(
        ran: true,
        candidates: candidates.length,
        purged: purged,
        skipped: skipped,
        aborted: true,
      );
    }

    await _db.syncMetaDao.setLastFullReconcileAt(now);

    DebugLogger.log(
      'reconcile-done',
      scope: 'sync/reconcile',
      data: {
        'candidates': candidates.length,
        'purged': purged,
        'skipped': skipped,
      },
    );
    return ReconcileResult(
      ran: true,
      candidates: candidates.length,
      purged: purged,
      skipped: skipped,
    );
  }

  /// Pages BOTH the main and archived lists to exhaustion (page until a page
  /// returns fewer than [kOpenWebUiChatListPageSize] items), unioning every
  /// id. NO `updated_at` early-stop — every page is read.
  Future<Set<String>> _enumerateCompleteServerIds() async {
    final ids = <String>{};
    await _pageToExhaustion(_client.getChatListPage, ids);
    await _pageToExhaustion(_client.getArchivedChatListPage, ids);
    return ids;
  }

  Future<void> _pageToExhaustion(
    Future<List<Map<String, dynamic>>> Function(int page) fetch,
    Set<String> into,
  ) async {
    var page = 1;
    while (true) {
      final items = await fetch(page);
      final idsBefore = into.length;
      for (final item in items) {
        final id = item['id'];
        if (id is String && id.isNotEmpty) into.add(id);
      }
      if (items.length < kOpenWebUiChatListPageSize) break;
      if (into.length == idsBefore) break;
      page++;
    }
  }

  bool _isTerminalProbeError(Object error) {
    if (error is SyncTerminalException) return true;
    final status = _probeStatusCode(error);
    return status == 401 || status == 403;
  }

  int? _probeStatusCode(Object error) {
    if (error is SyncTerminalException) return error.statusCode;
    if (error is DioException) return error.response?.statusCode;
    return null;
  }
}
