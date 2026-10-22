import 'dart:math' as math;

import 'package:conduit_core/models/response_animation.dart';
import 'package:material_ui/material_ui.dart';

/// A fixed-size mark whose animation repaints only its own canvas.
class ResponseActivityIndicator extends StatefulWidget {
  const ResponseActivityIndicator({
    super.key,
    required this.style,
    required this.color,
    this.size = 28,
    this.animate = true,
    this.speed = 1,
    this.hermesDither = false,
  });

  final ResponseIndicatorStyle style;
  final Color color;
  final double size;
  final bool animate;
  final double speed;
  final bool hermesDither;

  @override
  State<ResponseActivityIndicator> createState() =>
      ResponseActivityIndicatorState();
}

class ResponseActivityIndicatorState extends State<ResponseActivityIndicator>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _clock;
  bool _foreground = true;
  bool _tickerEnabled = true;

  /// Freeze the current frame for the short completion exit, without keeping
  /// the running ticker or its layout extent alive.
  ResponseActivityPainter get snapshotPainter => ResponseActivityPainter(
    style: widget.style,
    color: widget.color,
    progress: AlwaysStoppedAnimation(_clock.value),
    hermesDither: widget.hermesDither,
  );

  Duration get _period => Duration(
    milliseconds:
        ((widget.hermesDither ? 5000 : widget.style.cycleMilliseconds) /
                widget.speed.clamp(.5, 2))
            .round(),
  );

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(vsync: this, duration: _period);
    WidgetsBinding.instance.addObserver(this);
    _foreground = _isForeground(WidgetsBinding.instance.lifecycleState);
  }

  bool _isForeground(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _syncClock();
  }

  @override
  void didUpdateWidget(covariant ResponseActivityIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.style != widget.style ||
        oldWidget.speed != widget.speed ||
        oldWidget.hermesDither != widget.hermesDither) {
      _clock.stop();
      _clock.duration = _period;
      _clock.value = 0;
    }
    _syncClock();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = _isForeground(state);
    _syncClock();
  }

  void _syncClock() {
    if (widget.animate && _tickerEnabled && _foreground) {
      if (!_clock.isAnimating) _clock.repeat();
    } else {
      _clock.stop();
      if (!widget.animate) _clock.value = 420 / widget.style.cycleMilliseconds;
    }
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        key: const ValueKey('response-activity-indicator'),
        painter: ResponseActivityPainter(
          style: widget.style,
          color: widget.color,
          progress: _clock,
          hermesDither: widget.hermesDither,
        ),
      ),
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock.dispose();
    super.dispose();
  }
}

@visibleForTesting
class ResponseActivityPainter extends CustomPainter {
  ResponseActivityPainter({
    required this.style,
    required this.color,
    required this.progress,
    this.hermesDither = false,
  }) : super(repaint: progress);

  final ResponseIndicatorStyle style;
  final Color color;
  final Animation<double> progress;
  final bool hermesDither;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 28, size.height / 28);
    if (hermesDither) {
      final t = progress.value * 5000;
      final opacity = t < 400
          ? .75 + .25 * math.cos(t / 400 * math.pi * 2)
          : 1.0;
      final paint = Paint()..color = color.withValues(alpha: color.a * opacity);
      for (var y = 0; y < 6; y++) {
        for (var x = 0; x < 6; x++) {
          if ((x + y).isEven) {
            canvas.drawRect(
              Rect.fromLTWH(x * 28 / 6, y * 28 / 6, 28 / 6, 28 / 6),
              paint,
            );
          }
        }
      }
      canvas.restore();
      return;
    }
    final p = (1 - math.cos(math.pi * 2 * progress.value)) / 2;
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    void line(
      double x1,
      double y1,
      double x2,
      double y2,
      double alpha,
      double width,
    ) {
      paint
        ..color = color.withValues(alpha: color.a * alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = width;
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), paint);
    }

    void polygon(List<Offset> points, double alpha) {
      final path = Path()..addPolygon(points, true);
      paint
        ..color = color.withValues(alpha: color.a * alpha)
        ..style = PaintingStyle.fill;
      canvas.drawPath(path, paint);
    }

    switch (style) {
      case ResponseIndicatorStyle.scan:
        line(7, 7, 21, 7, .26, 1.6);
        line(4, 14, 24, 14, .26, 1.6);
        line(7, 21, 21, 21, .26, 1.6);
        final width = 14 + 6 * math.sin(p * math.pi);
        final y = 7 + 14 * p;
        line(14 - width / 2, y, 14 + width / 2, y, .95, 1.9);
      case ResponseIndicatorStyle.fold:
        final width = 2.4 + 6.6 * p;
        final tilt = 2 * (1 - p);
        polygon([
          const Offset(13, 5),
          Offset(13 - width, 5 + tilt),
          Offset(13 - width, 23 - tilt),
          const Offset(13, 23),
        ], .38 + .4 * p);
        polygon([
          const Offset(15, 5),
          Offset(15 + width, 5 + tilt),
          Offset(15 + width, 23 - tilt),
          const Offset(15, 23),
        ], .88 - .27 * p);
        line(14, 6, 14, 22, .22, 1);
      case ResponseIndicatorStyle.facets:
        double emphasis(int index) {
          return .22 +
              .75 *
                  math.pow(
                    .5 +
                        .5 *
                            math.cos(
                              math.pi * 2 * (progress.value - index / 3),
                            ),
                    4,
                  );
        }
        polygon(const [
          Offset(14, 3),
          Offset(24, 9),
          Offset(14, 15),
          Offset(4, 9),
        ], emphasis(0));
        polygon(const [
          Offset(4, 10.5),
          Offset(13.25, 16),
          Offset(13.25, 26),
          Offset(4, 20.5),
        ], emphasis(1));
        polygon(const [
          Offset(14.75, 16),
          Offset(24, 10.5),
          Offset(24, 20.5),
          Offset(14.75, 26),
        ], emphasis(2));
      case ResponseIndicatorStyle.gather:
        final d = 7.2 - 3 * p;
        for (var i = 0; i < 4; i++) {
          final x = 14 + (i.isOdd ? 1 : -1) * d - 2.5;
          final y = 14 + (i < 2 ? -1 : 1) * d - 2.5;
          paint
            ..style = PaintingStyle.fill
            ..color = color.withValues(
              alpha: color.a * (.5 + .35 * p + (i == 0 ? .12 : 0)),
            );
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(x, y, 5, 5),
              const Radius.circular(1.35),
            ),
            paint,
          );
        }
      case ResponseIndicatorStyle.exchange:
        final shift = p * 2.4;
        void chevron(List<Offset> points, double alpha) {
          paint
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.9
            ..color = color.withValues(alpha: color.a * alpha);
          canvas.drawPath(
            Path()
              ..moveTo(points[0].dx, points[0].dy)
              ..lineTo(points[1].dx, points[1].dy)
              ..lineTo(points[2].dx, points[2].dy),
            paint,
          );
        }
        chevron([
          Offset(9 + shift, 7),
          Offset(3 + shift, 14),
          Offset(9 + shift, 21),
        ], .38 + .54 * p);
        chevron([
          Offset(19 - shift, 7),
          Offset(25 - shift, 14),
          Offset(19 - shift, 21),
        ], .92 - .54 * p);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ResponseActivityPainter oldDelegate) =>
      oldDelegate.style != style ||
      oldDelegate.hermesDither != hermesDither ||
      oldDelegate.color != color ||
      oldDelegate.progress != progress;
}
