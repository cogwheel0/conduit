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
      expect(android.h1.fontSize, 24);
      expect(android.h2.fontSize, 22);
      expect(android.body.fontSize, 17);
      expect(android.body.height, 1.29);
      expect(ios.h1.fontSize, 24);
      expect(ios.h2.fontSize, 22);
      expect(ios.body.fontSize, 17);
      expect(ios.body.height, 1.29);
    });
  });
}
