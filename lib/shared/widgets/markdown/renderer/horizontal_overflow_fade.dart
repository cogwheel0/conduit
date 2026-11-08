import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
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
/// Each edge fades in proportion to how much content lies past it (up to
/// [fadeExtent]), so the fade eases away as the user reaches either end and
/// is absent when nothing overflows. Scrolling only repaints the mask; it
/// never rebuilds [builder]'s subtree.
class HorizontalOverflowFade extends StatefulWidget {
  const HorizontalOverflowFade({
    required this.builder,
    this.fadeExtent = 24,
    super.key,
  });

  /// Builds the horizontal scroll view; it must use the given controller.
  final Widget Function(BuildContext context, ScrollController controller)
  builder;

  /// Width of each edge fade.
  final double fadeExtent;

  @override
  State<HorizontalOverflowFade> createState() => _HorizontalOverflowFadeState();
}

class _HorizontalOverflowFadeState extends State<HorizontalOverflowFade> {
  final ScrollController _controller = ScrollController();
  final ValueNotifier<HorizontalFadeEdges> _edges = ValueNotifier(
    HorizontalFadeEdges.none,
  );

  /// Current fade strengths, for tests.
  @visibleForTesting
  HorizontalFadeEdges get edges => _edges.value;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateEdges);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateEdges();
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_updateEdges);
    _controller.dispose();
    _edges.dispose();
    super.dispose();
  }

  void _updateEdges() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    if (!position.hasContentDimensions || !position.hasPixels) return;
    final extent = widget.fadeExtent;
    double strength(double hidden) =>
        extent <= 0 ? 0 : (hidden / extent).clamp(0.0, 1.0);
    final before = strength(position.pixels - position.minScrollExtent);
    final after = strength(position.maxScrollExtent - position.pixels);
    final reversed = position.axisDirection == AxisDirection.left;
    _edges.value = HorizontalFadeEdges(
      left: reversed ? after : before,
      right: reversed ? before : after,
    );
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis == Axis.horizontal &&
            notification.depth == 0) {
          _updateEdges();
        }
        return false;
      },
      child: _EdgeFade(
        edges: _edges,
        fadeExtent: widget.fadeExtent,
        child: widget.builder(context, _controller),
      ),
    );
  }
}

class _EdgeFade extends SingleChildRenderObjectWidget {
  const _EdgeFade({required this.edges, required this.fadeExtent, super.child});

  final ValueListenable<HorizontalFadeEdges> edges;
  final double fadeExtent;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderEdgeFade(edges, fadeExtent);

  @override
  void updateRenderObject(BuildContext context, _RenderEdgeFade renderObject) {
    renderObject
      ..edges = edges
      ..fadeExtent = fadeExtent;
  }
}

class _RenderEdgeFade extends RenderProxyBox {
  _RenderEdgeFade(this._edges, this._fadeExtent);

  ValueListenable<HorizontalFadeEdges> _edges;
  double _fadeExtent;
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
    final stop = (_fadeExtent / size.width).clamp(0.0, 0.5);
    final shader = LinearGradient(
      colors: [
        Color.fromRGBO(0, 0, 0, 1 - edges.left),
        const Color(0xFF000000),
        const Color(0xFF000000),
        Color.fromRGBO(0, 0, 0, 1 - edges.right),
      ],
      stops: [0, stop, 1 - stop, 1],
    ).createShader(Offset.zero & size);
    final maskLayer = layer ?? ShaderMaskLayer();
    maskLayer
      ..shader = shader
      ..maskRect = offset & size
      ..blendMode = BlendMode.dstIn;
    layer = maskLayer;
    context.pushLayer(maskLayer, super.paint, offset);
  }
}
