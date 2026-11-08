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
/// content under it is clear and sharp.
const double kConduitScrollEdgeSoftExtent = 16.0;

/// The heaviest blur of the soft scroll edge, in logical pixels, reached
/// from the middle of the chrome outward.
const double kConduitScrollEdgeMaxSigma = 9.0;

/// Exponent of the blur's ease in from its clear end.
const double _kScrollEdgeSigmaEase = 1.6;

/// iOS 26's "soft" scroll edge for custom chrome that floats over scrolling
/// text: the content blurs progressively and dissolves into the page
/// background toward the screen edge, instead of being cut by a line.
///
/// Measured from the screen edge ([edge] says which), the effect is:
///
/// * fully covered across [solidExtent] (the status bar, the home
///   indicator), so the clock never sits over text;
/// * heavily blurred and mostly washed out behind the chrome, from
///   [chromeExtent] - [chromeThickness] to [chromeExtent], so Liquid Glass
///   there refracts a soft haze, never crisp text;
/// * easing to clear and sharp over [softExtent] beyond the chrome, so a
///   line of text passing under it dissolves rather than being cut in half.
///
/// The blur is one backdrop filter: a Gaussian whose strength follows the
/// distance from the edge (shaders/scroll_edge_blur.frag, run horizontally
/// then vertically), so it has no bands or seams. A tint of the page
/// background, eased with a monotone curve, lies over it. Where shader
/// filters are unavailable (no Impeller) only the tint is drawn.
class ConduitScrollEdgeEffect extends StatefulWidget {
  const ConduitScrollEdgeEffect({
    super.key,
    required this.edge,
    required this.chromeExtent,
    required this.chromeThickness,
    required this.solidExtent,
    this.softExtent = kConduitScrollEdgeSoftExtent,
    this.chromeEdgeOpacity = 0.7,
    this.chromeMiddleOpacity = 0.85,
    this.maxSigma = kConduitScrollEdgeMaxSigma,
    this.backgroundColor,
  });

  const ConduitScrollEdgeEffect.top({
    super.key,
    required this.chromeExtent,
    required this.chromeThickness,
    required this.solidExtent,
    this.softExtent = kConduitScrollEdgeSoftExtent,
    this.chromeEdgeOpacity = 0.7,
    this.chromeMiddleOpacity = 0.85,
    this.maxSigma = kConduitScrollEdgeMaxSigma,
    this.backgroundColor,
  }) : edge = ConduitChromeFadeEdge.top;

  const ConduitScrollEdgeEffect.bottom({
    super.key,
    required this.chromeExtent,
    required this.chromeThickness,
    required this.solidExtent,
    this.softExtent = kConduitScrollEdgeSoftExtent,
    this.chromeEdgeOpacity = 0.7,
    this.chromeMiddleOpacity = 0.85,
    this.maxSigma = kConduitScrollEdgeMaxSigma,
    this.backgroundColor,
  }) : edge = ConduitChromeFadeEdge.bottom;

  final ConduitChromeFadeEdge edge;

  /// Distance from the screen edge to the chrome's inner edge (the bottom of
  /// the header's buttons, the top of the composer).
  final double chromeExtent;

  /// How thick the chrome is, measured inward from [chromeExtent].
  final double chromeThickness;

  /// Distance from the screen edge that stays fully covered.
  final double solidExtent;

  /// How far beyond [chromeExtent] the effect reaches.
  final double softExtent;

  /// Tint at the chrome's inner edge.
  final double chromeEdgeOpacity;

  /// Tint at the chrome's middle.
  final double chromeMiddleOpacity;

  /// Blur from the chrome's middle outward.
  final double maxSigma;
  final Color? backgroundColor;

  /// Total depth of the effect from the screen edge.
  double get extent => math.max(0, chromeExtent + softExtent);

  /// Distance from the screen edge where the blur is at full strength.
  double get fullBlurExtent => math.max(0, chromeExtent - chromeThickness / 2);

  /// The tint's opacity at [distance] from the screen edge: 1 across the
  /// solid run, then a monotone ease through the chrome to 0 at [extent].
  @visibleForTesting
  double tintOpacityAt(double distance) =>
      _monotoneCubic(_tintPoints(), distance).clamp(0.0, 1.0);

  /// The blur at [distance] from the screen edge: [maxSigma] out to the
  /// chrome's middle, then easing to none at [extent]. Mirrors the shader.
  ///
  /// It eases in from the clear end: just past the chrome text mostly
  /// fades, and only blurs hard where the tint already hides most of it, so
  /// it dissolves instead of smearing into a dark smudge.
  @visibleForTesting
  double sigmaAt(double distance) {
    final end = extent;
    final full = fullBlurExtent;
    if (distance >= end) return 0;
    if (distance <= full || end <= full) return maxSigma;
    final u = (end - distance) / (end - full);
    return maxSigma * math.pow(u, _kScrollEdgeSigmaEase).toDouble();
  }

  List<Offset> _tintPoints() {
    final end = extent;
    final chromeInner = chromeExtent;
    final chromeMiddle = chromeExtent - chromeThickness / 2;
    final solid = math.min(solidExtent, chromeMiddle - 1);
    final points = <Offset>[
      const Offset(0, 1),
      if (solid > 0) Offset(solid, 1),
      if (chromeMiddle > solid) Offset(chromeMiddle, chromeMiddleOpacity),
      if (chromeInner > chromeMiddle) Offset(chromeInner, chromeEdgeOpacity),
      Offset(end, 0),
    ];
    final cleaned = <Offset>[];
    for (final point in points) {
      if (cleaned.isEmpty || point.dx > cleaned.last.dx + 0.001) {
        cleaned.add(point);
      }
    }
    return cleaned;
  }

  /// Fritsch–Carlson monotone cubic through [points], flat at both ends, so
  /// the tint never overshoots and meets the solid run and the clear end
  /// without a crease.
  static double _monotoneCubic(List<Offset> points, double x) {
    if (points.isEmpty) return 0;
    if (x <= points.first.dx) return points.first.dy;
    if (x >= points.last.dx) return points.last.dy;
    final n = points.length;
    final slopes = <double>[
      for (var i = 0; i < n - 1; i++)
        (points[i + 1].dy - points[i].dy) / (points[i + 1].dx - points[i].dx),
    ];
    final tangents = List<double>.filled(n, 0);
    for (var i = 1; i < n - 1; i++) {
      final a = slopes[i - 1];
      final b = slopes[i];
      tangents[i] = a * b <= 0 ? 0 : 2 / (1 / a + 1 / b);
    }
    var i = 0;
    while (x > points[i + 1].dx) {
      i++;
    }
    final h = points[i + 1].dx - points[i].dx;
    final t = (x - points[i].dx) / h;
    final t2 = t * t;
    final t3 = t2 * t;
    return (2 * t3 - 3 * t2 + 1) * points[i].dy +
        (t3 - 2 * t2 + t) * h * tangents[i] +
        (-2 * t3 + 3 * t2) * points[i + 1].dy +
        (t3 - t2) * h * tangents[i + 1];
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

  static const int _tintStops = 28;

  ImageFilter? _blurFilter(BuildContext context) {
    final horizontal = _horizontal;
    final vertical = _vertical;
    if (horizontal == null || vertical == null || widget.maxSigma <= 0) {
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
        ..setFloat(5, widget.fullBlurExtent * ratio)
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

    final colors = <Color>[];
    final stops = <double>[];
    for (var i = 0; i <= _tintStops; i++) {
      final t = i / _tintStops;
      colors.add(
        baseColor.withValues(
          alpha: baseColor.a * widget.tintOpacityAt(t * height),
        ),
      );
      stops.add(t);
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

    // Across the solid run the tint hides everything; blur only past it.
    final solid = math.max(
      0.0,
      math.min(widget.solidExtent, widget.fullBlurExtent),
    );
    final blur = _blurFilter(context);
    return IgnorePointer(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (blur != null && height > solid)
              Positioned(
                left: 0,
                right: 0,
                top: topDown ? solid : 0,
                bottom: topDown ? 0 : solid,
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
