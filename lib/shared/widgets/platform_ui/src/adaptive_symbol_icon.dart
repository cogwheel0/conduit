import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:flutter/widgets.dart';

import '../../../theme/theme_extensions.dart' show ConduitMotionContext;
import 'platform_ui_capabilities.dart';

/// A symbol animation that [AdaptiveSymbolIcon] runs for as long as it is
/// set.
enum AdaptiveSymbolEffect {
  /// Lights the symbol's variable layers in turn and back, such as the waves
  /// of `speaker.wave.3.fill` while audio plays. Symbols without variable
  /// layers stay still.
  variableColor,
}

/// How [AdaptiveSymbolIcon] animates a change of [AdaptiveSymbolIcon.symbol].
enum AdaptiveSymbolTransition {
  /// The old symbol scales out while the new one scales in.
  replace,

  /// Shared parts stay in place and only the difference animates, such as
  /// the slash of `mic.fill` → `mic.slash.fill`. Symbols without shared
  /// parts use [replace].
  magic,
}

/// An icon drawn as a native SF Symbol on iOS 26 and later, where it can
/// animate with Apple's symbol effects, and as [fallbackIcon] elsewhere.
///
/// Reduce Motion turns the [effect] and [transition] off; the symbol then
/// changes without animation.
///
/// The native symbol is a platform view: keep this widget at a stable place
/// in the tree, so that a new [symbol] updates the view instead of replacing
/// it, and use it only where the animation is worth a view.
class AdaptiveSymbolIcon extends StatelessWidget {
  const AdaptiveSymbolIcon({
    super.key,
    required this.symbol,
    required this.fallbackIcon,
    this.size,
    this.color,
    this.semanticLabel,
    this.effect,
    this.transition,
  });

  /// The SF Symbol name, such as `mic.fill`.
  final String symbol;

  /// The icon drawn where native symbols are unavailable.
  final IconData fallbackIcon;

  final double? size;
  final Color? color;

  /// Read by assistive technologies, as [Icon.semanticLabel] is.
  final String? semanticLabel;

  /// The animation that runs while it is set; null for none.
  final AdaptiveSymbolEffect? effect;

  /// How a change of [symbol] animates; null swaps it at once.
  final AdaptiveSymbolTransition? transition;

  @override
  Widget build(BuildContext context) {
    if (!PlatformUiCapabilities.usesNativeIOS26) {
      return Icon(
        fallbackIcon,
        size: size,
        color: color,
        semanticLabel: semanticLabel,
      );
    }
    final iconTheme = IconTheme.of(context);
    final iconSize = size ?? iconTheme.size ?? 24;
    final animate = !context.reduceMotion;
    return Semantics(
      label: semanticLabel,
      child: ExcludeSemantics(
        child: CNIcon(
          symbol: CNSymbol(symbol, size: iconSize),
          size: iconSize,
          color: color ?? iconTheme.color,
          effect: animate ? effect?._native : null,
          replaceTransition: animate ? transition?._native : null,
        ),
      ),
    );
  }
}

extension on AdaptiveSymbolEffect {
  CNSymbolEffect get _native => switch (this) {
    AdaptiveSymbolEffect.variableColor => const CNSymbolEffect.variableColor(
      reversing: true,
    ),
  };
}

extension on AdaptiveSymbolTransition {
  CNSymbolReplaceTransition get _native => switch (this) {
    AdaptiveSymbolTransition.replace => CNSymbolReplaceTransition.replace,
    AdaptiveSymbolTransition.magic => CNSymbolReplaceTransition.magic,
  };
}
