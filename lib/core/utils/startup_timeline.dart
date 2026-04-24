import 'dart:developer' as developer;

import 'debug_logger.dart';

/// Cross-file accessor for cold-start timing markers.
///
/// `main.dart` calls [start] once at process boot and [finish] after the first
/// frame paints. Other code (auth init, cache hydration, first chat paint)
/// calls [instant] to record where time goes between boot and interactivity.
///
/// Markers are recorded both via Dart's [developer.TimelineTask] (visible in
/// DevTools) and as named offsets summarised in the `cold-start-budget` log.
class StartupTimeline {
  StartupTimeline._();

  static developer.TimelineTask? _task;
  static DateTime? _startedAt;
  static final Map<String, Duration> _markers = <String, Duration>{};
  static bool _budgetLogged = false;

  /// Begin the timeline. Safe to call multiple times — no-ops after the first.
  static void start() {
    if (_task != null) return;
    _task = developer.TimelineTask();
    _task!.start('app_startup');
    _startedAt = DateTime.now();
    _markers.clear();
    _budgetLogged = false;
  }

  /// Record a named instant. Idempotent — first call wins per name so that
  /// providers which rebuild don't keep overwriting their first-paint time.
  static void instant(String name) {
    final task = _task;
    final startedAt = _startedAt;
    if (task == null || startedAt == null) return;
    if (_markers.containsKey(name)) return;
    task.instant(name);
    _markers[name] = DateTime.now().difference(startedAt);
  }

  /// End the timeline and emit a single `cold-start-budget` summary log.
  static void finish() {
    final task = _task;
    if (task == null) return;
    task.finish();
    _task = null;
    if (_budgetLogged) return;
    _budgetLogged = true;
    DebugLogger.log(
      'cold-start-budget',
      scope: 'app/startup',
      data: {
        for (final entry in _markers.entries)
          entry.key: entry.value.inMilliseconds,
      },
    );
  }

  /// Total milliseconds from [start] to now (or to [finish] if completed).
  /// Returns null if [start] has not been called.
  static int? get elapsedMs {
    final startedAt = _startedAt;
    if (startedAt == null) return null;
    return DateTime.now().difference(startedAt).inMilliseconds;
  }
}
