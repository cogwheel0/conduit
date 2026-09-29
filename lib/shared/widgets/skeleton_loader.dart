import 'package:material_ui/material_ui.dart';

import '../theme/theme_extensions.dart';

/// Enhanced skeleton loader with production-grade animations and better hierarchy
class SkeletonLoader extends StatefulWidget {
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final Duration? duration;
  final Color? baseColor;
  final Color? highlightColor;
  final bool isCompact;

  const SkeletonLoader({
    super.key,
    this.width,
    this.height,
    this.borderRadius,
    this.duration,
    this.baseColor,
    this.highlightColor,
    this.isCompact = false,
  });

  @override
  State<SkeletonLoader> createState() => _SkeletonLoaderState();
}

class _SkeletonLoaderState extends State<SkeletonLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: widget.duration ?? AnimationDuration.typingIndicator,
      vsync: this,
    );
    _animation =
        Tween<double>(
          begin: AnimationValues.shimmerBegin,
          end: AnimationValues.shimmerEnd,
        ).animate(
          CurvedAnimation(parent: _controller, curve: AnimationCurves.linear),
        );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = context.reduceMotion;
    if (_reduceMotion == reduceMotion && _controller.isAnimating) {
      return;
    }
    _reduceMotion = reduceMotion;
    _syncAnimation();
  }

  @override
  void didUpdateWidget(SkeletonLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration != oldWidget.duration) {
      _controller.duration =
          widget.duration ?? AnimationDuration.typingIndicator;
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    if (_reduceMotion) {
      _controller.stop();
      return;
    }
    if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void deactivate() {
    // Pause shimmer during deactivation to avoid rebuilds in wrong build scope
    _controller.stop();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    if (!_reduceMotion && !_controller.isAnimating) {
      // Resume shimmer after re-activation
      _controller.repeat();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_reduceMotion) {
      return Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: widget.baseColor ?? context.conduitTheme.shimmerBase,
          borderRadius:
              widget.borderRadius ??
              BorderRadius.circular(
                widget.isCompact ? AppBorderRadius.xs : AppBorderRadius.sm,
              ),
        ),
      );
    }

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius:
                widget.borderRadius ??
                BorderRadius.circular(
                  widget.isCompact ? AppBorderRadius.xs : AppBorderRadius.sm,
                ),
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                widget.baseColor ?? context.conduitTheme.shimmerBase,
                widget.highlightColor ?? context.conduitTheme.shimmerHighlight,
                widget.baseColor ?? context.conduitTheme.shimmerBase,
              ],
              stops: [
                _animation.value - 0.3,
                _animation.value,
                _animation.value + 0.3,
              ],
            ),
          ),
        );
      },
    );
  }
}
