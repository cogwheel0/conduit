import 'package:checks/checks.dart';
import 'package:conduit/platform/flutter_flush_scheduler.dart';
import 'package:conduit/platform/flutter_post_frame_scheduler.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two frame ports are easy to confuse and their difference is the whole
/// reason both exist, so it is pinned here rather than left to the doc
/// comments.
///
/// These also make `test/flutter_test_config.dart` load-bearing. It installs
/// the Flutter implementations as the host defaults so the suite keeps the
/// app's timing; without a test that can tell a frame callback from a
/// microtask, that line could be deleted and nothing would notice.
void main() {
  testWidgets('a flush is scheduled into the next frame', (tester) async {
    final log = <String>[];
    const FlutterFlushScheduler().scheduleFlush(() => log.add('flushed'));
    log.add('caller');

    // A frame callback runs at the start of the requested frame, so nothing
    // has happened yet in the turn that asked for it.
    check(log).deepEquals(['caller']);

    await tester.pump();
    check(log).deepEquals(['caller', 'flushed']);
  });

  testWidgets('post-frame work waits for the frame to finish', (tester) async {
    // A post-frame callback runs only when a frame is actually produced, and
    // registering one does not by itself ask for a frame. Verified: without
    // this `scheduleFrame`, the callback never fires no matter how many times
    // the test pumps.
    WidgetsBinding.instance.scheduleFrame();

    final log = <String>[];
    const FlutterPostFrameScheduler().runAfterCurrentFrame(
      () => log.add('deferred'),
    );
    log.add('caller');

    check(log).deepEquals(['caller']);

    await tester.pump();
    check(log).deepEquals(['caller', 'deferred']);
  });

  testWidgets('a post-frame callback needs a frame to have been asked for', (
    tester,
  ) async {
    final log = <String>[];
    const FlutterPostFrameScheduler().runAfterCurrentFrame(
      () => log.add('deferred'),
    );

    await tester.pump();
    await tester.pump();

    // Pinned because it is a real constraint on the callers of this port and
    // is invisible in the app, where something is almost always animating.
    // If nothing has scheduled a frame, deferred work simply never runs.
    check(log).isEmpty();
  });

  testWidgets('neither runs without a frame, unlike the microtask ones', (
    tester,
  ) async {
    final frameBacked = <String>[];
    const FlutterFlushScheduler().scheduleFlush(() => frameBacked.add('flush'));
    const FlutterPostFrameScheduler().runAfterCurrentFrame(
      () => frameBacked.add('post'),
    );

    final frameless = <String>[];
    const MicrotaskFlushScheduler().scheduleFlush(() => frameless.add('flush'));
    const MicrotaskPostFrameScheduler().runAfterCurrentFrame(
      () => frameless.add('post'),
    );

    // `idle()` drains the microtask queue without running a frame, which is
    // exactly the distinction under test. (`Future.delayed` would hang here:
    // inside testWidgets it arms a timer on the fake clock, which only a
    // pump advances.)
    await tester.idle();

    // This is the substitution the host binding exists to prevent: draining
    // the microtask queue is enough for the frameless implementations, and
    // not enough for the frame-backed ones. A test that never pumps would
    // therefore pass for the opposite reason under the wrong binding.
    check(frameBacked).isEmpty();
    check(frameless).deepEquals(['flush', 'post']);

    await tester.pump();
    check(frameBacked).deepEquals(['flush', 'post']);
  });

  testWidgets('the suite runs with the frame-backed hosts installed', (
    tester,
  ) async {
    // flutter_test_config.dart installs these before any test runs.
    check(FlushScheduler.hostDefault).isA<FlutterFlushScheduler>();
    check(PostFrameScheduler.hostDefault).isA<FlutterPostFrameScheduler>();
  });
}
