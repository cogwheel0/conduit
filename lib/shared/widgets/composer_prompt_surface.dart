import 'package:material_ui/material_ui.dart';

import '../theme/theme_extensions.dart';

class ComposerPromptSurface extends StatelessWidget {
  const ComposerPromptSurface({
    super.key,
    required this.semanticsLabel,
    required this.child,
    this.surfaceKey,
  });

  final String semanticsLabel;
  final Widget child;
  final Key? surfaceKey;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Semantics(
      container: true,
      liveRegion: true,
      label: semanticsLabel,
      child: Material(
        color: Colors.transparent,
        child: Container(
          key: surfaceKey,
          padding: const EdgeInsets.all(Spacing.md),
          decoration: BoxDecoration(
            color: theme.surfaceBackground,
            borderRadius: BorderRadius.circular(AppBorderRadius.card),
            border: Border.all(color: theme.cardBorder),
            boxShadow: ConduitShadows.card(context),
          ),
          child: child,
        ),
      ),
    );
  }
}
