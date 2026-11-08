import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:material_ui/material_ui.dart';

import '../../../theme/theme_extensions.dart';
import 'code_syntax_theme.dart';

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
    required this.looseListItemSpacing,
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
    final dark = theme.isDark;
    TextStyle resolveHeadingStyle(
      TextStyle? themedStyle,
      TextStyle fallback, {
      required Color color,
    }) {
      return themedStyle?.copyWith(color: color, fontWeight: FontWeight.w600) ??
          fallback.copyWith(color: color);
    }

    // Base body style used as the foundation for all text styles. Replies
    // are long-form reading, so prose gets 17/24 leading instead of the 17/22
    // UI body leading; the extra air keeps multi-line paragraphs scannable.
    final chatBody = AppTypography.chatMessageStyle;
    final bodyFontSize = chatBody.fontSize ?? 17;
    final bodyStyle = chatBody.copyWith(
      color: theme.textPrimary,
      height: readingLineHeight / bodyFontSize,
    );

    // Monospace base for code elements, in the platform's code typeface.
    final monoBase = CodeSyntaxTheme.monospace(
      theme.code ?? AppTypography.codeStyle,
      defaultTargetPlatform,
    ).copyWith(color: theme.codeText);

    // Inline code reads as part of the sentence: label colour, monospace at
    // ~0.9em, on a quiet neutral chip (no web-style red).
    final codeSpanText = theme.textPrimary;
    final codeSpanChip = theme.textPrimary.withValues(
      alpha: dark ? 0.14 : 0.07,
    );

    // Tables are dense reference data: subheadline (15/20) keeps 36-40pt
    // rows and fits more columns before scrolling.
    final tableBase = bodyStyle.copyWith(
      fontSize: tableFontSize,
      height: tableLineHeight / tableFontSize,
    );

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
      codeSpan: monoBase.copyWith(
        color: codeSpanText,
        fontSize: bodyFontSize * inlineCodeScale,
        height: 1.2,
      ),
      // Code reads at 13/19 in regular weight: quieter than the 17pt prose
      // around it, with room between lines for long listings.
      codeBlock: monoBase.copyWith(
        color: theme.codeText,
        fontSize: CodeSyntaxTheme.fontSize,
        fontWeight: FontWeight.w400,
        height: CodeSyntaxTheme.lineHeight / CodeSyntaxTheme.fontSize,
      ),
      blockquoteText: bodyStyle.copyWith(color: theme.textSecondary),
      tableHeader: tableBase.copyWith(
        color: theme.textPrimary,
        fontWeight: FontWeight.w600,
      ),
      tableCell: tableBase.copyWith(color: theme.textPrimary),

      // One rhythm: every block owns only the space below it, so the gap
      // between any two blocks is the same 16pt whichever way round they
      // are. Headings add extra space above (and keep a tight gap below) so
      // they group with the content they introduce.
      paragraphSpacing: Spacing.md,
      headingTopSpacing: Spacing.md - Spacing.xs,
      headingBottomSpacing: Spacing.sm,
      listItemSpacing: Spacing.xs + Spacing.xxs,
      looseListItemSpacing: Spacing.sm + Spacing.xxs,
      codeBlockSpacing: Spacing.md,
      blockquoteSpacing: Spacing.md,
      tableSpacing: Spacing.md,

      // -- Colors --
      codeSpanTextColor: codeSpanText,
      codeSpanBackgroundColor: codeSpanChip,
      codeBlockBackground: theme.codeBackground,
      codeBlockBorder: theme.codeBorder,
      blockquoteBorderColor: theme.textPrimary.withValues(
        alpha: dark ? 0.28 : 0.18,
      ),
      // A quiet but visible hairline (about #E3E3E3 on white): the theme's
      // divider tone vanished against the page and the header band.
      tableBorderColor: theme.textPrimary.withValues(
        alpha: dark ? tableRuleAlphaDark : tableRuleAlphaLight,
      ),
      tableHeaderBackground: theme.textPrimary.withValues(
        alpha: dark ? 0.08 : 0.04,
      ),
      linkColor: theme.variant.primary,
      dividerColor: theme.dividerColor,
      textPrimary: theme.textPrimary,
      textSecondary: theme.textSecondary,

      // -- Shapes --
      codeBlockRadius: AppBorderRadius.md,
      codeSpanRadius: AppBorderRadius.xs + 1,
      tableRadius: AppBorderRadius.md,
    );
  }

  /// Line height for reply prose (17/24).
  static const double readingLineHeight = 24;

  /// Inline code size relative to the surrounding text.
  static const double inlineCodeScale = 0.88;

  /// Table text size (subheadline) and its line height.
  static const double tableFontSize = 15;
  static const double tableLineHeight = 20;

  /// Strength of a table's outline and row rules: the label colour at this
  /// opacity, a little stronger in dark mode where hairlines read weaker.
  static const double tableRuleAlphaLight = 0.11;
  static const double tableRuleAlphaDark = 0.2;

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

  /// Vertical space below a paragraph or list: the base gap between blocks.
  final double paragraphSpacing;

  /// Extra space above a heading, on top of the previous block's gap.
  final double headingTopSpacing;

  /// Space below a heading element.
  final double headingBottomSpacing;

  /// Space between items of a tight list, and between a list item's text
  /// and a list nested under it.
  final double listItemSpacing;

  /// Space between items of a loose list (items separated by blank lines).
  final double looseListItemSpacing;

  /// Space below a code block.
  final double codeBlockSpacing;

  /// Space below a blockquote.
  final double blockquoteSpacing;

  /// Space below a table.
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

  /// Corner radius for fenced code blocks and other content cards.
  final double codeBlockRadius;

  /// Corner radius for inline code spans.
  final double codeSpanRadius;

  /// Corner radius for the table container.
  final double tableRadius;

  // ----- Helpers -----

  /// The thin scroll indicator of a code block or table that scrolls
  /// sideways: the label colour at about the strength of the system's.
  Color get scrollIndicatorColor =>
      textPrimary.withValues(alpha: isDark ? 0.42 : 0.34);

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
  TextStyle get detailValue => body.copyWith(color: textPrimary);

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
