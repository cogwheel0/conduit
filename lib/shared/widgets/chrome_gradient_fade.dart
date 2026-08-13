import 'dart:ui';

import 'package:flutter/widgets.dart';

import '../theme/theme_extensions.dart';

const double kConduitChromeFadeHeight = 42.0;

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
    final colors = edge == ConduitChromeFadeEdge.top
        ? [
            baseColor.withValues(alpha: 0.98),
            baseColor.withValues(alpha: 0.88),
            baseColor.withValues(alpha: 0.46),
            baseColor.withValues(alpha: 0.0),
          ]
        : [
            baseColor.withValues(alpha: 0.0),
            baseColor.withValues(alpha: 0.46),
            baseColor.withValues(alpha: 0.88),
            baseColor.withValues(alpha: 0.98),
          ];
    final blurMaskColors = edge == ConduitChromeFadeEdge.top
        ? const [Color(0xffffffff), Color(0x00ffffff)]
        : const [Color(0x00ffffff), Color(0xffffffff)];

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
                  stops: const [0.55, 1.0],
                ).createShader(bounds),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                  child: const SizedBox.expand(),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: colors,
                    stops: const [0.0, 0.3, 0.65, 1.0],
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
