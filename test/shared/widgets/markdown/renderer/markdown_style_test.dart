import 'dart:math' as math;

import 'package:checks/checks.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/markdown/renderer/code_syntax_theme.dart';
import 'package:conduit/shared/widgets/markdown/renderer/markdown_style.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ConduitMarkdownStyle.fromTheme', () {
    testWidgets('uses balanced markdown spacing defaults', (tester) async {
      late ConduitMarkdownStyle style;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          home: Builder(
            builder: (context) {
              style = ConduitMarkdownStyle.fromTheme(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      // Every block shares one 16pt gap below it; headings add space above
      // and keep a tighter gap below so they group with their content.
      check(style.paragraphSpacing).equals(Spacing.md);
      check(style.codeBlockSpacing).equals(style.paragraphSpacing);
      check(style.blockquoteSpacing).equals(style.paragraphSpacing);
      check(style.tableSpacing).equals(style.paragraphSpacing);
      check(style.headingTopSpacing).isGreaterThan(style.headingBottomSpacing);
      check(style.headingBottomSpacing).equals(Spacing.sm);
      check(style.listItemSpacing).isGreaterOrEqual(6);
      check(style.listItemSpacing).isLessOrEqual(8);
      check(style.looseListItemSpacing).isGreaterThan(style.listItemSpacing);
    });

    testWidgets('uses system font families', (tester) async {
      late ThemeData materialTheme;
      late ConduitThemeExtension conduitTheme;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          home: Builder(
            builder: (context) {
              materialTheme = Theme.of(context);
              conduitTheme = context.conduitTheme;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      check(materialTheme.textTheme.bodyMedium?.fontFamily).equals('Roboto');
      check(AppTypography.codeStyle.fontFamily)
          .equals(AppTypography.monospaceFontFamily);
      check(conduitTheme.code?.fontFamily)
          .equals(AppTypography.monospaceFontFamily);
    });

    testWidgets('uses one reading hierarchy with native font families', (
      tester,
    ) async {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      Future<ConduitMarkdownStyle> resolveStyle(TargetPlatform platform) async {
        debugDefaultTargetPlatformOverride = platform;
        late ConduitMarkdownStyle style;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            home: Builder(
              builder: (context) {
                style = ConduitMarkdownStyle.fromTheme(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        return style;
      }

      final android = await resolveStyle(TargetPlatform.android);
      final ios = await resolveStyle(TargetPlatform.iOS);
      debugDefaultTargetPlatformOverride = null;

      expect(android.codeBlock.fontFamily, 'monospace');
      expect(ios.codeBlock.fontFamily, CodeSyntaxTheme.appleFamily);
      expect(ios.codeBlock.fontFamilyFallback, contains('Menlo'));
      expect(ios.codeBlock.fontSize, 13);
      expect(ios.codeBlock.fontWeight, FontWeight.w400);
      expect(android.codeBlock.fontSize, ios.codeBlock.fontSize);
      expect(android.h1.fontSize, 24);
      expect(android.h2.fontSize, 22);
      // Reply prose reads at 17/24.
      expect(android.body.fontSize, 17);
      expect(android.body.fontSize! * android.body.height!, closeTo(24, 1e-9));
      expect(ios.h1.fontSize, 24);
      expect(ios.h2.fontSize, 22);
      expect(ios.body.fontSize, 17);
      expect(ios.body.fontSize! * ios.body.height!, closeTo(24, 1e-9));
      // Inline code is monospace at ~0.9em in the label colour.
      expect(ios.codeSpan.fontFamily, CodeSyntaxTheme.appleFamily);
      expect(ios.codeSpan.fontSize, closeTo(17 * 0.88, 0.01));
      expect(ios.codeSpanTextColor, ios.textPrimary);
    });

    for (final dark in [false, true]) {
      testWidgets('table rules are quiet but visible on the page and the '
          'header band (${dark ? 'dark' : 'light'})', (tester) async {
        late ConduitMarkdownStyle style;
        late Color page;
        await tester.pumpWidget(
          MaterialApp(
            theme: dark
                ? AppTheme.dark(TweakcnThemes.conduit)
                : AppTheme.light(TweakcnThemes.conduit),
            home: Builder(
              builder: (context) {
                style = ConduitMarkdownStyle.fromTheme(context);
                page = Theme.of(context).scaffoldBackgroundColor;
                return const SizedBox.shrink();
              },
            ),
          ),
        );

        double contrast(Color a, Color b) {
          final la = a.computeLuminance();
          final lb = b.computeLuminance();
          return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
        }

        final rule = Color.alphaBlend(style.tableBorderColor, page);
        final band = Color.alphaBlend(style.tableHeaderBackground, page);
        final ruleOnBand = Color.alphaBlend(style.tableBorderColor, band);
        // Visible against the page (the old divider tone was ~1.1:1)...
        expect(contrast(rule, page), greaterThan(1.2));
        // ...and against the header band it outlines...
        expect(contrast(ruleOnBand, band), greaterThan(1.15));
        // ...but far quieter than text.
        expect(contrast(rule, page), lessThan(1.8));
      });
    }
  });
}
