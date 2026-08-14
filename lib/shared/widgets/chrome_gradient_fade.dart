import 'dart:ui';

import 'package:flutter/widgets.dart';

import '../theme/theme_extensions.dart';

const double kConduitChromeFadeHeight = 42.0;
const double _kConduitChromeBlurSigma = 20.0;
const double _kConduitChromeLightTintOpacity = 0.78;
const double _kConduitChromeDarkTintOpacity = 0.72;

enum ConduitChromeFadeEdge { top, bottom }

/// Soft gradient blur used where scrolling content meets translucent chrome.
class ConduitChromeGradientFade extends StatelessWidget {
  const ConduitChromeGradientFade({
    super.key,
    required this.edge,
    required this.contentHeight,
    this.fadeHeight = kConduitChromeFadeHeight,
  });

  const ConduitChromeGradientFade.top({
    super.key,
    required this.contentHeight,
    this.fadeHeight = kConduitChromeFadeHeight,
  }) : edge = ConduitChromeFadeEdge.top;

  const ConduitChromeGradientFade.bottom({
    super.key,
    required this.contentHeight,
    this.fadeHeight = kConduitChromeFadeHeight,
  }) : edge = ConduitChromeFadeEdge.bottom;

  final ConduitChromeFadeEdge edge;
  final double contentHeight;
  final double fadeHeight;

  @override
  Widget build(BuildContext context) {
    final baseColor = context.conduitTheme.surfaceBackground;
    final height = contentHeight + fadeHeight;
    if (height <= 0) return const SizedBox.shrink();

    final brightness = MediaQuery.platformBrightnessOf(context);
    final tintOpacity = brightness == Brightness.dark
        ? _kConduitChromeDarkTintOpacity
        : _kConduitChromeLightTintOpacity;
    final tint = baseColor.withValues(alpha: tintOpacity);
    final clearTint = baseColor.withValues(alpha: 0);
    final contentFraction = (contentHeight / height).clamp(0.0, 1.0);
    final fadeFraction = (fadeHeight / height).clamp(0.0, 1.0);

    // Keep the material stable behind the actual chrome, then transition only
    // across fadeHeight. Stretching one gradient over both regions creates a
    // broad painted wash instead of the compact scroll-edge effect used by
    // native navigation and input chrome.
    final List<double> stops;
    final List<Color> tintColors;
    final List<Color> blurMaskColors;
    if (edge == ConduitChromeFadeEdge.top) {
      stops = [0, contentFraction, contentFraction + fadeFraction * 0.38, 1];
      tintColors = [
        tint,
        tint,
        tint.withValues(alpha: tintOpacity * 0.46),
        clearTint,
      ];
      blurMaskColors = const [
        Color(0xffffffff),
        Color(0xffffffff),
        Color(0x8cffffff),
        Color(0x00ffffff),
      ];
    } else {
      stops = [0, fadeFraction * 0.62, fadeFraction, 1];
      tintColors = [
        clearTint,
        tint.withValues(alpha: tintOpacity * 0.46),
        tint,
        tint,
      ];
      blurMaskColors = const [
        Color(0x00ffffff),
        Color(0x8cffffff),
        Color(0xffffffff),
        Color(0xffffffff),
      ];
    }

    return IgnorePointer(
      child: ClipRect(
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) => LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: blurMaskColors,
                  stops: stops,
                ).createShader(bounds),
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: _kConduitChromeBlurSigma,
                    sigmaY: _kConduitChromeBlurSigma,
                    tileMode: TileMode.mirror,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: tintColors,
                    stops: stops,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
