import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// How strongly each visual edge of a horizontal scroller is faded, from 0
/// (content runs to the edge) to 1 (fully faded).
@immutable
class HorizontalFadeEdges {
  const HorizontalFadeEdges({this.left = 0, this.right = 0});

  static const none = HorizontalFadeEdges();

  final double left;
  final double right;

  bool get isFading => left > 0 || right > 0;

  @override
  bool operator ==(Object other) =>
      other is HorizontalFadeEdges &&
      other.left == left &&
      other.right == right;

  @override
  int get hashCode => Object.hash(left, right);
}

/// Fades the edges of a horizontally scrolling child where more content is
/// hidden, so a clipped line or table reads as "scroll for more" instead of
/// being cut off.
///
/// An edge that hides content keeps a clear margin of [edgeInset] (or
/// [endEdgeInset] at the end the content scrolls towards) and fades the
/// content out over [fadeExtent] before it, along an eased ramp with no hard
/// start, so text never runs into the frame mid-glyph. The fade eases away as
/// the user reaches either end, moves to the leading edge once scrolled, and
/// is absent when nothing overflows. Scrolling only repaints the mask; it
/// never rebuilds [builder]'s subtree.
///
/// With a [scrollIndicatorColor], a slim system-style indicator runs along
/// the bottom while the content overflows: it shows briefly the first time
/// it comes into view in an enclosing vertical scroll view, as a scroll view
/// flashes its indicators when it appears, and while the user scrolls, then
/// fades away. It sits outside the fade, so it reads at full strength at
/// either end.
class HorizontalOverflowFade extends StatefulWidget {
  const HorizontalOverflowFade({
    required this.builder,
    this.fadeExtent = 24,
    this.edgeInset = 0,
    this.endEdgeInset,
    this.scrollIndicatorColor,
    this.scrollIndicatorInset = 0,
    this.onOverflowChanged,
    super.key,
  });

  /// Thickness of the scroll indicator, as thin as the system's.
  static const double scrollIndicatorThickness = 2.5;

  /// Gap between the scroll indicator and the bottom edge.
  static const double scrollIndicatorBottomGap = 3;

  /// Shortest the indicator gets, short of overscroll.
  static const double scrollIndicatorMinLength = 36;

  /// How long the indicator stays after scrolling stops, or when it first
  /// shows that the content overflows.
  static const Duration scrollIndicatorLinger = Duration(milliseconds: 800);

  /// Fade-in and fade-out of the indicator.
  static const Duration scrollIndicatorFadeIn = Duration(milliseconds: 120);
  static const Duration scrollIndicatorFadeOut = Duration(milliseconds: 280);

  /// Builds the horizontal scroll view; it must use the given controller.
  final Widget Function(BuildContext context, ScrollController controller)
  builder;

  /// Width of each edge fade, inside the [edgeInset] margin.
  final double fadeExtent;

  /// Clear margin at an edge that hides content: the content is fully faded
  /// out there, matching the padding the content keeps at its own ends.
  final double edgeInset;

  /// [edgeInset] at the end the content scrolls towards (the right, in a
  /// left-to-right layout), where its trailing padding may be wider; null
  /// uses [edgeInset].
  final double? endEdgeInset;

  /// The start (scrolled-from) and end edges' clear margins.
  double get _startInset => edgeInset;
  double get _endInset => endEdgeInset ?? edgeInset;

  /// Colour of the scroll indicator, or null for none.
  final Color? scrollIndicatorColor;

  /// How far the indicator's track stays from the leading and trailing edges,
  /// e.g. to clear rounded corners.
  final double scrollIndicatorInset;

  /// Called when the content starts or stops being wider than the view.
  final ValueChanged<bool>? onOverflowChanged;

  @override
  State<HorizontalOverflowFade> createState() => _HorizontalOverflowFadeState();
}

class _HorizontalOverflowFadeState extends State<HorizontalOverflowFade>
    with SingleTickerProviderStateMixin {
  final ScrollController _controller = ScrollController();
  final ValueNotifier<HorizontalFadeEdges> _edges = ValueNotifier(
    HorizontalFadeEdges.none,
  );
  late final AnimationController _indicator;
  late final Animation<double> _indicatorOpacity;
  bool _overflows = false;
  bool _hasFlashed = false;

  /// Current fade strengths, for tests.
  @visibleForTesting
  HorizontalFadeEdges get edges => _edges.value;

  /// Current opacity of the scroll indicator, for tests.
  @visibleForTesting
  double get scrollIndicatorOpacity => _indicatorOpacity.value;

  static final int _fadeInMs =
      HorizontalOverflowFade.scrollIndicatorFadeIn.inMilliseconds;
  static final int _lingerMs =
      HorizontalOverflowFade.scrollIndicatorLinger.inMilliseconds;
  static final int _fadeOutMs =
      HorizontalOverflowFade.scrollIndicatorFadeOut.inMilliseconds;
  static final int _totalMs = _fadeInMs + _lingerMs + _fadeOutMs;

  /// Controller value at which the indicator is fully shown and lingering.
  static final double _shownValue = _fadeInMs / _totalMs;

  @override
  void initState() {
    super.initState();
    // One timeline per appearance: fade in, linger, fade out. Scrolling holds
    // it at the start of the linger; letting go plays the rest.
    _indicator = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: _totalMs),
    );
    _indicatorOpacity = _indicator.drive(
      TweenSequence<double>([
        TweenSequenceItem(
          tween: Tween(begin: 0.0, end: 1.0),
          weight: _fadeInMs.toDouble(),
        ),
        TweenSequenceItem(
          tween: ConstantTween(1.0),
          weight: _lingerMs.toDouble(),
        ),
        TweenSequenceItem(
          tween: Tween(
            begin: 1.0,
            end: 0.0,
          ).chain(CurveTween(curve: Curves.easeOut)),
          weight: _fadeOutMs.toDouble(),
        ),
      ]),
    );
    _controller.addListener(_updateEdges);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateEdges();
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_updateEdges);
    _controller.dispose();
    _indicator.dispose();
    _edges.dispose();
    super.dispose();
  }

  void _updateEdges() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    if (!position.hasContentDimensions || !position.hasPixels) return;
    // Each edge reaches full strength once a whole margin and fade's worth of
    // content lies past it.
    double strength(double hidden, double inset) {
      final ramp = widget.fadeExtent + inset;
      return ramp <= 0 ? 0 : (hidden / ramp).clamp(0.0, 1.0);
    }

    final before = strength(
      position.pixels - position.minScrollExtent,
      widget._startInset,
    );
    final after = strength(
      position.maxScrollExtent - position.pixels,
      widget._endInset,
    );
    final reversed = position.axisDirection == AxisDirection.left;
    _edges.value = HorizontalFadeEdges(
      left: reversed ? after : before,
      right: reversed ? before : after,
    );
    final overflows = position.maxScrollExtent > position.minScrollExtent;
    if (overflows != _overflows) {
      _overflows = overflows;
      if (overflows && !_hasFlashed) {
        // Like a scroll view appearing: show where the view sits, briefly.
        _hasFlashed = true;
        _flashWhenSeen();
      }
      widget.onOverflowChanged?.call(overflows);
    }
  }

  /// Whether a post-frame check for the indicator coming into view is
  /// pending.
  bool _awaitingView = false;

  /// Flashes the indicator once it is first seen: now, if it is in view,
  /// or else after the first frame that shows it. Content laid out below the
  /// fold, ahead of it in a list's cache, or in a view that is still hidden
  /// while it settles would otherwise flash unseen.
  void _flashWhenSeen() {
    if (widget.scrollIndicatorColor == null) return;
    if (_indicatorInView()) {
      _flashIndicator();
    } else {
      _awaitView();
    }
  }

  /// Checks again after the next frame, whatever produces it: a scroll, a
  /// reveal, or content above moving this down. Waiting never asks for a
  /// frame itself.
  void _awaitView() {
    if (_awaitingView) return;
    _awaitingView = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _awaitingView = false;
      if (!mounted) return;
      if (_indicatorInView()) {
        _flashIndicator();
      } else {
        _awaitView();
      }
    });
  }

  /// Whether the indicator's track is on screen and painted: inside the
  /// enclosing vertical scroll view, clear of its lowest fifth (where a
  /// floating composer or toolbar usually covers the content; a view with
  /// nothing to scroll shows all of it), and not under a hidden ancestor
  /// such as a transcript kept invisible until it settles.
  bool _indicatorInView() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    for (RenderObject? node = box; node != null; node = node.parent) {
      if ((node is RenderOpacity && node.opacity == 0) ||
          (node is RenderAnimatedOpacity && node.opacity.value == 0) ||
          (node is RenderOffstage && node.offstage)) {
        return false;
      }
    }
    final outer = Scrollable.maybeOf(context, axis: Axis.vertical);
    if (outer == null) return true;
    final viewport = outer.context.findRenderObject();
    if (viewport is! RenderBox || !viewport.attached || !viewport.hasSize) {
      return false;
    }
    final position = outer.position;
    if (position.hasContentDimensions &&
        position.maxScrollExtent <= position.minScrollExtent) {
      return true;
    }
    final track = box
        .localToGlobal(
          Offset(
            0,
            box.size.height -
                HorizontalOverflowFade.scrollIndicatorBottomGap -
                HorizontalOverflowFade.scrollIndicatorThickness,
          ),
        )
        .dy;
    final top = viewport.localToGlobal(Offset.zero).dy;
    final bottom = top + viewport.size.height * 0.8;
    return track >= top && track <= bottom;
  }

  void _flashIndicator() {
    if (widget.scrollIndicatorColor == null) return;
    _indicator.forward(from: 0);
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.horizontal ||
        widget.scrollIndicatorColor == null ||
        !_overflows) {
      return false;
    }
    if (notification is ScrollEndNotification) {
      // Linger, then fade out.
      _indicator.forward();
    } else if (notification is ScrollStartNotification ||
        notification is ScrollUpdateNotification ||
        notification is OverscrollNotification) {
      // Shown, without fading, for as long as the content moves.
      if (_indicator.value >= _shownValue) {
        _indicator.value = _shownValue;
      } else if (!_indicator.isAnimating) {
        _indicator.animateTo(
          _shownValue,
          duration: HorizontalOverflowFade.scrollIndicatorFadeIn,
        );
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // A horizontal scroll view runs right to left in a right-to-left layout.
    final rtl = Directionality.maybeOf(context) == TextDirection.rtl;
    Widget content = _EdgeFade(
      edges: _edges,
      fadeExtent: widget.fadeExtent,
      leftInset: rtl ? widget._endInset : widget._startInset,
      rightInset: rtl ? widget._startInset : widget._endInset,
      child: widget.builder(context, _controller),
    );
    final indicatorColor = widget.scrollIndicatorColor;
    if (indicatorColor != null) {
      content = CustomPaint(
        foregroundPainter: _ScrollIndicatorPainter(
          controller: _controller,
          opacity: _indicatorOpacity,
          color: indicatorColor,
          inset: widget.scrollIndicatorInset,
        ),
        child: content,
      );
    }
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis == Axis.horizontal &&
            notification.depth == 0) {
          _updateEdges();
        }
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _handleScrollNotification,
        child: content,
      ),
    );
  }
}

/// A thin, rounded thumb along the bottom edge, like the system's
/// horizontal scroll indicator; it shortens while the content overscrolls.
class _ScrollIndicatorPainter extends CustomPainter {
  _ScrollIndicatorPainter({
    required this.controller,
    required this.opacity,
    required this.color,
    required this.inset,
  }) : super(repaint: Listenable.merge([controller, opacity]));

  final ScrollController controller;
  final Animation<double> opacity;
  final Color color;
  final double inset;

  @override
  void paint(Canvas canvas, Size size) {
    final alpha = opacity.value;
    if (alpha <= 0 || !controller.hasClients) return;
    final position = controller.position;
    if (!position.hasContentDimensions ||
        !position.hasPixels ||
        !position.hasViewportDimension) {
      return;
    }
    final scrollable = position.maxScrollExtent - position.minScrollExtent;
    if (scrollable <= 0) return;
    const thickness = HorizontalOverflowFade.scrollIndicatorThickness;
    final trackLength = size.width - inset * 2;
    if (trackLength <= thickness * 2) return;

    final viewport = position.viewportDimension;
    var length = math.max(
      trackLength * viewport / (viewport + scrollable),
      math.min(HorizontalOverflowFade.scrollIndicatorMinLength, trackLength),
    );
    final overscroll = position.pixels < position.minScrollExtent
        ? position.minScrollExtent - position.pixels
        : math.max(0.0, position.pixels - position.maxScrollExtent);
    length = math.max(thickness * 2, length - overscroll);
    final progress = ((position.pixels - position.minScrollExtent) / scrollable)
        .clamp(0.0, 1.0);
    var start = inset + (trackLength - length) * progress;
    if (position.axisDirection == AxisDirection.left) {
      start = size.width - start - length;
    }
    final rect = Rect.fromLTWH(
      start,
      size.height - HorizontalOverflowFade.scrollIndicatorBottomGap - thickness,
      length,
      thickness,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(thickness / 2)),
      Paint()..color = color.withValues(alpha: color.a * alpha),
    );
  }

  @override
  bool shouldRepaint(_ScrollIndicatorPainter oldDelegate) =>
      oldDelegate.controller != controller ||
      oldDelegate.opacity != opacity ||
      oldDelegate.color != color ||
      oldDelegate.inset != inset;
}

class _EdgeFade extends SingleChildRenderObjectWidget {
  const _EdgeFade({
    required this.edges,
    required this.fadeExtent,
    required this.leftInset,
    required this.rightInset,
    super.child,
  });

  final ValueListenable<HorizontalFadeEdges> edges;
  final double fadeExtent;
  final double leftInset;
  final double rightInset;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderEdgeFade(edges, fadeExtent, leftInset, rightInset);

  @override
  void updateRenderObject(BuildContext context, _RenderEdgeFade renderObject) {
    renderObject
      ..edges = edges
      ..fadeExtent = fadeExtent
      ..leftInset = leftInset
      ..rightInset = rightInset;
  }
}

class _RenderEdgeFade extends RenderProxyBox {
  _RenderEdgeFade(
    this._edges,
    this._fadeExtent,
    this._leftInset,
    this._rightInset,
  );

  /// Points along each fade's ramp: enough that the eased curve has no
  /// visible joints.
  static const int _rampSteps = 6;

  /// How far the mask reaches past the box on every side.
  static const double _maskOverhang = 2;

  ValueListenable<HorizontalFadeEdges> _edges;
  double _fadeExtent;
  double _leftInset;
  double _rightInset;
  bool _wasFading = false;

  set edges(ValueListenable<HorizontalFadeEdges> value) {
    if (identical(value, _edges)) return;
    if (attached) _edges.removeListener(_handleEdgesChanged);
    _edges = value;
    if (attached) _edges.addListener(_handleEdgesChanged);
    _handleEdgesChanged();
  }

  set fadeExtent(double value) {
    if (value == _fadeExtent) return;
    _fadeExtent = value;
    markNeedsPaint();
  }

  set leftInset(double value) {
    if (value == _leftInset) return;
    _leftInset = value;
    markNeedsPaint();
  }

  set rightInset(double value) {
    if (value == _rightInset) return;
    _rightInset = value;
    markNeedsPaint();
  }

  bool get _isFading => _edges.value.isFading;

  void _handleEdgesChanged() {
    final fading = _isFading;
    if (fading != _wasFading) {
      _wasFading = fading;
      markNeedsCompositingBitsUpdate();
    }
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _wasFading = _isFading;
    _edges.addListener(_handleEdgesChanged);
  }

  @override
  void detach() {
    _edges.removeListener(_handleEdgesChanged);
    super.detach();
  }

  @override
  bool get alwaysNeedsCompositing => child != null && _isFading;

  @override
  ShaderMaskLayer? get layer => super.layer as ShaderMaskLayer?;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null || !_isFading || size.width <= 0) {
      layer = null;
      if (child != null) context.paintChild(child, offset);
      return;
    }
    final edges = _edges.value;
    // The mask overhangs the box by a little: on a fractional offset (inside
    // a hairline border) the box's edge pixels are only partly inside it,
    // and content there would otherwise escape the mask as a sliver of
    // glyphs at the frame's edge.
    final maskRect = (offset & size).inflate(_maskOverhang);
    final width = maskRect.width;
    final half = size.width / 2;
    final colors = <Color>[];
    final stops = <double>[];
    // [x] runs across the box, from 0 at its left edge.
    void addStop(double x, double alpha) {
      colors.add(Color.fromRGBO(0, 0, 0, alpha));
      stops.add(((x + _maskOverhang) / width).clamp(0.0, 1.0));
    }

    // Each edge: a clear margin, then a fade that eases in and out of full
    // strength (smoothstep), so it has no hard line where it starts and
    // reads as content running on rather than a cut. Never past the middle.
    void addEdge(double inset, double strength, {required bool leading}) {
      final margin = math.min(inset, half);
      final fadeEnd = math.min(inset + _fadeExtent, half);
      for (var i = 0; i <= _rampSteps; i++) {
        // t runs from the frame's edge (0) to fully shown content (1).
        final t = leading ? i / _rampSteps : 1 - i / _rampSteps;
        final eased = t * t * (3 - 2 * t);
        final distance = margin + (fadeEnd - margin) * t;
        addStop(
          leading ? distance : size.width - distance,
          1 - strength * (1 - eased),
        );
      }
    }

    addStop(-_maskOverhang, 1 - edges.left);
    addEdge(_leftInset, edges.left, leading: true);
    addEdge(_rightInset, edges.right, leading: false);
    addStop(size.width + _maskOverhang, 1 - edges.right);
    final shader = LinearGradient(
      colors: colors,
      stops: stops,
    ).createShader(Offset.zero & maskRect.size);
    final maskLayer = layer ?? ShaderMaskLayer();
    maskLayer
      ..shader = shader
      ..maskRect = maskRect
      ..blendMode = BlendMode.dstIn;
    layer = maskLayer;
    context.pushLayer(maskLayer, super.paint, offset);
  }
}
