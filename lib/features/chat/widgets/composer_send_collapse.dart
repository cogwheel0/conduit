import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import '../../../shared/theme/theme_extensions.dart';
import 'chat_motion_spring.dart';
import 'chat_send_motion.dart';

/// Lets the composer shrink after a send on the same spring as the message
/// rising out of it (critically damped, [ChatSendEntrance.springResponse]),
/// on the same kind of clock ([ChatMotionClock]), instead of holding its old
/// height for a few frames and then snapping.
///
/// Each new [token] arms one collapse: from the height the composer had in
/// the last frame down to whatever its content now needs, the content held
/// at the bottom edge so the buttons stay put while the empty space above
/// them closes. While [holding], it keeps the height it had when the hold
/// began, however its content shrinks meanwhile (the sent words are still in
/// it, waiting to rise); the next [token] then collapses from there. Every
/// other height change (typing a line, deleting one) stays direct, so the
/// composer never trails the user's typing. Reduce Motion makes the collapse
/// immediate. [onNearlyClosed] runs once the composer is within
/// [nearlyClosedSlack] of its new height (at once when there is nothing to
/// close), so what belongs to a one-line composer (its placeholder) can come
/// in as it gets there; [onDone] runs once it has finished.
class ComposerSendCollapse extends StatefulWidget {
  const ComposerSendCollapse({
    super.key,
    required this.token,
    required this.child,
    this.holding = false,
    this.onNearlyClosed,
    this.onDone,
  });

  final int token;
  final Widget child;
  final bool holding;
  final VoidCallback? onNearlyClosed;
  final VoidCallback? onDone;

  /// Long enough for the spring to come within a fraction of a point (in
  /// the motion's time, which slow frames hold back).
  static const Duration duration = Duration(milliseconds: 600);

  /// How much taller than its content the composer may still be for
  /// [onNearlyClosed]: a sliver of a line.
  static const double nearlyClosedSlack = 10;

  @override
  State<ComposerSendCollapse> createState() => _ComposerSendCollapseState();
}

class _ComposerSendCollapseState extends State<ComposerSendCollapse>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final ChatMotionClock _clock = ChatMotionClock();

  /// Seconds of the running collapse so far, in the motion's time.
  final ValueNotifier<double> _seconds = ValueNotifier<double>(0);

  static final double _durationSeconds =
      ComposerSendCollapse.duration.inMicroseconds /
      Duration.microsecondsPerSecond;

  /// The height the collapse starts from (or the hold keeps), while one
  /// runs.
  double? _from;

  /// Whether this collapse has reported [ComposerSendCollapse.onNearlyClosed].
  bool _nearlyClosedReported = true;

  void _startCollapse() {
    _ticker.stop();
    _clock.reset();
    _seconds.value = 0;
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    _clock.advanceTo(elapsed.inMicroseconds / Duration.microsecondsPerSecond);
    _seconds.value = _clock.seconds;
    if (_clock.seconds < _durationSeconds) return;
    _ticker.stop();
    _finish();
  }

  void _finish() {
    if (widget.holding) return;
    _reportNearlyClosed();
    if (mounted) setState(() => _from = null);
    widget.onDone?.call();
  }

  /// Called by the box once it is within the slack of its content's height.
  void _reportNearlyClosed() {
    if (_nearlyClosedReported) return;
    _nearlyClosedReported = true;
    widget.onNearlyClosed?.call();
  }

  /// Reports [ComposerSendCollapse.onNearlyClosed] after this frame, for
  /// calls from inside layout or build.
  void _reportNearlyClosedAfterFrame() {
    if (_nearlyClosedReported) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reportNearlyClosed();
    });
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
        _ticker.stop();
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
    _nearlyClosedReported = false;
    final height = _currentHeight;
    if (height != null && !context.reduceMotion) {
      _from = height;
      _startCollapse();
      return;
    }
    _from = null;
    // Never change the parent's state from inside its build.
    _reportNearlyClosedAfterFrame();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onDone?.call();
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _seconds.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _CollapseBox(
      from: _from,
      holding: widget.holding,
      seconds: _seconds,
      onNearlyClosed: _reportNearlyClosedAfterFrame,
      child: widget.child,
    );
  }
}

class _CollapseBox extends SingleChildRenderObjectWidget {
  const _CollapseBox({
    required this.from,
    required this.holding,
    required this.seconds,
    required this.onNearlyClosed,
    required super.child,
  });

  final double? from;
  final bool holding;
  final ValueListenable<double> seconds;
  final VoidCallback onNearlyClosed;

  @override
  _RenderCollapseBox createRenderObject(BuildContext context) =>
      _RenderCollapseBox(
        from: from,
        holding: holding,
        seconds: seconds,
        onNearlyClosed: onNearlyClosed,
      );

  @override
  void updateRenderObject(BuildContext context, _RenderCollapseBox render) {
    render
      ..from = from
      ..holding = holding
      ..seconds = seconds
      ..onNearlyClosed = onNearlyClosed;
  }
}

class _RenderCollapseBox extends RenderShiftedBox {
  _RenderCollapseBox({
    required double? from,
    required bool holding,
    required ValueListenable<double> seconds,
    required this.onNearlyClosed,
  }) : _from = from,
       _holding = holding,
       _seconds = seconds,
       super(null);

  /// Told (it defers past the frame itself) whenever a layout finds the box
  /// within [ComposerSendCollapse.nearlyClosedSlack] of its content.
  VoidCallback onNearlyClosed;

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

  ValueListenable<double> _seconds;
  set seconds(ValueListenable<double> value) {
    if (identical(value, _seconds)) return;
    if (attached) _seconds.removeListener(markNeedsLayout);
    _seconds = value;
    if (attached) _seconds.addListener(markNeedsLayout);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _seconds.addListener(markNeedsLayout);
  }

  @override
  void detach() {
    _seconds.removeListener(markNeedsLayout);
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
        height =
            childHeight +
            (from - childHeight) * ChatSendEntrance.remainingAt(_seconds.value);
      }
    }
    if (height - childHeight <= ComposerSendCollapse.nearlyClosedSlack) {
      onNearlyClosed();
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
