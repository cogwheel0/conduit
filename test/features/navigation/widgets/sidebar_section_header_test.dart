import 'package:conduit/features/navigation/widgets/sidebar_section_header.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/color_tokens.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _chevronKey = ValueKey<String>('section-chevron');
const double _windowWidth = 402;

Widget _header({
  required ThemeData theme,
  double textScale = 1,
  bool expanded = true,
  bool collapsible = true,
}) {
  return MaterialApp(
    theme: theme,
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(_windowWidth, 874),
        textScaler: TextScaler.linear(textScale),
      ),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: _windowWidth,
            child: collapsible
                ? SidebarSectionHeader(
                    title: 'Pinned',
                    isExpanded: expanded,
                    onToggle: () {},
                    chevronKey: _chevronKey,
                  )
                : const SidebarSectionHeader(title: 'Pinned'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('the chevron leads its title on the list margin, centred on '
      'the title\'s line, and scales with it', (tester) async {
    tester.view.physicalSize = const Size(_windowWidth, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final widths = <double>[];
    for (final scale in [1.0, 1.5]) {
      await tester.pumpWidget(
        _header(theme: AppTheme.light(TweakcnThemes.conduit), textScale: scale),
      );
      final chevron = tester.getRect(find.byKey(_chevronKey));
      final title = tester.getRect(find.text('Pinned'));
      final column = IconSize.listItem * scale;
      expect(
        chevron.center.dx,
        moreOrLessEquals(kSidebarSectionHeaderInset + column / 2),
        reason: 'scale $scale',
      );
      expect(chevron.right, lessThan(title.left), reason: 'scale $scale');
      expect(
        chevron.center.dy,
        moreOrLessEquals(title.center.dy, epsilon: 0.5),
        reason: 'scale $scale',
      );
      widths.add(chevron.width);
    }
    // A symbol set in the title's font grows with Dynamic Type.
    expect(widths[1] / widths[0], moreOrLessEquals(1.5, epsilon: 0.01));
  });

  testWidgets('the title follows the chevron column at every text size, '
      'whether or not the section collapses', (tester) async {
    tester.view.physicalSize = const Size(_windowWidth, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final scale in [1.0, 1.5, 2.0]) {
      final expected =
          kSidebarSectionHeaderInset + IconSize.listItem * scale + Spacing.xxs;
      for (final collapsible in [true, false]) {
        await tester.pumpWidget(
          _header(
            theme: AppTheme.light(TweakcnThemes.conduit),
            textScale: scale,
            collapsible: collapsible,
          ),
        );
        expect(
          tester.getTopLeft(find.text('Pinned')).dx,
          moreOrLessEquals(expected),
          reason: 'scale $scale, collapsible $collapsible',
        );
      }
      expect(find.byKey(_chevronKey), findsNothing);
    }
  });

  testWidgets('dark section headers sit quieter than secondary text', (
    tester,
  ) async {
    final theme = AppTheme.dark(TweakcnThemes.conduit);
    await tester.pumpWidget(_header(theme: theme));
    final tokens = theme.extension<ConduitThemeExtension>()!;
    final page = tokens.surfaceBackground;
    final title = tester.widget<Text>(find.text('Pinned'));
    final color = title.style!.color!;

    expect(
      contrastRatio(color, page),
      lessThan(contrastRatio(tokens.textSecondary, page)),
    );
    // Further from the row text, so the header reads as a label above it.
    expect(
      contrastRatio(color, tokens.textPrimary),
      greaterThan(contrastRatio(tokens.textSecondary, tokens.textPrimary)),
    );
  });

  test('section headers stay legible on every palette', () {
    for (final palette in TweakcnThemes.all) {
      for (final theme in [AppTheme.light(palette), AppTheme.dark(palette)]) {
        final tokens = theme.extension<ConduitThemeExtension>()!;
        final color = sidebarSectionHeaderColor(tokens);
        expect(
          contrastRatio(color, tokens.surfaceBackground),
          greaterThanOrEqualTo(4.5),
          reason: '${palette.id} ${tokens.isDark ? 'dark' : 'light'}',
        );
      }
    }
  });
}
