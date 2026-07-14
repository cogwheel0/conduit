import 'dart:async';
import 'dart:collection';

import '../../../core/models/chat_message.dart';
import '../models/direct_completion.dart';

/// Collision-free identity for one direct assistant inside its conversation.
typedef DirectRunKey = ({
  String ownerConversationId,
  String assistantMessageId,
});

/// Retained finals are only a short recovery bridge across a failed database
/// write. Bound both cardinality and estimated heap use so a sequence of
/// unique failures cannot turn that bridge into an unbounded in-memory queue.
const int kMaxRetainedDirectFinalizedOutputs = 32;
const int kMaxRetainedDirectFinalizedOutputBytes = 32 * 1024 * 1024;

/// Owns active direct completions by conversation-scoped assistant identity.
final class DirectRunRegistry {
  DirectRunRegistry({
    this.maxRetainedFinalizedOutputs = kMaxRetainedDirectFinalizedOutputs,
    this.maxRetainedFinalizedOutputBytes =
        kMaxRetainedDirectFinalizedOutputBytes,
  }) {
    if (maxRetainedFinalizedOutputs <= 0) {
      throw ArgumentError.value(
        maxRetainedFinalizedOutputs,
        'maxRetainedFinalizedOutputs',
      );
    }
    if (maxRetainedFinalizedOutputBytes <= 0) {
      throw ArgumentError.value(
        maxRetainedFinalizedOutputBytes,
        'maxRetainedFinalizedOutputBytes',
      );
    }
  }

  final int maxRetainedFinalizedOutputs;
  final int maxRetainedFinalizedOutputBytes;
  final Map<DirectRunKey, DirectCompletionRun> _runs = {};
  final Map<DirectRunKey, DirectRunReservation> _pending = {};
  final Map<DirectRunKey, DirectRunReservation> _active = {};
  final Map<DirectRunKey, DirectRunReservation> _latest = {};
  final LinkedHashMap<_DirectPersistenceKey, DirectFinalizedOutput>
  _retainedFinalizedOutputs = LinkedHashMap();
  int _retainedFinalizedOutputBytes = 0;

  DirectCompletionRun? runFor(DirectRunKey key) => _runs[key];

  /// True while a non-cancelled preflight or concrete run owns [key].
  bool hasLiveIntent(DirectRunKey key) {
    final reservation = _latest[key];
    return reservation != null &&
        !reservation._cancelled &&
        !reservation._outputFinalized;
  }

  /// Reserves an assistant identity before asynchronous attachment/history
  /// preflight begins. A stop or profile edit can then cancel the intent before
  /// an HTTP request exists.
  DirectRunReservation reserve(DirectRunKey key, String profileId) {
    // The run key already contains the stable server/store owner. A new
    // generation for this exact assistant supersedes every uncommitted final
    // output in that same store before any retry can claim and persist it.
    for (final entry
        in _retainedFinalizedOutputs.entries
            .where((entry) => entry.key.runKey == key)
            .toList(growable: false)) {
      _evictRetainedFinalizedOutput(entry.key);
    }
    final previous = _runs.remove(key);
    if (previous != null) {
      _cancelDetachedBestEffort(previous, 'replaced');
    }
    final previousReservation = _latest[key];
    if (previousReservation != null) {
      previousReservation._signalCancellation();
    }
    _pending.remove(key);
    _active.remove(key);
    final reservation = DirectRunReservation._(key, profileId);
    _pending[key] = reservation;
    _latest[key] = reservation;
    return reservation;
  }

  /// Moves [reservation] when a new chat receives its durable id or an
  /// OpenWebUI local id is remapped.
  ///
  /// The destination is an exact reservation boundary: an unrelated pending
  /// intent, active run, or retained final already at [key] wins. On such a
  /// collision the moving source is revoked and its transport is cancelled;
  /// the destination is never displaced. This fail-closed behavior prevents a
  /// late remap from taking ownership from a newer generation.
  bool rebindIfVacant(DirectRunReservation reservation, DirectRunKey key) {
    final previousKey = reservation._key;
    if (previousKey == key) return isLatest(reservation);
    if (!identical(_latest[previousKey], reservation)) return false;

    final wasPending = identical(_pending[previousKey], reservation);
    final wasActive = identical(_active[previousKey], reservation);
    final run = _runs[previousKey];

    if (_keyIsOccupied(key)) {
      _revokeRebindSource(
        reservation,
        previousKey,
        run,
        reason: 'run identity collision during remap',
      );
      return false;
    }

    if (identical(_pending[previousKey], reservation)) {
      _pending.remove(previousKey);
    }
    if (identical(_active[previousKey], reservation)) {
      _active.remove(previousKey);
    }
    if (identical(_latest[previousKey], reservation)) {
      _latest.remove(previousKey);
    }
    if (run != null && identical(_runs[previousKey], run)) {
      _runs.remove(previousKey);
    }

    _rebindRetainedFinalizedOutputs(previousKey, key);
    reservation._key = key;
    _latest[key] = reservation;
    if (wasPending) _pending[key] = reservation;
    if (wasActive) _active[key] = reservation;
    if (run != null) _runs[key] = run;
    return true;
  }

  bool _keyIsOccupied(DirectRunKey key) {
    if (_latest.containsKey(key) ||
        _pending.containsKey(key) ||
        _active.containsKey(key) ||
        _runs.containsKey(key)) {
      return true;
    }
    return _retainedFinalizedOutputs.keys.any(
      (persistenceKey) => persistenceKey.runKey == key,
    );
  }

  void _revokeRebindSource(
    DirectRunReservation reservation,
    DirectRunKey sourceKey,
    DirectCompletionRun? run, {
    required String reason,
  }) {
    if (identical(_pending[sourceKey], reservation)) {
      _pending.remove(sourceKey);
    }
    if (identical(_active[sourceKey], reservation)) {
      _active.remove(sourceKey);
    }
    if (identical(_latest[sourceKey], reservation)) {
      _latest.remove(sourceKey);
    }
    if (run != null && identical(_runs[sourceKey], run)) {
      _runs.remove(sourceKey);
    }
    for (final persistenceKey
        in _retainedFinalizedOutputs.keys
            .where((candidate) => candidate.runKey == sourceKey)
            .toList(growable: false)) {
      _evictRetainedFinalizedOutput(persistenceKey);
    }
    reservation._signalCancellation();
    if (run != null) _cancelDetachedBestEffort(run, reason);
  }

  void _rebindRetainedFinalizedOutputs(
    DirectRunKey sourceKey,
    DirectRunKey destinationKey,
  ) {
    if (!_retainedFinalizedOutputs.keys.any(
      (persistenceKey) => persistenceKey.runKey == sourceKey,
    )) {
      return;
    }

    // Rebuild in-place so rebinding does not make an old failed write look
    // newest for deterministic eviction. The retained output's mutable key is
    // the settlement handle used by an in-flight retry, so future completion
    // still addresses the same object after the move.
    final rebound = <_DirectPersistenceKey, DirectFinalizedOutput>{};
    for (final entry in _retainedFinalizedOutputs.entries) {
      if (entry.key.runKey != sourceKey) {
        rebound[entry.key] = entry.value;
        continue;
      }
      final nextKey = _DirectPersistenceKey(
        runKey: destinationKey,
        persistenceOwnerId: entry.key.persistenceOwnerId,
        authSessionEpoch: entry.key.authSessionEpoch,
      );
      entry.value._key = nextKey;
      rebound[nextKey] = entry.value;
    }
    _retainedFinalizedOutputs
      ..clear()
      ..addAll(rebound);
  }

  /// A reservation is no longer publishable after cancellation, replacement,
  /// or release. Identity validation prevents a stale preflight from observing
  /// or consuming a newer intent for the same assistant identity.
  bool isCancelled(DirectRunReservation reservation) =>
      !identical(_latest[reservation._key], reservation) ||
      reservation._cancelled;

  /// Whether [reservation] is still the newest generation for its assistant.
  ///
  /// Explicit stop cancels transport ownership but deliberately leaves the
  /// generation current until its dispatcher settles. That lets the stopped
  /// run persist its partial accumulator. A replacement reservation revokes
  /// this immediately, preventing the old dispatcher from touching the new
  /// generation even though both reuse the same assistant message id.
  bool isLatest(DirectRunReservation reservation) =>
      identical(_latest[reservation._key], reservation);

  /// Whether [run] currently owns live event delivery for [reservation].
  /// Cancellation and replacement both revoke this synchronously, before the
  /// provider stream has a chance to deliver a late event.
  bool owns(DirectRunReservation reservation, DirectCompletionRun run) {
    final key = reservation._key;
    return !reservation._cancelled &&
        identical(_latest[key], reservation) &&
        identical(_active[key], reservation) &&
        identical(_runs[key], run);
  }

  /// Binds durable state to both its scoped chat id and stable store owner.
  ///
  /// OpenWebUI chat ids are only server-local. The database identity prevents
  /// a retained result for server A/chat X from being projected or retried in
  /// server B/chat X. A stable server id also survives closing and reopening
  /// that server's database after a transient write failure.
  void bindPersistenceIdentity(
    DirectRunReservation reservation,
    String persistenceOwnerId, {
    Object? authSessionEpoch,
  }) {
    if (!isLatest(reservation)) return;
    reservation
      .._persistenceOwnerId = persistenceOwnerId
      .._authSessionEpoch = authSessionEpoch;
    final key = _DirectPersistenceKey(
      runKey: reservation._key,
      persistenceOwnerId: persistenceOwnerId,
      authSessionEpoch: authSessionEpoch,
    );
    _evictRetainedFinalizedOutput(key);
  }

  /// Records the final provider output before attempting its durable write.
  ///
  /// The output is no longer live/streaming at this point, but it is not
  /// considered durable until [markDurablyPersisted] runs. A failed write is
  /// retained for immediate projection and an idempotent retry on reopen.
  DirectFinalizedOutput? markOutputFinalized(
    DirectRunReservation reservation,
    ChatMessage output, {
    String? persistenceOwnerId,
    Object? authSessionEpoch,
  }) {
    if (!isLatest(reservation)) return null;
    final identity = persistenceOwnerId ?? reservation._persistenceOwnerId;
    reservation
      .._outputFinalized = true
      .._durablyPersisted = identity == null
      .._persistenceOwnerId = identity
      .._authSessionEpoch = authSessionEpoch ?? reservation._authSessionEpoch;
    if (identity == null) return null;
    final key = _DirectPersistenceKey(
      runKey: reservation._key,
      persistenceOwnerId: identity,
      authSessionEpoch: reservation._authSessionEpoch,
    );
    _evictRetainedFinalizedOutput(key);
    final retained = DirectFinalizedOutput._(
      key: key,
      message: output,
      estimatedBytes: _estimateRetainedFinalizedOutputBytes(
        output,
        maxRetainedFinalizedOutputBytes,
      ),
    );
    _retainedFinalizedOutputs[key] = retained;
    _retainedFinalizedOutputBytes += retained._estimatedBytes;
    _enforceRetainedFinalizedOutputLimits();
    return retained;
  }

  bool isOutputFinalized(DirectRunReservation reservation) =>
      isLatest(reservation) && reservation._outputFinalized;

  bool isDurablyPersisted(DirectRunReservation reservation) =>
      isLatest(reservation) && reservation._durablyPersisted;

  /// Completes synchronously when cancellation/replacement revokes delivery.
  Future<void> cancellationSignal(DirectRunReservation reservation) =>
      reservation._cancellation.future;

  void markDurablyPersisted(DirectRunReservation reservation) {
    if (!isLatest(reservation) || !reservation._outputFinalized) return;
    reservation._durablyPersisted = true;
    final identity = reservation._persistenceOwnerId;
    if (identity == null) return;
    final key = _DirectPersistenceKey(
      runKey: reservation._key,
      persistenceOwnerId: identity,
      authSessionEpoch: reservation._authSessionEpoch,
    );
    _evictRetainedFinalizedOutput(key);
  }

  DirectFinalizedOutput? retainedFinalizedOutput(
    DirectRunKey key,
    String persistenceOwnerId, {
    Object? authSessionEpoch,
  }) =>
      _retainedFinalizedOutputs[_DirectPersistenceKey(
        runKey: key,
        persistenceOwnerId: persistenceOwnerId,
        authSessionEpoch: authSessionEpoch,
      )];

  /// Drops a finalized snapshot that is no longer authorized to persist, for
  /// example after an OpenWebUI logout/login epoch change.
  void discardFinalizedOutput(DirectRunReservation reservation) {
    if (!isLatest(reservation)) return;
    final identity = reservation._persistenceOwnerId;
    reservation
      .._outputFinalized = false
      .._durablyPersisted = false;
    if (identity == null) return;
    _evictRetainedFinalizedOutput(
      _DirectPersistenceKey(
        runKey: reservation._key,
        persistenceOwnerId: identity,
        authSessionEpoch: reservation._authSessionEpoch,
      ),
    );
  }

  bool beginRetainedPersistenceRetry(DirectFinalizedOutput output) {
    if (!identical(_retainedFinalizedOutputs[output._key], output) ||
        !output._retryEligible ||
        output._retrying) {
      return false;
    }
    output._retrying = true;
    return true;
  }

  bool retainedFinalizedOutputIsCurrent(DirectFinalizedOutput output) =>
      identical(_retainedFinalizedOutputs[output._key], output);

  void finishRetainedPersistenceRetry(
    DirectFinalizedOutput output, {
    required bool persisted,
  }) {
    if (!identical(_retainedFinalizedOutputs[output._key], output)) return;
    if (persisted) {
      _evictRetainedFinalizedOutput(output._key);
    } else {
      output._retrying = false;
    }
  }

  void _enforceRetainedFinalizedOutputLimits() {
    while (_retainedFinalizedOutputs.length > maxRetainedFinalizedOutputs ||
        _retainedFinalizedOutputBytes > maxRetainedFinalizedOutputBytes) {
      _evictRetainedFinalizedOutput(_retainedFinalizedOutputs.keys.first);
    }
  }

  void _evictRetainedFinalizedOutput(_DirectPersistenceKey key) {
    final evicted = _retainedFinalizedOutputs.remove(key);
    if (evicted == null) return;
    _retainedFinalizedOutputBytes -= evicted._estimatedBytes;
    if (_retainedFinalizedOutputBytes < 0) {
      // Keep release builds fail-safe if a future mutation path forgets to
      // account for a removal; the map remains authoritative.
      _retainedFinalizedOutputBytes = 0;
    }
    evicted._settlePrimaryPersistence(retryEligible: false);
  }

  /// Attaches the concrete provider run to a prior reservation. Returns false
  /// when that intent was stopped during preflight; the just-created request is
  /// cancelled immediately and never exposed as active.
  bool register(DirectRunReservation reservation, DirectCompletionRun run) {
    final key = reservation._key;
    final pending = _pending[key];
    if (!identical(pending, reservation)) {
      _cancelDetachedBestEffort(run, 'stopped before request start');
      return false;
    }
    if (reservation._cancelled) {
      // Consume only this rejected generation. A stale registration must
      // never remove a newer reservation that has since claimed the key.
      if (identical(_pending[key], reservation)) {
        _pending.remove(key);
      }
      _cancelDetachedBestEffort(run, 'stopped before request start');
      return false;
    }
    _pending.remove(key);
    final previous = _runs[key];
    if (previous != null && !identical(previous, run)) {
      _cancelDetachedBestEffort(previous, 'replaced');
    }
    _runs[key] = run;
    _active[key] = reservation;
    return true;
  }

  Future<void>? cancel(DirectRunKey key) {
    final run = _runs.remove(key);
    final active = _active.remove(key);
    active?._signalCancellation();
    if (run != null) return run.cancel();
    final pending = _pending[key];
    if (pending == null) return null;
    pending._signalCancellation();
    return Future<void>.value();
  }

  List<Future<void>> cancelProfile(String profileId) {
    final futures = <Future<void>>[];
    for (final entry in _runs.entries.toList(growable: false)) {
      // Adapter-returned run metadata is not an ownership boundary. A custom
      // adapter may accidentally (or deliberately) return a different profile
      // id, but the reservation was minted by this registry from the trusted
      // routing decision and remains authoritative for profile revocation.
      final active = _active[entry.key];
      if (active?._profileId != profileId) continue;
      _runs.remove(entry.key);
      _active.remove(entry.key);
      active!._signalCancellation();
      futures.add(entry.value.cancel('profile changed'));
    }
    for (final entry in _pending.entries) {
      if (entry.value._profileId != profileId || entry.value._cancelled) {
        continue;
      }
      entry.value._signalCancellation();
      futures.add(Future<void>.value());
    }
    return futures;
  }

  List<Future<void>> cancelAll() {
    final futures = <Future<void>>[];
    for (final key in _runs.keys.toList(growable: false)) {
      final cancellation = cancel(key);
      if (cancellation != null) futures.add(cancellation);
    }
    for (final pending in _pending.values) {
      if (pending._cancelled) continue;
      pending._signalCancellation();
      futures.add(Future<void>.value());
    }
    return futures;
  }

  void releaseReservation(DirectRunReservation reservation) {
    final key = reservation._key;
    if (identical(_latest[key], reservation) &&
        reservation._outputFinalized &&
        !reservation._durablyPersisted) {
      final persistenceOwnerId = reservation._persistenceOwnerId;
      if (persistenceOwnerId != null) {
        final retained =
            _retainedFinalizedOutputs[_DirectPersistenceKey(
              runKey: key,
              persistenceOwnerId: persistenceOwnerId,
              authSessionEpoch: reservation._authSessionEpoch,
            )];
        retained?._settlePrimaryPersistence(retryEligible: true);
      }
    }
    if (identical(_pending[key], reservation)) _pending.remove(key);
    if (identical(_active[key], reservation)) _active.remove(key);
    if (identical(_latest[key], reservation)) _latest.remove(key);
  }

  bool complete(DirectRunReservation reservation, DirectCompletionRun run) {
    final key = reservation._key;
    if (!identical(_runs[key], run)) return false;
    _runs.remove(key);
    _active.remove(key);
    return true;
  }

  /// Revokes a displaced transport without making registry mutation depend on
  /// provider cleanup. Hostile transports may reject their cleanup future (or
  /// an alternate run implementation may throw before returning one), so both
  /// failure modes are contained here instead of escaping as an unhandled zone
  /// error.
  static void _cancelDetachedBestEffort(
    DirectCompletionRun run,
    String reason,
  ) {
    try {
      final cleanup = run.cancel(reason);
      unawaited(
        cleanup.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    } on Object {
      // Ownership is already revoked synchronously by the registry mutation.
    }
  }
}

/// Opaque ownership token for one direct-completion preflight.
///
/// Callers can only pass it back to [DirectRunRegistry]; its identity, rather
/// than the reusable assistant id, determines which preflight may publish.
final class DirectRunReservation {
  DirectRunReservation._(this._key, this._profileId);

  DirectRunKey _key;
  final String _profileId;
  bool _cancelled = false;
  bool _outputFinalized = false;
  bool _durablyPersisted = false;
  String? _persistenceOwnerId;
  Object? _authSessionEpoch;
  final Completer<void> _cancellation = Completer<void>();

  void _signalCancellation() {
    _cancelled = true;
    if (!_cancellation.isCompleted) _cancellation.complete();
  }
}

/// Final direct output retained only while its database write is outstanding.
final class DirectFinalizedOutput {
  DirectFinalizedOutput._({
    required _DirectPersistenceKey key,
    required this.message,
    required int estimatedBytes,
  }) : _key = key,
       _estimatedBytes = estimatedBytes;

  _DirectPersistenceKey _key;
  final ChatMessage message;
  final int _estimatedBytes;
  final Completer<void> _primaryPersistenceSettled = Completer<void>();
  bool _retryEligible = false;
  bool _retrying = false;

  Future<void> get primaryPersistenceSettled =>
      _primaryPersistenceSettled.future;

  void _settlePrimaryPersistence({required bool retryEligible}) {
    _retryEligible = retryEligible;
    if (!_primaryPersistenceSettled.isCompleted) {
      _primaryPersistenceSettled.complete();
    }
  }
}

/// Estimates the retained object graph without serializing the output into a
/// second large string/byte buffer. The walk is cycle-safe, saturates just
/// above the configured aggregate limit, and treats excessive nesting as
/// oversized so hostile metadata cannot make accounting itself unbounded.
int _estimateRetainedFinalizedOutputBytes(ChatMessage message, int maxBytes) {
  final saturation = maxBytes + 1;
  var bytes = 0;
  var nodes = 0;
  final visited = HashSet<Object>.identity();

  void add(int amount) {
    if (bytes >= saturation || amount <= 0) return;
    final remaining = saturation - bytes;
    bytes += amount >= remaining ? remaining : amount;
  }

  void visit(Object? value, int depth) {
    if (bytes >= saturation) return;
    nodes += 1;
    if (depth > 64 || nodes > 65536) {
      bytes = saturation;
      return;
    }
    add(16);
    switch (value) {
      case null || bool() || num() || DateTime():
        return;
      case String():
        // Dart strings retain one or two bytes per code unit depending on
        // contents. Two is a conservative heap estimate without allocating a
        // UTF-8 copy solely for accounting.
        add(value.length * 2);
        return;
      case Map():
        if (!visited.add(value)) return;
        add(32 + value.length * 16);
        if (bytes >= saturation) return;
        for (final entry in value.entries) {
          visit(entry.key, depth + 1);
          visit(entry.value, depth + 1);
          if (bytes >= saturation) return;
        }
        return;
      case Iterable():
        if (!visited.add(value)) return;
        final length = value is List ? value.length : null;
        if (length != null) add(32 + length * 8);
        if (bytes >= saturation) return;
        for (final item in value) {
          visit(item, depth + 1);
          if (bytes >= saturation) return;
        }
        return;
      default:
        // Generated ChatMessage JSON should contain only JSON-like values.
        // Unknown objects receive a fixed conservative charge.
        add(64);
    }
  }

  try {
    visit(message.toJson(), 0);
  } catch (_) {
    // A malformed/cyclic custom payload must never bypass the budget or break
    // completion finalization. Treat it as too large to retain for retry.
    return saturation;
  }
  return bytes == 0 ? 1 : bytes;
}

final class _DirectPersistenceKey {
  const _DirectPersistenceKey({
    required this.runKey,
    required this.persistenceOwnerId,
    required this.authSessionEpoch,
  });

  final DirectRunKey runKey;
  final String persistenceOwnerId;
  final Object? authSessionEpoch;

  @override
  bool operator ==(Object other) =>
      other is _DirectPersistenceKey &&
      other.runKey == runKey &&
      other.persistenceOwnerId == persistenceOwnerId &&
      identical(other.authSessionEpoch, authSessionEpoch);

  @override
  int get hashCode => Object.hash(
    runKey,
    persistenceOwnerId,
    authSessionEpoch == null ? null : identityHashCode(authSessionEpoch!),
  );
}
