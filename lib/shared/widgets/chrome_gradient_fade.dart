import 'dart:math' as math;

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

/// How far past floating chrome the scroll edge reaches before the content
/// under it is clear. A just-sent message pinned under the chat header rests
/// about 22 pt below its buttons, where the fade has all but ended (about a
/// tenth of the way to the background, at the very top of its bubble).
const double kConduitScrollEdgeSoftExtent = 28.0;

/// iOS 26's scroll edge for custom chrome that floats over scrolling text:
/// the content reaches the page background before it reaches the glass.
///
/// Measured from the screen edge ([edge] says which), the effect is:
///
/// * fully covered in the page background across [coverExtent]: the status
///   bar and the chrome's full height (the header's buttons, the composer),
///   so Liquid Glass never sits over text, legible or blurred;
/// * a strip of [softExtent] beyond it where the content fades into the
///   background along a smoothstep, flat where it meets the cover and flat
///   where it clears, so a line passing under the chrome dissolves rather
///   than being cut by it.
///
/// The fade is an opacity ramp only, with no blur. The strip is shorter than
/// a line of text, so a blur ramp across it would change strength from the
/// top of a line's letters to their foot: smeared ascenders over sharp
/// bodies, read as a line slicing the text. A smooth fade has no such step,
/// and costs no backdrop pass.
///
/// [engagement] says how much content lies under the edge, from 0 (none: the
/// list rests at that end) to 1. The strip grows with it, so content resting
/// at the end of the list is never washed out, and a scroll toward the edge
/// meets the strip at its clear end, without a step.
class ConduitScrollEdgeEffect extends StatelessWidget {
  const ConduitScrollEdgeEffect({
    super.key,
    required this.edge,
    required this.coverExtent,
    this.softExtent = kConduitScrollEdgeSoftExtent,
    this.engagement = 1,
    this.backgroundColor,
  });

  const ConduitScrollEdgeEffect.top({
    super.key,
    required this.coverExtent,
    this.softExtent = kConduitScrollEdgeSoftExtent,
    this.engagement = 1,
    this.backgroundColor,
  }) : edge = ConduitChromeFadeEdge.top;

  const ConduitScrollEdgeEffect.bottom({
    super.key,
    required this.coverExtent,
    this.softExtent = kConduitScrollEdgeSoftExtent,
    this.engagement = 1,
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

  final Color? backgroundColor;

  double get _cover => math.max(0.0, coverExtent);

  /// The strip's length now.
  double get stripExtent =>
      math.max(0.0, softExtent) * engagement.clamp(0.0, 1.0).toDouble();

  /// Total depth of the effect from the screen edge.
  double get extent => _cover + stripExtent;

  /// The page background's opacity over the content at [distance] from the
  /// screen edge: 1 across the cover, then easing (smoothstep, flat at both
  /// ends) to 0 at [extent].
  @visibleForTesting
  double tintOpacityAt(double distance) {
    if (distance <= _cover) return 1;
    final strip = stripExtent;
    if (strip <= 0 || distance >= extent) return 0;
    final u = (extent - distance) / strip;
    return u * u * (3 - 2 * u);
  }

  /// Stops across the strip; enough that the eased ramp reads as a curve.
  static const int _stripStops = 16;

  @override
  Widget build(BuildContext context) {
    final height = extent;
    if (height <= 0) return const SizedBox.shrink();
    final baseColor =
        backgroundColor ?? context.conduitTheme.surfaceBackground;
    final topDown = edge == ConduitChromeFadeEdge.top;

    final colors = <Color>[baseColor, baseColor];
    final stops = <double>[0, _cover / height];
    final strip = stripExtent;
    if (strip > 0) {
      for (var i = 1; i <= _stripStops; i++) {
        final distance = _cover + strip * i / _stripStops;
        colors.add(
          baseColor.withValues(alpha: baseColor.a * tintOpacityAt(distance)),
        );
        stops.add(distance / height);
      }
    }
    return IgnorePointer(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: topDown ? Alignment.topCenter : Alignment.bottomCenter,
              end: topDown ? Alignment.bottomCenter : Alignment.topCenter,
              colors: colors,
              stops: stops,
            ),
          ),
        ),
      ),
    );
  }
}
