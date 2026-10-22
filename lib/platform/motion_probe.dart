import 'dart:ui' show FramePhase;
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

/// Geometry and Flutter timings for opt-in physical-device measurements.
/// No text, model, account, or request contents are recorded.
class MotionProbe {
  static const enabled = bool.fromEnvironment('CONDUIT_MOTION_PROBE');
  // Timing-only captures must not pay for geometry JSON, logcat and barcode
  // repaint on every frame. This is opt-in measurement, never app behavior.
  static const quiet = bool.fromEnvironment('CONDUIT_MOTION_PROBE_QUIET');
  static final _frames = <Map<String, Object?>>[];
  static final _boxes = <String, _GeometryBox>{};
  static bool _installed = false;
  static final stamp = ValueNotifier<int>(0);

  static void install() {
    if (!enabled || _installed) return;
    _installed = true;
    if (quiet) {
      developer.registerExtension('ext.conduit.motionFrames', (_, args) async {
        if (args['clear'] == 'true') _frames.clear();
        return developer.ServiceExtensionResponse.result(
          jsonEncode({'frames': _frames}),
        );
      });
    }
    WidgetsBinding.instance.addObserver(_MetricObserver());
    if (!quiet) {
      const MethodChannel('app.cogwheel.conduit/keyboard_insets')
          .invokeMethod<void>('startContinuityProbe')
          .catchError((Object _) {});
    }
    SchedulerBinding.instance.addTimingsCallback((frames) {
      for (final frame in frames) {
        final data = <String, Object?>{
          'vsync': frame.timestampInMicroseconds(FramePhase.vsyncStart),
          'buildStart': frame.timestampInMicroseconds(FramePhase.buildStart),
          'rasterFinish': frame.timestampInMicroseconds(
            FramePhase.rasterFinish,
          ),
          'buildUs': frame.buildDuration.inMicroseconds,
          'rasterUs': frame.rasterDuration.inMicroseconds,
          'totalUs': frame.totalSpan.inMicroseconds,
        };
        if (quiet) {
          if (_frames.length == 2000) _frames.removeRange(0, 1000);
          _frames.add(data);
        } else {
          _emit('frame', data);
        }
      }
    });
    if (quiet) return;
    SchedulerBinding.instance.addPersistentFrameCallback((_) {
      stamp.value = (stamp.value + 1) & 0xffff;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        final view = WidgetsBinding.instance.platformDispatcher.views.first;
        final dpr = view.devicePixelRatio;
        final boxes = <String, Object?>{};
        for (final entry in _boxes.entries) {
          final box = entry.value;
          if (!box.attached || !box.hasSize) continue;
          final origin = box.localToGlobal(Offset.zero);
          boxes[entry.key] = {
            'top': origin.dy,
            'bottom': origin.dy + box.size.height,
            'width': box.size.width,
            ...?box.data?.call(),
          };
        }
        if (boxes.isNotEmpty) {
          _emit('geometry', {
            'inset': view.viewInsets.bottom / dpr,
            'viewHeight': view.physicalSize.height / dpr,
            'dpr': dpr,
            'boxes': boxes,
          });
        }
      });
    });
  }

  static Widget wrap(
    String label,
    Widget child, {
    Map<String, Object?> Function()? data,
  }) => enabled && !quiet
      ? _GeometryWidget(label: label, data: data, child: child)
      : child;

  static void mark(String phase) {
    if (enabled) _emit('state', {'phase': phase});
  }

  static void _emit(String type, Map<String, Object?> values) {
    final data = {
      'type': type,
      'wallUs': DateTime.now().microsecondsSinceEpoch,
      'monoUs': developer.Timeline.now,
      'stamp': stamp.value,
      ...values,
    };
    developer.Timeline.instantSync('conduit.motion.$type', arguments: data);
    // Opt-in trace artifacts only; stdout is captured by ADB in profile builds.
    // ignore: avoid_print
    print('CONDUIT_MOTION ${jsonEncode(data)}');
  }

  static Widget overlay(Widget child) => !enabled || quiet
      ? child
      : Stack(
          fit: StackFit.expand,
          children: [
            child,
            Positioned(
              left: 8,
              top: 56,
              width: 384,
              height: 6,
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: CustomPaint(painter: _FrameStamp()),
                ),
              ),
            ),
          ],
        );
}

class _MetricObserver with WidgetsBindingObserver {
  @override
  void didChangeMetrics() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    MotionProbe._emit('metrics', {'insetPx': view.viewInsets.bottom});
  }
}

class _FrameStamp extends CustomPainter {
  _FrameStamp() : super(repaint: MotionProbe.stamp);
  @override
  void paint(Canvas canvas, Size size) {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final boxes = <String, Object?>{};
    for (final entry in MotionProbe._boxes.entries) {
      final box = entry.value;
      if (!box.attached || !box.hasSize) continue;
      final p = box.localToGlobal(Offset.zero);
      boxes[entry.key] = {
        'left': p.dx,
        'top': p.dy,
        'width': box.size.width,
        'bottom': p.dy + box.size.height,
        ...?box.data?.call(),
      };
    }
    final composer = boxes['composer'] as Map<String, Object?>?;
    final bottom =
        ((composer?['bottom'] as double? ?? 0) * view.devicePixelRatio).round();
    final words = [
      0xa55a,
      MotionProbe.stamp.value,
      view.viewInsets.bottom.round(),
      bottom,
    ];
    for (var i = 0; i < 64; i++) {
      final bit = (words[i ~/ 16] >> (15 - i % 16)) & 1;
      canvas.drawRect(
        Rect.fromLTWH(i * 6, 0, 6, size.height),
        Paint()..color = Color(bit == 1 ? 0xffffffff : 0xff000000),
      );
    }
    MotionProbe._emit('paint', {
      'insetPx': view.viewInsets.bottom,
      'composerBottomPx': bottom,
      'boxes': boxes,
    });
  }

  @override
  bool shouldRepaint(covariant _FrameStamp oldDelegate) => false;
}

class _GeometryWidget extends SingleChildRenderObjectWidget {
  const _GeometryWidget({required this.label, this.data, required super.child});
  final String label;
  final Map<String, Object?> Function()? data;
  @override
  _GeometryBox createRenderObject(BuildContext context) =>
      _GeometryBox(label, data);
  @override
  void updateRenderObject(BuildContext context, _GeometryBox renderObject) =>
      renderObject.data = data;
}

class _GeometryBox extends RenderProxyBox {
  _GeometryBox(this.label, this.data);
  final String label;
  Map<String, Object?> Function()? data;
  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    MotionProbe._boxes[label] = this;
  }

  @override
  void detach() {
    if (identical(MotionProbe._boxes[label], this)) {
      MotionProbe._boxes.remove(label);
    }
    super.detach();
  }
}
