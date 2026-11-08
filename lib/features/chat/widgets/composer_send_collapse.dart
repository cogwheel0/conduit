import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../../../shared/theme/theme_extensions.dart';
import 'chat_send_motion.dart';

/// Lets the composer shrink after a send on the same spring as the message
/// rising out of it (critically damped, 0.35 s response), instead of holding
/// its old height for a few frames and then snapping.
///
/// Each new [token] arms one collapse: from the height the composer had in
/// the last frame down to whatever its content now needs, the content held
/// at the bottom edge so the buttons stay put while the empty space above
/// them closes. While [holding], it keeps the height it had when the hold
/// began, however its content shrinks meanwhile (the sent words are still
/// flying out of it); the next [token] then collapses from there. Every
/// other height change (typing a line, deleting one) stays direct, so the
/// composer never trails the user's typing. Reduce Motion makes the
/// collapse immediate. [onDone] runs once it has finished.
class ComposerSendCollapse extends StatefulWidget {
  const ComposerSendCollapse({
    super.key,
    required this.token,
    required this.child,
    this.holding = false,
    this.onDone,
  });

  final int token;
  final Widget child;
  final bool holding;
  final VoidCallback? onDone;

  /// Long enough for the spring to come within a fraction of a point.
  static const Duration duration = Duration(milliseconds: 600);

  @override
  State<ComposerSendCollapse> createState() => _ComposerSendCollapseState();
}

class _ComposerSendCollapseState extends State<ComposerSendCollapse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: ComposerSendCollapse.duration,
  )..addStatusListener(_handleStatus);

  /// The height the collapse starts from (or the hold keeps), while one
  /// runs.
  double? _from;

  void _handleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || widget.holding) return;
    if (mounted) setState(() => _from = null);
    widget.onDone?.call();
  }

  double? get _currentHeight {
    final box = context.findRenderObject();
    return box is RenderBox && box.hasSize ? box.size.height : null;
  }

  @override
  void didUpdateWidget(covariant ComposerSendCollapse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.holding) {
      if (!oldWidget.holding) {
        // Keep the height of the last frame until the hold ends.
        _controller.stop();
        _from = _currentHeight;
      }
      return;
    }
    if (oldWidget.token == widget.token) {
      if (oldWidget.holding) {
        // A hold that ends without a collapse: back to the content's size.
        _from = null;
      }
      return;
    }
    final height = _currentHeight;
    if (height != null && !context.reduceMotion) {
      _from = height;
      _controller.forward(from: 0);
      return;
    }
    _from = null;
    // Never change the parent's state from inside its build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onDone?.call();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _CollapseBox(
      from: _from,
      holding: widget.holding,
      animation: _controller,
      child: widget.child,
    );
  }
}

class _CollapseBox extends SingleChildRenderObjectWidget {
  const _CollapseBox({
    required this.from,
    required this.holding,
    required this.animation,
    required super.child,
  });

  final double? from;
  final bool holding;
  final AnimationController animation;

  @override
  _RenderCollapseBox createRenderObject(BuildContext context) =>
      _RenderCollapseBox(from: from, holding: holding, animation: animation);

  @override
  void updateRenderObject(BuildContext context, _RenderCollapseBox render) {
    render
      ..from = from
      ..holding = holding
      ..animation = animation;
  }
}

class _RenderCollapseBox extends RenderShiftedBox {
  _RenderCollapseBox({
    required double? from,
    required bool holding,
    required AnimationController animation,
  }) : _from = from,
       _holding = holding,
       _animation = animation,
       super(null);

  double? _from;
  set from(double? value) {
    if (value == _from) return;
    _from = value;
    markNeedsLayout();
  }

  bool _holding;
  set holding(bool value) {
    if (value == _holding) return;
    _holding = value;
    markNeedsLayout();
  }

  AnimationController _animation;
  set animation(AnimationController value) {
    if (identical(value, _animation)) return;
    if (attached) _animation.removeListener(markNeedsLayout);
    _animation = value;
    if (attached) _animation.addListener(markNeedsLayout);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _animation.addListener(markNeedsLayout);
  }

  @override
  void detach() {
    _animation.removeListener(markNeedsLayout);
    super.detach();
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      child?.getDryLayout(constraints) ?? constraints.smallest;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    final childHeight = child.size.height;
    var height = childHeight;
    final from = _from;
    if (from != null && from > childHeight) {
      if (_holding) {
        height = from;
      } else {
        final seconds =
            _animation.value *
            ComposerSendCollapse.duration.inMicroseconds /
            Duration.microsecondsPerSecond;
        height =
            childHeight +
            (from - childHeight) * ChatSendEntrance.remainingAt(seconds);
      }
    }
    size = constraints.constrain(Size(child.size.width, height));
    // The content keeps to the bottom edge: the buttons stay where they were
    // while the emptied text area above them closes.
    (child.parentData! as BoxParentData).offset = Offset(
      0,
      size.height - childHeight,
    );
  }
}
