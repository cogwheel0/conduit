import 'dart:async';

/// A task that can run away from the calling isolate.
///
/// Returns `FutureOr` because the two host mechanisms differ: Flutter's
/// `compute` accepts an async callback, `Isolate.run` accepts either, and an
/// inline runner has nothing to await. Callbacks must be top-level or static
/// and their arguments sendable, or the isolate-backed hosts will reject them.
typedef WorkerCallback<Q, R> = FutureOr<R> Function(Q message);

/// Runs a pure function off the calling isolate.
///
/// Flutter's `compute` spawns an isolate through the engine's entry point,
/// which does not exist in the `conduitd` sidecar; there the equivalent is
/// `Isolate.run`. Both have the same contract, so the core needs one method.
abstract interface class WorkerPort {
  Future<R> run<Q, R>(WorkerCallback<Q, R> callback, Q message);
}

/// Runs the callback on the calling isolate.
///
/// The honest answer for a host with no isolate support — the web build, and
/// tests, where it also keeps ordering deterministic and lets a callback see
/// test state that isolate copying would hide. Not what production wants: the
/// point of a worker is to leave the UI isolate free.
class InlineWorkerPort implements WorkerPort {
  const InlineWorkerPort();

  @override
  Future<R> run<Q, R>(WorkerCallback<Q, R> callback, Q message) =>
      Future<R>.sync(() => callback(message));
}
