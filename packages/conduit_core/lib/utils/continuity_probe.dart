import 'dart:convert';
import 'dart:developer' as developer;

/// Opt-in timing markers. Records stages and sizes, never payload contents.
class ContinuityProbe {
  static const enabled = bool.fromEnvironment('CONDUIT_MOTION_PROBE');
  static int _operation = 0;

  /// Measures async wait time, not CPU time. Callers supply only fixed stage
  /// names and non-sensitive counts/flags, never request bodies or addresses.
  static Future<T> measure<T>(
    String stage,
    Future<T> Function() action, [
    Map<String, Object?> values = const {},
  ]) {
    if (!enabled) return action();
    return _measure(stage, action, values);
  }

  static Future<T> _measure<T>(
    String stage,
    Future<T> Function() action,
    Map<String, Object?> values,
  ) async {
    final operation = ++_operation;
    final elapsed = Stopwatch()..start();
    mark('$stage-start', {'operation': operation, ...values});
    var succeeded = false;
    try {
      final result = await action();
      succeeded = true;
      return result;
    } finally {
      mark('$stage-end', {
        'operation': operation,
        'elapsedUs': elapsed.elapsedMicroseconds,
        'succeeded': succeeded,
        ...values,
      });
    }
  }

  static void mark(String stage, [Map<String, Object?> values = const {}]) {
    if (!enabled) return;
    final data = {
      'stage': stage,
      'monoUs': developer.Timeline.now,
      'wallUs': DateTime.now().microsecondsSinceEpoch,
      ...values,
    };
    developer.Timeline.instantSync('conduit.continuity', arguments: data);
    // ignore: avoid_print
    print('CONDUIT_CONTINUITY ${jsonEncode(data)}');
  }
}
