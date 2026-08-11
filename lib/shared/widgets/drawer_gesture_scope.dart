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
