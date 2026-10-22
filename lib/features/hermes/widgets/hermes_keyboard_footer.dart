import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Space reserved for floating navigation inside a full-height chat canvas.
class HermesNavigationInset extends InheritedWidget {
  const HermesNavigationInset({
    super.key,
    required this.bottom,
    required super.child,
  });
  final double bottom;
  static double of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<HermesNavigationInset>()
          ?.bottom ??
      0;
  @override
  bool updateShouldNotify(HermesNavigationInset oldWidget) =>
      bottom != oldWidget.bottom;
}

/// Consumes measured footer space as the Android IME covers it. The chat
/// composer remains the only owner of the full progressive keyboard inset.
class HermesKeyboardFooter extends StatelessWidget {
  const HermesKeyboardFooter({
    super.key,
    required this.inset,
    required this.followSystemGeometry,
    required this.child,
  });
  final double inset;
  final bool followSystemGeometry;
  final Widget child;
  @override
  Widget build(BuildContext context) => ExcludeFocus(
    excluding: inset > 0,
    child: _MeasuredFooter(
      inset: inset,
      follow: followSystemGeometry,
      child: child,
    ),
  );
}

class _MeasuredFooter extends SingleChildRenderObjectWidget {
  const _MeasuredFooter({
    required this.inset,
    required this.follow,
    required super.child,
  });
  final double inset;
  final bool follow;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _KeyboardFooter(inset, follow);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _KeyboardFooter).update(inset, follow);
  }
}

class _KeyboardFooter extends RenderProxyBox {
  _KeyboardFooter(this.inset, this.follow);
  double inset;
  bool follow;
  void update(double value, bool enabled) {
    if (value == inset && enabled == follow) return;
    inset = value;
    follow = enabled;
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final natural = child?.getDryLayout(constraints) ?? Size.zero;
    return constraints.constrain(
      Size(
        natural.width,
        follow
            ? math.max(0, natural.height - inset)
            : inset > 0
            ? 0
            : natural.height,
      ),
    );
  }

  @override
  void performLayout() {
    child?.layout(constraints, parentUsesSize: true);
    final natural = child?.size ?? Size.zero;
    size = constraints.constrain(
      Size(
        natural.width,
        follow
            ? math.max(0, natural.height - inset)
            : inset > 0
            ? 0
            : natural.height,
      ),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) return;
    context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      super.paint,
    );
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (inset == 0) super.visitChildrenForSemantics(visitor);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      inset == 0 && super.hitTestChildren(result, position: position);
}
