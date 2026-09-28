import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart';

/// Callbacks a fake-time test body may schedule. Real tests schedule a few
/// hundred; code that keeps rescheduling itself with no delay reaches this in
/// well under a second instead of spinning the fake clock forever (which the
/// test timeout, a real timer, could never interrupt).
const int _callbackBudget = 100000;

/// Declares a test whose body runs on fake time: its timers, timeouts, and
/// delays advance with the fake clock instead of the wall clock, so waiting
/// out a deadline costs nothing and never races a busy machine.
///
/// Waits measured with a [Stopwatch] or [DateTime.now] still use real time.
@isTest
void fakeTimeTest(String description, Future<void> Function() body) {
  test(description, () {
    fakeAsync((async) {
      var done = false;
      Object? error;
      StackTrace? stackTrace;
      var callbacks = 0;
      bool admit() => ++callbacks <= _callbackBudget;
      runZoned(
        () => body().then(
          (_) => done = true,
          onError: (Object e, StackTrace s) {
            error = e;
            stackTrace = s;
            done = true;
          },
        ),
        zoneSpecification: ZoneSpecification(
          scheduleMicrotask: (self, parent, zone, callback) {
            if (admit()) parent.scheduleMicrotask(zone, callback);
          },
          createTimer: (self, parent, zone, duration, callback) =>
              parent.createTimer(zone, duration, admit() ? callback : () {}),
        ),
      );
      const limit = Duration(minutes: 1);
      while (!done && callbacks <= _callbackBudget && async.elapsed < limit) {
        async.elapse(const Duration(milliseconds: 10));
      }
      if (callbacks > _callbackBudget) {
        fail(
          'The test body scheduled more than $_callbackBudget callbacks; '
          'something is rescheduling itself without a delay.',
        );
      }
      if (error != null) Error.throwWithStackTrace(error!, stackTrace!);
      if (!done) fail('The test body did not finish within $limit');
    });
  });
}
