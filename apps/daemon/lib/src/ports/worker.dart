import 'dart:isolate';

import 'package:conduit_core/ports/worker_port.dart';

/// The desktop [WorkerPort].
///
/// `Isolate.run` is what `compute` is on mobile, minus the Flutter engine:
/// it spawns a short-lived isolate, runs the callback, returns the result and
/// shuts the isolate down. The daemon is a plain Dart process, so it is
/// available directly.
final class DaemonWorkerPort implements WorkerPort {
  const DaemonWorkerPort();

  @override
  Future<R> run<Q, R>(WorkerCallback<Q, R> callback, Q message) =>
      Isolate.run(() => callback(message));
}
