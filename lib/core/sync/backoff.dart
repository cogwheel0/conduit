import 'dart:math' as math;

import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'backoff.g.dart';

/// Exponential FULL-JITTER backoff (CDT-RFC-001 §7.2, A6).
///
/// `delay = random(0, min(cap, base * 2^attempt))`. The jitter source is
/// injected so tests are deterministic: pass `() => 0.0` for the floor
/// (`0`), `() => 1.0 - epsilon` for the ceiling (`window - 1` ms via
/// `floor()`).
///
/// `attempt` is the attempt index AFTER the failing attempt has been counted
/// (0-based): the FIRST retry passes `attempt = newAttempts - 1 = 0`, so its
/// window is `[0, base)`; the second retry passes `attempt = 1`, window
/// `[0, 2*base)`; and so on until the window saturates at `cap`.
class Backoff {
  const Backoff({
    this.baseMs = 2000,
    this.capMs = 300000,
    required this.jitter,
  });

  /// Base delay in milliseconds (the §7.2 floor of the schedule: 2s).
  final int baseMs;

  /// Cap in milliseconds (the §7.2 ceiling: 5min).
  final int capMs;

  /// Returns a value in `[0, 1)`.
  final double Function() jitter;

  /// Full-jitter delay in milliseconds for a 0-based [attempt] index.
  int delayMsForAttempt(int attempt) {
    // Clamp the shift to avoid 1<<n overflow; the window saturates at capMs
    // long before attempt reaches 30 anyway.
    final shift = attempt.clamp(0, 30).toInt();
    final window = (baseMs * (1 << shift)).clamp(baseMs, capMs);
    final sample = jitter();
    final boundedJitter = sample.isNaN
        ? 0.0
        : sample.clamp(0.0, 0.9999999999999999);
    return (window * boundedJitter).floor();
  }
}

@Riverpod(keepAlive: true)
Backoff backoff(Ref ref) => Backoff(jitter: math.Random().nextDouble);
