import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../utils/debug_logger.dart';

class PerformanceProfiler {
  PerformanceProfiler._();

  static final PerformanceProfiler instance = PerformanceProfiler._();

  static bool get isEnabled => !kReleaseMode;

  final Map<String, developer.TimelineTask> _activeTasks =
      <String, developer.TimelineTask>{};
  bool _frameTimingsAttached = false;
  DateTime? _lastSlowFrameLogAt;

  void attachFrameTimings() {
    if (!isEnabled || _frameTimingsAttached) {
      return;
    }
    _frameTimingsAttached = true;
    SchedulerBinding.instance.addTimingsCallback(_handleFrameTimings);
  }

  void instant(
    String name, {
    String scope = 'perf',
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    if (!isEnabled) {
      return;
    }
    developer.Timeline.instantSync(
      _eventName(scope, name),
      arguments: _sanitizeData(data),
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
    task.start(_eventName(scope, name), arguments: _sanitizeData(data));
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
    task.finish(arguments: _sanitizeData(data));
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

  void _handleFrameTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final buildMs = timing.buildDuration.inMicroseconds / 1000.0;
      final rasterMs = timing.rasterDuration.inMicroseconds / 1000.0;
      final totalMs = timing.totalSpan.inMicroseconds / 1000.0;

      final isSlowFrame = totalMs > 16.7 || buildMs > 8.3 || rasterMs > 8.3;
      if (!isSlowFrame) {
        continue;
      }

      final data = <String, Object?>{
        'totalMs': totalMs.toStringAsFixed(2),
        'buildMs': buildMs.toStringAsFixed(2),
        'rasterMs': rasterMs.toStringAsFixed(2),
        'vsyncOverheadMs': (timing.vsyncOverhead.inMicroseconds / 1000.0)
            .toStringAsFixed(2),
      };
      developer.Timeline.instantSync(
        _eventName('frame', 'slow_frame'),
        arguments: _sanitizeData(data),
      );

      final now = DateTime.now();
      final shouldLog =
          _lastSlowFrameLogAt == null ||
          now.difference(_lastSlowFrameLogAt!) >= const Duration(seconds: 2);
      if (shouldLog) {
        _lastSlowFrameLogAt = now;
        DebugLogger.warning('slow-frame', scope: 'perf', data: data);
      }
    }
  }

  static String _eventName(String scope, String name) {
    final normalizedScope = scope.trim().replaceAll(' ', '_');
    final normalizedName = name.trim().replaceAll(' ', '_');
    return '$normalizedScope/$normalizedName';
  }

  static Map<String, Object> _sanitizeData(Map<String, Object?> data) {
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
