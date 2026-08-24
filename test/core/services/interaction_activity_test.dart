import 'package:checks/checks.dart';
import 'package:conduit/core/services/interaction_activity.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => InteractionActivity.instance.debugReset());
  tearDown(() => InteractionActivity.instance.debugReset());

  test('whenIdle completes immediately with no interaction', () {
    fakeAsync((async) {
      var completed = false;
      InteractionActivity.instance.whenIdle.then((_) => completed = true);
      async.flushMicrotasks();
      check(completed).isTrue();
    });
  });

  test('whenIdle waits for interaction end plus cool-down', () {
    fakeAsync((async) {
      final activity = InteractionActivity.instance;
      activity.beginInteraction();
      var completed = false;
      activity.whenIdle.then((_) => completed = true);
      async.flushMicrotasks();
      check(completed).isFalse();

      activity.endInteraction();
      async.flushMicrotasks();
      // Still cooling down: a catch-and-refling gap must not admit work.
      check(completed).isFalse();
      check(activity.isInteracting).isTrue();

      async.elapse(InteractionActivity.idleCooldown);
      async.flushMicrotasks();
      check(completed).isTrue();
      check(activity.isInteracting).isFalse();
    });
  });

  test('a new interaction during cool-down keeps waiters deferred', () {
    fakeAsync((async) {
      final activity = InteractionActivity.instance;
      activity.beginInteraction();
      var completed = false;
      activity.whenIdle.then((_) => completed = true);
      activity.endInteraction();
      async.elapse(const Duration(milliseconds: 100));

      // Re-fling before the cool-down expires.
      activity.beginInteraction();
      async.elapse(InteractionActivity.idleCooldown * 2);
      async.flushMicrotasks();
      check(completed).isFalse();

      activity.endInteraction();
      async.elapse(InteractionActivity.idleCooldown);
      async.flushMicrotasks();
      check(completed).isTrue();
    });
  });

  test('maxDeferral bounds starvation under a stuck interaction', () {
    fakeAsync((async) {
      final activity = InteractionActivity.instance;
      activity.beginInteraction();
      var completed = false;
      activity.whenIdle.then((_) => completed = true);

      async.elapse(InteractionActivity.maxDeferral);
      async.flushMicrotasks();
      check(completed).isTrue();
      // The interaction itself is still considered active.
      check(activity.isInteracting).isTrue();
    });
  });

  test('nested interactions require all ends before idle', () {
    fakeAsync((async) {
      final activity = InteractionActivity.instance;
      activity.beginInteraction();
      activity.beginInteraction();
      var completed = false;
      activity.whenIdle.then((_) => completed = true);

      activity.endInteraction();
      async.elapse(InteractionActivity.idleCooldown * 2);
      async.flushMicrotasks();
      check(completed).isFalse();

      activity.endInteraction();
      async.elapse(InteractionActivity.idleCooldown);
      async.flushMicrotasks();
      check(completed).isTrue();
    });
  });

  test('touch-down alone never defers background work', () {
    fakeAsync((async) {
      final activity = InteractionActivity.instance;
      // A tap boosts the display but is not an "interaction": whenIdle must
      // not wait on it.
      activity.notifyTouchDown();
      var completed = false;
      activity.whenIdle.then((_) => completed = true);
      async.flushMicrotasks();
      check(completed).isTrue();
      check(activity.isInteracting).isFalse();
      // Grace timer expiry is a no-op beyond releasing the boost.
      async.elapse(InteractionActivity.touchBoostGrace * 2);
    });
  });

  test('unbalanced endInteraction is harmless', () {
    fakeAsync((async) {
      final activity = InteractionActivity.instance;
      activity.endInteraction();
      async.elapse(InteractionActivity.idleCooldown);
      var completed = false;
      activity.whenIdle.then((_) => completed = true);
      async.flushMicrotasks();
      check(completed).isTrue();
    });
  });
}
