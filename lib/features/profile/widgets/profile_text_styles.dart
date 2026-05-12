import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';

TextStyle? profileTitleTextStyle(BuildContext context, {bool large = false}) {
  final theme = context.conduitTheme;
  final baseStyle = large
      ? (Platform.isAndroid
            ? AppTypography.titleLargeStyle
            : theme.headingMedium)
      : (Platform.isAndroid
            ? AppTypography.titleMediumStyle
            : theme.bodyMedium);

  return baseStyle?.copyWith(
    color: theme.sidebarForeground,
    fontWeight: FontWeight.w600,
  );
}

TextStyle? profileSubtitleTextStyle(BuildContext context) {
  final theme = context.conduitTheme;
  final baseStyle = Platform.isAndroid
      ? AppTypography.bodyMediumStyle
      : theme.bodySmall;

  return baseStyle?.copyWith(
    color: theme.sidebarForeground.withValues(alpha: 0.75),
  );
}
