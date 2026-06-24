import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../features/auth/providers/unified_auth_providers.dart';
import '../database/app_database.dart';
import '../database/database_provider.dart';
import '../database/fts/fts_ddl.dart' show kFtsBuiltKey;
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
import 'hive_cache_migrator.dart';
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

  /// Stable, session-independent sink for committed remaps. The per-session
  /// [_remapper] is rebuilt on every dependency rebind and its own stream dies
  /// with it, but [remapRouteSyncProvider] subscribes to [remapEvents] exactly
  /// once at startup. Forwarding each session's remapper into this long-lived
  /// broadcast controller keeps that single subscription live across rebinds
  /// (otherwise post-rebind remaps would be silently dropped and an open chat
  /// route would never swap its local id in place). Never closed — the engine
  /// notifier is keepAlive for the app's lifetime.
  final StreamController<RemapEvent> _remapEvents =
      StreamController<RemapEvent>.broadcast(sync: true);

  /// Forwards the current session's [_remapper] events into [_remapEvents].
  /// Cancelled (and re-established against the new remapper) on every rebind.
  StreamSubscription<RemapEvent>? _remapForward;

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

  AppDatabase? _boundDb;
  SyncApiClient? _boundClient;
  ConversationLocks? _boundChatLocks;
  FolderLocks? _boundFolderLocks;
  NoteLocks? _boundNoteLocks;
  SyncClock? _boundClock;
  Backoff? _boundBackoff;
  RequestCompletionRunner? _boundCompletionRunner;
  bool? _boundAuthenticated;

  /// The migrator runs at most once per process (it is also internally
  /// idempotent + flag-gated per server, so a re-attempt is a cheap no-op).
  bool _migrated = false;
  Future<void>? _migrationInFlight;
  AppDatabase? _migrationDb;

  /// Prevents overlapping fire-and-forget FTS backfills while the durable
  /// `fts_built` flag is still unset.
  bool _ftsBuildInFlight = false;

  /// Completer for the cycle callers are currently joining (debouncing or
  /// queued behind a running cycle).
  Completer<PullResult?>? _joinable;

  /// Monotonic dependency snapshot id. Incremented whenever db/client/auth or
  /// lock/clock/backoff/completion bindings change so in-flight cycles can
  /// abort before crossing work into a different server/session.
  int _sessionEpoch = 0;

  /// Auth-only generation captured by drainers. Unlike [_sessionEpoch], this
  /// stays stable across non-auth dependency refreshes so preserved drainers can
  /// finish same-session work, but flips on login/logout boundaries.
  int _authEpoch = 0;
  bool _disposeHookRegistered = false;
  bool _drainerStaleAfterDrain = false;
  final Map<OutboxDrainer, List<IdRemapper>> _retiredDrainerRemappers =
      <OutboxDrainer, List<IdRemapper>>{};
  final Map<OutboxDrainer, List<StreamSubscription<RemapEvent>>>
  _retiredDrainerRemapForwards =
      <OutboxDrainer, List<StreamSubscription<RemapEvent>>>{};

  @override
  SyncStatus build() {
    _registerDisposeForBuild();
    _bindDependencies(
      db: ref.watch(appDatabaseProvider),
      client: ref.watch(syncApiClientProvider),
      authenticated: ref.watch(isAuthenticatedProvider2),
      chatLocks: ref.watch(chatLocksProvider),
      folderLocks: ref.watch(folderLocksProvider),
      noteLocks: ref.watch(noteLocksProvider),
      clock: ref.watch(syncClockProvider),
      backoff: ref.watch(backoffProvider),
      completionRunner: ref.watch(requestCompletionRunnerProvider),
    );
    return const SyncStatus();
  }

  void _registerDisposeForBuild() {
    if (_disposeHookRegistered) {
      return;
    }
    _disposeHookRegistered = true;
    ref.onDispose(() {
      _disposeHookRegistered = false;
      _resetSessionBoundState(
        completeJoinable: false,
        preserveDrainer: _drainer?.isDraining ?? false,
        preserveMigration: _boundDb != null,
      );
      scheduleMicrotask(() {
        if (ref.mounted) {
          return;
        }
        _disposeSessionBoundState();
      });
    });
  }

  bool _refreshBoundDependencies() {
    if (!ref.mounted) {
      return false;
    }
    _bindDependencies(
      db: ref.read(appDatabaseProvider),
      client: ref.read(syncApiClientProvider),
      authenticated: ref.read(isAuthenticatedProvider2),
      chatLocks: ref.read(chatLocksProvider),
      folderLocks: ref.read(folderLocksProvider),
      noteLocks: ref.read(noteLocksProvider),
      clock: ref.read(syncClockProvider),
      backoff: ref.read(backoffProvider),
      completionRunner: ref.read(requestCompletionRunnerProvider),
    );
    return true;
  }

  void _bindDependencies({
    required AppDatabase? db,
    required SyncApiClient? client,
    required bool authenticated,
    required ConversationLocks chatLocks,
    required FolderLocks folderLocks,
    required NoteLocks noteLocks,
    required SyncClock clock,
    required Backoff backoff,
    required RequestCompletionRunner completionRunner,
  }) {
    final authChanged = _boundAuthenticated != authenticated;
    final dependenciesChanged =
        !identical(_boundDb, db) ||
        !identical(_boundClient, client) ||
        !identical(_boundChatLocks, chatLocks) ||
        !identical(_boundFolderLocks, folderLocks) ||
        !identical(_boundNoteLocks, noteLocks) ||
        !identical(_boundClock, clock) ||
        !identical(_boundBackoff, backoff) ||
        !identical(_boundCompletionRunner, completionRunner) ||
        authChanged;
    if (!dependenciesChanged) {
      // A reactive rebuild can follow an eager _refreshBoundDependencies() call
      // that already updated the snapshot. onDispose cancels the debounce but
      // keeps the joinable, so a no-op build must repair the armed waiter.
      _reschedulePreservedJoinableIfNeeded();
      return;
    }

    final sameDbBinding = identical(_boundDb, db);
    final sameServerBinding = sameDbBinding && identical(_boundClient, client);
    final authenticatedSameSession =
        _boundAuthenticated == true && authenticated;
    final activeDrainer = _drainer?.isDraining ?? false;
    final preserveActiveDrainer =
        sameServerBinding && authenticatedSameSession && activeDrainer;
    final retireActiveDrainerRemapper = activeDrainer && !preserveActiveDrainer;
    final preserveJoinable =
        _joinable != null &&
        !_joinable!.isCompleted &&
        sameServerBinding &&
        db != null &&
        client != null &&
        authenticated;

    _sessionEpoch++;
    if (authChanged) {
      _authEpoch++;
    }
    _resetSessionBoundState(
      completeJoinable: !preserveJoinable,
      preserveDrainer: preserveActiveDrainer,
      preserveRemapper: preserveActiveDrainer,
      retireActiveDrainerRemapper: retireActiveDrainerRemapper,
      preserveMigration: sameDbBinding && db != null,
    );
    _boundDb = db;
    _boundClient = client;
    _boundChatLocks = chatLocks;
    _boundFolderLocks = folderLocks;
    _boundNoteLocks = noteLocks;
    _boundClock = clock;
    _boundBackoff = backoff;
    _boundCompletionRunner = completionRunner;
    _boundAuthenticated = authenticated;
    if (preserveJoinable) {
      _schedulePreservedJoinable();
    }
  }

  void _resetSessionBoundState({
    bool completeJoinable = true,
    bool preserveDrainer = false,
    bool preserveRemapper = false,
    bool retireActiveDrainerRemapper = false,
    bool preserveMigration = false,
  }) {
    _debounce?.cancel();
    _debounce = null;
    if (preserveDrainer) {
      if (retireActiveDrainerRemapper) {
        _retireActiveDrainerRemapperForCleanup();
      }
      _drainerStaleAfterDrain = true;
    } else {
      if (retireActiveDrainerRemapper) {
        _retireActiveDrainerRemapperForCleanup();
      } else if (!preserveRemapper) {
        unawaited(_remapForward?.cancel());
        _remapForward = null;
        unawaited(_remapper?.dispose());
        _remapper = null;
      }
      _drainer = null;
      _drainerStaleAfterDrain = false;
    }
    if (!preserveMigration) {
      _migrated = false;
      if (_migrationInFlight == null) {
        _migrationDb = null;
      }
    }
    _ftsBuildInFlight = false;
    if (completeJoinable) {
      final joinable = _joinable;
      _joinable = null;
      if (joinable != null && !joinable.isCompleted) {
        joinable.complete(null);
      }
    }
    if (!_running) {
      _rerunRequested = false;
    }
  }

  void _schedulePreservedJoinable() {
    if (_joinable == null) {
      return;
    }
    if (_running) {
      assert(
        _joinable != null && !_joinable!.isCompleted,
        'A queued rerun requires a live joinable.',
      );
      // The current cycle already captured its own completer in _startCycle.
      // If the epoch change aborts that cycle, those callers receive null.
      // This preserved _joinable belongs to callers that queued a rerun while
      // the cycle was active; the finally block below will start their cycle.
      // Until that finally block runs, future reset paths must not clear
      // _joinable without also completing it or clearing _rerunRequested.
      _rerunRequested = true;
      return;
    }
    assert(_debounce == null);
    if (_debounce != null) {
      return;
    }
    _debounce = Timer(kSyncPullDebounce, _startCycle);
  }

  void _reschedulePreservedJoinableIfNeeded() {
    final joinable = _joinable;
    if (joinable == null ||
        joinable.isCompleted ||
        _debounce != null ||
        _inert) {
      return;
    }
    _schedulePreservedJoinable();
  }

  void _disposeSessionBoundState() {
    final activeDrainer = _drainer?.isDraining ?? false;
    _resetSessionBoundState(
      preserveDrainer: activeDrainer,
      retireActiveDrainerRemapper: activeDrainer,
    );
    if (!activeDrainer) {
      _disposeRetiredDrainerRemappers();
    }
    _boundDb = null;
    _boundClient = null;
    _boundChatLocks = null;
    _boundFolderLocks = null;
    _boundNoteLocks = null;
    _boundClock = null;
    _boundBackoff = null;
    _boundCompletionRunner = null;
    _boundAuthenticated = null;
  }

  bool _cycleStillBound(int epoch, String checkpoint) {
    if (!ref.mounted || epoch != _sessionEpoch) {
      DebugLogger.log(
        'cycle-aborted-dependencies-changed',
        scope: 'sync/engine',
        data: {'checkpoint': checkpoint},
      );
      return false;
    }
    return true;
  }

  bool get _inert =>
      _boundDb == null || _boundClient == null || _boundAuthenticated != true;

  /// The engine's single [IdRemapper] (shared by [PullSync] and [PushSync]).
  /// Lazily built against the current db; null when there is no active db.
  IdRemapper? _ensureRemapper() {
    final db = _boundDb;
    if (db == null) return null;
    final existing = _remapper;
    if (existing != null) return existing;
    final remapper = IdRemapper(db);
    _remapForward = remapper.remapEvents.listen(_remapEvents.add);
    return _remapper = remapper;
  }

  /// Stream of committed local->server id remaps (Wiring C). The route/active
  /// chat consumer (`remapRouteSyncProvider`) listens here to swap ids in place.
  /// Backed by a long-lived controller ([_remapEvents]) so the consumer's single
  /// startup subscription survives session rebinds that replace [_remapper].
  Stream<RemapEvent> get remapEvents => _remapEvents.stream;

  /// The engine's single [IdRemapper] (the same instance feeding [remapEvents]
  /// and shared with PushSync/PullSync). Exposed for tests to drive a committed
  /// remap and assert the [remapRouteSyncProvider] consumer reacts.
  @visibleForTesting
  IdRemapper? get remapperForTesting => _ensureRemapper();

  @visibleForTesting
  bool get hasCachedDrainerForTesting => _drainer != null;

  @visibleForTesting
  bool get hasCachedRemapperForTesting => _remapper != null;

  @visibleForTesting
  void Function()? legacyMigrationJoinObserverForTesting;

  /// Connectivity-regained drain (Wiring, §A6/A7): resets backoff on pending
  /// ops then drains. Called from `sync_triggers` on the false->true edge.
  Future<void> drainNow() async {
    if (!_refreshBoundDependencies()) return;
    if (_inert) return;
    await _migrateLegacyTaskQueueIfNeeded();
    final drainer = _ensureDrainer();
    if (drainer == null) return;
    try {
      await drainer.onConnectivityRegained();
    } finally {
      _clearStaleDrainerIfIdle(drainer);
    }
  }

  /// Plain outbox drain (no backoff reset). Used by the active-conversation
  /// trigger so a completion deferred because a DIFFERENT chat was foregrounded
  /// (request_completion_runner Option B) runs promptly once the user opens its
  /// chat. Single-flight via the shared drainer's `_draining` guard.
  Future<void> drainOutbox() async {
    if (!_refreshBoundDependencies()) return;
    if (_inert) return;
    await _migrateLegacyTaskQueueIfNeeded();
    final drainer = _ensureDrainer();
    if (drainer == null) return;
    try {
      await drainer.drain();
    } finally {
      _clearStaleDrainerIfIdle(drainer);
    }
  }

  /// Single debounced entry point (RFC §7.6). 300 ms debounce; single-flight:
  /// a call during a running cycle sets a rerun flag (storms collapse to <= 1
  /// queued cycle). The returned future completes when the cycle the caller
  /// joined finishes — pull-to-refresh spinners await it.
  Future<PullResult?> requestPull({required String reason}) {
    if (!_refreshBoundDependencies()) {
      return Future.value(null);
    }
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
    if (!_refreshBoundDependencies()) return null;
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
    final db = _boundDb;
    final client = _boundClient;
    final chatLocks = _boundChatLocks;
    if (db == null || client == null || chatLocks == null) return null;
    final remapper = _ensureRemapper();
    if (remapper == null) return null;
    return PullSync(
      client: client,
      db: db,
      locks: chatLocks,
      remapper: remapper,
    );
  }

  /// Engine-internal: [PushSync] shares the engine's [IdRemapper] so the §7.3
  /// remap stream is single (PullSync crash-heal + PushSync create remap both
  /// emit on it).
  PushSync? _buildPushSync() {
    final db = _boundDb;
    final client = _boundClient;
    final chatLocks = _boundChatLocks;
    final folderLocks = _boundFolderLocks;
    final clock = _boundClock;
    if (db == null ||
        client == null ||
        chatLocks == null ||
        folderLocks == null ||
        clock == null) {
      return null;
    }
    final remapper = _ensureRemapper();
    if (remapper == null) return null;
    return PushSync(
      client: client,
      db: db,
      chatLocks: chatLocks,
      folderLocks: folderLocks,
      clock: clock,
      remapper: remapper,
    );
  }

  /// Engine-internal: the note pull driver (Phase 5, D-11). Shares the engine's
  /// IdRemapper (the §7.3 remap stream is single) + the SEPARATE noteLocks
  /// domain. Null until db/client/remapper are ready.
  NotePullSync? _buildNotePullSync({int? sessionEpoch}) {
    final db = _boundDb;
    final client = _boundClient;
    final noteLocks = _boundNoteLocks;
    if (db == null || client == null || noteLocks == null) return null;
    final remapper = _ensureRemapper();
    if (remapper == null) return null;
    final boundSessionEpoch = sessionEpoch ?? _sessionEpoch;
    return NotePullSync(
      client: client,
      db: db,
      locks: noteLocks,
      remapper: remapper,
      onFeatureEnabled: (enabled) {
        if (!ref.mounted) return;
        if (boundSessionEpoch != _sessionEpoch) return;
        ref.read(notesFeatureEnabledProvider.notifier).setEnabled(enabled);
      },
    );
  }

  /// Engine-internal: the note push handlers (Phase 5). Shares the engine's
  /// IdRemapper + the noteLocks domain.
  NotePushSync? _buildNotePushSync() {
    final db = _boundDb;
    final client = _boundClient;
    final noteLocks = _boundNoteLocks;
    if (db == null || client == null || noteLocks == null) return null;
    final remapper = _ensureRemapper();
    if (remapper == null) return null;
    return NotePushSync(
      client: client,
      db: db,
      noteLocks: noteLocks,
      remapper: remapper,
    );
  }

  /// Engine-internal: a [NoteAdapter] for the generic note PULL driver
  /// (`runPullFor`). A fresh instance per cycle is fine — the adapter is
  /// stateless over its injected pull/push/locks; the locks + remapper that
  /// carry cross-cycle state are the shared engine-owned singletons.
  NoteAdapter? _buildNoteAdapterForPull(int sessionEpoch) {
    final notePull = _buildNotePullSync(sessionEpoch: sessionEpoch);
    final notePush = _buildNotePushSync();
    if (notePull == null || notePush == null) return null;
    return NoteAdapter(pull: notePull, push: notePush);
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
    if (pull == null || push == null || notePull == null || notePush == null) {
      return null;
    }
    return [
      ChatAdapter(pull: pull, push: push),
      NoteAdapter(pull: notePull, push: notePush),
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
    if (existing != null) {
      if (_drainerStaleAfterDrain && !existing.isDraining) {
        _drainer = null;
        _drainerStaleAfterDrain = false;
      } else {
        return existing;
      }
    }
    final db = _boundDb;
    final client = _boundClient;
    final clock = _boundClock;
    final backoff = _boundBackoff;
    final completion = _boundCompletionRunner;
    // The drainer pushes through the PushSync instances embedded in adapters;
    // _buildAdapters() already builds (and null-guards on) PushSync internally,
    // so a separate _buildPushSync() here would be a discarded duplicate.
    final adapters = _buildAdapters();
    if (db == null ||
        client == null ||
        clock == null ||
        backoff == null ||
        completion == null ||
        adapters == null) {
      return null;
    }
    final drainerAuthEpoch = _authEpoch;
    final drainerDb = db;
    final drainerClient = client;
    final drainerChatLocks = _boundChatLocks;
    final drainerFolderLocks = _boundFolderLocks;
    final drainerNoteLocks = _boundNoteLocks;
    final drainerClock = clock;
    final drainerBackoff = backoff;
    final drainerCompletion = completion;
    final drainerRemapper = _remapper;
    return _drainer = OutboxDrainer(
      db: db,
      clock: clock,
      backoff: backoff,
      isOnline: () =>
          ref.mounted &&
          identical(_boundDb, drainerDb) &&
          identical(_boundClient, drainerClient) &&
          identical(_boundChatLocks, drainerChatLocks) &&
          identical(_boundFolderLocks, drainerFolderLocks) &&
          identical(_boundNoteLocks, drainerNoteLocks) &&
          identical(_boundClock, drainerClock) &&
          identical(_boundBackoff, drainerBackoff) &&
          identical(_boundCompletionRunner, drainerCompletion) &&
          identical(_remapper, drainerRemapper) &&
          _boundAuthenticated == true &&
          _authEpoch == drainerAuthEpoch &&
          ref.read(isOnlineProvider),
      completion: completion,
      adapters: adapters,
    );
  }

  void _clearStaleDrainerIfIdle(OutboxDrainer drainer) {
    final hasRetiredRemappers =
        _retiredDrainerRemappers[drainer]?.isNotEmpty ?? false;
    final hasRetiredForwards =
        _retiredDrainerRemapForwards[drainer]?.isNotEmpty ?? false;
    if (hasRetiredRemappers || hasRetiredForwards) {
      if (drainer.isDraining) {
        return;
      }
      _disposeRetiredDrainerRemappersFor(drainer);
    }
    if (!identical(_drainer, drainer) ||
        !_drainerStaleAfterDrain ||
        drainer.isDraining) {
      return;
    }
    _drainer = null;
    _drainerStaleAfterDrain = false;
  }

  void _retireActiveDrainerRemapperForCleanup() {
    final drainer = _drainer;
    final remapper = _remapper;
    final forward = _remapForward;
    if (drainer != null && remapper != null) {
      (_retiredDrainerRemappers[drainer] ??= <IdRemapper>[]).add(remapper);
      if (forward != null) {
        (_retiredDrainerRemapForwards[drainer] ??=
                <StreamSubscription<RemapEvent>>[])
            .add(forward);
      }
    } else {
      unawaited(forward?.cancel());
      unawaited(remapper?.dispose());
    }
    _remapForward = null;
    _remapper = null;
  }

  void _disposeRetiredDrainerRemappers() {
    if (_retiredDrainerRemappers.isEmpty &&
        _retiredDrainerRemapForwards.isEmpty) {
      return;
    }
    final drainers = <OutboxDrainer>{
      ..._retiredDrainerRemappers.keys,
      ..._retiredDrainerRemapForwards.keys,
    };
    for (final drainer in drainers) {
      if (!drainer.isDraining) {
        _disposeRetiredDrainerRemappersFor(drainer);
      }
    }
  }

  void _disposeRetiredDrainerRemappersFor(OutboxDrainer drainer) {
    final remappers =
        _retiredDrainerRemappers.remove(drainer) ?? const <IdRemapper>[];
    final forwards =
        _retiredDrainerRemapForwards.remove(drainer) ??
        const <StreamSubscription<RemapEvent>>[];
    for (final forward in forwards) {
      unawaited(forward.cancel());
    }
    for (final remapper in remappers) {
      unawaited(remapper.dispose());
    }
  }

  /// Engine-internal: the one-time legacy Hive task-queue migrator. Built
  /// lazily so it sees the current db/clock/default-model. Internally idempotent
  /// + per-server flag-gated; the engine's [_migrated] guard limits it to a
  /// single successful attempt per process.
  OutboxTaskQueueMigrator? _buildMigrator() {
    final db = _boundDb;
    final chatLocks = _boundChatLocks;
    final clock = _boundClock;
    if (db == null || chatLocks == null || clock == null) return null;
    return OutboxTaskQueueMigrator(
      db: db,
      hiveBoxes: ref.read(hiveBoxesProvider),
      chatLocks: chatLocks,
      clock: clock,
      resolveDefaultModel: () => ref.read(selectedModelProvider)?.id ?? '',
    );
  }

  /// Engine-internal: the one-time per-server Hive caches → Drift `app_cache`
  /// migration (PR-2 of the Hive removal). Built lazily so it sees the current
  /// active DB; internally idempotent + per-server flag-gated.
  HiveCacheMigrator? _buildCacheMigrator() {
    final db = _boundDb;
    if (db == null) return null;
    return HiveCacheMigrator(
      db: db,
      hiveBoxes: ref.read(hiveBoxesProvider),
      resolveActiveServerId: () =>
          ref.read(optimizedStorageServiceProvider).getActiveServerId(),
    );
  }

  /// §9 step 2 / §11: convert the legacy Hive task queue into rows+ops EXACTLY
  /// ONCE per process, BEFORE any drain entry point can consume the outbox.
  Future<void> _migrateLegacyTaskQueueIfNeeded() async {
    while (true) {
      if (_migrated) return;
      final db = _boundDb;
      if (db == null) return;
      final inFlight = _migrationInFlight;
      if (inFlight != null) {
        final inFlightDb = _migrationDb;
        legacyMigrationJoinObserverForTesting?.call();
        await inFlight;
        if (_migrated && identical(inFlightDb, db) && identical(_boundDb, db)) {
          return;
        }
        continue;
      }

      late final Future<void> migration;
      migration = _runLegacyTaskQueueMigration(migrationDb: db).whenComplete(
        () {
          if (identical(_migrationInFlight, migration)) {
            _migrationInFlight = null;
            _migrationDb = null;
          }
        },
      );
      _migrationInFlight = migration;
      _migrationDb = db;
      await migration;
      if (identical(_boundDb, db)) {
        return;
      }
    }
  }

  Future<void> _runLegacyTaskQueueMigration({
    required AppDatabase migrationDb,
  }) async {
    try {
      final taskQueueMigrator = _buildMigrator();
      await taskQueueMigrator?.migrateIfNeeded();
      if (!identical(_boundDb, migrationDb)) {
        return;
      }
      final cacheMigrator = _buildCacheMigrator();
      await cacheMigrator?.migrateIfNeeded();
      if (identical(_boundDb, migrationDb)) {
        _migrated = true;
      }
    } catch (error, stackTrace) {
      // A migration abort/error must not abort the triggering drain/cycle; it
      // retries next time. The process guard is set only after the migrator
      // returns, and the durable flag is set only after a full conversion pass.
      DebugLogger.error(
        'task-queue-migrate-failed',
        scope: 'sync/engine',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Engine-internal: the §7.5 deletion reconcile, sharing the engine's
  /// db/client/chatLocks/clock. Its own 24h throttle gates the [background]
  /// reason; [reconcileNow] drives [ReconcileReason.manualRefresh].
  DeletionReconcile? _buildReconcile() {
    final db = _boundDb;
    final client = _boundClient;
    final chatLocks = _boundChatLocks;
    final clock = _boundClock;
    if (db == null || client == null || chatLocks == null || clock == null) {
      return null;
    }
    return DeletionReconcile(
      client: client,
      db: db,
      locks: chatLocks,
      clock: clock,
    );
  }

  /// Engine-internal: the §7.5 NOTE deletion reconcile (own throttle key + note
  /// list/probe endpoints + note lock domain). Mirrors [_buildReconcile].
  NoteDeletionReconcile? _buildNoteReconcile() {
    final db = _boundDb;
    final client = _boundClient;
    final noteLocks = _boundNoteLocks;
    final clock = _boundClock;
    if (db == null || client == null || noteLocks == null || clock == null) {
      return null;
    }
    return NoteDeletionReconcile(
      client: client,
      db: db,
      locks: noteLocks,
      clock: clock,
    );
  }

  /// Manual pull-to-refresh deletion reconcile (bypasses the 24h throttle) for
  /// both chats and notes. Safe to call ad hoc; no-op until db/client are ready.
  Future<void> reconcileNow() async {
    if (!_refreshBoundDependencies()) return;
    if (_inert) return;
    // Independent try/catch per entity: an unexpected error from the chat
    // reconcile must NOT skip the note reconcile (and vice versa).
    try {
      await _buildReconcile()?.run(ReconcileReason.manualRefresh);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'reconcile-manual-failed',
        scope: 'sync/engine',
        error: error,
        stackTrace: stackTrace,
      );
    }
    try {
      await _buildNoteReconcile()?.run(ReconcileReason.manualRefresh);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'note-reconcile-manual-failed',
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
    final cycleEpoch = _sessionEpoch;
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
      result = await _runOnce(cycleEpoch);
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
      _clearCachedDrainerIfIdle();
      if (ref.mounted) {
        final previousStateWatermark = state.lastSuccessUpdatedAtWatermark;
        var watermark = previousStateWatermark;
        if (result?.success ?? false) {
          try {
            watermark =
                (await _readWatermark(cycleEpoch)) ?? previousStateWatermark;
          } catch (error, stackTrace) {
            DebugLogger.error(
              'watermark-state-read-failed',
              scope: 'sync/engine',
              error: error,
              stackTrace: stackTrace,
            );
          }
        }
        state = SyncStatus(
          phase: SyncPhase.idle,
          lastSuccessUpdatedAtWatermark: watermark,
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

  Future<PullResult?> _runOnce(int cycleEpoch) async {
    final db = _boundDb;
    final clock = _boundClock;
    final pull = _buildPullSync();
    if (db == null ||
        clock == null ||
        pull == null ||
        _boundAuthenticated != true) {
      DebugLogger.log(
        'inert',
        scope: 'sync/engine',
        data: {'reason': 'dependencies-changed-mid-cycle'},
      );
      return null;
    }

    final previousWatermark = await db.syncMetaDao.getPullWatermark();
    if (!_cycleStillBound(cycleEpoch, 'after-watermark-read')) return null;

    final result = await pull.run();
    if (!_cycleStillBound(cycleEpoch, 'after-chat-pull')) return null;

    // Phase 5 (D-11): pull NOTES through the generic adapter driver, on the
    // SEPARATE nanosecond `notes_pull_watermark` (R-09 — never compared to the
    // chat seconds watermark; runPullFor reads the adapter's OWN key). A note
    // pull failure must NOT freeze the chat watermark or abort the cycle; it is
    // logged and the idempotent field-LWW merge self-heals next cycle.
    final noteAdapter = _buildNoteAdapterForPull(cycleEpoch);
    AdapterPullResult? noteResult;
    int? previousNotesWatermark;
    if (noteAdapter != null) {
      try {
        previousNotesWatermark = await db.syncMetaDao.getNotesPullWatermark();
        noteResult = await runPullFor(noteAdapter, db: db);
        DebugLogger.log(
          'note-cycle-done',
          scope: 'sync/notes',
          data: {
            'success': noteResult.success,
            'changed': noteResult.changed,
            'failedFetches': noteResult.failedFetches,
            'watermarkAdvanced': noteResult.watermarkAdvanced,
          },
        );
      } catch (error, stackTrace) {
        DebugLogger.error(
          'note-pull-failed',
          scope: 'sync/engine',
          error: error,
          stackTrace: stackTrace,
        );
      }
      if (!_cycleStillBound(cycleEpoch, 'after-note-pull')) return null;
    }

    // A watermark-0 pull is itself a COMPLETE enumeration of the server set,
    // and a watermark-0 DB starts empty (fresh install / post-§9.3 cold pull),
    // so there are no pre-existing local chats for the deletion reconcile to
    // purge right after it. Record it as the last full reconcile so the
    // background reconcile waits a full interval instead of redundantly
    // re-enumerating every page on the very first cycle (§7.5).
    final shouldAdvanceChatReconcile = result.success && previousWatermark == 0;
    final shouldAdvanceNoteReconcile =
        noteResult?.success == true && previousNotesWatermark == 0;
    if (shouldAdvanceChatReconcile || shouldAdvanceNoteReconcile) {
      final nowSeconds = clock.nowEpochSeconds();
      if (shouldAdvanceChatReconcile) {
        await db.syncMetaDao.setLastFullReconcileAt(nowSeconds);
      }
      // Same for the NOTE reconcile gate: the first cycle's note pull already
      // enumerated every note, so pre-advance its gate too (it otherwise reads
      // 0 and runs a redundant getNoteListRaw + full-ID diff right after the
      // first full pull).
      if (shouldAdvanceNoteReconcile) {
        await db.syncMetaDao.setNotesLastFullReconcileAt(nowSeconds);
      }
      if (!_cycleStillBound(cycleEpoch, 'after-first-pull-gates')) {
        return null;
      }
    }

    await _migrateLegacyTaskQueueIfNeeded();
    if (!_cycleStillBound(cycleEpoch, 'after-task-migration')) return null;

    // Drain the outbox AFTER pull (W: pull-then-push ordering). Errors are
    // caught + logged by the enclosing `_startCycle` try.
    final drainer = _ensureDrainer();
    if (drainer != null) {
      try {
        await drainer.drain();
      } finally {
        _clearStaleDrainerIfIdle(drainer);
      }
    }
    if (!_cycleStillBound(cycleEpoch, 'after-outbox-drain')) return null;

    // §7.5 deletion reconcile (background reason; its own 24h throttle gates
    // how often it actually enumerates). A failure here must not abort the
    // cycle — it self-throttles and retries on a later cycle. Independent
    // try/catch per entity so a chat-reconcile error can't skip the note one.
    try {
      await _buildReconcile()?.run(ReconcileReason.background);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'reconcile-background-failed',
        scope: 'sync/engine',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (!_cycleStillBound(cycleEpoch, 'after-chat-reconcile')) return null;
    try {
      await _buildNoteReconcile()?.run(ReconcileReason.background);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'note-reconcile-background-failed',
        scope: 'sync/engine',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (!_cycleStillBound(cycleEpoch, 'after-note-reconcile')) return null;

    final foldersEnabled = result.foldersFeatureEnabled;
    if (foldersEnabled != null && ref.mounted) {
      ref
          .read(foldersFeatureEnabledProvider.notifier)
          .setEnabled(foldersEnabled);
    }
    if (!_cycleStillBound(cycleEpoch, 'after-folder-flag')) return null;

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
      if (!_cycleStillBound(cycleEpoch, 'after-hive-cache-purge')) {
        return null;
      }
    }
    // Phase 4 FTS5 population (CDT-RFC-001 §10/§E): build the search index
    // after a successful sync has written chat/message rows. The first attempt
    // normally runs after the first full pull; if it fails and leaves
    // `fts_built` unset, later successful cycles retry even after the pull
    // watermark has advanced.
    if (result.success && ref.mounted) {
      await _scheduleFtsBuildIfNeeded(db, cycleEpoch);
    }
    return result;
  }

  void _clearCachedDrainerIfIdle() {
    final drainer = _drainer;
    if (drainer == null) {
      return;
    }
    _clearStaleDrainerIfIdle(drainer);
  }

  Future<void> _scheduleFtsBuildIfNeeded(AppDatabase db, int cycleEpoch) async {
    if (_ftsBuildInFlight) return;
    String? built;
    try {
      built = await db.syncMetaDao.getValue(kFtsBuiltKey);
    } catch (error) {
      if (_isExpectedClosedDbError(error)) {
        DebugLogger.log('fts-build-skipped-db-closed', scope: 'sync/fts');
        return;
      }
      rethrow;
    }
    if (!_cycleStillBound(cycleEpoch, 'after-fts-flag-read')) return;
    if (built == '1') return;

    _ftsBuildInFlight = true;
    // The conversation list already streams from `watchChatList`; running this
    // out of band keeps large backfills off the cycle completion path.
    unawaited(
      Future.microtask(() async {
        try {
          await db.buildFtsIfNeeded();
        } catch (error, stackTrace) {
          // A server switch / logout can dispose this db while the
          // fire-and-forget build is in flight. That race is expected and
          // harmless (the flag stays unset -> the next active db rebuilds);
          // log it at debug, not error, so it isn't mistaken for a real
          // FTS failure.
          if (_isExpectedClosedDbError(error)) {
            DebugLogger.log('fts-build-skipped-db-closed', scope: 'sync/fts');
          } else {
            DebugLogger.error(
              'fts-build-failed',
              scope: 'sync/fts',
              error: error,
              stackTrace: stackTrace,
            );
          }
        } finally {
          if (cycleEpoch == _sessionEpoch) {
            _ftsBuildInFlight = false;
          }
        }
      }),
    );
  }

  bool _isExpectedClosedDbError(Object error) {
    if (error is! StateError) return false;
    final message = error.message;
    return message.startsWith(
          'This database or transaction runner has already been closed',
        ) ||
        message == 'This database has already been closed' ||
        message.startsWith("Can't re-open a database after closing it.");
  }

  Future<int?> _readWatermark(int cycleEpoch) async {
    final db = _boundDb;
    if (db == null) return null;
    if (!_cycleStillBound(cycleEpoch, 'before-watermark-state-read')) {
      return null;
    }
    final watermark = await db.syncMetaDao.getPullWatermark();
    if (!_cycleStillBound(cycleEpoch, 'after-watermark-state-read')) {
      return null;
    }
    return watermark;
  }
}
