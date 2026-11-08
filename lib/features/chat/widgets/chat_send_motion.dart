import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../../../shared/theme/theme_extensions.dart';
import 'chat_motion_spring.dart';
import 'chat_timeline_viewport.dart' show ChatScrollDestination;

/// Where the text of the message being sent was on screen: the composer's
/// field, or the follow-up row that was tapped. The new bubble rises from
/// here, so the message visibly travels from where it was written.
class ChatSendOrigin {
  ChatSendOrigin._();

  static Rect? _rect;
  static DateTime? _recordedAt;

  /// The box [_rect] was measured from, to follow it if it has moved since
  /// (the keyboard going down carries the composer with it).
  static RenderBox? _box;
  static Offset? _boxBottomLeft;

  /// How long a recorded origin stays usable. The bubble mounts within a
  /// frame or two of the send; anything later is not this send's bubble.
  static const Duration maxAge = Duration(milliseconds: 1500);

  /// Records [globalRect] (logical pixels in the view) as the next bubble's
  /// origin.
  static void record(Rect globalRect) {
    _rect = globalRect;
    _recordedAt = DateTime.now();
    _box = null;
    _boxBottomLeft = null;
  }

  /// Records the on-screen rect of [context]'s render box, if laid out. A
  /// bubble that only gets to leave a few frames later (its row was off
  /// screen) leaves from where that box is then, moved as the box moved, so
  /// it never appears where the composer used to be.
  static void recordFrom(BuildContext? context) {
    final box = context?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    record(rect);
    _box = box;
    _boxBottomLeft = rect.bottomLeft;
  }

  /// Whether a fresh origin is waiting, without spending it.
  static bool get hasFresh {
    final at = _recordedAt;
    return _rect != null &&
        at != null &&
        DateTime.now().difference(at) <= maxAge;
  }

  /// Returns the recorded origin once, if it is still fresh, moved as the
  /// recorded box has moved since (the keyboard going down carries the
  /// composer with it). Measures that box, so call it from paint or later.
  static Rect? take({DateTime? now}) {
    final taken = takeFollowing(now: now);
    return taken?.rect.shift(taken.drift());
  }

  /// Returns the recorded origin once, if it is still fresh, as recorded,
  /// with how far its box has moved since recording (zero once it is gone).
  /// Measures nothing until [drift] is called, so it is safe during layout;
  /// a bubble still waiting to leave stays with the composer through it.
  static ({Rect rect, Offset Function() drift})? takeFollowing({
    DateTime? now,
  }) {
    final rect = _rect;
    final at = _recordedAt;
    final box = _box;
    final recorded = _boxBottomLeft;
    _rect = null;
    _recordedAt = null;
    _box = null;
    _boxBottomLeft = null;
    if (rect == null || at == null) return null;
    if ((now ?? DateTime.now()).difference(at) > maxAge) return null;
    return (
      rect: rect,
      drift: () {
        if (box == null || recorded == null || !box.attached || !box.hasSize) {
          return Offset.zero;
        }
        final current = box.localToGlobal(Offset(0, box.size.height));
        return current.isFinite ? current - recorded : Offset.zero;
      },
    );
  }

  @visibleForTesting
  static void debugReset() {
    _rect = null;
    _recordedAt = null;
    _box = null;
    _boxBottomLeft = null;
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

/// Content that a send makes obsolete (the last reply's follow-up
/// suggestions) dissolving instead of vanishing. When [child] becomes null,
/// its last appearance stays drawn where it was and fades out over
/// [duration], opacity only, while taking no room: layout moves on at once,
/// so the new turn takes its place and the transcript's scroll is unchanged,
/// but nothing pops out of view. The fade is front-loaded, as the leaving
/// greeting's is, so it is all but gone before the rising message crosses
/// its lines. Reduce Motion keeps the same fade, as a cross-fade. A leaving
/// child never takes touches or VoiceOver focus.
class ChatLeavingContent extends StatefulWidget {
  const ChatLeavingContent({super.key, required this.child});

  /// What shows now, or null once it has gone.
  final Widget? child;

  static const Duration duration = Duration(milliseconds: 150);

  @override
  State<ChatLeavingContent> createState() => _ChatLeavingContentState();
}

class _ChatLeavingContentState extends State<ChatLeavingContent>
    with SingleTickerProviderStateMixin {
  /// How far the leaving child has gone: 0 while it shows, 1 once gone.
  late final AnimationController _exit = AnimationController(
    vsync: this,
    duration: ChatLeavingContent.duration,
  );
  late final Animation<double> _opacity = ReverseAnimation(
    CurvedAnimation(parent: _exit, curve: Curves.easeOutCubic),
  );

  /// The child that is leaving, kept to draw it fading.
  Widget? _leaving;

  @override
  void didUpdateWidget(covariant ChatLeavingContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.child;
    if (widget.child != null) {
      _leaving = null;
      _exit.value = 0;
    } else if (previous != null) {
      _leaving = previous;
      _exit.forward(from: 0).whenCompleteOrCancel(() {
        if (mounted && widget.child == null && _leaving != null) {
          setState(() => _leaving = null);
        }
      });
    }
  }

  @override
  void dispose() {
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.child ?? _leaving;
    if (child == null) return const SizedBox.shrink();
    final leaving = widget.child == null;
    // One shape whether it shows or leaves, so the child is not rebuilt
    // from scratch the moment it starts to go.
    return _LeavingLayout(
      leaving: leaving,
      child: IgnorePointer(
        ignoring: leaving,
        child: ExcludeSemantics(
          excluding: leaving,
          child: FadeTransition(opacity: _opacity, child: child),
        ),
      ),
    );
  }
}

/// Lays its child out as usual and takes its size, or no height at all while
/// [leaving], still painting it where it was.
class _LeavingLayout extends SingleChildRenderObjectWidget {
  const _LeavingLayout({required this.leaving, required super.child});

  final bool leaving;

  @override
  _RenderLeavingLayout createRenderObject(BuildContext context) =>
      _RenderLeavingLayout(leaving);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderLeavingLayout renderObject,
  ) {
    renderObject.leaving = leaving;
  }
}

class _RenderLeavingLayout extends RenderProxyBox {
  _RenderLeavingLayout(this._leaving);

  bool _leaving;
  set leaving(bool value) {
    if (value == _leaving) return;
    _leaving = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints.copyWith(minHeight: 0), parentUsesSize: true);
    size = constraints.constrain(
      Size(child.size.width, _leaving ? 0 : child.size.height),
    );
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final childSize =
        child?.getDryLayout(constraints.copyWith(minHeight: 0)) ?? Size.zero;
    return constraints.constrain(
      Size(childSize.width, _leaving ? 0 : childSize.height),
    );
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      !_leaving && super.hitTest(result, position: position);
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

/// How much higher a row in [position]'s transcript will rest once the
/// programmatic scroll it is running settles (the transcript bringing a sent
/// turn up to the top), in points; zero when nothing is scrolling it to a
/// destination. A message flying to its row aims this much above the row, so
/// it heads for where the row will be, on the same spring as the scroll, and
/// the two close their gap instead of the message chasing a moving target
/// across the text above it.
double chatRestingRise(ScrollPosition? position) {
  if (position == null ||
      !position.hasPixels ||
      position.axisDirection != AxisDirection.down) {
    return 0;
  }
  final Object destination = position;
  if (destination is! ChatScrollDestination) return 0;
  final resting = destination.restingPixels;
  return resting == null ? 0 : resting - position.pixels;
}

/// A just-sent message rising into place from where it was written.
///
/// It moves on a critically damped spring (0.35 s response, damping 1.0,
/// so no overshoot) from the send origin to its place in the thread. The
/// spring chases that place live, keeping its own position and velocity, so
/// whatever the timeline does meanwhile (a new chat settling its first turn)
/// folds into one continuous motion with no jump. While the transcript
/// scrolls the turn up to the top on the same spring, the message aims at
/// where its row will come to rest (see [chatRestingRise]), so message and
/// row arrive together and the message never crosses the reply above.
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

  /// The message's spring. The transcript bringing a sent turn up to the top
  /// moves on it too, so the message and its row arrive together.
  static const CriticallyDampedSpring spring = CriticallyDampedSpring(
    springResponse,
  );

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

  /// Displacement left at [t] seconds for a critically damped spring with
  /// [springResponse] released at rest, as a fraction of the starting
  /// distance.
  static double remainingAt(double t) => spring.remainingAt(t);

  /// How far a flying message has grown from its words into its bubble at
  /// [t] seconds: the travel's own spring, so size and place arrive together.
  static double morphAt(double t) => 1 - remainingAt(t);

  /// Advances the spring [dt] seconds from [displacement] (points from its
  /// target) moving at [velocity] (points per second).
  static ({double displacement, double velocity}) step({
    required double displacement,
    required double velocity,
    required double dt,
  }) => spring.step(displacement: displacement, velocity: velocity, dt: dt);

  @override
  State<ChatSendEntrance> createState() => _ChatSendEntranceState();
}

class _ChatSendEntranceState extends State<ChatSendEntrance>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  _TakenOrigin? _origin;
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

  /// The first frame that shows the bubble (or, for a stand-in, lays out its
  /// row) spends its entrance and takes the send origin; a mount replaced
  /// before that leaves both.
  _TakenOrigin? _beginOnScreen() {
    markChatEntranceShown(widget.messageId);
    if (_fadeOnly) {
      // The origin belongs to this send either way; spend it.
      ChatSendOrigin.takeFollowing();
      return null;
    }
    return _origin ??= widget.useSendOrigin
        ? ChatSendOrigin.takeFollowing()
        : null;
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
    final scroll = Scrollable.maybeOf(context)?.position;
    flight?.scroll = scroll;
    final motion = _SendEntranceMotion(
      controller: controller,
      fadeOnly: _fadeOnly,
      beginOnScreen: _beginOnScreen,
      onSettled: _settled,
      flight: flight,
      scroll: scroll,
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

/// A send origin as taken: where the words were, and how far their box has
/// moved since.
typedef _TakenOrigin = ({Rect rect, Offset Function() drift});

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
  /// first laid out (or for good, if this send had none).
  Rect? origin;

  /// How far the composer the words left has moved since [origin] was
  /// taken: a stand-in still waiting for its row stays with it.
  Offset Function()? originDrift;

  /// Repaints the stand-in's layer, once the flight is decided.
  VoidCallback? repaint;

  /// The row in the thread the stand-in flies to.
  RenderBox? row;

  /// The transcript's scroll position, to aim where the row will rest.
  ScrollPosition? scroll;

  /// Whether the row's first paint has decided the flight.
  bool decided = false;

  /// Whether the row shows itself again.
  bool ended = false;

  /// The spring's top-left for the stand-in in its layer, and its velocity.
  Offset? position;
  Offset velocity = Offset.zero;

  /// Where the stand-in started, and where it is painted: the spring's
  /// place, held at or below its row while the transcript brings the turn
  /// up (see [ridesTurn]).
  Offset? start;
  Offset? painted;

  /// Whether the transcript has been scrolling the turn up to a destination
  /// during this flight. From then on the stand-in never shows above its
  /// row: a turn brought up from far below meets it where it was written
  /// and carries it up, instead of the stand-in racing ahead across the
  /// text that streams past.
  bool ridesTurn = false;

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
    if (attached) _flight.repaint = markNeedsPaint;
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
    _flight.repaint = markNeedsPaint;
  }

  @override
  void detach() {
    _controller.removeListener(markNeedsPaint);
    if (_flight.repaint == markNeedsPaint) _flight.repaint = null;
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
    final position = _flight.painted ?? _flight.position ?? Offset.zero;
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
    final live = globalToLocal(row.localToGlobal(Offset.zero));
    // Where the row will be once the transcript has scrolled the turn up.
    final rise = chatRestingRise(flight.scroll);
    if (rise.abs() >= ChatSendEntrance.restDistance) flight.ridesTurn = true;
    final target = live.translate(0, -rise);
    final elapsed = _clockSeconds;
    var position = flight.position;
    if (position == null) {
      // The words leave from where they were typed, wherever the composer
      // has carried that place since.
      final textOffset = _textOffsetIn(child) ?? Offset.zero;
      final start = globalToLocal(origin.topLeft) - textOffset;
      flight.start = start;
      position = start + (flight.originDrift?.call() ?? Offset.zero);
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
    var painted = position;
    final start = flight.start;
    if (flight.ridesTurn && start != null) {
      // Never above its row while the row is still on its way: it waits
      // where it was written (with the composer, as the keyboard goes down)
      // until the row rises to meet it, then goes up on it. A row already
      // above it changes nothing.
      final waiting = start + (flight.originDrift?.call() ?? Offset.zero);
      final floor = math.min(live.dy, waiting.dy);
      if (painted.dy < floor) painted = Offset(painted.dx, floor);
    }
    // It hands over only on the row itself, once the scroll has landed too.
    final settled =
        ChatSendEntrance.morphAt(elapsed) >= 0.999 &&
        (position - target).distance < ChatSendEntrance.restDistance &&
        (target - live).distance < ChatSendEntrance.restDistance &&
        flight.velocity.distance < ChatSendEntrance.restSpeed;
    if (settled) {
      position = target;
      painted = target;
      flight.scheduleEnd();
    }
    flight.position = position;
    flight.painted = painted;
    context.paintChild(child, offset + painted);
  }
}

class _SendEntranceMotion extends SingleChildRenderObjectWidget {
  const _SendEntranceMotion({
    required this.controller,
    required this.fadeOnly,
    required this.beginOnScreen,
    required this.onSettled,
    required this.flight,
    required this.scroll,
    required super.child,
  });

  final AnimationController controller;
  final bool fadeOnly;
  final _SendFlight? flight;
  final ScrollPosition? scroll;

  /// Called at the first paint; returns the send origin, if any.
  final _TakenOrigin? Function() beginOnScreen;
  final VoidCallback onSettled;

  @override
  _RenderSendEntrance createRenderObject(BuildContext context) =>
      _RenderSendEntrance(
        controller: controller,
        fadeOnly: fadeOnly,
        beginOnScreen: beginOnScreen,
        onSettled: onSettled,
        flight: flight,
        scroll: scroll,
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
      ..flight = flight
      ..scroll = scroll;
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
    required this.scroll,
  }) : _controller = controller;

  bool fadeOnly;
  _TakenOrigin? Function() beginOnScreen;
  VoidCallback onSettled;

  /// The transcript's scroll position, to aim where the row will rest.
  ScrollPosition? scroll;

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

  /// Where it started, and whether the transcript has been bringing the turn
  /// up (see [_SendFlight.ridesTurn]).
  double? _startTop;
  bool _ridesTurn = false;

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
    // Where the row will be once the transcript has scrolled the turn up.
    final rise = chatRestingRise(scroll);
    if (rise.abs() >= ChatSendEntrance.restDistance) _ridesTurn = true;
    final targetTop = layoutTop - rise;
    var visualTop = _visualTop;
    if (visualTop == null) {
      final taken = beginOnScreen();
      final origin = taken?.rect.shift(taken.drift());
      visualTop = origin == null
          ? layoutTop + ChatSendEntrance.fallbackRise
          // The message's last line starts where the field's last line was.
          : origin.bottom - size.height;
      _startTop = visualTop;
      _velocity = 0;
      _advancedTo = elapsed;
    } else if (elapsed > _advancedTo) {
      final next = ChatSendEntrance.step(
        displacement: visualTop - targetTop,
        velocity: _velocity,
        dt: elapsed - _advancedTo,
      );
      visualTop = targetTop + next.displacement;
      _velocity = next.velocity;
      _advancedTo = elapsed;
    }
    _visualTop = visualTop;
    var paintedTop = visualTop;
    final startTop = _startTop;
    if (_ridesTurn && startTop != null) {
      // Never above where its row is while the turn is brought up.
      paintedTop = math.max(paintedTop, math.min(layoutTop, startTop));
    }
    _offsetY = paintedTop - layoutTop;
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

  /// Starts the clock after this frame, once.
  void _startClock() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached && !_controller.isAnimating && !_settled) {
        _controller.forward();
      }
    });
  }

  @override
  void performLayout() {
    super.performLayout();
    final flight = this.flight;
    if (flight == null || flight.decided) return;
    // The first layout of the row decides whether the stand-in flies: it
    // needs the send origin, which this spends. Deciding here rather than
    // at the first paint lets the words leave in the frame of the send even
    // when the row is still below the screen (a reply that ran on under the
    // composer); the stand-in then waits with the composer for the row.
    flight.decided = true;
    final taken = beginOnScreen();
    if (taken != null) {
      flight
        ..origin = taken.rect
        ..originDrift = taken.drift
        ..row = this;
      _startClock();
      flight.repaint?.call();
    } else {
      flight.scheduleEnd();
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    if (!_started) {
      if (fadeOnly) beginOnScreen();
      // The clock starts with the first frame that shows the row.
      _startClock();
    }
    final flight = this.flight;
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
