import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

// Give the visual meter more movement without changing recognition audio.
double _visualLevel(double level) => (level * 1.25).clamp(0.0, 1.0);

/// Contour 09: a fixed outline with a traveling highlight, never a waveform.
class RecordingContour extends StatefulWidget {
  const RecordingContour({
    super.key,
    required this.active,
    required this.level,
    required this.color,
    required this.borderRadius,
    required this.reduceMotion,
    required this.child,
  });

  final bool active;
  final ValueListenable<double> level;
  final Color color;
  final BorderRadius borderRadius;
  final bool reduceMotion;
  final Widget child;

  @override
  State<RecordingContour> createState() => _RecordingContourState();
}

class _RecordingContourState extends State<RecordingContour>
    with TickerProviderStateMixin {
  late final _clock = AnimationController(
    vsync: this,
    duration: const Duration(hours: 1),
  );
  late final _visibility = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    reverseDuration: const Duration(milliseconds: 480),
  );

  @override
  void initState() {
    super.initState();
    _updateMotion();
  }

  @override
  void didUpdateWidget(RecordingContour oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active ||
        oldWidget.reduceMotion != widget.reduceMotion) {
      _updateMotion();
    }
  }

  void _updateMotion() {
    if (widget.reduceMotion) {
      _clock.stop();
      _visibility.value = widget.active ? 1 : 0;
    } else if (widget.active) {
      _clock.value = 0;
      _clock.repeat();
      _visibility.forward();
    } else {
      _visibility.reverse().whenCompleteOrCancel(() {
        if (mounted && !widget.active) _clock.stop();
      });
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    _visibility.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.passthrough,
    children: [
      widget.child,
      Positioned.fill(
        child: IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(
              key: const ValueKey('composer-recording-contour'),
              painter: _ContourPainter(
                clock: _clock,
                visibility: _visibility,
                level: widget.level,
                color: widget.color,
                radius: widget.borderRadius,
                reduceMotion: widget.reduceMotion,
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

class _ContourPainter extends CustomPainter {
  _ContourPainter({
    required this.clock,
    required this.visibility,
    required this.level,
    required this.color,
    required this.radius,
    required this.reduceMotion,
  }) : super(repaint: Listenable.merge([clock, visibility, level]));

  final Animation<double> clock;
  final Animation<double> visibility;
  final ValueListenable<double> level;
  final Color color;
  final BorderRadius radius;
  final bool reduceMotion;

  @override
  void paint(Canvas canvas, Size size) {
    final opacity = Curves.easeOutCubic.transform(visibility.value);
    if (opacity == 0 || size.isEmpty) return;
    final rect = Offset.zero & size;
    final outline = radius.toRRect(rect).deflate(2);
    final path = Path()..addRRect(outline);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: opacity * 0.38)
      ..strokeWidth = 1.1 + _visualLevel(level.value) * 1.2;
    canvas.drawPath(path, paint);
    if (reduceMotion) return;
    final metric = path.computeMetrics().first;
    final start = (clock.value * 3600 * 80) % metric.length;
    final end = start + math.min(80, metric.length * 0.25);
    paint
      ..color = color.withValues(alpha: opacity)
      ..strokeWidth = 2.4;
    canvas.drawPath(
      metric.extractPath(start, math.min(end, metric.length)),
      paint,
    );
    if (end > metric.length) {
      canvas.drawPath(metric.extractPath(0, end - metric.length), paint);
    }
  }

  @override
  bool shouldRepaint(_ContourPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.radius != radius ||
      oldDelegate.reduceMotion != reduceMotion ||
      oldDelegate.level != level;
}

/// The straight audio meter and elapsed time shown in the text-entry area.
class RecordingContourMeter extends StatefulWidget {
  const RecordingContourMeter({
    super.key,
    required this.level,
    required this.color,
    required this.recordingColor,
    required this.label,
    required this.reduceMotion,
    this.elapsedBeforeMount = Duration.zero,
  });

  final ValueListenable<double> level;
  final Color color;
  final Color recordingColor;
  final String label;
  final bool reduceMotion;
  final Duration elapsedBeforeMount;

  @override
  State<RecordingContourMeter> createState() => _RecordingContourMeterState();
}

class _RecordingContourMeterState extends State<RecordingContourMeter> {
  late final _initialSeconds = widget.elapsedBeforeMount.inSeconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = _initialSeconds + (_timer?.tick ?? 0);
    final elapsed =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    return Semantics(
      label: widget.label,
      child: ExcludeSemantics(
        child: Row(
          children: [
            Expanded(
              child: ValueListenableBuilder<double>(
                valueListenable: widget.level,
                builder: (context, level, _) => TweenAnimationBuilder<double>(
                  tween: Tween(end: _visualLevel(level)),
                  duration: widget.reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 120),
                  curve: Curves.easeOutCubic,
                  builder: (context, value, _) => SizedBox(
                    height: 6,
                    child: CustomPaint(
                      key: const ValueKey('composer-recording-meter'),
                      painter: _MeterPainter(value, widget.color),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: widget.recordingColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              elapsed,
              key: const ValueKey('composer-recording-elapsed'),
              style: TextStyle(fontSize: 14, color: widget.color),
            ),
          ],
        ),
      ),
    );
  }
}

class _MeterPainter extends CustomPainter {
  _MeterPainter(this.level, this.color);
  final double level;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..color = color.withValues(alpha: 0.3)
        ..strokeWidth = 1,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          0,
          0,
          math.min(size.width, math.max(2, size.width * level)),
          size.height,
        ),
        const Radius.circular(3),
      ),
      Paint()..color = color.withValues(alpha: 0.8),
    );
  }

  @override
  bool shouldRepaint(_MeterPainter oldDelegate) =>
      level != oldDelegate.level || color != oldDelegate.color;
}
