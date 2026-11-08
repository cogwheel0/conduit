import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../../../shared/theme/theme_extensions.dart';

/// Where the text of the message being sent was on screen: the composer's
/// field, or the follow-up row that was tapped. The new bubble rises from
/// here, so the message visibly travels from where it was written.
class ChatSendOrigin {
  ChatSendOrigin._();

  static Rect? _rect;
  static DateTime? _recordedAt;

  /// How long a recorded origin stays usable. The bubble mounts within a
  /// frame or two of the send; anything later is not this send's bubble.
  static const Duration maxAge = Duration(milliseconds: 1500);

  /// Records [globalRect] (logical pixels in the view) as the next bubble's
  /// origin.
  static void record(Rect globalRect) {
    _rect = globalRect;
    _recordedAt = DateTime.now();
  }

  /// Records the on-screen rect of [context]'s render box, if laid out.
  static void recordFrom(BuildContext? context) {
    final box = context?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return;
    record(box.localToGlobal(Offset.zero) & box.size);
  }

  /// Returns the recorded origin once, if it is still fresh.
  static Rect? take({DateTime? now}) {
    final rect = _rect;
    final at = _recordedAt;
    _rect = null;
    _recordedAt = null;
    if (rect == null || at == null) return null;
    final age = (now ?? DateTime.now()).difference(at);
    return age <= maxAge ? rect : null;
  }

  @visibleForTesting
  static void debugReset() {
    _rect = null;
    _recordedAt = null;
  }
}

/// Messages whose entrance has been decided, so a remount (scrolling away
/// and back, a rebuilt timeline) never replays it.
final LinkedHashSet<String> _enteredMessageIds = LinkedHashSet<String>();
const int _enteredMessageIdCapacity = 512;

@visibleForTesting
void debugResetChatSendEntrances() => _enteredMessageIds.clear();

/// How long a new reply's placeholder (model label, "Thinking…") waits
/// before fading in, so the sent message rising above it lands first.
const Duration chatReplyEntranceDelay = Duration(milliseconds: 160);

/// Content created this long ago or less still animates in; anything older
/// is history and appears in place.
const Duration chatEntranceFreshness = Duration(seconds: 3);

/// Whether a message stamped [timestamp] is new enough to animate in.
bool isFreshChatContent(DateTime timestamp, {DateTime? now}) {
  final age = (now ?? DateTime.now()).difference(timestamp);
  return age.abs() <= chatEntranceFreshness;
}

/// Whether [key]'s one entrance is still to be shown. A row can mount and be
/// replaced before it is ever painted (the timeline stays hidden while a new
/// turn's position settles), so this only asks; [markChatEntranceShown]
/// spends the entrance once it is actually on screen.
bool isChatEntranceAvailable(String key) =>
    key.isNotEmpty && !_enteredMessageIds.contains(key);

/// Records that [key]'s entrance was shown, so remounts stay still.
void markChatEntranceShown(String key) {
  if (key.isEmpty) return;
  _enteredMessageIds.add(key);
  while (_enteredMessageIds.length > _enteredMessageIdCapacity) {
    _enteredMessageIds.remove(_enteredMessageIds.first);
  }
}

/// Claims the one entrance [key] may ever play, at once. Returns false when
/// it already played, so a remount stays still.
bool claimChatEntrance(String key) {
  if (!isChatEntranceAvailable(key)) return false;
  markChatEntranceShown(key);
  return true;
}

/// Calls [onFirstPaint] after the first frame in which [child] is actually
/// painted: not while an ancestor hides it (the timeline's settle cover, a
/// zero opacity), and only once per element.
class ChatFirstPaintListener extends SingleChildRenderObjectWidget {
  const ChatFirstPaintListener({
    super.key,
    required this.onFirstPaint,
    required super.child,
  });

  final VoidCallback onFirstPaint;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFirstPaintListener(onFirstPaint);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderFirstPaintListener).onFirstPaint = onFirstPaint;
  }
}

class _RenderFirstPaintListener extends RenderProxyBox {
  _RenderFirstPaintListener(this.onFirstPaint);

  VoidCallback onFirstPaint;
  bool _painted = false;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!_painted) {
      _painted = true;
      // Never change state from inside paint.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (attached) onFirstPaint();
      });
    }
    super.paint(context, offset);
  }
}

/// A just-sent message rising into place from where it was written.
///
/// It moves on a critically damped spring (0.35 s response, damping 1.0,
/// so no overshoot) from the send origin to its place in the thread,
/// tracking that place live, so a scroll that settles the new turn at the
/// same time folds into one motion. It fades in over the first 120 ms as
/// the composer clears. Without an origin (a message from elsewhere) it
/// rises a short way instead. Only a message created in the last few
/// seconds, mounting for the first time, animates; Reduce Motion shows it in
/// place.
class ChatSendEntrance extends StatefulWidget {
  const ChatSendEntrance({
    super.key,
    required this.messageId,
    required this.timestamp,
    required this.child,
    this.useSendOrigin = true,
  });

  final String messageId;
  final DateTime timestamp;
  final Widget child;

  /// Whether to rise from [ChatSendOrigin]; false rises a short way.
  final bool useSendOrigin;

  /// Spring response (seconds) and the time it takes to settle within half
  /// a pixel over a full-screen travel.
  static const double springResponse = 0.35;
  static const Duration settleDuration = Duration(milliseconds: 560);
  static const Duration fadeDuration = Duration(milliseconds: 120);

  /// The rise without a known origin.
  static const double fallbackRise = 14;

  /// Displacement left at [t] seconds for a critically damped spring with
  /// [springResponse], as a fraction of the starting distance.
  static double remainingAt(double t) {
    if (t <= 0) return 1;
    final omega = 2 * math.pi / springResponse;
    return (1 + omega * t) * math.exp(-omega * t);
  }

  @override
  State<ChatSendEntrance> createState() => _ChatSendEntranceState();
}

class _ChatSendEntranceState extends State<ChatSendEntrance>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Rect? _origin;
  bool _decided = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decided) return;
    _decided = true;
    if (!isChatEntranceAvailable(widget.messageId) ||
        context.reduceMotion ||
        !isFreshChatContent(widget.timestamp)) {
      return;
    }
    _controller = AnimationController(
      vsync: this,
      duration: ChatSendEntrance.settleDuration,
    );
  }

  /// The first frame that shows the bubble spends its entrance and takes the
  /// send origin; a mount replaced before it was ever seen leaves both.
  Rect? _beginOnScreen() {
    markChatEntranceShown(widget.messageId);
    return _origin ??= widget.useSendOrigin ? ChatSendOrigin.take() : null;
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return widget.child;
    return _SendEntranceMotion(
      controller: controller,
      beginOnScreen: _beginOnScreen,
      child: widget.child,
    );
  }
}

class _SendEntranceMotion extends SingleChildRenderObjectWidget {
  const _SendEntranceMotion({
    required this.controller,
    required this.beginOnScreen,
    required super.child,
  });

  final AnimationController controller;

  /// Called at the first paint; returns the send origin, if any.
  final Rect? Function() beginOnScreen;

  @override
  _RenderSendEntrance createRenderObject(BuildContext context) =>
      _RenderSendEntrance(controller: controller, beginOnScreen: beginOnScreen);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSendEntrance renderObject,
  ) {
    renderObject
      ..controller = controller
      ..beginOnScreen = beginOnScreen;
  }
}

/// Paints its child displaced towards the send origin. The displacement is
/// decided at paint time from the child's live position, which only paint
/// knows; the first paint starts the clock, so a row laid out but not yet
/// shown (an initial scroll settling behind a cover) still enters fully.
class _RenderSendEntrance extends RenderProxyBox {
  _RenderSendEntrance({
    required AnimationController controller,
    required this.beginOnScreen,
  }) : _controller = controller;

  Rect? Function() beginOnScreen;

  AnimationController _controller;
  set controller(AnimationController value) {
    if (identical(value, _controller)) return;
    if (attached) _controller.removeListener(markNeedsPaint);
    _controller = value;
    if (attached) _controller.addListener(markNeedsPaint);
  }

  Rect? _origin;

  /// Global top the child starts from, fixed at the first paint.
  double? _startTop;
  double _offsetY = 0;
  double _opacity = 1;
  bool _started = false;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _controller.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _controller.removeListener(markNeedsPaint);
    super.detach();
  }

  bool get _finished => _started && _controller.isCompleted;

  void _resolveFrame() {
    if (_finished) {
      _offsetY = 0;
      _opacity = 1;
      return;
    }
    final layoutTop = localToGlobal(Offset.zero).dy;
    final origin = _origin;
    _startTop ??= origin == null
        ? layoutTop + ChatSendEntrance.fallbackRise
        // The message's last line starts where the field's last line was.
        : origin.bottom - size.height;
    final elapsed =
        _controller.value *
        ChatSendEntrance.settleDuration.inMicroseconds /
        Duration.microsecondsPerSecond;
    final remaining = ChatSendEntrance.remainingAt(elapsed);
    _offsetY = (_startTop! - layoutTop) * remaining;
    final fadeSeconds =
        ChatSendEntrance.fadeDuration.inMicroseconds /
        Duration.microsecondsPerSecond;
    _opacity = (elapsed / fadeSeconds).clamp(0.0, 1.0);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    if (!_started) {
      _started = true;
      _origin = beginOnScreen();
      // The clock starts with the first frame that shows the row.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (attached && !_controller.isAnimating) _controller.forward();
      });
    }
    _resolveFrame();
    if (_finished || (_offsetY.abs() < 0.25 && _opacity >= 1)) {
      _opacityLayer.layer = null;
      context.paintChild(child, offset);
      return;
    }
    if (_opacity <= 0) {
      _opacityLayer.layer = null;
      return;
    }
    if (_opacity >= 1) {
      _opacityLayer.layer = null;
      context.paintChild(child, offset + Offset(0, _offsetY));
      return;
    }
    _opacityLayer.layer = context.pushOpacity(
      offset,
      (_opacity * 255).round(),
      (context, layerOffset) =>
          context.paintChild(child, layerOffset + Offset(0, _offsetY)),
      oldLayer: _opacityLayer.layer,
    );
  }

  final LayerHandle<OpacityLayer> _opacityLayer = LayerHandle<OpacityLayer>();

  @override
  void dispose() {
    _opacityLayer.layer = null;
    super.dispose();
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(0, _finished ? 0 : _offsetY, 0, 1);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return result.addWithPaintOffset(
      offset: Offset(0, _finished ? 0 : _offsetY),
      position: position,
      hitTest: (result, transformed) =>
          super.hitTestChildren(result, position: transformed),
    );
  }
}
