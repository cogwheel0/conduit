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
  factory ConduitMarkdownStyle.fromTheme(BuildContext context) {
    final theme = context.conduitTheme;
    final textTheme = Theme.of(context).textTheme;
    final textScaler = MediaQuery.textScalerOf(context);
    final tokens = theme.tokens;
    final dark = theme.isDark;
    TextStyle resolveHeadingStyle(
      TextStyle? themedStyle,
      TextStyle fallback, {
      required Color color,
    }) {
      return themedStyle?.copyWith(color: color, fontWeight: FontWeight.w600) ??
          fallback.copyWith(color: color);
    }

    // Base body style used as the foundation for all
    // text styles.
    final bodyStyle =
        textTheme.bodyLarge?.copyWith(color: theme.textPrimary) ??
        AppTypography.chatMessageStyle.copyWith(color: theme.textPrimary);
    final bodyLineHeight =
        textScaler.scale(bodyStyle.fontSize ?? AppTypography.bodyLarge) *
        (bodyStyle.height ?? 1.0);
    final paragraphSpacing = AppTypography.usesAppleRamp
        ? Spacing.md
        : (bodyLineHeight * 0.5)
              .clamp(Spacing.sm + Spacing.xs, Spacing.md)
              .toDouble();

    // Monospace base for code elements.
    final monoBase =
        theme.code?.copyWith(color: theme.codeText) ??
        AppTypography.codeStyle.copyWith(color: theme.codeText);

    // Inline code highlight color that matches common
    // chat-UI conventions (#eb5757 light / #E06C75 dark).
    final codeSpanText = dark
        ? const Color(0xFFE06C75)
        : const Color(0xFFEB5757);

    return ConduitMarkdownStyle(
      isDark: dark,

      // -- Text styles --
      body: bodyStyle,
      h1: resolveHeadingStyle(
        textTheme.displaySmall,
        AppTypography.displaySmallStyle,
        color: theme.textPrimary,
      ),
      h2: resolveHeadingStyle(
        textTheme.headlineLarge,
        AppTypography.headlineLargeStyle,
        color: theme.textPrimary,
      ),
      h3: resolveHeadingStyle(
        textTheme.headlineMedium,
        AppTypography.headlineMediumStyle,
        color: theme.textPrimary,
      ),
      h4: resolveHeadingStyle(
        textTheme.headlineSmall,
        AppTypography.headlineSmallStyle,
        color: theme.textPrimary,
      ),
      h5: resolveHeadingStyle(
        textTheme.titleLarge,
        AppTypography.titleLargeStyle,
        color: theme.textPrimary,
      ),
      h6: resolveHeadingStyle(
        textTheme.titleMedium,
        AppTypography.titleMediumStyle,
        color: theme.textSecondary,
      ),
      codeSpan: monoBase.copyWith(color: codeSpanText),
      codeBlock: monoBase.copyWith(color: theme.codeText),
      blockquoteText: bodyStyle.copyWith(color: theme.textSecondary),
      tableHeader: bodyStyle.copyWith(
        color: theme.textPrimary,
        fontWeight: FontWeight.w600,
      ),
      tableCell: bodyStyle.copyWith(color: theme.textPrimary),

      // Paragraph rhythm follows the active platform ramp.
      paragraphSpacing: paragraphSpacing,
      headingTopSpacing: Spacing.md,
      headingBottomSpacing: Spacing.sm,
      listItemSpacing: Spacing.sm,
      codeBlockSpacing: Spacing.md,
      blockquoteSpacing: Spacing.md,
      tableSpacing: Spacing.md,

      // -- Colors --
      codeSpanTextColor: codeSpanText,
      codeSpanBackgroundColor: tokens.codeBackground,
      codeBlockBackground: theme.codeBackground,
      codeBlockBorder: theme.codeBorder,
      blockquoteBorderColor: theme.dividerColor,
      tableBorderColor: theme.dividerColor,
      tableHeaderBackground: tokens.codeBackground,
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

  /// Title style used by markdown-owned sheets and dialogs.
  TextStyle get sheetTitle =>
      h5.copyWith(color: textPrimary, fontWeight: FontWeight.w600);

  TextStyle get _detailTextBase => codeBlock.copyWith(
    fontSize: AppTypography.bodySmallStyle.fontSize,
    height: AppTypography.bodySmallStyle.height,
    letterSpacing: AppTypography.bodySmallStyle.letterSpacing,
  );

  TextStyle get _detailCodeBase => codeBlock.copyWith(
    fontSize: AppTypography.bodySmallStyle.fontSize,
    height: AppTypography.bodySmallStyle.height,
  );

  /// Secondary label style used for section headings and metadata.
  TextStyle get detailLabel => _detailTextBase.copyWith(
    color: textSecondary,
    fontWeight: FontWeight.w600,
  );

  /// Body style used for plain-text values inside tool call details.
  TextStyle get detailValue => tableCell.copyWith(color: textPrimary);

  /// Monospace body style used for code-like values inside tool call details.
  TextStyle get detailCode => _detailCodeBase.copyWith(color: textPrimary);

  /// Action style used for lightweight affordances in markdown chrome.
  TextStyle get detailAction => _detailTextBase.copyWith(
    color: textSecondary,
    fontWeight: FontWeight.w500,
  );

  /// Monospace metadata style used for code block headers and preview chrome.
  TextStyle get codeChrome => _detailTextBase.copyWith(
    color: textSecondary,
    fontWeight: FontWeight.w500,
  );

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
