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
  });
  final VoidCallback? onPressed;
  final Widget child;
  final String semanticLabel;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final bool mini;

  @override
  Widget build(BuildContext context) => FloatingActionButton(
    onPressed: onPressed,
    tooltip: semanticLabel,
    mini: mini,
    backgroundColor: backgroundColor,
    foregroundColor: foregroundColor,
    child: child,
  );
}
