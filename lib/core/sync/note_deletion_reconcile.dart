import 'dart:math' as math;

import '../database/app_database.dart';
import '../utils/debug_logger.dart';
import 'chat_locks.dart';
import 'clock.dart';
import 'deletion_reconcile.dart'
    show
        ReconcileReason,
        ReconcileResult,
        kReconcileMinIntervalSeconds,
        kReconcileMaxPurgeFraction,
        kReconcileMinCandidatesForValve;
import 'sync_api_client.dart';

/// §7.5 deletion reconcile for NOTES — the flat-document analogue of
/// [DeletionReconcile]. Absence from the (single, unpaginated) note list is not
/// a delete signal on its own; a candidate is purged ONLY after [getNoteRaw]
/// confirms it is gone (null). Shares the chat reconcile's throttle interval,
/// safety valve, and session-liveness guard, but under its OWN sync_meta gate
/// key and over the note list/probe endpoints.
///
/// Reuses [ReconcileReason]/[ReconcileResult] from the chat reconcile.
class NoteDeletionReconcile {
  NoteDeletionReconcile({
    required SyncApiClient client,
    required AppDatabase db,
    required NoteLocks locks,
    required SyncClock clock,
  }) : _client = client,
       _db = db,
       _locks = locks,
       _clock = clock;

  final SyncApiClient _client;
  final AppDatabase _db;
  final NoteLocks _locks;
  final SyncClock _clock;

  Future<ReconcileResult> run(ReconcileReason reason) async {
    final now = _clock.nowEpochSeconds();
    if (reason == ReconcileReason.background) {
      final last = await _db.syncMetaDao.getNotesLastFullReconcileAt();
      if (now - last < kReconcileMinIntervalSeconds) {
        DebugLogger.log(
          'note-reconcile-throttled',
          scope: 'sync/reconcile',
          data: {'last': last, 'now': now},
        );
        return const ReconcileResult(ran: false);
      }
    }

    // 1. Enumerate the COMPLETE server note id set. The note list endpoint is
    //    a single unpaginated call returning (items, featureEnabled). A list
    //    failure aborts WITHOUT advancing the throttle so a transient error can
    //    never false-delete; feature-disabled is a completed no-op and advances
    //    the gate so background cycles do not keep probing servers with notes
    //    disabled.
    final Set<String> serverIds;
    final bool featureEnabled;
    try {
      final (items, enabled) = await _client.getNoteListRaw();
      featureEnabled = enabled;
      serverIds = {
        for (final item in items)
          if (item['id'] is String && (item['id'] as String).isNotEmpty)
            item['id'] as String,
      };
    } catch (error, stackTrace) {
      DebugLogger.error(
        'note-reconcile-enumerate-failed',
        scope: 'sync/reconcile',
        error: error,
        stackTrace: stackTrace,
      );
      return const ReconcileResult(ran: false);
    }
    if (!featureEnabled) {
      // Notes feature off is not a deletion of everything. Verify the broader
      // session is alive before advancing the throttle because the notes list
      // endpoint also reports auth loss as featureEnabled=false.
      try {
        await _client.getChatListPage(1);
      } catch (error, stackTrace) {
        DebugLogger.warning(
          'note-reconcile-feature-disabled-session-dead',
          scope: 'sync/reconcile',
          data: {'error': error.toString(), 'stack': stackTrace.toString()},
        );
        return const ReconcileResult(ran: false);
      }
      await _db.syncMetaDao.setNotesLastFullReconcileAt(now);
      return const ReconcileResult(ran: true);
    }

    // 2. Diff against local server-keyed, non-tombstoned notes.
    final localServerIds = await _db.notesDao.allServerNoteIds();
    final candidates = [
      for (final id in localServerIds)
        if (!serverIds.contains(id)) id,
    ];
    if (candidates.isEmpty) {
      await _db.syncMetaDao.setNotesLastFullReconcileAt(now);
      return const ReconcileResult(ran: true);
    }

    // 3. Safety valve: an implausibly-LARGE candidate set (above an absolute
    //    floor AND a large fraction) aborts without purging. The floor keeps a
    //    legitimate small-library note deletion from being mistaken for a
    //    token-expiry mass-delete and blocked forever.
    if (candidates.length >
        math.max(
          kReconcileMinCandidatesForValve,
          localServerIds.length * kReconcileMaxPurgeFraction,
        )) {
      DebugLogger.warning(
        'note-reconcile-aborted-safety-valve',
        scope: 'sync/reconcile',
        data: {'candidates': candidates.length, 'local': localServerIds.length},
      );
      return ReconcileResult(
        ran: true,
        candidates: candidates.length,
        aborted: true,
      );
    }

    // 4. Probe + purge under each note's lock. getNoteRaw returns null only
    //    when the note is gone (404); auth/permission failures throw and abort
    //    the run with no throttle advance. The list fetch above is the single
    //    liveness/feature check for this run; unlike chats, note 404 is not
    //    ambiguous with auth failure, so per-candidate full-list checks would
    //    only add O(library * candidates) work.
    var purged = 0;
    var skipped = 0;
    var sessionDead = false;
    for (final id in candidates) {
      if (sessionDead) {
        skipped++;
        continue;
      }
      await _locks.runExclusive(id, () async {
        bool gone;
        try {
          gone = (await _client.getNoteRaw(id)) == null;
        } on SyncTerminalException catch (error, stackTrace) {
          DebugLogger.warning(
            'note-reconcile-aborted-terminal-probe',
            scope: 'sync/reconcile',
            data: {
              'noteId': id,
              'status': error.statusCode,
              'message': error.message,
            },
          );
          DebugLogger.error(
            'note-reconcile-probe-terminal',
            scope: 'sync/reconcile',
            error: error,
            stackTrace: stackTrace,
            data: {'noteId': id},
          );
          sessionDead = true;
          skipped++;
          return;
        } catch (error, stackTrace) {
          DebugLogger.error(
            'note-reconcile-probe-error',
            scope: 'sync/reconcile',
            error: error,
            stackTrace: stackTrace,
            data: {'noteId': id},
          );
          skipped++;
          return;
        }
        if (!gone) {
          skipped++;
          return;
        }
        await _db.notesDao.purgeReconciledNote(id);
        purged++;
        DebugLogger.log(
          'note-reconcile-purged',
          scope: 'sync/reconcile',
          data: {'noteId': id},
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

    await _db.syncMetaDao.setNotesLastFullReconcileAt(now);
    return ReconcileResult(
      ran: true,
      candidates: candidates.length,
      purged: purged,
      skipped: skipped,
    );
  }
}
