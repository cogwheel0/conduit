import 'package:conduit_core/conduit_core.dart';
import 'package:flutter/scheduler.dart';

/// The Flutter app's [FlushScheduler].
///
/// Uses `scheduleFrameCallback`, not a post-frame callback, and the
/// distinction is load-bearing. A frame callback runs at the *start* of the
/// requested frame, so Riverpod can rebuild the streaming tail within it. A
/// post-frame callback spends one frame doing no visible work and then
/// schedules a second frame for the provider update — an extra submit that is
/// especially expensive on iOS, where every frame also composites the
/// persistent Liquid Glass platform views.
class FlutterFlushScheduler implements FlushScheduler {
  const FlutterFlushScheduler();

  @override
  void scheduleFlush(void Function() callback) {
    SchedulerBinding.instance.scheduleFrameCallback((_) => callback());
  }
}
