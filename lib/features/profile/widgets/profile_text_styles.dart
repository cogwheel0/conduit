import 'package:material_ui/material_ui.dart';

import '../../../shared/theme/theme_extensions.dart';

TextStyle? profileTitleTextStyle(BuildContext context, {bool large = false}) {
  final theme = context.conduitTheme;
  final baseStyle = large ? theme.headingMedium : theme.bodyMedium;

  return baseStyle?.copyWith(
    // Page text, not the sidebar's: these tiles sit on settings surfaces, and
    // some palettes tint the sidebar foreground (T3 Chat uses pink).
    color: theme.textPrimary,
    fontWeight: FontWeight.w600,
  );
}

TextStyle? profileSubtitleTextStyle(BuildContext context) {
  final theme = context.conduitTheme;
  final baseStyle = theme.bodySmall;

  return baseStyle?.copyWith(
    color: theme.textSecondary,
  );
}
