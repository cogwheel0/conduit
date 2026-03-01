import 'package:flutter/material.dart';

import '../../../theme/theme_extensions.dart';

/// Centralized per-element style configuration for the
/// custom markdown renderer.
///
/// All colors, text styles, spacing values, and border radii
/// needed to render markdown elements are derived from the
/// app's [ConduitThemeExtension] so that the renderer
/// automatically adapts to light/dark mode and the active
/// theme palette.
///
/// Create an instance via [ConduitMarkdownStyle.fromTheme]:
///
/// ```dart
/// final style = ConduitMarkdownStyle.fromTheme(context);
/// ```
@immutable
class ConduitMarkdownStyle {
  /// Constructs a [ConduitMarkdownStyle] with all required
  /// properties. Prefer using [fromTheme] instead.
  const ConduitMarkdownStyle({
    required this.isDark,
    // Text styles
    required this.body,
    required this.h1,
    required this.h2,
    required this.h3,
    required this.h4,
    required this.h5,
    required this.h6,
    required this.codeSpan,
    required this.codeBlock,
    required this.blockquoteText,
    required this.tableHeader,
    required this.tableCell,
    // Spacing
    required this.paragraphSpacing,
    required this.headingTopSpacing,
    required this.headingBottomSpacing,
    required this.listItemSpacing,
    required this.codeBlockSpacing,
    required this.blockquoteSpacing,
    required this.tableSpacing,
    // Colors
    required this.codeSpanTextColor,
    required this.codeSpanBackgroundColor,
    required this.codeBlockBackground,
    required this.codeBlockBorder,
    required this.blockquoteBorderColor,
    required this.tableBorderColor,
    required this.tableHeaderBackground,
    required this.linkColor,
    required this.dividerColor,
    required this.textPrimary,
    required this.textSecondary,
    // Shapes
    required this.codeBlockRadius,
    required this.codeSpanRadius,
    required this.tableRadius,
  });

  /// Builds a [ConduitMarkdownStyle] from the current
  /// [ConduitThemeExtension] and [Theme] accessible via
  /// [context].
  ///
  /// This is the recommended way to create an instance.
  factory ConduitMarkdownStyle.fromTheme(
    BuildContext context,
  ) {
    final theme = context.conduitTheme;
    final typo = theme.typography;
    final tokens = theme.tokens;
    final dark = theme.isDark;

    // Base body style used as the foundation for all
    // text styles.
    final bodyStyle = TextStyle(
      fontSize: AppTypography.bodyMedium,
      fontWeight: FontWeight.w400,
      color: theme.textPrimary,
      height: 1.5,
    );

    // Monospace base for code elements.
    final monoBase = TextStyle(
      fontFamily: typo.monospaceFont,
      fontFamilyFallback: typo.monospaceFallback,
      fontSize: AppTypography.bodySmall,
      fontWeight: FontWeight.w400,
      height: 1.5,
    );

    // Inline code highlight color that matches common
    // chat-UI conventions (#eb5757 light / #E06C75 dark).
    final codeSpanText = dark
        ? const Color(0xFFE06C75)
        : const Color(0xFFEB5757);

    return ConduitMarkdownStyle(
      isDark: dark,

      // -- Text styles --
      body: bodyStyle,
      h1: TextStyle(
        fontSize: AppTypography.headlineLarge,
        fontWeight: FontWeight.w700,
        color: theme.textPrimary,
        height: 1.3,
        letterSpacing: -0.4,
      ),
      h2: TextStyle(
        fontSize: AppTypography.headlineMedium,
        fontWeight: FontWeight.w600,
        color: theme.textPrimary,
        height: 1.3,
        letterSpacing: -0.2,
      ),
      h3: TextStyle(
        fontSize: AppTypography.headlineSmall,
        fontWeight: FontWeight.w600,
        color: theme.textPrimary,
        height: 1.4,
      ),
      h4: TextStyle(
        fontSize: AppTypography.bodyLarge,
        fontWeight: FontWeight.w600,
        color: theme.textPrimary,
        height: 1.4,
      ),
      h5: TextStyle(
        fontSize: AppTypography.bodyMedium,
        fontWeight: FontWeight.w600,
        color: theme.textPrimary,
        height: 1.5,
      ),
      h6: TextStyle(
        fontSize: AppTypography.bodySmall,
        fontWeight: FontWeight.w600,
        color: theme.textSecondary,
        height: 1.5,
      ),
      codeSpan: monoBase.copyWith(
        color: codeSpanText,
      ),
      codeBlock: monoBase.copyWith(
        color: theme.codeText,
      ),
      blockquoteText: bodyStyle.copyWith(
        color: theme.textSecondary,
        fontStyle: FontStyle.italic,
      ),
      tableHeader: TextStyle(
        fontSize: AppTypography.bodySmall,
        fontWeight: FontWeight.w600,
        color: theme.textPrimary,
        height: 1.4,
      ),
      tableCell: TextStyle(
        fontSize: AppTypography.bodySmall,
        fontWeight: FontWeight.w400,
        color: theme.textPrimary,
        height: 1.4,
      ),

      // -- Spacing (chat-optimized, tight) --
      paragraphSpacing: Spacing.xs,
      headingTopSpacing: Spacing.sm,
      headingBottomSpacing: Spacing.xs,
      listItemSpacing: Spacing.xxs,
      codeBlockSpacing: Spacing.xs,
      blockquoteSpacing: Spacing.xs,
      tableSpacing: Spacing.xs,

      // -- Colors --
      codeSpanTextColor: codeSpanText,
      codeSpanBackgroundColor: dark
          ? tokens.codeBackground
          : tokens.codeBackground,
      codeBlockBackground: theme.codeBackground,
      codeBlockBorder: theme.codeBorder,
      blockquoteBorderColor: theme.dividerColor,
      tableBorderColor: theme.dividerColor,
      tableHeaderBackground: dark
          ? tokens.codeBackground
          : tokens.codeBackground,
      linkColor: theme.variant.primary,
      dividerColor: theme.dividerColor,
      textPrimary: theme.textPrimary,
      textSecondary: theme.textSecondary,

      // -- Shapes --
      codeBlockRadius: AppBorderRadius.lg,
      codeSpanRadius: AppBorderRadius.xs,
      tableRadius: AppBorderRadius.sm,
    );
  }

  // ----- Properties -----

  /// Whether the current theme is dark.
  final bool isDark;

  // -- Text styles --

  /// Default body text style.
  final TextStyle body;

  /// Heading level 1 style.
  final TextStyle h1;

  /// Heading level 2 style.
  final TextStyle h2;

  /// Heading level 3 style.
  final TextStyle h3;

  /// Heading level 4 style.
  final TextStyle h4;

  /// Heading level 5 style.
  final TextStyle h5;

  /// Heading level 6 style.
  final TextStyle h6;

  /// Inline code span style.
  final TextStyle codeSpan;

  /// Code block text style.
  final TextStyle codeBlock;

  /// Text style inside blockquotes.
  final TextStyle blockquoteText;

  /// Table header cell text style.
  final TextStyle tableHeader;

  /// Table body cell text style.
  final TextStyle tableCell;

  // -- Spacing --

  /// Vertical space between consecutive paragraphs.
  final double paragraphSpacing;

  /// Space above a heading element.
  final double headingTopSpacing;

  /// Space below a heading element.
  final double headingBottomSpacing;

  /// Space between list items.
  final double listItemSpacing;

  /// Space around a code block.
  final double codeBlockSpacing;

  /// Space around a blockquote.
  final double blockquoteSpacing;

  /// Space around a table.
  final double tableSpacing;

  // -- Colors --

  /// Text color for inline code spans.
  final Color codeSpanTextColor;

  /// Background color for inline code spans.
  final Color codeSpanBackgroundColor;

  /// Background color for fenced code blocks.
  final Color codeBlockBackground;

  /// Border color for fenced code blocks.
  final Color codeBlockBorder;

  /// Left-border color for blockquotes.
  final Color blockquoteBorderColor;

  /// Border color for table outlines and dividers.
  final Color tableBorderColor;

  /// Background color for the table header row.
  final Color tableHeaderBackground;

  /// Color used for hyperlinks.
  final Color linkColor;

  /// Color used for horizontal rules / dividers.
  final Color dividerColor;

  /// Primary text color from the theme.
  final Color textPrimary;

  /// Secondary (muted) text color from the theme.
  final Color textSecondary;

  // -- Shapes --

  /// Corner radius for fenced code blocks (16 px).
  final double codeBlockRadius;

  /// Corner radius for inline code spans (4 px).
  final double codeSpanRadius;

  /// Corner radius for tables (8 px).
  final double tableRadius;

  // ----- Helpers -----

  /// Returns the heading [TextStyle] for the given
  /// [level] (1-6).
  ///
  /// Values outside 1-6 fall back to the body style.
  TextStyle headingStyle(int level) {
    return switch (level) {
      1 => h1,
      2 => h2,
      3 => h3,
      4 => h4,
      5 => h5,
      6 => h6,
      _ => body,
    };
  }
}
