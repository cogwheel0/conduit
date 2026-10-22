import 'package:material_ui/material_ui.dart';

import '../../../theme/theme_extensions.dart';
import '../../../theme/color_tokens.dart';

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
    required this.strongColor,
    required this.emphasisColor,
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
    final tokens = theme.tokens;
    final dark = theme.isDark;
    final bodyStyle = AppTypography.chatMessageStyle.copyWith(
      color: theme.textPrimary,
      height: 1.5,
    );
    final bodySize = bodyStyle.fontSize ?? 17;
    TextStyle heading(double ratio) => bodyStyle.copyWith(
      fontSize: bodySize * ratio,
      fontWeight: FontWeight.w600,
      height: 1.3,
    );
    final monoBase =
        theme.code?.copyWith(color: theme.codeText) ??
        AppTypography.codeStyle.copyWith(color: theme.codeText);
    Color readingAccent(Color color) {
      for (final surface in [
        theme.surfaceBackground,
        theme.chatBubbleAssistant,
        theme.surfaceMessage,
      ]) {
        color = withMinContrast(color, surface, 4.5);
      }
      return color;
    }

    // Neutral presets still need visible formatting accents. Chromatic
    // palettes keep their own hues; contrast is resolved on the actual surfaces.
    Color accentOr(Color color, Color light, Color darkColor) {
      final hsl = HSLColor.fromColor(color);
      return hsl.saturation >= .12 && hsl.lightness > .12 && hsl.lightness < .88
          ? color
          : dark
          ? darkColor
          : light;
    }

    final accent = readingAccent(
      accentOr(
        tokens.brandTone40,
        const Color(0xFF4555A0),
        const Color(0xFFAFBEF5),
      ),
    );
    final codeAccent = dark ? const Color(0xFFE6A0AF) : const Color(0xFF9D425A);
    final codeSpanBackground = Color.alphaBlend(
      codeAccent.withValues(alpha: dark ? .12 : .07),
      tokens.codeBackground,
    );
    final codeSpanText = withMinContrast(codeAccent, codeSpanBackground, 4.5);

    return ConduitMarkdownStyle(
      isDark: dark,

      // -- Text styles --
      body: bodyStyle,
      h1: heading(21 / 17),
      h2: heading(20 / 17),
      h3: heading(18 / 17),
      h4: heading(1),
      h5: heading(1),
      h6: heading(1).copyWith(color: theme.textSecondary),
      codeSpan: monoBase.copyWith(
        color: codeSpanText,
        fontSize: bodySize * .9,
        fontWeight: FontWeight.w400,
      ),
      codeBlock: monoBase.copyWith(color: theme.codeText, height: 1.6),
      blockquoteText: bodyStyle.copyWith(
        color: theme.textSecondary,
        fontStyle: FontStyle.italic,
      ),
      tableHeader: bodyStyle.copyWith(
        color: theme.textSecondary,
        fontSize: bodySize * .85,
        fontWeight: FontWeight.w500,
      ),
      tableCell: bodyStyle.copyWith(color: theme.textPrimary, height: 1.35),
      paragraphSpacing: 12,
      headingTopSpacing: Spacing.md,
      headingBottomSpacing: Spacing.xs,
      listItemSpacing: Spacing.xs,
      codeBlockSpacing: Spacing.sm,
      blockquoteSpacing: Spacing.sm,
      tableSpacing: Spacing.sm,

      // -- Colors --
      codeSpanTextColor: codeSpanText,
      codeSpanBackgroundColor: codeSpanBackground,
      codeBlockBackground: theme.codeBackground,
      codeBlockBorder: theme.codeBorder,
      blockquoteBorderColor: theme.dividerColor,
      tableBorderColor: Color.alphaBlend(
        theme.textPrimary.withValues(alpha: dark ? .15 : .12),
        theme.surfaceBackground,
      ),
      tableHeaderBackground: theme.surfaceBackground,
      linkColor: withMinContrast(
        withMinContrast(theme.variant.primary, theme.surfaceBackground, 4.5),
        theme.chatBubbleAssistant,
        4.5,
      ),
      strongColor: accent,
      emphasisColor: readingAccent(
        accentOr(
          tokens.accentTeal60,
          const Color(0xFF277568),
          const Color(0xFF8BCFC0),
        ),
      ),
      dividerColor: theme.dividerColor,
      textPrimary: theme.textPrimary,
      textSecondary: theme.textSecondary,

      // -- Shapes --
      codeBlockRadius: 12,
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

  /// Theme accents for emphasis, corrected for chat and page surfaces.
  final Color strongColor;
  final Color emphasisColor;

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
