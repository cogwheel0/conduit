import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Conduit's low-frequency streaming mark.
///
/// Five tapered nodes advance around a quiet track as discrete paint updates.
/// This retains the character of an orbiting indicator without scheduling
/// display-rate animation frames or changing layout while text streams.
class ConduitStreamingOrbit extends StatefulWidget {
  const ConduitStreamingOrbit({
    super.key,
    required this.color,
    required this.size,
    this.animate = true,
    this.stepInterval = const Duration(milliseconds: 400),
  });

  final Color color;
  final double size;
  final bool animate;
  final Duration stepInterval;

  @override
  State<ConduitStreamingOrbit> createState() => _ConduitStreamingOrbitState();
}

class _ConduitStreamingOrbitState extends State<ConduitStreamingOrbit>
    with WidgetsBindingObserver {
  Timer? _stepTimer;
  int _phase = 0;
  bool _tickerModeEnabled = true;
  bool _appForeground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appForeground = _isForeground(WidgetsBinding.instance.lifecycleState);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _syncTimer(rebuildOnReset: false);
  }

  @override
  void didUpdateWidget(covariant ConduitStreamingOrbit oldWidget) {
    super.didUpdateWidget(oldWidget);
    final intervalChanged = widget.stepInterval != oldWidget.stepInterval;
    if (intervalChanged) {
      _stepTimer?.cancel();
      _stepTimer = null;
    }
    if (widget.animate != oldWidget.animate || intervalChanged) {
      _syncTimer(rebuildOnReset: false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final appForeground = _isForeground(state);
    if (_appForeground == appForeground) return;
    _appForeground = appForeground;
    _syncTimer();
  }

  bool _isForeground(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;

  void _syncTimer({bool rebuildOnReset = true}) {
    final shouldStep = widget.animate && _tickerModeEnabled && _appForeground;
    if (!shouldStep) {
      _stepTimer?.cancel();
      _stepTimer = null;
      if (_phase != 0) {
        if (rebuildOnReset) {
          setState(() => _phase = 0);
        } else {
          _phase = 0;
        }
      }
      return;
    }
    if (_stepTimer?.isActive ?? false) return;
    _stepTimer = Timer.periodic(widget.stepInterval, (_) {
      if (!mounted) return;
      setState(() => _phase = (_phase + 1) % 5);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        key: const ValueKey<String>('conduit-streaming-orbit'),
        painter: ConduitStreamingOrbitPainter(
          color: widget.color,
          size: widget.size,
          phase: _phase,
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stepTimer?.cancel();
    super.dispose();
  }
}

@visibleForTesting
class ConduitStreamingOrbitPainter extends CustomPainter {
  const ConduitStreamingOrbitPainter({
    required this.color,
    required this.size,
    required this.phase,
  });

  static const int nodeCount = 5;
  static const List<double> _radiusFactors = <double>[
    0.11,
    0.09,
    0.075,
    0.06,
    0.05,
  ];
  static const List<double> _alphaFactors = <double>[1, 0.72, 0.48, 0.30, 0.18];

  final Color color;
  final double size;
  final int phase;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final center = canvasSize.center(Offset.zero);
    final orbitRadius = size * 0.31;
    final trackRadius = size * 0.305;
    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, size * 0.04)
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: color.a * 0.12);
    canvas.drawCircle(center, trackRadius, trackPaint);

    for (var index = 0; index < nodeCount; index += 1) {
      final trailIndex = (phase - index) % nodeCount;
      final angle = -math.pi / 2 + (math.pi * 2 * index / nodeCount);
      final nodeCenter =
          center +
          Offset(math.cos(angle) * orbitRadius, math.sin(angle) * orbitRadius);
      final paint = Paint()
        ..color = color.withValues(alpha: color.a * _alphaFactors[trailIndex]);
      canvas.drawCircle(nodeCenter, size * _radiusFactors[trailIndex], paint);
    }
  }

  @override
  bool shouldRepaint(covariant ConduitStreamingOrbitPainter oldDelegate) {
    return phase != oldDelegate.phase ||
        color != oldDelegate.color ||
        size != oldDelegate.size;
  }
}
