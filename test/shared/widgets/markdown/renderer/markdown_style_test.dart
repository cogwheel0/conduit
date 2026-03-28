import 'package:checks/checks.dart';
import 'package:qonduit/shared/theme/app_theme.dart';
import 'package:qonduit/shared/theme/theme_extensions.dart';
import 'package:qonduit/shared/theme/tweakcn_themes.dart';
import 'package:qonduit/shared/widgets/markdown/renderer/markdown_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('QonduitMarkdownStyle.fromTheme', () {
    testWidgets('uses balanced markdown spacing defaults', (tester) async {
      late QonduitMarkdownStyle style;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          home: Builder(
            builder: (context) {
              style = QonduitMarkdownStyle.fromTheme(context);
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
  });
}
