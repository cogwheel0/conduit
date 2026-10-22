import 'package:checks/checks.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/color_tokens.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/markdown/renderer/markdown_style.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('inline code and links remain readable across palettes', (
    tester,
  ) async {
    for (final palette in TweakcnThemes.all) {
      for (final brightness in Brightness.values) {
        late ConduitMarkdownStyle style;
        late ConduitThemeExtension theme;
        await tester.pumpWidget(
          MaterialApp(
            theme: brightness == Brightness.dark
                ? AppTheme.dark(palette)
                : AppTheme.light(palette),
            home: Builder(
              builder: (context) {
                style = ConduitMarkdownStyle.fromTheme(context);
                theme = context.conduitTheme;
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        expect(
          contrastRatio(style.codeSpanTextColor, style.codeSpanBackgroundColor),
          greaterThanOrEqualTo(4.5),
          reason: '${palette.id} $brightness code',
        );
        for (final surface in [
          theme.surfaceBackground,
          theme.chatBubbleAssistant,
          theme.surfaceMessage,
        ]) {
          for (final color in [style.strongColor, style.emphasisColor]) {
            expect(
              contrastRatio(color, surface),
              greaterThanOrEqualTo(4.5),
              reason: '${palette.id} $brightness emphasis',
            );
          }
          expect(
            contrastRatio(style.linkColor, surface),
            greaterThanOrEqualTo(4.5),
            reason: '${palette.id} $brightness link',
          );
        }
      }
    }
  });

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

      check(style.paragraphSpacing).equals(12);
      check(style.headingTopSpacing).equals(Spacing.md);
      check(style.headingBottomSpacing).equals(4);
      check(style.listItemSpacing).equals(4);
      check(style.codeBlockSpacing).equals(8);
      check(style.blockquoteSpacing).equals(8);
      check(style.tableSpacing).equals(8);
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
      expect(ios.codeBlock.fontFamily, 'Menlo');
      expect(android.codeBlock.fontSize, ios.codeBlock.fontSize);
      expect(android.h1.fontSize, 21);
      expect(android.h2.fontSize, 20);
      expect(android.body.fontSize, 17);
      expect(android.body.height, 1.5);
      expect(ios.h1.fontSize, 21);
      expect(ios.h2.fontSize, 20);
      expect(ios.body.fontSize, 17);
      expect(ios.body.height, 1.5);
    });
  });
}
