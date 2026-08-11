import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Marks content that owns horizontal gestures so an ancestor recognizer can
/// stay out of its gesture arena.
class HorizontalGestureExclusion extends SingleChildRenderObjectWidget {
  const HorizontalGestureExclusion({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderHorizontalGestureExclusion();
}

class RenderHorizontalGestureExclusion
    extends RenderProxyBoxWithHitTestBehavior {
  RenderHorizontalGestureExclusion()
    : super(behavior: HitTestBehavior.translucent);
}

/// Publishes the leading-edge state of a horizontal scrollable through the
/// render-object hit-test path for ancestor gesture arbitration.
///
/// The boundary deliberately exposes no navigation policy. Any ancestor that
/// competes for horizontal gestures can interpret the marker.
class HorizontalScrollGestureBoundary extends StatefulWidget {
  const HorizontalScrollGestureBoundary({super.key, required this.child});

  final Widget child;

  @override
  State<HorizontalScrollGestureBoundary> createState() =>
      _HorizontalScrollGestureBoundaryState();
}

class _HorizontalScrollGestureBoundaryState
    extends State<HorizontalScrollGestureBoundary> {
  AxisDirection? _axisDirection;
  double _pixels = 0;
  double _minimum = 0;
  double _maximum = 0;

  bool _handleMetrics(ScrollMetrics metrics) {
    final direction = metrics.axisDirection;
    if (direction != AxisDirection.left && direction != AxisDirection.right) {
      return false;
    }
    _axisDirection = direction;
    _pixels = metrics.pixels;
    _minimum = metrics.minScrollExtent;
    _maximum = metrics.maxScrollExtent;
    return false;
  }

  bool get _isAtLeadingEdge {
    const epsilon = 0.5;
    return switch (_axisDirection) {
      AxisDirection.right => _pixels <= _minimum + epsilon,
      AxisDirection.left => _pixels >= _maximum - epsilon,
      AxisDirection.up || AxisDirection.down || null => true,
    };
  }

  @override
  Widget build(BuildContext context) {
    return _HorizontalScrollGestureMarker(
      isAtLeadingEdge: () => _isAtLeadingEdge,
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (notification) => notification.depth == 0
            ? _handleMetrics(notification.metrics)
            : false,
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) => notification.depth == 0
              ? _handleMetrics(notification.metrics)
              : false,
          child: widget.child,
        ),
      ),
    );
  }
}

class _HorizontalScrollGestureMarker extends SingleChildRenderObjectWidget {
  const _HorizontalScrollGestureMarker({
    required this.isAtLeadingEdge,
    required super.child,
  });

  final bool Function() isAtLeadingEdge;

  @override
  RenderHorizontalScrollGestureBoundary createRenderObject(
    BuildContext context,
  ) => RenderHorizontalScrollGestureBoundary(isAtLeadingEdge: isAtLeadingEdge);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderHorizontalScrollGestureBoundary renderObject,
  ) {
    renderObject.isAtLeadingEdgeCallback = isAtLeadingEdge;
  }
}

class RenderHorizontalScrollGestureBoundary
    extends RenderProxyBoxWithHitTestBehavior {
  RenderHorizontalScrollGestureBoundary({
    required bool Function() isAtLeadingEdge,
  }) : _isAtLeadingEdge = isAtLeadingEdge,
       super(behavior: HitTestBehavior.translucent);

  bool Function() _isAtLeadingEdge;

  bool get isAtLeadingEdge => _isAtLeadingEdge();

  set isAtLeadingEdgeCallback(bool Function() callback) {
    _isAtLeadingEdge = callback;
  }
}

/// Supplies an ancestor-defined priority arena to reusable gesture owners.
class HorizontalGesturePriorityScope extends InheritedWidget {
  const HorizontalGesturePriorityScope({
    super.key,
    required this.buildPrioritizedGestureArena,
    required super.child,
  });

  final Widget Function(Widget child) buildPrioritizedGestureArena;

  static HorizontalGesturePriorityScope? maybeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<HorizontalGesturePriorityScope>();

  @override
  bool updateShouldNotify(HorizontalGesturePriorityScope oldWidget) =>
      buildPrioritizedGestureArena != oldWidget.buildPrioritizedGestureArena;
}

/// Lets an ancestor prioritize a deliberate horizontal drag inside an
/// otherwise excluded gesture owner while preserving stationary long presses.
class PrioritizedHorizontalGesture extends StatelessWidget {
  const PrioritizedHorizontalGesture({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      HorizontalGesturePriorityScope.maybeOf(
        context,
      )?.buildPrioritizedGestureArena(child) ??
      child;
}
