import 'package:checks/checks.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
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

      check(style.paragraphSpacing).equals(Spacing.md);
      check(style.headingTopSpacing).equals(Spacing.md);
      check(style.headingBottomSpacing).equals(Spacing.sm);
      check(style.listItemSpacing).equals(Spacing.sm);
      check(style.codeBlockSpacing).equals(Spacing.md);
      check(style.blockquoteSpacing).equals(Spacing.md);
      check(style.tableSpacing).equals(Spacing.md);
    });

    testWidgets('uses bundled Geist font families', (tester) async {
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

      check(materialTheme.textTheme.bodyMedium?.fontFamily)
          .equals(AppTypography.fontFamily);
      check(AppTypography.codeStyle.fontFamily)
          .equals(AppTypography.monospaceFontFamily);
      check(conduitTheme.code?.fontFamily)
          .equals(AppTypography.monospaceFontFamily);
    });

    testWidgets('uses the same reading hierarchy on Android and iOS', (
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

      expect(android.body, ios.body);
      expect(android.h1, ios.h1);
      expect(android.h2, ios.h2);
      expect(android.h3, ios.h3);
      expect(android.h4, ios.h4);
      expect(android.h5, ios.h5);
      expect(android.h6, ios.h6);
      expect(android.codeBlock, ios.codeBlock);
      expect(android.h1.fontSize, 24);
      expect(android.h2.fontSize, 22);
      expect(android.body.fontSize, 17);
      expect(android.body.height, 1.29);
    });
  });
}
