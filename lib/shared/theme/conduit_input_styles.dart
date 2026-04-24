import 'package:flutter/material.dart';

import 'theme_extensions.dart';

/// Provides named [InputDecoration] presets derived from
/// [ConduitThemeExtension] tokens.
///
/// Use via `context.conduitInputStyles` or construct directly
/// with a [ConduitThemeExtension].
class ConduitInputStyles {
  /// Creates input styles backed by the given theme tokens.
  const ConduitInputStyles(this.theme);

  /// The theme extension supplying color and spacing tokens.
  final ConduitThemeExtension theme;

  // -- shared helpers ------------------------------------------------

  OutlineInputBorder _outlineBorder({
    required Color color,
    required double width,
    required BorderRadius radius,
  }) => OutlineInputBorder(
    borderRadius: radius,
    borderSide: BorderSide(color: color, width: width),
  );

  BorderRadius get _standardRadius =>
      BorderRadius.circular(AppBorderRadius.input);

  TextStyle get _hintStyle =>
      AppTypography.bodyMediumStyle.copyWith(color: theme.inputPlaceholder);

  TextStyle get _errorStyle => AppTypography.small.copyWith(color: theme.error);

  // -- variants ------------------------------------------------------

  /// Filled input with outline border. Default for forms.
  InputDecoration standard({String? hint, String? error}) => InputDecoration(
    hintText: hint,
    hintStyle: _hintStyle,
    filled: true,
    fillColor: theme.inputBackground,
    border: _outlineBorder(
      color: theme.inputBorder,
      width: BorderWidth.standard,
      radius: _standardRadius,
    ),
    enabledBorder: _outlineBorder(
      color: theme.inputBorder,
      width: BorderWidth.standard,
      radius: _standardRadius,
    ),
    focusedBorder: _outlineBorder(
      color: theme.inputBorderFocused,
      width: BorderWidth.thick,
      radius: _standardRadius,
    ),
    errorBorder: _outlineBorder(
      color: theme.error,
      width: BorderWidth.standard,
      radius: _standardRadius,
    ),
    focusedErrorBorder: _outlineBorder(
      color: theme.error,
      width: BorderWidth.thick,
      radius: _standardRadius,
    ),
    errorText: error,
    errorStyle: _errorStyle,
    contentPadding: EdgeInsets.symmetric(
      horizontal: Spacing.inputPadding,
      vertical: AppTypography.inputVerticalPadding,
    ),
  );

  /// No borders or fill. For chat input, note editor, inline
  /// edit.
  InputDecoration borderless({String? hint}) => InputDecoration(
    hintText: hint,
    hintStyle: _hintStyle,
    filled: false,
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    errorBorder: InputBorder.none,
    focusedErrorBorder: InputBorder.none,
    contentPadding: EdgeInsets.symmetric(
      horizontal: Spacing.md,
      vertical: AppTypography.borderlessInputVerticalPadding,
    ),
  );

  /// Underline border, no fill. For dialog text inputs.
  InputDecoration underline({String? hint}) => InputDecoration(
    hintText: hint,
    hintStyle: _hintStyle.copyWith(
      color: theme.textSecondary.withValues(alpha: 0.6),
    ),
    filled: false,
    border: UnderlineInputBorder(
      borderSide: BorderSide(color: theme.cardBorder),
    ),
    enabledBorder: UnderlineInputBorder(
      borderSide: BorderSide(color: theme.cardBorder),
    ),
    focusedBorder: UnderlineInputBorder(
      borderSide: BorderSide(
        color: theme.buttonPrimary,
        width: BorderWidth.thick,
      ),
    ),
    contentPadding: EdgeInsets.symmetric(
      horizontal: Spacing.sm,
      vertical: AppTypography.compactInputVerticalPadding,
    ),
  );

  /// Same as [standard] but with tighter padding.
  ///
  /// Suited for search fields and compact forms.
  InputDecoration compact({String? hint, String? error}) =>
      standard(hint: hint, error: error).copyWith(
        contentPadding: EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: AppTypography.compactInputVerticalPadding,
        ),
      );
}

/// Convenient access to [ConduitInputStyles] from a
/// [BuildContext].
extension ConduitInputStylesContext on BuildContext {
  /// Returns [ConduitInputStyles] using the nearest
  /// [ConduitThemeExtension].
  ConduitInputStyles get conduitInputStyles => ConduitInputStyles(conduitTheme);
}
