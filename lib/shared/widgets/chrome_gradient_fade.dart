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
