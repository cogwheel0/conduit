import 'dart:async';

/// Defers work until the current frame has been presented.
///
/// Distinct from [FlushScheduler], which asks for the *next* frame so a
/// buffered update renders in it. This one is the opposite concern: the work
/// is not about painting at all, it just must not run during the current
/// build or provider construction. Connecting a socket from inside a
/// provider's `build` is the case that needs it — the connect can rebuild
/// providers, and doing that mid-build is what the post-frame callback
/// exists to avoid.
///
/// A host with no frames has no build phase to get out of either, so
/// deferring by one turn of the event loop is the faithful equivalent.
abstract interface class PostFrameScheduler {
  /// Runs [callback] once the current frame, if any, has finished.
  ///
  /// Never runs synchronously: callers rely on the current call stack having
  /// unwound first.
  ///
  /// One caveat, verified rather than assumed, and inherited from the
  /// `addPostFrameCallback` this replaces: a frame-backed implementation only
  /// runs the callback if a frame was already going to be produced.
  /// Registering one does not ask for a frame, and no amount of waiting
  /// substitutes. In the app that is invisible, because something is nearly
  /// always animating — but work that *must* happen should not be queued here
  /// on a quiescent host.
  void runAfterCurrentFrame(void Function() callback);

  /// What `postFrameSchedulerProvider` resolves to when nothing overrides it.
  ///
  /// Installed once at startup the way the host installs `DebugLogger.sink`.
  /// `main.dart` and `test/flutter_test_config.dart` both install the
  /// frame-backed version, so the app and the suite keep the timing they
  /// have; a provider override still wins for a test that wants determinism.
  static PostFrameScheduler hostDefault = const MicrotaskPostFrameScheduler();
}

/// Defers to a microtask.
///
/// Correct wherever there are no frames — the daemon, and unit tests that
/// never pump one. Still asynchronous, which is the property callers depend
/// on.
class MicrotaskPostFrameScheduler implements PostFrameScheduler {
  const MicrotaskPostFrameScheduler();

  @override
  void runAfterCurrentFrame(void Function() callback) =>
      scheduleMicrotask(callback);
}
