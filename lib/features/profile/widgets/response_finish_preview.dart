import 'package:conduit_core/models/response_animation.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/widgets/response_activity_indicator.dart';
import '../../chat/widgets/response_finish_transition.dart';

/// Repeats a running mark, its actual chat exit, and a quiet empty interval.
class ResponseFinishPreview extends StatefulWidget {
  const ResponseFinishPreview({
    super.key,
    required this.style,
    required this.indicatorStyle,
    required this.color,
    required this.animate,
    this.speed = 1,
    this.size = 28,
    this.replayToken = 0,
  });

  final ResponseFinishStyle style;
  final ResponseIndicatorStyle indicatorStyle;
  final Color color;
  final bool animate;
  final double speed;
  final double size;
  final int replayToken;

  @override
  State<ResponseFinishPreview> createState() => _ResponseFinishPreviewState();
}

class _ResponseFinishPreviewState extends State<ResponseFinishPreview>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const runningMilliseconds = 1200;
  static const cycleMilliseconds = 2200;
  late final AnimationController _clock;
  bool _foreground = true;
  bool _tickerEnabled = true;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: cycleMilliseconds),
    );
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
  void didUpdateWidget(covariant ResponseFinishPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.replayToken != widget.replayToken) {
      _clock.stop();
      _clock.value = runningMilliseconds / cycleMilliseconds;
    }
    _syncClock();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = _isForeground(state);
    _syncClock();
  }

  void _syncClock() {
    if (widget.animate && _foreground && _tickerEnabled) {
      if (!_clock.isAnimating) _clock.repeat();
    } else {
      _clock.stop();
      if (!widget.animate) _clock.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: _clock,
          builder: (context, _) {
            final elapsed = _clock.value * cycleMilliseconds;
            final exit = widget.animate
                ? (1 -
                          (elapsed - runningMilliseconds) /
                              responseFinishDuration.inMilliseconds)
                      .clamp(0.0, 1.0)
                : 1.0;
            final runningProgress = widget.animate
                ? elapsed.clamp(0, runningMilliseconds) *
                      widget.speed.clamp(.5, 2) /
                      widget.indicatorStyle.cycleMilliseconds
                : 420 / widget.indicatorStyle.cycleMilliseconds;
            return ResponseFinishTransition(
              style: widget.style,
              progress: AlwaysStoppedAnimation(exit),
              child: CustomPaint(
                painter: ResponseActivityPainter(
                  style: widget.indicatorStyle,
                  color: widget.color,
                  progress: AlwaysStoppedAnimation(runningProgress),
                ),
              ),
            );
          },
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
