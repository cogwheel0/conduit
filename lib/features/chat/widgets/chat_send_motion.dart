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

/// The new-chat greeting leaving as the first message is sent: it fades out
/// over [duration] while the message rises from the composer, so the two
/// share one motion and no frame goes blank. Reduce Motion makes the same
/// fade the cross-fade. It never takes touches or VoiceOver focus, and
/// calls [onDone] once it has gone.
class ChatGreetingExit extends StatefulWidget {
  const ChatGreetingExit({
    super.key,
    required this.child,
    required this.onDone,
  });

  final Widget child;
  final VoidCallback onDone;

  static const Duration duration = Duration(milliseconds: 180);

  @override
  State<ChatGreetingExit> createState() => _ChatGreetingExitState();
}

class _ChatGreetingExitState extends State<ChatGreetingExit>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: ChatGreetingExit.duration,
  );
  late final Animation<double> _opacity = ReverseAnimation(
    CurvedAnimation(parent: _controller, curve: Curves.easeOut),
  );

  @override
  void initState() {
    super.initState();
    // Start the clock after the first frame that shows the greeting leaving,
    // as the rising message does: a slow first frame (the new chat's
    // transcript mounting) then delays both together instead of spending
    // the fade before the message has moved.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.forward().whenCompleteOrCancel(() {
        if (mounted) widget.onDone();
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: FadeTransition(opacity: _opacity, child: widget.child),
      ),
    );
  }
}

/// A just-sent message rising into place from where it was written.
///
/// It moves on a critically damped spring (0.35 s response, damping 1.0,
/// so no overshoot) from the send origin to its place in the thread. The
/// spring chases that place live, keeping its own position and velocity, so
/// whatever the timeline does meanwhile (a new chat settling its first turn,
/// a scroll bringing the turn up) folds into one continuous motion with no
/// jump. It is visible from its first frame and fades the rest of the way in
/// as the composer clears, so the hand-off never shows an empty frame.
/// Without an origin (a message from elsewhere) it rises a short way
/// instead. Only a message created in the last few seconds, mounting for the
/// first time, animates; Reduce Motion fades it in where it lands.
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

  /// Spring response in seconds (critically damped: damping ratio 1.0).
  static const double springResponse = 0.35;

  /// Upper bound on the motion. A full-screen travel settles within half a
  /// pixel in about 0.56 s; the rest is headroom for a target that keeps
  /// moving for a while (a scroll bringing the turn into place).
  static const Duration settleDuration = Duration(milliseconds: 1400);

  /// The bubble starts this opaque, so its first frame already shows the
  /// message, and reaches full opacity over [fadeDuration].
  static const double initialOpacity = 0.45;
  static const Duration fadeDuration = Duration(milliseconds: 150);

  /// Reduce Motion: no travel, a plain fade in place.
  static const Duration reducedMotionFadeDuration = Duration(milliseconds: 200);

  /// The rise without a known origin.
  static const double fallbackRise = 14;

  /// Within this many points and points per second of its place, at rest.
  static const double restDistance = 0.25;
  static const double restSpeed = 6;

  static double get _omega => 2 * math.pi / springResponse;

  /// Displacement left at [t] seconds for a critically damped spring with
  /// [springResponse] released at rest, as a fraction of the starting
  /// distance.
  static double remainingAt(double t) {
    if (t <= 0) return 1;
    final omega = _omega;
    return (1 + omega * t) * math.exp(-omega * t);
  }

  /// Advances the spring [dt] seconds from [displacement] (points from its
  /// target) moving at [velocity] (points per second).
  static ({double displacement, double velocity}) step({
    required double displacement,
    required double velocity,
    required double dt,
  }) {
    if (dt <= 0) return (displacement: displacement, velocity: velocity);
    final omega = _omega;
    final decay = math.exp(-omega * dt);
    final b = velocity + omega * displacement;
    return (
      displacement: (displacement + b * dt) * decay,
      velocity: (velocity - omega * b * dt) * decay,
    );
  }

  @override
  State<ChatSendEntrance> createState() => _ChatSendEntranceState();
}

class _ChatSendEntranceState extends State<ChatSendEntrance>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Rect? _origin;
  bool _decided = false;
  bool _fadeOnly = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decided) return;
    _decided = true;
    if (!isChatEntranceAvailable(widget.messageId) ||
        !isFreshChatContent(widget.timestamp)) {
      return;
    }
    _fadeOnly = context.reduceMotion;
    _controller = AnimationController(
      vsync: this,
      duration: _fadeOnly
          ? ChatSendEntrance.reducedMotionFadeDuration
          : ChatSendEntrance.settleDuration,
    );
  }

  /// The first frame that shows the bubble spends its entrance and takes the
  /// send origin; a mount replaced before it was ever seen leaves both.
  Rect? _beginOnScreen() {
    markChatEntranceShown(widget.messageId);
    if (_fadeOnly) {
      // The origin belongs to this send either way; spend it.
      ChatSendOrigin.take();
      return null;
    }
    return _origin ??= widget.useSendOrigin ? ChatSendOrigin.take() : null;
  }

  /// The spring came to rest before the clock ran out; stop asking for
  /// frames.
  void _settled() {
    final controller = _controller;
    if (controller == null || !controller.isAnimating) return;
    controller.value = 1;
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
      fadeOnly: _fadeOnly,
      beginOnScreen: _beginOnScreen,
      onSettled: _settled,
      child: widget.child,
    );
  }
}

class _SendEntranceMotion extends SingleChildRenderObjectWidget {
  const _SendEntranceMotion({
    required this.controller,
    required this.fadeOnly,
    required this.beginOnScreen,
    required this.onSettled,
    required super.child,
  });

  final AnimationController controller;
  final bool fadeOnly;

  /// Called at the first paint; returns the send origin, if any.
  final Rect? Function() beginOnScreen;
  final VoidCallback onSettled;

  @override
  _RenderSendEntrance createRenderObject(BuildContext context) =>
      _RenderSendEntrance(
        controller: controller,
        fadeOnly: fadeOnly,
        beginOnScreen: beginOnScreen,
        onSettled: onSettled,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSendEntrance renderObject,
  ) {
    renderObject
      ..controller = controller
      ..fadeOnly = fadeOnly
      ..beginOnScreen = beginOnScreen
      ..onSettled = onSettled;
  }
}

/// Paints its child displaced towards where the spring has carried it. The
/// spring's state is its painted global top and velocity; each paint aims
/// it at the child's live laid-out top, which only paint knows. A target
/// that jumps (the timeline settling) changes where the spring is heading,
/// never where it is, so the bubble moves continuously. The first paint
/// starts the clock, so a row laid out but not yet shown still enters fully.
class _RenderSendEntrance extends RenderProxyBox {
  _RenderSendEntrance({
    required AnimationController controller,
    required this.fadeOnly,
    required this.beginOnScreen,
    required this.onSettled,
  }) : _controller = controller;

  bool fadeOnly;
  Rect? Function() beginOnScreen;
  VoidCallback onSettled;

  AnimationController _controller;
  set controller(AnimationController value) {
    if (identical(value, _controller)) return;
    if (attached) _controller.removeListener(markNeedsPaint);
    _controller = value;
    if (attached) _controller.addListener(markNeedsPaint);
  }

  /// Global top the spring has carried the child to, and its velocity.
  double? _visualTop;
  double _velocity = 0;

  /// Clock reading (seconds) the spring state was last advanced to.
  double _advancedTo = 0;
  double _offsetY = 0;
  double _opacity = 1;
  bool _started = false;
  bool _settled = false;

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

  bool get _finished => _settled || (_started && _controller.isCompleted);

  double get _clockSeconds {
    final duration = _controller.duration ?? Duration.zero;
    return _controller.value *
        duration.inMicroseconds /
        Duration.microsecondsPerSecond;
  }

  double _secondsOf(Duration duration) =>
      duration.inMicroseconds / Duration.microsecondsPerSecond;

  void _resolveFrame() {
    if (_finished) {
      _offsetY = 0;
      _opacity = 1;
      return;
    }
    final elapsed = _clockSeconds;
    if (fadeOnly) {
      _offsetY = 0;
      final t =
          (elapsed / _secondsOf(ChatSendEntrance.reducedMotionFadeDuration))
              .clamp(0.0, 1.0);
      _opacity = Curves.easeOut.transform(t);
      return;
    }
    final layoutTop = localToGlobal(Offset.zero).dy;
    var visualTop = _visualTop;
    if (visualTop == null) {
      final origin = beginOnScreen();
      visualTop = origin == null
          ? layoutTop + ChatSendEntrance.fallbackRise
          // The message's last line starts where the field's last line was.
          : origin.bottom - size.height;
      _velocity = 0;
      _advancedTo = elapsed;
    } else if (elapsed > _advancedTo) {
      final next = ChatSendEntrance.step(
        displacement: visualTop - layoutTop,
        velocity: _velocity,
        dt: elapsed - _advancedTo,
      );
      visualTop = layoutTop + next.displacement;
      _velocity = next.velocity;
      _advancedTo = elapsed;
    }
    _visualTop = visualTop;
    _offsetY = visualTop - layoutTop;
    final fade = (elapsed / _secondsOf(ChatSendEntrance.fadeDuration)).clamp(
      0.0,
      1.0,
    );
    _opacity =
        ChatSendEntrance.initialOpacity +
        (1 - ChatSendEntrance.initialOpacity) * Curves.easeOut.transform(fade);
    if (fade >= 1 &&
        _offsetY.abs() < ChatSendEntrance.restDistance &&
        _velocity.abs() < ChatSendEntrance.restSpeed) {
      _settled = true;
      _offsetY = 0;
      _opacity = 1;
      // Never change state from inside paint.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (attached) onSettled();
      });
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    if (!_started) {
      _started = true;
      if (fadeOnly) beginOnScreen();
      // The clock starts with the first frame that shows the row.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (attached && !_controller.isAnimating && !_settled) {
          _controller.forward();
        }
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
