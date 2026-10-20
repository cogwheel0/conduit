import 'package:conduit_core/conduit_core.dart';
import 'package:flutter/foundation.dart';

/// The Flutter app's [WorkerPort].
///
/// `compute` spawns a short-lived isolate through the Flutter engine's entry
/// point, so it exists only inside a Flutter app — which is exactly why the
/// core cannot call it directly.
class FlutterWorkerPort implements WorkerPort {
  const FlutterWorkerPort();

  @override
  Future<R> run<Q, R>(WorkerCallback<Q, R> callback, Q message) {
    // The web build has no secondary isolates, so `compute` would run the
    // callback on the main thread anyway — but only after paying for a
    // message round trip. Call it directly instead.
    if (kIsWeb) return Future<R>.sync(() => callback(message));
    return compute(callback, message);
  }
}
