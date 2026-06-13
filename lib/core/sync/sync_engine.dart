import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../features/auth/providers/unified_auth_providers.dart';
import '../database/database_provider.dart';
import '../models/conversation.dart';
import '../persistence/persistence_providers.dart';
import '../providers/app_providers.dart';
import '../services/connectivity_service.dart';
import '../utils/debug_logger.dart';
import 'backoff.dart';
import 'chat_adapter.dart';
import 'chat_locks.dart';
import 'clock.dart';
import 'deletion_reconcile.dart';
import 'id_remapper.dart';
import 'note_adapter.dart';
import 'note_deletion_reconcile.dart';
import 'note_sync.dart';
import 'outbox_drainer.dart';
import 'outbox_task_queue_migrator.dart';
import 'pull_sync.dart';
import 'push_sync.dart';
import 'request_completion_runner_provider.dart';
import 'sync_api_client.dart';
import 'sync_entity_adapter.dart';

part 'sync_engine.g.dart';

/// Debounce window for [SyncEngine.requestPull] (RFC §7.6).
const Duration kSyncPullDebounce = Duration(milliseconds: 300);

enum SyncPhase { idle, running }

/// Engine status surfaced to the UI.
class SyncStatus {
  const SyncStatus({
    this.phase = SyncPhase.idle,
    this.lastSuccessUpdatedAtWatermark,
    this.lastError,
  });

  final SyncPhase phase;

  /// Server epoch seconds of the last successful cycle's watermark.
  final int? lastSuccessUpdatedAtWatermark;
  final String? lastError;
}

/// §9.3 cleanup seam: deletes the legacy Hive conversation/folder caches once
/// the first full pull has committed. Overridable in tests.
@Riverpod(keepAlive: true)
Future<void> Function() legacyConversationCachePurger(Ref ref) {
  return () async {
    final storage = ref.read(optimizedStorageServiceProvider);
    await storage.deleteLegacyConversationCaches();
  };
}

/// Debounced, single-flight pull orchestrator (CDT-RFC-001 §7.6, Phase 1).
///
/// Inert (requestPull logs and returns null) while unauthenticated or while
/// no database/client exists (no active server, reviewer mode).
@Riverpod(keepAlive: true)
class SyncEngine extends _$SyncEngine {
  Timer? _debounce;
  bool _running = false;
  bool _rerunRequested = false;

  /// Owned per notifier instance (which follows db identity via [build]). Wired
  /// into [PullSync]/[PushSync] (the SAME instance, so `remapEvents` is a single
  /// stream) so pull merges can complete the §7.3 createChat crash-heal instead
  /// of duplicating. Disposed with the notifier.
  IdRemapper? _remapper;

  /// The engine's single [OutboxDrainer], built lazily against the current db
  /// (which the notifier identity follows via [build]) and shared by BOTH drain
  /// entry points — the pull cycle ([_runOnce]) and connectivity-regained
  /// ([drainNow]). Caching one instance (rather than `_buildDrainer()` minting a
  /// fresh one per call) is load-bearing: the drainer's single-flight `_draining`
  /// guard and the once-per-process stranded-`inFlight` recovery (`_recovered`)
  /// are PER-INSTANCE. Two instances would each recover independently, so
  /// instance B's `resetInFlightToPending` could re-arm an op instance A has
  /// legitimately claimed and is mid-push on → duplicate server chat / double
  /// send. A single shared instance serializes the two paths through one
  /// `_draining` mutex and runs recovery exactly once.
  OutboxDrainer? _drainer;

  /// The migrator runs at most once per process (it is also internally
  /// idempotent + flag-gated per server, so a re-attempt is a cheap no-op).
  bool _migrated = false;

  /// Completer for the cycle callers are currently joining (debouncing or
  /// queued behind a running cycle).
  Completer<PullResult?>? _joinable;

  @override
  SyncStatus build() {
    // Engine identity follows these dependencies; any change recreates the
    // notifier (pending waiters are released with null).
    ref.watch(appDatabaseProvider);
    ref.watch(syncApiClientProvider);
    ref.watch(isAuthenticatedProvider2);
    ref.watch(chatLocksProvider);
    ref.onDispose(() {
      _debounce?.cancel();
      unawaited(_remapper?.dispose());
      _remapper = null;
      _drainer = null;
      final joinable = _joinable;
      _joinable = null;
      if (joinable != null && !joinable.isCompleted) {
        joinable.complete(null);
      }
    });
    return const SyncStatus();
  }

  bool get _inert =>
      ref.read(appDatabaseProvider) == null ||
      ref.read(syncApiClientProvider) == null ||
      !ref.read(isAuthenticatedProvider2);

  /// The engine's single [IdRemapper] (shared by [PullSync] and [PushSync]).
  /// Lazily built against the current db; null when there is no active db.
  IdRemapper? _ensureRemapper() {
    final db = ref.read(appDatabaseProvider);
    if (db == null) return null;
    return _remapper ??= IdRemapper(db);
  }

  /// Stream of committed local->server id remaps (Wiring C). The route/active
  /// chat consumer (`remapRouteSyncProvider`) listens here to swap ids in place.
  /// Empty (a never-emitting stream) while there is no active db.
  Stream<RemapEvent> get remapEvents =>
      _ensureRemapper()?.remapEvents ?? const Stream<RemapEvent>.empty();

  /// The engine's single [IdRemapper] (the same instance feeding [remapEvents]
  /// and shared with PushSync/PullSync). Exposed for tests to drive a committed
  /// remap and assert the [remapRouteSyncProvider] consumer reacts.
  @visibleForTesting
  IdRemapper? get remapperForTesting => _ensureRemapper();

  /// Connectivity-regained drain (Wiring, §A6/A7): resets backoff on pending
  /// ops then drains. Called from `sync_triggers` on the false->true edge.
  Future<void> drainNow() async {
    if (_inert) return;
    await _ensureDrainer()?.onConnectivityRegained();
  }

  /// Plain outbox drain (no backoff reset). Used by the active-conversation
  /// trigger so a completion deferred because a DIFFERENT chat was foregrounded
  /// (request_completion_runner Option B) runs promptly once the user opens its
  /// chat. Single-flight via the shared drainer's `_draining` guard.
  Future<void> drainOutbox() async {
    if (_inert) return;
    await _ensureDrainer()?.drain();
  }

  /// Single debounced entry point (RFC §7.6). 300 ms debounce; single-flight:
  /// a call during a running cycle sets a rerun flag (storms collapse to <= 1
  /// queued cycle). The returned future completes when the cycle the caller
  /// joined finishes — pull-to-refresh spinners await it.
  Future<PullResult?> requestPull({required String reason}) {
    if (_inert) {
      DebugLogger.log('inert', scope: 'sync/engine', data: {'reason': reason});
      return Future.value(null);
    }
    DebugLogger.log('request', scope: 'sync/engine', data: {'reason': reason});

    final joinable = _joinable ??= Completer<PullResult?>();
    if (_running) {
      // Queued cycle starts as soon as the running one finishes.
      _rerunRequested = true;
    } else {
      _debounce?.cancel();
      _debounce = Timer(kSyncPullDebounce, _startCycle);
    }
    return joinable.future;
  }

  /// Immediate, not debounced; serialization comes from [ChatLocks].
  Future<Conversation?> pullChatNow(String chatId) async {
    if (_inert) {
      DebugLogger.log(
        'inert',
        scope: 'sync/engine',
        data: {'reason': 'pullChatNow', 'chatId': chatId},
      );
      return null;
    }
    final pull = _buildPullSync();
    if (pull == null) return null;
    return pull.pullChat(chatId);
  }

  PullSync? _buildPullSync() {
    final db = ref.read(appDatabaseProvider);
    final client = ref.read(syncApiClientProvider);
    if (db == null || client == null) return null;
    final remapper = _ensureRemapper();
    if (remapper == null) return null;
    return PullSync(
      client: client,
      db: db,
      locks: ref.read(chatLocksProvider),
      remapper: remapper,
    );
  }

  /// Engine-internal: [PushSync] shares the engine's [IdRemapper] so the §7.3
  /// remap stream is single (PullSync crash-heal + PushSync create remap both
  /// emit on it).
  PushSync? _buildPushSync() {
    final db = ref.read(appDatabaseProvider);
    final client = ref.read(syncApiClientProvider);
    if (db == null || client == null) return null;
    final remapper = _ensureRemapper();
    if (remapper == null) return null;
    return PushSync(
      client: client,
      db: db,
      chatLocks: ref.read(chatLocksProvider),
      folderLocks: ref.read(folderLocksProvider),
      clock: ref.read(syncClockProvider),
      remapper: remapper,
    );
  }

  /// Engine-internal: the note pull driver (Phase 5, D-11). Shares the engine's
  /// IdRemapper (the §7.3 remap stream is single) + the SEPARATE noteLocks
  /// domain. Null until db/client/remapper are ready.
  NotePullSync? _buildNotePullSync() {
    final db = ref.read(appDatabaseProvider);
    final client = ref.read(syncApiClientProvider);
    if (db == null || client == null) return null;
    final remapper = _ensureRemapper();
    if (remapper == null) return null;
    return NotePullSync(
      client: client,
      db: db,
      locks: ref.read(noteLocksProvider),
      remapper: remapper,
    );
  }

  /// Engine-internal: the note push handlers (Phase 5). Shares the engine's
  /// IdRemapper + the noteLocks domain.
  NotePushSync? _buildNotePushSync() {
    final db = ref.read(appDatabaseProvider);
    final client = ref.read(syncApiClientProvider);
    if (db == null || client == null) return null;
    final remapper = _ensureRemapper();
    if (remapper == null) return null;
    return NotePushSync(
      client: client,
      db: db,
      noteLocks: ref.read(noteLocksProvider),
      remapper: remapper,
    );
  }

  /// Engine-internal: a [NoteAdapter] for the generic note PULL driver
  /// (`runPullFor`). A fresh instance per cycle is fine — the adapter is
  /// stateless over its injected pull/push/locks; the locks + remapper that
  /// carry cross-cycle state are the shared engine-owned singletons.
  NoteAdapter? _buildNoteAdapterForPull() {
    final notePull = _buildNotePullSync();
    final notePush = _buildNotePushSync();
    if (notePull == null || notePush == null) return null;
    return NoteAdapter(
      pull: notePull,
      push: notePush,
      noteLocks: ref.read(noteLocksProvider),
    );
  }

  /// Engine-internal: the entity adapters that partition the outbox kinds
  /// (CDT-RFC-001 Phase 5 seam). `[ChatAdapter, NoteAdapter]` — the drainer
  /// routes each op to its owning adapter's `pushOp`. Returns null when any
  /// dependency is missing.
  List<SyncEntityAdapter>? _buildAdapters() {
    final pull = _buildPullSync();
    final push = _buildPushSync();
    final notePull = _buildNotePullSync();
    final notePush = _buildNotePushSync();
    if (pull == null ||
        push == null ||
        notePull == null ||
        notePush == null) {
      return null;
    }
    return [
      ChatAdapter(
        pull: pull,
        push: push,
        chatLocks: ref.read(chatLocksProvider),
      ),
      NoteAdapter(
        pull: notePull,
        push: notePush,
        noteLocks: ref.read(noteLocksProvider),
      ),
    ];
  }

  /// Engine-internal: the engine's SINGLE outbox drainer, cached per notifier
  /// instance (db identity, like [_remapper]) so both drain entry points share
  /// one `_draining` mutex and one once-per-process `_recovered` guard. Built
  /// lazily; `isOnline` is the live bool provider read each call; `completion`
  /// is the chat runner injected via the [requestCompletionRunnerProvider] seam.
  /// Returns null (and does NOT cache) until db/client are ready.
  OutboxDrainer? _ensureDrainer() {
    final existing = _drainer;
    if (existing != null) return existing;
    final db = ref.read(appDatabaseProvider);
    final push = _buildPushSync();
    final adapters = _buildAdapters();
    if (db == null || push == null || adapters == null) return null;
    return _drainer = OutboxDrainer(
      db: db,
      chatLocks: ref.read(chatLocksProvider),
      folderLocks: ref.read(folderLocksProvider),
      push: push,
      clock: ref.read(syncClockProvider),
      backoff: ref.read(backoffProvider),
      isOnline: () => ref.read(isOnlineProvider),
      completion: ref.read(requestCompletionRunnerProvider),
      adapters: adapters,
    );
  }

  /// Engine-internal: the one-time legacy Hive task-queue migrator. Built
  /// lazily so it sees the current db/clock/default-model. Internally idempotent
  /// + per-server flag-gated; the engine's [_migrated] guard limits it to a
  /// single ATTEMPT per process.
  OutboxTaskQueueMigrator? _buildMigrator() {
    final db = ref.read(appDatabaseProvider);
    if (db == null) return null;
    return OutboxTaskQueueMigrator(
      db: db,
      hiveBoxes: ref.read(hiveBoxesProvider),
      chatLocks: ref.read(chatLocksProvider),
      clock: ref.read(syncClockProvider),
      resolveDefaultModel: () => ref.read(selectedModelProvider)?.id ?? '',
    );
  }

  /// Engine-internal: the §7.5 deletion reconcile, sharing the engine's
  /// db/client/chatLocks/clock. Its own 24h throttle gates the [background]
  /// reason; [reconcileNow] drives [ReconcileReason.manualRefresh].
  DeletionReconcile? _buildReconcile() {
    final db = ref.read(appDatabaseProvider);
    final client = ref.read(syncApiClientProvider);
    if (db == null || client == null) return null;
    return DeletionReconcile(
      client: client,
      db: db,
      locks: ref.read(chatLocksProvider),
      clock: ref.read(syncClockProvider),
    );
  }

  /// Engine-internal: the §7.5 NOTE deletion reconcile (own throttle key + note
  /// list/probe endpoints + note lock domain). Mirrors [_buildReconcile].
  NoteDeletionReconcile? _buildNoteReconcile() {
    final db = ref.read(appDatabaseProvider);
    final client = ref.read(syncApiClientProvider);
    if (db == null || client == null) return null;
    return NoteDeletionReconcile(
      client: client,
      db: db,
      locks: ref.read(noteLocksProvider),
      clock: ref.read(syncClockProvider),
    );
  }

  /// Manual pull-to-refresh deletion reconcile (bypasses the 24h throttle) for
  /// both chats and notes. Safe to call ad hoc; no-op until db/client are ready.
  Future<void> reconcileNow() async {
    if (_inert) return;
    try {
      await _buildReconcile()?.run(ReconcileReason.manualRefresh);
      await _buildNoteReconcile()?.run(ReconcileReason.manualRefresh);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'reconcile-manual-failed',
        scope: 'sync/engine',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _startCycle() async {
    final joined = _joinable;
    _joinable = null;
    if (joined == null || _running) return;
    _running = true;

    PullResult? result;
    String? lastError;
    try {
      if (ref.mounted) {
        state = SyncStatus(
          phase: SyncPhase.running,
          lastSuccessUpdatedAtWatermark: state.lastSuccessUpdatedAtWatermark,
          lastError: state.lastError,
        );
      }
      result = await _runOnce();
    } catch (error, stackTrace) {
      lastError = error.toString();
      DebugLogger.error(
        'cycle-failed',
        scope: 'sync/engine',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _running = false;
      if (ref.mounted) {
        state = SyncStatus(
          phase: SyncPhase.idle,
          lastSuccessUpdatedAtWatermark: (result?.success ?? false)
              ? await _readWatermark()
              : state.lastSuccessUpdatedAtWatermark,
          lastError:
              lastError ??
              ((result != null && !result.success)
                  ? 'pull failed (${result.failedFetches} fetch failures)'
                  : null),
        );
      }
      if (!joined.isCompleted) {
        joined.complete(result);
      }
      if (_rerunRequested && ref.mounted) {
        _rerunRequested = false;
        if (_joinable != null) {
          unawaited(_startCycle());
        }
      }
    }
  }

  Future<PullResult?> _runOnce() async {
    final db = ref.read(appDatabaseProvider);
    final pull = _buildPullSync();
    if (db == null || pull == null || !ref.read(isAuthenticatedProvider2)) {
      DebugLogger.log(
        'inert',
        scope: 'sync/engine',
        data: {'reason': 'dependencies-changed-mid-cycle'},
      );
      return null;
    }

    final previousWatermark = await db.syncMetaDao.getPullWatermark();
    final result = await pull.run();

    // Phase 5 (D-11): pull NOTES through the generic adapter driver, on the
    // SEPARATE nanosecond `notes_pull_watermark` (R-09 — never compared to the
    // chat seconds watermark; runPullFor reads the adapter's OWN key). A note
    // pull failure must NOT freeze the chat watermark or abort the cycle; it is
    // logged and the idempotent field-LWW merge self-heals next cycle.
    final noteAdapter = _buildNoteAdapterForPull();
    if (noteAdapter != null) {
      try {
        await runPullFor(noteAdapter, db: db);
      } catch (error, stackTrace) {
        DebugLogger.error(
          'note-pull-failed',
          scope: 'sync/engine',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    // A watermark-0 pull is itself a COMPLETE enumeration of the server set,
    // and a watermark-0 DB starts empty (fresh install / post-§9.3 cold pull),
    // so there are no pre-existing local chats for the deletion reconcile to
    // purge right after it. Record it as the last full reconcile so the
    // background reconcile waits a full interval instead of redundantly
    // re-enumerating every page on the very first cycle (§7.5).
    if (result.success && previousWatermark == 0) {
      await db.syncMetaDao.setLastFullReconcileAt(
        ref.read(syncClockProvider).nowEpochSeconds(),
      );
    }

    // §9 step 2 / §11: convert the legacy Hive task queue into rows+ops EXACTLY
    // ONCE per process, BEFORE the first drain, so converted ops are visible to
    // it (the migrator is also internally idempotent + per-server flag-gated).
    if (!_migrated) {
      _migrated = true;
      try {
        await _buildMigrator()?.migrateIfNeeded();
      } catch (error, stackTrace) {
        // A migration abort/error must not abort the pull cycle; it retries
        // next process (the flag is only set after a full conversion pass).
        DebugLogger.error(
          'task-queue-migrate-failed',
          scope: 'sync/engine',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    // Drain the outbox AFTER pull (W: pull-then-push ordering). Errors are
    // caught + logged by the enclosing `_startCycle` try.
    await _ensureDrainer()?.drain();

    // §7.5 deletion reconcile (background reason; its own 24h throttle gates
    // how often it actually enumerates). A failure here must not abort the
    // cycle — it self-throttles and retries on a later cycle.
    try {
      await _buildReconcile()?.run(ReconcileReason.background);
      await _buildNoteReconcile()?.run(ReconcileReason.background);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'reconcile-background-failed',
        scope: 'sync/engine',
        error: error,
        stackTrace: stackTrace,
      );
    }

    final foldersEnabled = result.foldersFeatureEnabled;
    if (foldersEnabled != null && ref.mounted) {
      ref
          .read(foldersFeatureEnabledProvider.notifier)
          .setEnabled(foldersEnabled);
    }

    // §9.3 cleanup: the legacy Hive cache is disposable; delete it exactly
    // once after the first successful full pull.
    if (result.success && previousWatermark == 0 && ref.mounted) {
      final purged = await db.syncMetaDao.getValue('hive_cache_purged');
      if (purged != '1') {
        try {
          await ref.read(legacyConversationCachePurgerProvider)();
          await db.syncMetaDao.setValue('hive_cache_purged', '1');
          DebugLogger.log('hive-cache-purged', scope: 'sync/engine');
        } catch (error, stackTrace) {
          DebugLogger.error(
            'hive-cache-purge-failed',
            scope: 'sync/engine',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }

      // Phase 4 FTS5 population (CDT-RFC-001 §10/§E): build the search index
      // AFTER the first full sync has written chat/message rows. The
      // conversation list already streams from `watchChatList` (it emitted the
      // moment chats landed, before this post-pull step), so populating here is
      // off the first-interactive-render path. Run it unawaited so a large
      // backfill never blocks the cycle's completion / render; `buildFtsIfNeeded`
      // is idempotent + flag-gated, so it retries next cycle on failure (the
      // flag stays unset on error). Errors must NOT abort the cycle.
      unawaited(
        Future.microtask(() async {
          try {
            await db.buildFtsIfNeeded();
          } catch (error, stackTrace) {
            // A server switch / logout can dispose this db while the
            // fire-and-forget build is in flight. That race is expected and
            // harmless (the flag stays unset → the next active db rebuilds);
            // log it at debug, not error, so it isn't mistaken for a real
            // FTS failure.
            if (error.toString().contains('closed')) {
              DebugLogger.log(
                'fts-build-skipped-db-closed',
                scope: 'sync/fts',
              );
            } else {
              DebugLogger.error(
                'fts-build-failed',
                scope: 'sync/fts',
                error: error,
                stackTrace: stackTrace,
              );
            }
          }
        }),
      );
    }
    return result;
  }

  Future<int?> _readWatermark() async {
    final db = ref.read(appDatabaseProvider);
    if (db == null) return null;
    return db.syncMetaDao.getPullWatermark();
  }
}
