import 'package:checks/checks.dart';
import 'package:conduit/core/sync/backoff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Backoff.delayMsForAttempt (full jitter, A6)', () {
    test('jitter 0.0 floors every window to 0', () {
      final backoff = Backoff(jitter: () => 0.0);
      for (var attempt = 0; attempt < 10; attempt++) {
        check(backoff.delayMsForAttempt(attempt)).equals(0);
      }
    });

    test('ceiling jitter yields window-1 ms (floor of window*~1.0)', () {
      // 0.999999 * window then floored == window - 1 for these windows.
      final backoff = Backoff(jitter: () => 0.999999);
      // attempt 0 -> window = base = 2000.
      check(backoff.delayMsForAttempt(0)).equals(1999);
      // attempt 1 -> window = 4000.
      check(backoff.delayMsForAttempt(1)).equals(3999);
      // attempt 2 -> window = 8000.
      check(backoff.delayMsForAttempt(2)).equals(7999);
    });

    test('exponential doubling of the window with the attempt index', () {
      // Half jitter makes the delay exactly half the window, exposing the
      // window size deterministically.
      final backoff = Backoff(jitter: () => 0.5);
      check(backoff.delayMsForAttempt(0)).equals(1000); // window 2000
      check(backoff.delayMsForAttempt(1)).equals(2000); // window 4000
      check(backoff.delayMsForAttempt(2)).equals(4000); // window 8000
      check(backoff.delayMsForAttempt(3)).equals(8000); // window 16000
    });

    test('window saturates at the cap (5 min default)', () {
      final ceil = Backoff(jitter: () => 0.999999);
      // 2000 * 2^8 = 512000 > 300000 cap; window clamps to 300000.
      check(ceil.delayMsForAttempt(8)).equals(299999);
      check(ceil.delayMsForAttempt(20)).equals(299999);
      // half jitter -> exactly half the capped window.
      final half = Backoff(jitter: () => 0.5);
      check(half.delayMsForAttempt(8)).equals(150000);
      check(half.delayMsForAttempt(30)).equals(150000);
    });

    test('huge attempt indices never overflow (shift clamped)', () {
      final half = Backoff(jitter: () => 0.5);
      // attempt 1000 must not throw / overflow; stays at the capped half.
      check(half.delayMsForAttempt(1000)).equals(150000);
    });

    test('honors custom base and cap', () {
      final backoff = Backoff(
        baseMs: 1000,
        capMs: 4000,
        jitter: () => 0.999999,
      );
      check(backoff.delayMsForAttempt(0)).equals(999); // window 1000
      check(backoff.delayMsForAttempt(1)).equals(1999); // window 2000
      check(backoff.delayMsForAttempt(2)).equals(3999); // window 4000
      check(backoff.delayMsForAttempt(3)).equals(3999); // window clamps to cap
    });

    test('clamps invalid jitter samples into the full-jitter window', () {
      check(Backoff(jitter: () => -0.5).delayMsForAttempt(0)).equals(0);
      check(Backoff(jitter: () => 1.0).delayMsForAttempt(0)).equals(1999);
      check(Backoff(jitter: () => double.nan).delayMsForAttempt(0)).equals(0);
    });
  });
}
