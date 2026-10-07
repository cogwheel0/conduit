import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

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
      return LinearProgressIndicator(
        value: value,
        color: color,
        backgroundColor: backgroundColor,
        minHeight: minHeight,
        semanticsLabel: semanticLabel,
        semanticsValue: semanticValue,
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
