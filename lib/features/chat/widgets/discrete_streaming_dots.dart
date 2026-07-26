import 'dart:async';

import 'package:flutter/material.dart';

/// A low-frequency streaming indicator that never schedules display-rate
/// animation frames.
///
/// The active dot advances as a discrete state update. The timer is suspended
/// with the route's [TickerMode], while the app is backgrounded, and whenever
/// motion is disabled.
class DiscreteStreamingDots extends StatefulWidget {
  const DiscreteStreamingDots({
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
  State<DiscreteStreamingDots> createState() => _DiscreteStreamingDotsState();
}

class _DiscreteStreamingDotsState extends State<DiscreteStreamingDots>
    with WidgetsBindingObserver {
  Timer? _stepTimer;
  int _activeIndex = 0;
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
  void didUpdateWidget(covariant DiscreteStreamingDots oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate != oldWidget.animate ||
        widget.stepInterval != oldWidget.stepInterval) {
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
      if (_activeIndex != 0) {
        if (rebuildOnReset) {
          setState(() => _activeIndex = 0);
        } else {
          _activeIndex = 0;
        }
      }
      return;
    }
    if (_stepTimer?.isActive ?? false) return;
    _stepTimer = Timer.periodic(widget.stepInterval, (_) {
      if (!mounted) return;
      setState(() => _activeIndex = (_activeIndex + 1) % 3);
    });
  }

  @override
  Widget build(BuildContext context) {
    final dotSize = widget.size * 0.2;
    final gap = widget.size * 0.12;
    final inactiveColor = widget.color.withValues(alpha: widget.color.a * 0.32);

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < 3; index += 1) ...[
              if (index > 0) SizedBox(width: gap),
              Container(
                key: ValueKey<String>('streaming-dot-$index'),
                width: dotSize,
                height: dotSize,
                decoration: BoxDecoration(
                  color: widget.animate && index != _activeIndex
                      ? inactiveColor
                      : widget.color,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ],
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
