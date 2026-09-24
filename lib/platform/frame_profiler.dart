import 'dart:developer' as developer;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:conduit_core/services/performance_profiler.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/scheduler.dart';

/// Frame instrumentation for the Flutter app.
///
/// Split out of [PerformanceProfiler] because frames are the one thing in it
/// that only a Flutter host has. The task and timeline half is used from 38
/// places across the core and had no business dragging `dart:ui` and
/// `SchedulerBinding` behind it into the sidecar's dependency closure.
class FrameProfiler {
  FrameProfiler._();

  static final FrameProfiler instance = FrameProfiler._();

  bool _frameTimingsAttached = false;
  DateTime? _lastSlowFrameLogAt;
  _FrameCadenceRecording? _cadenceRecording;

  void attachFrameTimings() {
    if (!PerformanceProfiler.isEnabled || _frameTimingsAttached) {
      return;
    }
    _frameTimingsAttached = true;
    SchedulerBinding.instance.addTimingsCallback(_handleFrameTimings);
  }

  void startFrameCadence() {
    if (!PerformanceProfiler.isEnabled) return;
    attachFrameTimings();
    _cadenceRecording = _FrameCadenceRecording();
  }

  /// Ends collection and logs an interval histogram summary.
  ///
  /// A buttery scroll shows one tight cluster (all intervals ≈ 1000/refresh
  /// rate ms). Streaking shows either a cluster at a lower rate than the
  /// panel's (display not running at peak) or a multi-modal spread
  /// (uneven presentation).
  void stopFrameCadence({String reason = 'stopped'}) {
    final recording = _cadenceRecording;
    _cadenceRecording = null;
    if (recording == null || !PerformanceProfiler.isEnabled) return;
    final summary = recording.summarize();
    if (summary == null) return;
    DebugLogger.info(
      'frame-cadence',
      scope: 'perf/frame-cadence',
      data: {'reason': reason, ...summary},
    );
  }

  void _handleFrameTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      _cadenceRecording?.addFrame(timing);
      final buildMs = timing.buildDuration.inMicroseconds / 1000.0;
      final rasterMs = timing.rasterDuration.inMicroseconds / 1000.0;
      final totalMs = timing.totalSpan.inMicroseconds / 1000.0;
      final vsyncOverheadMs = timing.vsyncOverhead.inMicroseconds / 1000.0;
      final workloadMs = totalMs - vsyncOverheadMs;

      final isSlowFrame = workloadMs > 16.7 || buildMs > 8.3 || rasterMs > 8.3;
      if (!isSlowFrame) {
        continue;
      }

      final data = <String, Object?>{
        'totalMs': totalMs.toStringAsFixed(2),
        'workloadMs': workloadMs.toStringAsFixed(2),
        'buildMs': buildMs.toStringAsFixed(2),
        'rasterMs': rasterMs.toStringAsFixed(2),
        'vsyncOverheadMs': vsyncOverheadMs.toStringAsFixed(2),
      };
      developer.Timeline.instantSync(
        PerformanceProfiler.eventName('frame', 'slow_frame'),
        arguments: PerformanceProfiler.sanitizeData(data),
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
}

class _FrameCadenceRecording {
  static const int _maxSamples = 2048;

  final List<double> _intervalsMs = <double>[];
  int? _lastRasterFinishMicros;

  void addFrame(FrameTiming timing) {
    final finish = timing.timestampInMicroseconds(FramePhase.rasterFinish);
    final last = _lastRasterFinishMicros;
    _lastRasterFinishMicros = finish;
    if (last == null) return;
    final deltaMs = (finish - last) / 1000.0;
    // Gaps over 200 ms are idle time between gestures, not cadence.
    if (deltaMs <= 0 || deltaMs > 200) return;
    if (_intervalsMs.length < _maxSamples) {
      _intervalsMs.add(deltaMs);
    }
  }

  Map<String, Object?>? summarize() {
    if (_intervalsMs.length < 8) return null;
    final sorted = List<double>.of(_intervalsMs)..sort();
    double at(double fraction) =>
        sorted[((sorted.length - 1) * fraction).round()];
    // Bucket by the display cadences that matter: an interval belongs to
    // the nearest of the 120/90/80/60 Hz presentation slots (8.33 / 11.11 /
    // 12.5 / 16.67 ms), so each boundary is the midpoint between adjacent
    // slots; past the 60 Hz/40 Hz midpoint counts as slower.
    var at120 = 0, at90 = 0, at80 = 0, at60 = 0, slower = 0;
    for (final interval in sorted) {
      if (interval < 9.72) {
        at120 += 1;
      } else if (interval < 11.81) {
        at90 += 1;
      } else if (interval < 14.58) {
        at80 += 1;
      } else if (interval < 20.83) {
        at60 += 1;
      } else {
        slower += 1;
      }
    }
    String percent(int count) =>
        '${(count * 100 / sorted.length).toStringAsFixed(1)}%';
    return <String, Object?>{
      'samples': sorted.length,
      'p50Ms': at(0.5).toStringAsFixed(2),
      'p90Ms': at(0.9).toStringAsFixed(2),
      'p99Ms': at(0.99).toStringAsFixed(2),
      'share120hz': percent(at120),
      'share90hz': percent(at90),
      'share80hz': percent(at80),
      'share60hz': percent(at60),
      'shareSlower': percent(slower),
    };
  }
}
