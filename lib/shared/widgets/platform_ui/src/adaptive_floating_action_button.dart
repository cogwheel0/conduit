import 'package:material_ui/material_ui.dart';

class AdaptiveFloatingActionButton extends StatelessWidget {
  const AdaptiveFloatingActionButton({
    super.key,
    required this.onPressed,
    required this.child,
    required this.semanticLabel,
    this.backgroundColor,
    this.foregroundColor,
    this.mini = false,
    this.heroTag,
    this.shape,
  });
  final VoidCallback? onPressed;
  final Widget child;
  final String semanticLabel;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final bool mini;

  /// Hero tag for route transitions. Null, the default, flies no hero, so
  /// several buttons can share a route.
  final Object? heroTag;

  /// Outline of the button; the theme's when null.
  final ShapeBorder? shape;

  @override
  Widget build(BuildContext context) => FloatingActionButton(
    onPressed: onPressed,
    tooltip: semanticLabel,
    mini: mini,
    heroTag: heroTag,
    shape: shape,
    backgroundColor: backgroundColor,
    foregroundColor: foregroundColor,
    child: child,
  );
}
