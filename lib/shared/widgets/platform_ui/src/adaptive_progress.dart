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
       minHeight = null;
  const AdaptiveProgressIndicator.linear({
    super.key,
    this.value,
    this.color,
    this.backgroundColor,
    this.minHeight,
    this.semanticLabel,
    this.semanticValue,
  }) : linear = true,
       strokeWidth = 4;

  final bool linear;
  final double? value;
  final Color? color;
  final Color? backgroundColor;
  final double strokeWidth;
  final double? minHeight;
  final String? semanticLabel;
  final String? semanticValue;

  @override
  Widget build(BuildContext context) {
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
