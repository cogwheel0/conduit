import 'package:flutter/widgets.dart';

import '../theme/theme_extensions.dart';

/// A restrained trailing edge cue for horizontally scrollable utility rows.
class HorizontalOverflowFade extends StatelessWidget {
  const HorizontalOverflowFade({
    super.key,
    required this.child,
    this.width = 28,
    this.color,
  });

  final Widget child;
  final double width;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final background = color ?? context.conduitTheme.surfaceBackground;
    return Stack(
      children: [
        child,
        Positioned(
          top: 0,
          right: 0,
          bottom: 0,
          width: width,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    background.withValues(alpha: 0),
                    background.withValues(alpha: 0.9),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
