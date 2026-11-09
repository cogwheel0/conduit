import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'platform_ui_capabilities.dart';

/// Progress remains a value in [0, 1]; null means work with no known total.
class AdaptiveProgressIndicator extends StatelessWidget {
  const AdaptiveProgressIndicator({
    super.key,
    this.value,
    this.color,
    this.backgroundColor,
    this.strokeWidth = 4,
    this.semanticLabel,
    this.semanticValue,
  }) : linear = false,
       minHeight = null,
       radius = null;

  /// A horizontal bar. On iOS 26 and later a bar with a known [value] is the
  /// native `UIProgressView`, which has its own height and track colour, so
  /// [minHeight] applies to the Flutter bar only; a [backgroundColor] or a
  /// [semanticValue] keeps the Flutter bar.
  const AdaptiveProgressIndicator.linear({
    super.key,
    this.value,
    this.color,
    this.backgroundColor,
    this.minHeight,
    this.semanticLabel,
    this.semanticValue,
  }) : linear = true,
       strokeWidth = 4,
       radius = null;

  /// The iOS activity spinner on every platform, [radius] points in radius.
  const AdaptiveProgressIndicator.activity({
    super.key,
    double this.radius = 10,
    this.color,
  }) : linear = false,
       value = null,
       backgroundColor = null,
       strokeWidth = 4,
       minHeight = null,
       semanticLabel = null,
       semanticValue = null;

  final bool linear;
  final double? value;
  final Color? color;
  final Color? backgroundColor;
  final double strokeWidth;
  final double? minHeight;
  final double? radius;
  final String? semanticLabel;
  final String? semanticValue;

  @override
  Widget build(BuildContext context) {
    if (radius case final radius?) {
      return CupertinoActivityIndicator(radius: radius, color: color);
    }
    if (linear) {
      if (value case final progress?
          when backgroundColor == null &&
              semanticValue == null &&
              PlatformUiCapabilities.usesNativeIOS26) {
        return Semantics(
          label: semanticLabel,
          value: '${(progress.clamp(0, 1) * 100).round()}%',
          child: ExcludeSemantics(
            child: CNProgressIndicator(value: progress, tint: color),
          ),
        );
      }
      return LinearProgressIndicator(
        value: value,
        color: color,
        backgroundColor: backgroundColor,
        minHeight: minHeight,
        semanticsLabel: semanticLabel,
        semanticsValue: semanticValue,
      );
    }
    if (PlatformUiCapabilities.isIOS) {
      return Semantics(
        label: semanticLabel,
        value:
            semanticValue ??
            (value == null ? null : '${(value! * 100).round()}%'),
        child: FittedBox(
          child: value == null
              ? CupertinoActivityIndicator(radius: 18, color: color)
              : CupertinoActivityIndicator.partiallyRevealed(
                  radius: 18,
                  color: color,
                  progress: value!.clamp(0, 1),
                ),
        ),
      );
    }
    return CircularProgressIndicator(
      value: value,
      color: color,
      backgroundColor: backgroundColor,
      strokeWidth: strokeWidth,
      semanticsLabel: semanticLabel,
      semanticsValue: semanticValue,
    );
  }
}
