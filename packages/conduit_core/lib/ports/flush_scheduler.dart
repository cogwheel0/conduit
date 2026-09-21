import 'dart:async';

/// Schedules a coalesced UI flush (WP-1.10).
///
/// The streaming pipeline buffers deltas and flushes them as a batch, and
/// *when* that batch lands decides whether the tail renders in the same frame
/// or one frame late. On mobile that means
/// `SchedulerBinding.scheduleFrameCallback`, which runs at the start of the
/// requested frame so Riverpod can rebuild within it — a post-frame callback
/// would spend a frame doing nothing, then schedule a second one for the
/// provider update.
///
/// The desktop renderer has the same problem and a different answer
/// (`requestAnimationFrame`), and the daemon — which does the buffering — has
/// no frames at all and simply coalesces on a timer. None of that belongs in
/// the turn pipeline.
abstract interface class FlushScheduler {
  /// Runs [callback] at the next opportunity to paint.
  ///
  /// Implementations must not coalesce calls themselves; the caller already
  /// guards with its own "frame scheduled" flag and relies on being called
  /// exactly once per request.
  void scheduleFlush(void Function() callback);
}

/// Flushes on a microtask.
///
/// The right behaviour where there are no frames — the daemon, and tests,
/// where it also keeps ordering deterministic instead of depending on a test
/// binding pumping frames.
class MicrotaskFlushScheduler implements FlushScheduler {
  const MicrotaskFlushScheduler();

  @override
  void scheduleFlush(void Function() callback) => scheduleMicrotask(callback);
}

/// Runs the callback immediately, in the caller's stack.
///
/// Only for tests that assert synchronously on a flush. Using it in
/// production would defeat the coalescing the buffer exists for.
class ImmediateFlushScheduler implements FlushScheduler {
  const ImmediateFlushScheduler();

  @override
  void scheduleFlush(void Function() callback) => callback();
}
