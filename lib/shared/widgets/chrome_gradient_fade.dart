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
  }) : edge = ConduitChromeFadeEdge.bottom,
       solidBehindChrome = false;

  final ConduitChromeFadeEdge edge;
  final double contentHeight;
  final double fadeHeight;
  final Color? backgroundColor;

  /// Keeps the fade near-opaque across [contentHeight] and only softens it
  /// in the [fadeHeight] strip beyond, like iOS's "hard" scroll-edge style.
  /// For bars with a title over scrolling rows, where the default ramp lets
  /// text read through behind the title.
  final bool solidBehindChrome;

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

    return IgnorePointer(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: solidBehindChrome
                  ? [
                      baseColor.withValues(alpha: 0.96),
                      baseColor.withValues(alpha: 0.96),
                      baseColor.withValues(alpha: 0.0),
                    ]
                  : colors,
              stops: solidBehindChrome
                  ? [0.0, solidStop, 1.0]
                  : const [0.0, 0.3, 0.65, 1.0],
            ),
          ),
        ),
      ),
    );
  }
}
