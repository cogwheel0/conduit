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

/// Where the scroll edge's fade is half way, measured past the far side of
/// the floating chrome (the bottom of the header's buttons, the top of the
/// composer): content there shows at half its ink. Far enough out that, by
/// the chrome's far side, what is left of a line is below what the eye
/// picks out (about 1.5 L* from the page, in light and dark alike), so no
/// text is ever legible beside or behind the glass.
const double kConduitScrollEdgeFadeMidpoint = 30.0;

/// The fade's scale: content loses the same share of its ink over every
/// stretch of this length, wherever it is in the fade (a logistic curve).
/// A 17 pt line's letters stand about 16 pt tall, so the upper half of a
/// line under the edge keeps about two fifths of the ink of its lower half,
/// wherever the line sits: it dissolves as a whole. When the top of a line
/// is too faint to see, its foot is too faint to read (about 6 L* from the
/// page), where an opaque cover with a 44 pt smoothstep below it left the
/// foot of a vanished line at 23 to 29 L*, plainly legible.
const double kConduitScrollEdgeFadeScale = 9.0;

/// How far before the chrome's far side the content is fully covered: the
/// status bar and the upper part of the header's buttons, or the lower part
/// of the composer. Between there and the chrome's far side the content is
/// at most a trace too faint to read (about 3% of its ink at the far side),
/// so a line passing under the chrome has no hard edge to be cut at.
const double kConduitScrollEdgeCoverInset = 32.0;

/// How far past the chrome's far side the fade reaches before the content
/// under it is clear: [kConduitScrollEdgeFadeMidpoint] plus five times
/// [kConduitScrollEdgeFadeScale], where less than 1% of the tint is left. A
/// just-sent message rests well below it (see the chat's pinned-turn peek),
/// crisp from its first line.
const double kConduitScrollEdgeSoftExtent =
    kConduitScrollEdgeFadeMidpoint + 5 * kConduitScrollEdgeFadeScale;

/// How far content has to scroll under the chrome before the scroll edge
/// reaches its full depth (engagement 1). Shorter than the fade itself, so
/// the edge settles into its full shape while the first lines are still
/// behind the chrome; the fade's clear end still runs ahead of the content
/// coming up to it, which meets it there, without a step.
const double kConduitScrollEdgeEngageDistance = 44.0;

/// iOS 26's scroll edge for custom chrome that floats over scrolling text:
/// the content dissolves into the page background as it passes under the
/// chrome, and is gone before the status bar.
///
/// Measured from the screen edge ([edge] says which), the effect is:
///
/// * fully covered in the page background out to [coverExtent] less
///   [kConduitScrollEdgeCoverInset]: the status bar and the upper part of the
///   header's buttons (or the lower part of the composer);
/// * from there to [kConduitScrollEdgeSoftExtent] past [coverExtent], a fade
///   along a logistic curve: half the content's ink
///   [kConduitScrollEdgeFadeMidpoint] past the chrome, too faint to read at
///   the chrome's far side and behind it, and clear at the end.
///
/// A logistic fade loses the same share of ink over every stretch of the same
/// length, so a line under the edge is never faint at its top and solid at
/// its foot: the whole line dims together, and the part under the chrome is
/// too faint to read. An opaque cover that stopped at the chrome's far side
/// cut a line there, leaving the foot of its letters showing below the
/// buttons.
///
/// The fade is an opacity ramp only, with no blur: a blur ramp changes
/// strength from the top of a line's letters to their foot, smearing
/// ascenders over sharp bodies. It costs no backdrop pass.
///
/// [engagement] says how much content lies under the edge, from 0 (none: the
/// list rests at that end) to 1. With none, the whole fade sits on the
/// chrome's side of [coverExtent], so content resting at the end of the list
/// is never washed out; as content scrolls under, the clear end moves out to
/// its full reach, so a scroll toward the edge meets the fade at its clear
/// end, without a step. The covered part never moves.
class ConduitScrollEdgeEffect extends StatelessWidget {
  const ConduitScrollEdgeEffect({
    super.key,
    required this.edge,
    required this.coverExtent,
    this.engagement = 1,
    this.backgroundColor,
  });

  const ConduitScrollEdgeEffect.top({
    super.key,
    required this.coverExtent,
    this.engagement = 1,
    this.backgroundColor,
  }) : edge = ConduitChromeFadeEdge.top;

  const ConduitScrollEdgeEffect.bottom({
    super.key,
    required this.coverExtent,
    this.engagement = 1,
    this.backgroundColor,
  }) : edge = ConduitChromeFadeEdge.bottom;

  final ConduitChromeFadeEdge edge;

  /// Distance from the screen edge to the far side of the chrome: the bottom
  /// of the header's buttons, the top of the composer.
  final double coverExtent;

  /// How much content lies under the edge, 0 to 1.
  final double engagement;

  final Color? backgroundColor;

  double get _chrome => math.max(0.0, coverExtent);

  double get _engagement => engagement.clamp(0.0, 1.0).toDouble();

  /// Distance from the screen edge that is always fully covered.
  double get solidExtent =>
      math.max(0.0, _chrome - kConduitScrollEdgeCoverInset);

  /// Total depth of the effect from the screen edge: where the content is
  /// clear.
  double get extent => _chrome + kConduitScrollEdgeSoftExtent * _engagement;

  /// The page background's opacity over the content at [distance] from the
  /// screen edge: 1 out to [solidExtent], then easing along the logistic
  /// curve to 0 at [extent].
  @visibleForTesting
  double tintOpacityAt(double distance) {
    final start = solidExtent;
    final end = extent;
    if (distance <= start) return 1;
    if (distance >= end) return 0;
    // Offsets past the chrome's far side: the fade's full shape runs from
    // the covered part ([from], at or before the chrome) to [to]; with less
    // content under the edge it is squeezed into what is left of it.
    final from = start - _chrome;
    const to = kConduitScrollEdgeSoftExtent;
    final offset = from + (distance - start) / (end - start) * (to - from);
    final ink = _normalizedInk(offset, from: from, to: to);
    return (1 - ink).clamp(0.0, 1.0).toDouble();
  }

  /// The logistic ink at [offset] past the chrome's far side, scaled so it
  /// is 0 at [from] and 1 at [to].
  static double _normalizedInk(
    double offset, {
    required double from,
    required double to,
  }) {
    double raw(double x) =>
        1 /
        (1 +
            math.exp(
              -(x - kConduitScrollEdgeFadeMidpoint) /
                  kConduitScrollEdgeFadeScale,
            ));
    final low = raw(from);
    final high = raw(to);
    return (raw(offset) - low) / (high - low);
  }

  /// Stops across the fade; enough that the curve reads as a curve.
  static const int _fadeStops = 28;

  @override
  Widget build(BuildContext context) {
    final height = extent;
    if (height <= 0) return const SizedBox.shrink();
    final baseColor = backgroundColor ?? context.conduitTheme.surfaceBackground;
    final topDown = edge == ConduitChromeFadeEdge.top;

    final start = solidExtent;
    final colors = <Color>[baseColor, baseColor];
    final stops = <double>[0, start / height];
    for (var i = 1; i <= _fadeStops; i++) {
      final distance = start + (height - start) * i / _fadeStops;
      colors.add(
        baseColor.withValues(alpha: baseColor.a * tintOpacityAt(distance)),
      );
      stops.add(distance / height);
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
