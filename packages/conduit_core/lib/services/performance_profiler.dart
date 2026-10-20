import 'dart:developer' as developer;

import '../utils/debug_logger.dart';

class PerformanceProfiler {
  PerformanceProfiler._();

  static final PerformanceProfiler instance = PerformanceProfiler._();

  // Was Flutter's kReleaseMode, which is this constant.
  static bool get isEnabled => !const bool.fromEnvironment('dart.vm.product');

  final Map<String, developer.TimelineTask> _activeTasks =
      <String, developer.TimelineTask>{};

  void instant(
    String name, {
    String scope = 'perf',
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    if (!isEnabled) {
      return;
    }
    developer.Timeline.instantSync(
      eventName(scope, name),
      arguments: sanitizeData(data),
    );
  }

  String startTask(
    String name, {
    String scope = 'perf',
    String? key,
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    if (!isEnabled) {
      return key ?? '';
    }

    final effectiveKey =
        key ?? '$scope:$name:${DateTime.now().microsecondsSinceEpoch}';
    finishTask(effectiveKey);

    final task = developer.TimelineTask();
    task.start(eventName(scope, name), arguments: sanitizeData(data));
    _activeTasks[effectiveKey] = task;
    return effectiveKey;
  }

  void finishTask(
    String? key, {
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    if (!isEnabled || key == null || key.isEmpty) {
      return;
    }

    final task = _activeTasks.remove(key);
    if (task == null) {
      return;
    }
    task.finish(arguments: sanitizeData(data));
  }

  Future<T> runAsync<T>(
    String name,
    Future<T> Function() body, {
    String scope = 'perf',
    String? key,
    Map<String, Object?> data = const <String, Object?>{},
    Map<String, Object?> Function(T result)? finishData,
  }) async {
    final taskKey = startTask(name, scope: scope, key: key, data: data);
    try {
      final result = await body();
      finishTask(taskKey, data: finishData?.call(result) ?? const {});
      return result;
    } catch (error, stackTrace) {
      finishTask(taskKey, data: {'error': error.toString()});
      DebugLogger.error(
        'profile-task-failed',
        scope: scope,
        error: error,
        stackTrace: stackTrace,
        data: {'task': name},
      );
      rethrow;
    }
  }

  /// Begins collecting presentation-cadence samples until [stopFrameCadence].
  ///
  /// "Streaky but not janky" scrolling is a cadence problem, not a workload
  /// problem: frames complete under budget yet present at uneven intervals
  /// (60/80/120 Hz switching, missed-then-caught-up vsyncs). Workload-based
  /// slow-frame logging cannot see it; deltas between raster-finish wall
  /// times can.
  /// Exposed for `FrameProfiler`, which emits the same timeline events
  /// from the Flutter side of the split.
  static String eventName(String scope, String name) {
    final normalizedScope = scope.trim().replaceAll(' ', '_');
    final normalizedName = name.trim().replaceAll(' ', '_');
    return '$normalizedScope/$normalizedName';
  }

  /// See [eventName].
  static Map<String, Object> sanitizeData(Map<String, Object?> data) {
    if (data.isEmpty) {
      return const <String, Object>{};
    }

    final result = <String, Object>{};
    data.forEach((key, value) {
      result[key] = switch (value) {
        null => 'null',
        final num number => number,
        final bool flag => flag,
        final String text => text,
        final Duration duration => duration.inMicroseconds,
        final Enum enumValue => enumValue.name,
        _ => value.toString(),
      };
    });
    return result;
  }
}
