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

  /// Whether a fresh origin is waiting, without spending it.
  static bool get hasFresh {
    final at = _recordedAt;
    return _rect != null &&
        at != null &&
        DateTime.now().difference(at) <= maxAge;
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
/// before fading in, so the sent message rising above it lands first: by
/// then the message's spring has under a tenth of its travel left, so it no
/// longer crosses the label's line.
const Duration chatReplyEntranceDelay = Duration(milliseconds: 220);

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
/// where it stands over [duration], opacity only, while the message rises
/// from the composer. The fade is quick and front-loaded, so the greeting is
/// all but gone before the rising message reaches its line, and the two never
/// cross. Its first [child] is kept as it was, so the keyboard going down or
/// the composer shrinking meanwhile never moves it. Reduce Motion makes the
/// same fade the cross-fade. It never takes touches or VoiceOver focus, and
/// calls [onDone] once it has gone.
class ChatGreetingExit extends StatefulWidget {
  const ChatGreetingExit({
    super.key,
    required this.child,
    required this.onDone,
  });

  final Widget child;
  final VoidCallback onDone;

  static const Duration duration = Duration(milliseconds: 120);

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
    CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
  );

  /// The greeting as it stood when the send began. Rebuilds of the page
  /// (a new composer height) would re-centre a fresh copy; the leaving one
  /// holds still.
  late final Widget _frozenChild = widget.child;

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
        child: FadeTransition(
          opacity: _opacity,
          // The page grows as the keyboard goes down; laid out as it first
          // was, the greeting stays on its line instead of sliding with it.
          child: _FirstLayoutHold(child: _frozenChild),
        ),
      ),
    );
  }
}

/// Builds the stand-in that flies up from where a message was written. It
/// lays out exactly like the message's row and draws the words alone at
/// [morph] 0 and the finished bubble at 1.
typedef ChatSendFlightBuilder = Widget Function(
  BuildContext context,
  Animation<double> morph,
);

/// Lays its child out with the constraints it first had, at the top-left,
/// whatever its parent offers later.
class _FirstLayoutHold extends SingleChildRenderObjectWidget {
  const _FirstLayoutHold({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFirstLayoutHold();
}

class _RenderFirstLayoutHold extends RenderProxyBox {
  BoxConstraints? _first;

  @override
  void performLayout() {
    final first = _first ??= constraints;
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(first, parentUsesSize: true);
    size = constraints.constrain(child.size);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.constrain(
    child?.getDryLayout(_first ?? constraints) ?? Size.zero,
  );
}

/// A just-sent message rising into place from where it was written.
///
/// It moves on a critically damped spring (0.35 s response, damping 1.0,
/// so no overshoot) from the send origin to its place in the thread. The
/// spring chases that place live, keeping its own position and velocity, so
/// whatever the timeline does meanwhile (a new chat settling its first turn,
/// a scroll bringing the turn up) folds into one continuous motion with no
/// jump.
///
/// With a [flightBuilder] (a plain text message), the message leaves from
/// the words themselves: a stand-in drawn above everything, the composer
/// included, starts with its text exactly where the typed text was, fully
/// opaque, and its bubble grows out from around the words (position and size
/// on the same spring) while it travels. The row in the thread stays hidden
/// until the stand-in lands on it, then takes its place in the same frame.
/// Without one it rises from the origin and fades the rest of the way in.
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
    this.flightBuilder,
  });

  final String messageId;
  final DateTime timestamp;
  final Widget child;

  /// Whether to rise from [ChatSendOrigin]; false rises a short way.
  final bool useSendOrigin;

  /// The stand-in that flies from the origin above the composer, or null to
  /// move the row itself.
  final ChatSendFlightBuilder? flightBuilder;

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

  /// How far a flying message has grown from its words into its bubble at
  /// [t] seconds: the travel's own spring, so size and place arrive together.
  static double morphAt(double t) => 1 - remainingAt(t);

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

  /// The stand-in's flight, when this message leaves from its words.
  _SendFlight? _flight;
  Animation<double>? _morph;
  final OverlayPortalController _portal = OverlayPortalController();

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
    final controller = _controller = AnimationController(
      vsync: this,
      duration: _fadeOnly
          ? ChatSendEntrance.reducedMotionFadeDuration
          : ChatSendEntrance.settleDuration,
    );
    if (!_fadeOnly &&
        widget.useSendOrigin &&
        widget.flightBuilder != null &&
        ChatSendOrigin.hasFresh &&
        Overlay.maybeOf(context) != null) {
      _flight = _SendFlight(onEnd: _endFlight);
      _morph = CurvedAnimation(
        parent: controller,
        curve: const _SpringMorphCurve(),
      );
      // Shown from the first frame, so the stand-in is laid out and ready
      // the moment the row is first painted.
      _portal.show();
      // A stand-in that never got to paint must not keep the row hidden.
      controller.addStatusListener((status) {
        if (status == AnimationStatus.completed) _endFlight();
      });
    }
  }

  /// The stand-in landed (or could not fly): the row shows itself in the
  /// next frame and the stand-in goes.
  void _endFlight() {
    final flight = _flight;
    if (flight == null || flight.ended) return;
    flight.ended = true;
    if (!mounted) return;
    _portal.hide();
    final controller = _controller;
    if (controller != null) {
      controller.stop();
      // Completing the clock repaints the row, now at rest in its place.
      controller.value = 1;
    }
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
    final flight = _flight;
    final motion = _SendEntranceMotion(
      controller: controller,
      fadeOnly: _fadeOnly,
      beginOnScreen: _beginOnScreen,
      onSettled: _settled,
      flight: flight,
      child: widget.child,
    );
    final flightBuilder = widget.flightBuilder;
    final morph = _morph;
    if (flight == null || flightBuilder == null || morph == null) {
      return motion;
    }
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _portal,
      overlayChildBuilder: (context, info) => IgnorePointer(
        child: ExcludeSemantics(
          child: _SendFlightLayer(
            flight: flight,
            controller: controller,
            rowWidth: info.childSize.width,
            child: flightBuilder(context, morph),
          ),
        ),
      ),
      child: motion,
    );
  }
}

/// [ChatSendEntrance.morphAt] over the entrance's clock.
class _SpringMorphCurve extends Curve {
  const _SpringMorphCurve();

  @override
  double transformInternal(double t) {
    final seconds =
        t *
        ChatSendEntrance.settleDuration.inMicroseconds /
        Duration.microsecondsPerSecond;
    return ChatSendEntrance.morphAt(seconds);
  }
}

/// The state a flying stand-in shares with the row it lands on.
class _SendFlight {
  _SendFlight({required this.onEnd});

  /// Ends the flight; never called from inside paint.
  final VoidCallback onEnd;

  /// Where the typed text was, in global coordinates; null until the row is
  /// first painted (or for good, if this send had none).
  Rect? origin;

  /// The row in the thread the stand-in flies to.
  RenderBox? row;

  /// Whether the row's first paint has decided the flight.
  bool decided = false;

  /// Whether the row shows itself again.
  bool ended = false;

  /// The stand-in's painted top-left in its layer, and its velocity.
  Offset? position;
  Offset velocity = Offset.zero;

  /// Clock reading (seconds) the spring was last advanced to.
  double advancedTo = 0;

  bool _endScheduled = false;

  bool get flying => origin != null && !ended;

  void scheduleEnd() {
    if (_endScheduled || ended) return;
    _endScheduled = true;
    // Never change state from inside paint.
    WidgetsBinding.instance.addPostFrameCallback((_) => onEnd());
    WidgetsBinding.instance.scheduleFrame();
  }
}

class _SendFlightLayer extends SingleChildRenderObjectWidget {
  const _SendFlightLayer({
    required this.flight,
    required this.controller,
    required this.rowWidth,
    required super.child,
  });

  final _SendFlight flight;
  final AnimationController controller;
  final double rowWidth;

  @override
  _RenderSendFlightLayer createRenderObject(BuildContext context) =>
      _RenderSendFlightLayer(
        flight: flight,
        controller: controller,
        rowWidth: rowWidth,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSendFlightLayer renderObject,
  ) {
    renderObject
      ..flight = flight
      ..controller = controller
      ..rowWidth = rowWidth;
  }
}

/// Fills the overlay and paints the stand-in where its spring has carried it,
/// aiming each frame at the row's live place in the thread. It starts with
/// its text's top-left on the typed text's, and settles on the row exactly,
/// so the row can take over in the next frame.
class _RenderSendFlightLayer extends RenderProxyBox {
  _RenderSendFlightLayer({
    required _SendFlight flight,
    required AnimationController controller,
    required double rowWidth,
  }) : _flight = flight,
       _controller = controller,
       _rowWidth = rowWidth;

  _SendFlight _flight;
  set flight(_SendFlight value) {
    if (identical(value, _flight)) return;
    _flight = value;
    markNeedsPaint();
  }

  AnimationController _controller;
  set controller(AnimationController value) {
    if (identical(value, _controller)) return;
    if (attached) _controller.removeListener(markNeedsPaint);
    _controller = value;
    if (attached) _controller.addListener(markNeedsPaint);
  }

  double _rowWidth;
  set rowWidth(double value) {
    if (value == _rowWidth) return;
    _rowWidth = value;
    markNeedsLayout();
  }

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

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    final width = _rowWidth.isFinite && _rowWidth > 0
        ? _rowWidth
        : constraints.maxWidth;
    child?.layout(
      BoxConstraints(minWidth: width, maxWidth: width),
      parentUsesSize: true,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      false;

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final position = _flight.position ?? Offset.zero;
    transform.translateByDouble(position.dx, position.dy, 0, 1);
  }

  double get _clockSeconds {
    final duration = _controller.duration ?? Duration.zero;
    return _controller.value *
        duration.inMicroseconds /
        Duration.microsecondsPerSecond;
  }

  /// Where the stand-in's words start inside it: its first paragraph.
  static Offset? _textOffsetIn(RenderBox root) {
    RenderParagraph? found;
    void visit(RenderObject node) {
      if (found != null) return;
      if (node is RenderParagraph) {
        found = node;
        return;
      }
      node.visitChildren(visit);
    }

    root.visitChildren(visit);
    final paragraph = found;
    if (paragraph == null || !paragraph.hasSize) return null;
    return paragraph.localToGlobal(Offset.zero, ancestor: root);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    final flight = _flight;
    final origin = flight.origin;
    final row = flight.row;
    if (child == null ||
        !flight.flying ||
        origin == null ||
        row == null ||
        !row.attached ||
        !row.hasSize) {
      return;
    }
    final target = globalToLocal(row.localToGlobal(Offset.zero));
    final elapsed = _clockSeconds;
    var position = flight.position;
    if (position == null) {
      // The words leave from where they were typed.
      final textOffset = _textOffsetIn(child) ?? Offset.zero;
      position = globalToLocal(origin.topLeft) - textOffset;
      flight.velocity = Offset.zero;
      flight.advancedTo = elapsed;
    } else if (elapsed > flight.advancedTo) {
      final dt = elapsed - flight.advancedTo;
      final x = ChatSendEntrance.step(
        displacement: position.dx - target.dx,
        velocity: flight.velocity.dx,
        dt: dt,
      );
      final y = ChatSendEntrance.step(
        displacement: position.dy - target.dy,
        velocity: flight.velocity.dy,
        dt: dt,
      );
      position = target + Offset(x.displacement, y.displacement);
      flight.velocity = Offset(x.velocity, y.velocity);
      flight.advancedTo = elapsed;
    }
    final settled =
        ChatSendEntrance.morphAt(elapsed) >= 0.999 &&
        (position - target).distance < ChatSendEntrance.restDistance &&
        flight.velocity.distance < ChatSendEntrance.restSpeed;
    if (settled) {
      position = target;
      flight.scheduleEnd();
    }
    flight.position = position;
    context.paintChild(child, offset + position);
  }
}

class _SendEntranceMotion extends SingleChildRenderObjectWidget {
  const _SendEntranceMotion({
    required this.controller,
    required this.fadeOnly,
    required this.beginOnScreen,
    required this.onSettled,
    required this.flight,
    required super.child,
  });

  final AnimationController controller;
  final bool fadeOnly;
  final _SendFlight? flight;

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
        flight: flight,
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
      ..onSettled = onSettled
      ..flight = flight;
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
    required this.flight,
  }) : _controller = controller;

  bool fadeOnly;
  Rect? Function() beginOnScreen;
  VoidCallback onSettled;

  /// A stand-in flying to this row; while it flies, the row paints nothing.
  _SendFlight? flight;

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

  bool get _finished =>
      _settled ||
      (_started && _controller.isCompleted) ||
      (flight?.ended ?? false);

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
    final flight = this.flight;
    if (flight != null && !flight.decided) {
      // The first frame that shows the row decides whether the stand-in
      // flies: it needs the send origin, which this spends.
      flight.decided = true;
      final origin = beginOnScreen();
      if (origin != null) {
        flight
          ..origin = origin
          ..row = this;
      } else {
        flight.scheduleEnd();
      }
    }
    if (flight != null && flight.flying) {
      // The stand-in above the composer is this row until it lands.
      _opacityLayer.layer = null;
      return;
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
