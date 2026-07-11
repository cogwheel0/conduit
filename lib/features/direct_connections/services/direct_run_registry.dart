import 'dart:async';

import '../models/direct_completion.dart';

/// Owns active direct completions by assistant message id.
final class DirectRunRegistry {
  final Map<String, DirectCompletionRun> _runs = {};
  final Map<String, DirectRunReservation> _pending = {};

  DirectCompletionRun? runFor(String assistantMessageId) =>
      _runs[assistantMessageId];

  /// Reserves an assistant id before asynchronous attachment/history preflight
  /// begins. A stop or profile edit can then cancel the intent before an HTTP
  /// request exists.
  DirectRunReservation reserve(String assistantMessageId, String profileId) {
    final previous = _runs.remove(assistantMessageId);
    if (previous != null) unawaited(previous.cancel('replaced'));
    final previousReservation = _pending[assistantMessageId];
    if (previousReservation != null) previousReservation._cancelled = true;
    final reservation = DirectRunReservation._(assistantMessageId, profileId);
    _pending[assistantMessageId] = reservation;
    return reservation;
  }

  /// A reservation is no longer publishable after cancellation, replacement,
  /// registration, or release. Identity validation prevents a stale preflight
  /// from observing or consuming a newer intent for the same assistant id.
  bool isCancelled(DirectRunReservation reservation) =>
      !identical(_pending[reservation._assistantMessageId], reservation) ||
      reservation._cancelled;

  /// Attaches the concrete provider run to a prior reservation. Returns false
  /// when that intent was stopped during preflight; the just-created request is
  /// cancelled immediately and never exposed as active.
  bool register(DirectRunReservation reservation, DirectCompletionRun run) {
    final assistantMessageId = reservation._assistantMessageId;
    final pending = _pending[assistantMessageId];
    if (!identical(pending, reservation) || reservation._cancelled) {
      unawaited(run.cancel('stopped before request start'));
      return false;
    }
    _pending.remove(assistantMessageId);
    final previous = _runs[assistantMessageId];
    if (previous != null && !identical(previous, run)) {
      unawaited(previous.cancel('replaced'));
    }
    _runs[assistantMessageId] = run;
    return true;
  }

  Future<void>? cancel(String assistantMessageId) {
    final run = _runs.remove(assistantMessageId);
    if (run != null) return run.cancel();
    final pending = _pending[assistantMessageId];
    if (pending == null) return null;
    pending._cancelled = true;
    return Future<void>.value();
  }

  List<Future<void>> cancelProfile(String profileId) {
    final futures = <Future<void>>[];
    for (final entry in _runs.entries.toList(growable: false)) {
      if (entry.value.profileId != profileId) continue;
      _runs.remove(entry.key);
      futures.add(entry.value.cancel('profile changed'));
    }
    for (final entry in _pending.entries) {
      if (entry.value._profileId != profileId || entry.value._cancelled) {
        continue;
      }
      entry.value._cancelled = true;
      futures.add(Future<void>.value());
    }
    return futures;
  }

  List<Future<void>> cancelAll() {
    final futures = <Future<void>>[];
    for (final id in _runs.keys.toList(growable: false)) {
      final cancellation = cancel(id);
      if (cancellation != null) futures.add(cancellation);
    }
    for (final pending in _pending.values) {
      if (pending._cancelled) continue;
      pending._cancelled = true;
      futures.add(Future<void>.value());
    }
    return futures;
  }

  void releaseReservation(DirectRunReservation reservation) {
    final assistantMessageId = reservation._assistantMessageId;
    if (identical(_pending[assistantMessageId], reservation)) {
      _pending.remove(assistantMessageId);
    }
  }

  bool complete(String assistantMessageId, DirectCompletionRun run) {
    if (!identical(_runs[assistantMessageId], run)) return false;
    _runs.remove(assistantMessageId);
    return true;
  }
}

/// Opaque ownership token for one direct-completion preflight.
///
/// Callers can only pass it back to [DirectRunRegistry]; its identity, rather
/// than the reusable assistant id, determines which preflight may publish.
final class DirectRunReservation {
  DirectRunReservation._(this._assistantMessageId, this._profileId);

  final String _assistantMessageId;
  final String _profileId;
  bool _cancelled = false;
}
