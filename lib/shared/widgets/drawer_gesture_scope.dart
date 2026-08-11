import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Prevents a parent drawer-open recognizer from competing with a descendant
/// that owns horizontal gestures, such as rich-text selection or an editor.
class DrawerOpenGestureExclusion extends SingleChildRenderObjectWidget {
  const DrawerOpenGestureExclusion({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderDrawerOpenGestureExclusion();
}

class RenderDrawerOpenGestureExclusion
    extends RenderProxyBoxWithHitTestBehavior {
  RenderDrawerOpenGestureExclusion()
    : super(behavior: HitTestBehavior.translucent);
}

/// Marks a horizontal scrollable for typed drawer-open gesture arbitration.
///
/// The boundary snapshots scroll metrics from its direct descendant and makes
/// the leading-edge state available in the render-object hit-test path. This
/// keeps the navigation shell independent of Flutter's private Scrollable
/// render-object structure.
class DrawerHorizontalScrollBoundary extends StatefulWidget {
  const DrawerHorizontalScrollBoundary({super.key, required this.child});

  final Widget child;

  @override
  State<DrawerHorizontalScrollBoundary> createState() =>
      _DrawerHorizontalScrollBoundaryState();
}

class _DrawerHorizontalScrollBoundaryState
    extends State<DrawerHorizontalScrollBoundary> {
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

  bool get _isAtOpenGestureLeadingEdge {
    const epsilon = 0.5;
    return switch (_axisDirection) {
      AxisDirection.right => _pixels <= _minimum + epsilon,
      AxisDirection.left => _pixels >= _maximum - epsilon,
      AxisDirection.up || AxisDirection.down || null => true,
    };
  }

  @override
  Widget build(BuildContext context) {
    return _DrawerHorizontalScrollMarker(
      isAtOpenGestureLeadingEdge: () => _isAtOpenGestureLeadingEdge,
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

class _DrawerHorizontalScrollMarker extends SingleChildRenderObjectWidget {
  const _DrawerHorizontalScrollMarker({
    required this.isAtOpenGestureLeadingEdge,
    required super.child,
  });

  final bool Function() isAtOpenGestureLeadingEdge;

  @override
  RenderDrawerHorizontalScrollBoundary createRenderObject(
    BuildContext context,
  ) => RenderDrawerHorizontalScrollBoundary(
    isAtOpenGestureLeadingEdge: isAtOpenGestureLeadingEdge,
  );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderDrawerHorizontalScrollBoundary renderObject,
  ) {
    renderObject.isAtOpenGestureLeadingEdgeCallback =
        isAtOpenGestureLeadingEdge;
  }
}

class RenderDrawerHorizontalScrollBoundary
    extends RenderProxyBoxWithHitTestBehavior {
  RenderDrawerHorizontalScrollBoundary({
    required bool Function() isAtOpenGestureLeadingEdge,
  }) : _isAtOpenGestureLeadingEdge = isAtOpenGestureLeadingEdge,
       super(behavior: HitTestBehavior.translucent);

  bool Function() _isAtOpenGestureLeadingEdge;

  bool get isAtOpenGestureLeadingEdge => _isAtOpenGestureLeadingEdge();

  set isAtOpenGestureLeadingEdgeCallback(bool Function() callback) {
    _isAtOpenGestureLeadingEdge = callback;
  }
}

/// Supplies drawer gesture arbitration without coupling reusable content to a
/// particular navigation shell implementation.
class DrawerGestureScope extends InheritedWidget {
  const DrawerGestureScope({
    super.key,
    required this.buildPrioritizedGestureArena,
    required super.child,
  });

  final Widget Function(Widget child) buildPrioritizedGestureArena;

  static DrawerGestureScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DrawerGestureScope>();

  @override
  bool updateShouldNotify(DrawerGestureScope oldWidget) =>
      buildPrioritizedGestureArena != oldWidget.buildPrioritizedGestureArena;
}

/// Gives a quick rightward drawer drag priority inside an otherwise excluded
/// gesture owner while preserving stationary long-press gestures.
class DrawerOpenGesturePriority extends StatelessWidget {
  const DrawerOpenGesturePriority({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      DrawerGestureScope.maybeOf(
        context,
      )?.buildPrioritizedGestureArena(child) ??
      child;
}
