import 'dart:math' as math;
import 'dart:ui' show FragmentProgram, FragmentShader, ImageFilter;

import 'package:flutter/widgets.dart';

import '../theme/theme_extensions.dart';

const double kConduitChromeFadeHeight = 30.0;

enum ConduitChromeFadeEdge { top, bottom }

/// Gradient-only chrome edge used when custom Flutter bars replace native bars.
///
/// This intentionally does not blur. It gives transparent custom chrome the
/// same soft scroll-edge separation as the adaptive bars while keeping the
/// underlying content readable.
class ConduitChromeGradientFade extends StatelessWidget {
  const ConduitChromeGradientFade({
    super.key,
    required this.edge,
    required this.contentHeight,
    this.fadeHeight = kConduitChromeFadeHeight,
    this.backgroundColor,
    this.solidBehindChrome = false,
  });

  const ConduitChromeGradientFade.top({
    super.key,
    required this.contentHeight,
    this.fadeHeight = kConduitChromeFadeHeight,
    this.backgroundColor,
    this.solidBehindChrome = false,
  }) : edge = ConduitChromeFadeEdge.top;

  const ConduitChromeGradientFade.bottom({
    super.key,
    required this.contentHeight,
    this.fadeHeight = kConduitChromeFadeHeight,
    this.backgroundColor,
    this.solidBehindChrome = false,
  }) : edge = ConduitChromeFadeEdge.bottom;

  final ConduitChromeFadeEdge edge;
  final double contentHeight;
  final double fadeHeight;
  final Color? backgroundColor;

  /// Keeps the fade opaque across [contentHeight] and only softens it in the
  /// [fadeHeight] strip beyond, like iOS's "hard" scroll-edge style.
  ///
  /// For floating chrome over scrolling text (a title, glass buttons, a
  /// composer), where the default ramp lets text read through the chrome and
  /// Liquid Glass refracts it into ghosts. The soft strip follows an
  /// ease-in-out curve so the edge never shows a line.
  final bool solidBehindChrome;

  /// Stops across the soft strip. Enough for the eased ramp to read as a
  /// curve rather than linear bands.
  static const int _softStops = 8;

  @override
  Widget build(BuildContext context) {
    final baseColor = backgroundColor ?? context.conduitTheme.surfaceBackground;
    final height = contentHeight + fadeHeight;
    final solidStop = height <= 0 ? 0.0 : contentHeight / height;
    final colors = edge == ConduitChromeFadeEdge.top
        ? [
            baseColor.withValues(alpha: 0.92),
            baseColor.withValues(alpha: 0.72),
            baseColor.withValues(alpha: 0.28),
            baseColor.withValues(alpha: 0.0),
          ]
        : [
            baseColor.withValues(alpha: 0.0),
            baseColor.withValues(alpha: 0.28),
            baseColor.withValues(alpha: 0.72),
            baseColor.withValues(alpha: 0.92),
          ];

    final gradient = solidBehindChrome
        ? _solidGradient(baseColor, solidStop)
        : LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: colors,
            stops: const [0.0, 0.3, 0.65, 1.0],
          );

    return IgnorePointer(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: DecoratedBox(decoration: BoxDecoration(gradient: gradient)),
      ),
    );
  }

  /// Opaque from the chrome's edge through [solidStop], then an eased ramp
  /// to clear at the far end of the soft strip.
  LinearGradient _solidGradient(Color baseColor, double solidStop) {
    final colors = <Color>[baseColor, baseColor];
    final stops = <double>[0.0, solidStop];
    for (var i = 1; i <= _softStops; i++) {
      final t = i / _softStops;
      // Cosine ease: flat where it meets the opaque band, flat as it clears.
      final alpha = 0.5 * (1 + math.cos(math.pi * t));
      colors.add(baseColor.withValues(alpha: baseColor.a * alpha));
      stops.add(solidStop + (1 - solidStop) * t);
    }
    final topDown = edge == ConduitChromeFadeEdge.top;
    return LinearGradient(
      begin: topDown ? Alignment.topCenter : Alignment.bottomCenter,
      end: topDown ? Alignment.bottomCenter : Alignment.topCenter,
      colors: colors,
      stops: stops,
    );
  }
}

/// How far past floating chrome the soft scroll edge reaches before the
/// content under it is clear and sharp. A first message resting under the
/// chat header starts about 22 pt below its buttons, just clear of it.
const double kConduitScrollEdgeSoftExtent = 24.0;

/// The heaviest blur of the soft scroll edge, in logical pixels, reached
/// where the strip meets the covered band.
const double kConduitScrollEdgeMaxSigma = 9.0;

/// Exponent of the blur's ease in from its clear end (mirrors
/// shaders/scroll_edge_blur.frag).
const double _kScrollEdgeSigmaEase = 1.6;

/// The share of the strip, next to the cover, where the content has already
/// settled into the background (fully tinted and blurred), so text right
/// beside the glass is gone rather than half-legible. The rest eases out.
const double _kScrollEdgeSettledShare = 0.3;

/// iOS 26's scroll edge for custom chrome that floats over scrolling text:
/// the content reaches the page background before it reaches the glass.
///
/// Measured from the screen edge ([edge] says which), the effect is:
///
/// * fully covered in the page background across [coverExtent]: the status
///   bar and the chrome's full height (the header's buttons, the composer),
///   so Liquid Glass never sits over text, legible or blurred;
/// * a strip of [softExtent] beyond it where the content blurs and fades
///   into the background, so a line passing under the chrome dissolves
///   rather than being cut by it: settled into the background across the
///   strip's first 30%, then easing out (smoothstep, flat at both ends) to
///   clear and sharp.
///
/// [engagement] says how much content lies under the edge, from 0 (none: the
/// list rests at that end) to 1. The strip grows with it, so content resting
/// at the end of the list is never washed out, and a scroll toward the edge
/// meets the strip at its clear end, without a step.
///
/// The blur is one backdrop filter over the strip alone: a Gaussian whose
/// strength follows the distance from the edge
/// (shaders/scroll_edge_blur.frag, run horizontally then vertically), so it
/// has no bands or seams. The tint lies over it. Where shader filters are
/// unavailable (no Impeller) only the tint is drawn.
class ConduitScrollEdgeEffect extends StatefulWidget {
  const ConduitScrollEdgeEffect({
    super.key,
    required this.edge,
    required this.coverExtent,
    this.softExtent = kConduitScrollEdgeSoftExtent,
    this.engagement = 1,
    this.maxSigma = kConduitScrollEdgeMaxSigma,
    this.backgroundColor,
  });

  const ConduitScrollEdgeEffect.top({
    super.key,
    required this.coverExtent,
    this.softExtent = kConduitScrollEdgeSoftExtent,
    this.engagement = 1,
    this.maxSigma = kConduitScrollEdgeMaxSigma,
    this.backgroundColor,
  }) : edge = ConduitChromeFadeEdge.top;

  const ConduitScrollEdgeEffect.bottom({
    super.key,
    required this.coverExtent,
    this.softExtent = kConduitScrollEdgeSoftExtent,
    this.engagement = 1,
    this.maxSigma = kConduitScrollEdgeMaxSigma,
    this.backgroundColor,
  }) : edge = ConduitChromeFadeEdge.bottom;

  final ConduitChromeFadeEdge edge;

  /// Distance from the screen edge that is fully covered: to the far side of
  /// the chrome (the bottom of the header's buttons, the top of the
  /// composer).
  final double coverExtent;

  /// Length of the eased strip beyond [coverExtent] when fully engaged.
  final double softExtent;

  /// How much content lies under the edge, 0 to 1; scales the strip.
  final double engagement;

  /// Blur where the strip meets the cover.
  final double maxSigma;
  final Color? backgroundColor;

  double get _cover => math.max(0.0, coverExtent);

  /// The strip's length now.
  double get stripExtent =>
      math.max(0.0, softExtent) * engagement.clamp(0.0, 1.0).toDouble();

  /// Total depth of the effect from the screen edge.
  double get extent => _cover + stripExtent;

  /// Distance from the screen edge out to which the content has settled
  /// into the background: fully tinted, fully blurred.
  double get settledExtent => _cover + stripExtent * _kScrollEdgeSettledShare;

  /// How far [distance] is into the easing part of the strip, from 0 at its
  /// clear end to 1 where the content has settled; null past the strip.
  double? _easeAt(double distance) {
    if (distance <= settledExtent) return 1;
    final span = extent - settledExtent;
    if (span <= 0 || distance >= extent) return null;
    return (extent - distance) / span;
  }

  /// The tint's opacity at [distance] from the screen edge: 1 across the
  /// cover and the settled part of the strip, then easing (smoothstep, flat
  /// at both ends) to 0 at [extent].
  @visibleForTesting
  double tintOpacityAt(double distance) {
    final u = _easeAt(distance);
    if (u == null) return 0;
    return u * u * (3 - 2 * u);
  }

  /// The blur at [distance] from the screen edge: [maxSigma] out to
  /// [settledExtent], easing to none at [extent]. Mirrors the shader.
  ///
  /// It eases in from the clear end: text just inside the strip mostly
  /// fades, and only blurs hard where the tint already hides most of it, so
  /// it dissolves instead of smearing into a grey smudge.
  @visibleForTesting
  double sigmaAt(double distance) {
    final u = _easeAt(distance);
    if (u == null) return 0;
    return maxSigma * math.pow(u, _kScrollEdgeSigmaEase).toDouble();
  }

  @override
  State<ConduitScrollEdgeEffect> createState() =>
      _ConduitScrollEdgeEffectState();
}

class _ConduitScrollEdgeEffectState extends State<ConduitScrollEdgeEffect> {
  static const String _shaderAsset = 'shaders/scroll_edge_blur.frag';
  static Future<FragmentProgram?>? _loading;
  static FragmentProgram? _program;

  FragmentShader? _horizontal;
  FragmentShader? _vertical;

  @override
  void initState() {
    super.initState();
    if (_program != null) {
      _createShaders(_program!);
    } else if (ImageFilter.isShaderFilterSupported) {
      _loading ??= FragmentProgram.fromAsset(_shaderAsset)
          .then<FragmentProgram?>((program) => _program = program)
          .catchError((Object _) => null);
      _loading!.then((program) {
        if (!mounted || program == null) return;
        setState(() => _createShaders(program));
      });
    }
  }

  void _createShaders(FragmentProgram program) {
    _horizontal = program.fragmentShader();
    _vertical = program.fragmentShader();
  }

  @override
  void dispose() {
    _horizontal?.dispose();
    _vertical?.dispose();
    super.dispose();
  }

  /// Stops across the strip; enough for the eased ramp to read as a curve.
  static const int _stripStops = 16;

  /// A strip shorter than this has nothing to blur.
  static const double _minBlurStrip = 0.5;

  ImageFilter? _blurFilter(BuildContext context) {
    final horizontal = _horizontal;
    final vertical = _vertical;
    if (horizontal == null ||
        vertical == null ||
        widget.maxSigma <= 0 ||
        widget.stripExtent < _minBlurStrip) {
      return null;
    }
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final screenHeight = MediaQuery.sizeOf(context).height * ratio;
    final topDown = widget.edge == ConduitChromeFadeEdge.top;
    void configure(FragmentShader shader, {required bool vertical}) {
      // 0, 1: uSize, set by the engine.
      shader
        ..setFloat(2, vertical ? 1 : 0)
        ..setFloat(3, topDown ? 1 : 0)
        ..setFloat(4, widget.extent * ratio)
        ..setFloat(5, widget.settledExtent * ratio)
        ..setFloat(6, widget.maxSigma * ratio)
        ..setFloat(7, screenHeight);
    }

    configure(horizontal, vertical: false);
    configure(vertical, vertical: true);
    return ImageFilter.compose(
      outer: ImageFilter.shader(vertical),
      inner: ImageFilter.shader(horizontal),
    );
  }

  @override
  Widget build(BuildContext context) {
    final height = widget.extent;
    if (height <= 0) return const SizedBox.shrink();
    final baseColor =
        widget.backgroundColor ?? context.conduitTheme.surfaceBackground;
    final topDown = widget.edge == ConduitChromeFadeEdge.top;
    // Opaque across the cover and the strip's settled part; only the rest
    // eases out, and only it needs the blur.
    final settled = math.min(widget.settledExtent, height);
    final easing = height - settled;

    final colors = <Color>[baseColor, baseColor];
    final stops = <double>[0, settled / height];
    if (easing > 0) {
      for (var i = 1; i <= _stripStops; i++) {
        final distance = settled + easing * i / _stripStops;
        colors.add(
          baseColor.withValues(
            alpha: baseColor.a * widget.tintOpacityAt(distance),
          ),
        );
        stops.add(distance / height);
      }
    }
    final tint = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: topDown ? Alignment.topCenter : Alignment.bottomCenter,
          end: topDown ? Alignment.bottomCenter : Alignment.topCenter,
          colors: colors,
          stops: stops,
        ),
      ),
    );

    final blur = _blurFilter(context);
    return IgnorePointer(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (blur != null)
              Positioned(
                left: 0,
                right: 0,
                top: topDown ? settled : 0,
                bottom: topDown ? 0 : settled,
                child: ClipRect(
                  child: BackdropFilter(
                    filter: blur,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            tint,
          ],
        ),
      ),
    );
  }
}
