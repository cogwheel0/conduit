import 'dart:async';

import '../database/app_database.dart';
import '../database/daos/outbox_dao.dart';
import '../utils/debug_logger.dart';
import 'backoff.dart';
import 'clock.dart';
import 'sync_api_client.dart';
import 'sync_entity_adapter.dart';

/// Completion seam (Wiring D). The concrete `RequestCompletionRunner` (in
/// features/chat, touching the streaming providers) implements this. Rebuilds
/// the completion request from rows at drain time — never snapshots — so
/// mid-flight edits are reflected. NOT held under the chat lock for the whole
/// stream; only the placeholder/finalize writes are.
abstract interface class RequestCompletionRunner {
  Future<void> run({
    required String chatId,
    required Map<String, dynamic> payload,
  });
}

/// Marker for temporary conditions that mean an op did not actually attempt
/// network work and therefore must not burn retry/parking budget.
abstract interface class OutboxDeferralException implements Exception {}

/// Classifies a push error as a terminal (non-retryable) server response so
/// the drainer can park/handle it instead of retrying forever (A7, §B5).
/// Returns the HTTP status code for a terminal server error (401/403, and a
/// modelled 404), or null when the error is transient and should be retried.
///
/// The default ([OutboxDrainer._defaultTerminal]) treats every
/// [SyncTerminalException] as terminal (the §B5 contract: `SyncApiClient`
/// write methods throw it for 401/403). Tests override it to simulate
/// per-status outcomes without constructing HTTP errors.
typedef TerminalErrorClassifier = int? Function(Object error);

/// Drains the outbox in seq order per chat, independent chats concurrently
/// (pool of 2) — CDT-RFC-001 §7.2, A7. Constructor injection only; NO Riverpod
/// inside (mirrors `PullSync`/`PushSync`).
class OutboxDrainer {
  OutboxDrainer({
    required AppDatabase db,
    required SyncClock clock,
    required Backoff backoff,
    required bool Function() isOnline,
    required RequestCompletionRunner completion,
    required List<SyncEntityAdapter> adapters,
    TerminalErrorClassifier? terminalClassifier,
  }) : _db = db,
       _clock = clock,
       _backoff = backoff,
       _isOnline = isOnline,
       _completion = completion,
       _adapters = adapters,
       _isTerminal = terminalClassifier ?? _defaultTerminal;

  /// §7.2 pool of 2, matching legacy parallelism.
  static const int kPoolSize = 2;

  /// N=5 (§7.2): requestCompletion parks after this many failed attempts.
  static const int kCompletionMaxAttempts = 5;

  /// Short retry window for a sync op that failed only because we were
  /// offline (pure sync ops retry indefinitely; this just paces re-checks).
  static const int _offlineRetrySeconds = 5;

  final AppDatabase _db;

  /// Entity adapters that own outbox kinds (chat + note). The drainer routes
  /// each op to `adapters.firstWhere((a) => a.ownsKind(kind))` instead of a
  /// hardcoded per-kind switch. requestCompletion is the lone chat-only kind
  /// with no adapter pushOp; it is dispatched to [_completion] directly.
  final List<SyncEntityAdapter> _adapters;
  final SyncClock _clock;
  final Backoff _backoff;
  final bool Function() _isOnline;
  final RequestCompletionRunner _completion;
  final TerminalErrorClassifier _isTerminal;

  /// Queue-domain keys currently held by a worker. Claims are serialized through
  /// [_claimTail] so a returned op is reserved in this set before any other
  /// worker can claim.
  final Set<String> _busy = <String>{};
  Future<void> _claimTail = Future<void>.value();

  bool _draining = false;
  bool _rerun = false;

  bool get isDraining => _draining;

  /// Stranded-`inFlight` recovery runs exactly once per process, before the
  /// first claim of the first drain (§7.2/§11 crash recovery). Guarded so a
  /// rerun mid-session never re-reclaims an op a live worker just flipped to
  /// `inFlight`.
  bool _recovered = false;

  /// §B5: `SyncApiClient` write methods throw [SyncTerminalException] for
  /// 401/403 (not owner / no perm). Treat those as terminal; everything else
  /// is transient and retried with backoff.
  static int? _defaultTerminal(Object error) =>
      error is SyncTerminalException ? (error.statusCode ?? 403) : null;

  /// One drain: spins up to [kPoolSize] workers, each claiming + running ops
  /// until `claimNextRunnable` returns null. Single-flight — overlapping
  /// triggers collapse to at most one queued rerun (mirrors
  /// `SyncEngine._startCycle`).
  Future<void> drain() async {
    if (_draining) {
      _rerun = true;
      return;
    }
    _draining = true;
    try {
      await _recoverStrandedOnce();
      do {
        _rerun = false;
        await _runPass();
      } while (_rerun);
    } finally {
      _draining = false;
    }
  }

  /// Reclaims ops left `inFlight` by a previous process that was killed
  /// mid-push, flipping them back to `pending` so they re-run and stop blocking
  /// their chat head (§7.2/§11). Runs at most once per [OutboxDrainer] instance,
  /// before the first claim. Safe to invoke from [drain] because the guard +
  /// single-threaded event loop ensure no worker is mid-push the first time.
  Future<void> _recoverStrandedOnce() async {
    if (_recovered) return;
    final reclaimed = await _db.outboxDao.resetInFlightToPending();
    _recovered = true;
    if (reclaimed > 0) {
      DebugLogger.log(
        'reclaimed stranded inFlight ops',
        scope: 'outbox/drain',
        data: {'count': reclaimed},
      );
    }
  }

  /// Connectivity regained: reset backoff on every pending op (next attempt =
  /// now) so they re-run immediately, then drain (A6/A7).
  Future<void> onConnectivityRegained() async {
    final now = _clock.nowEpochSeconds();
    await _db.outboxDao.resetBackoffForPending(nowEpochSeconds: now);
    await drain();
  }

  Future<void> _runPass() async {
    await Future.wait([for (var i = 0; i < kPoolSize; i++) _worker()]);
  }

  Future<void> _worker() async {
    while (true) {
      final op = await _claimNextReserved();
      if (op == null) return;

      final busyKey = OutboxDao.busyKeyFor(op);
      try {
        await _process(op);
      } finally {
        _busy.remove(busyKey);
      }
    }
  }

  Future<OutboxOp?> _claimNextReserved() {
    final previous = _claimTail;
    final release = Completer<void>();
    _claimTail = release.future;

    return previous.then((_) async {
      try {
        final op = await _db.outboxDao.claimNextRunnable(
          nowEpochSeconds: _clock.nowEpochSeconds(),
          busyChatIds: _busy,
        );
        if (op != null) {
          _busy.add(OutboxDao.busyKeyFor(op));
        }
        return op;
      } finally {
        release.complete();
      }
    });
  }

  Future<void> _process(OutboxOp op) async {
    final kind = OutboxKind.fromName(op.kind);
    if (kind == null) {
      // Unknown/legacy kind: log and SKIP — do not crash, do not mark done
      // (A1). Park it so it never blocks the chat head forever.
      DebugLogger.error(
        'unknown outbox kind, parking',
        scope: 'outbox/drain',
        data: {'seq': op.seq, 'kind': op.kind},
      );
      await _db.outboxDao.markParked(op.seq, error: 'unknown kind ${op.kind}');
      return;
    }

    final now = _clock.nowEpochSeconds();

    if (!_isOnline()) {
      // Offline: never park (even requestCompletion) and never burn the N=5
      // budget (§7.2). markOfflineDeferred re-paces without bumping attempts so
      // only true online failures count toward parking; pure sync ops retry
      // indefinitely regardless.
      await _db.outboxDao.markOfflineDeferred(
        op.seq,
        nextAttemptAt: now + _offlineRetrySeconds,
      );
      return;
    }

    if (kind == OutboxKind.requestCompletion && op.chatId == null) {
      const message = 'malformed requestCompletion op: missing chatId';
      DebugLogger.error(
        'malformed requestCompletion op, parking',
        scope: 'outbox/drain',
        data: {'seq': op.seq},
      );
      await _db.outboxDao.markParked(op.seq, error: message);
      return;
    }

    try {
      final executed = await _execute(op, kind);
      if (executed) {
        await _db.outboxDao.markDone(op.seq);
      }
    } catch (error, stack) {
      await _handleFailure(op, kind, error, stack);
    }
  }

  Future<bool> _execute(OutboxOp op, OutboxKind kind) async {
    // requestCompletion must be consumed here before the adapter loop. The
    // ChatAdapter owns the kind for FIFO partitioning, but its pushOp
    // intentionally throws for requestCompletion; falling through is a bug.
    if (kind == OutboxKind.requestCompletion) {
      final chatId = op.chatId;
      if (chatId == null) {
        throw StateError('requestCompletion missing chatId after validation');
      }
      await _completion.run(
        chatId: chatId,
        payload: decodeOutboxPayload(op.payload),
      );
      return true;
    }
    // Ownership dispatch (CDT-RFC-001 Phase 5 seam): the chat + note adapters
    // partition every remaining kind, so exactly one owns it. The busy-key /
    // per-id FIFO / crash-recovery / backoff machinery above is entity-agnostic
    // and unchanged — note ids share the chat_id column but are distinct UUIDs,
    // so a note op never blocks a chat op.
    for (final adapter in _adapters) {
      if (adapter.ownsKind(kind)) {
        await adapter.pushOp(op);
        return true;
      }
    }
    // No owner: should be unreachable (the enum is fully partitioned), but never
    // crash the drain — park it so it can't block its id's head forever.
    DebugLogger.error(
      'no adapter owns kind, parking',
      scope: 'outbox/drain',
      data: {'seq': op.seq, 'kind': kind.name},
    );
    await _db.outboxDao.markParked(
      op.seq,
      error: 'no adapter for ${kind.name}',
    );
    return false;
  }

  Future<void> _handleFailure(
    OutboxOp op,
    OutboxKind kind,
    Object error,
    StackTrace stack,
  ) async {
    final message = error.toString();
    if (error is OutboxDeferralException) {
      DebugLogger.error(
        'outbox op deferred without attempt',
        scope: 'outbox/drain',
        error: error,
        stackTrace: stack,
        data: {'seq': op.seq, 'kind': kind.name, 'attempts': op.attempts},
      );
      await _db.outboxDao.markDeferred(
        op.seq,
        error: message,
        nextAttemptAt: _clock.nowEpochSeconds() + 1,
      );
      return;
    }

    final newAttempts = op.attempts + 1;

    DebugLogger.error(
      'outbox op failed',
      scope: 'outbox/drain',
      error: error,
      stackTrace: stack,
      data: {'seq': op.seq, 'kind': kind.name, 'attempts': newAttempts},
    );

    if (kind == OutboxKind.requestCompletion &&
        newAttempts >= kCompletionMaxAttempts) {
      // Parked-failure: surfaced via watchParkedForChat for manual retry.
      await _db.outboxDao.markParked(op.seq, error: message);
      return;
    }

    final terminalStatus = _isTerminal(error);
    if (terminalStatus != null) {
      await _handleTerminal(op, kind, terminalStatus, message);
      return;
    }

    final delayMs = _backoff.delayMsForAttempt(newAttempts - 1);
    // At LEAST 1s in the future: full jitter can legitimately return 0, but a
    // nextAttemptAt of `now` would make this same op re-claimable inside the
    // current drain pass (a busy-loop for non-parking sync ops). Pushing it a
    // whole second forward guarantees forward progress out of this pass while
    // still honoring the schedule (the op waits until the clock advances).
    final delaySeconds = (delayMs / 1000).ceil();
    final nextAttemptAt =
        _clock.nowEpochSeconds() + (delaySeconds < 1 ? 1 : delaySeconds);
    await _db.outboxDao.markFailedRetryable(
      op.seq,
      error: message,
      nextAttemptAt: nextAttemptAt,
    );
  }

  /// Per-kind terminal (non-retryable) server-error handling (A7, §B).
  /// Delete 404s are absorbed inside [SyncApiClient] delete methods as
  /// already-gone success; terminal errors that reach the drainer are parked.
  Future<void> _handleTerminal(
    OutboxOp op,
    OutboxKind kind,
    int status,
    String message,
  ) async {
    DebugLogger.error(
      'outbox op parked on terminal server error',
      scope: 'outbox/drain',
      data: {'seq': op.seq, 'kind': kind.name, 'status': status},
    );
    await _db.outboxDao.markParked(op.seq, error: message);
  }
}
