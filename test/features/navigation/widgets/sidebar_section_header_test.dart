import 'package:conduit/features/navigation/widgets/conversation_tile.dart';
import 'package:conduit/features/navigation/widgets/sidebar_section_header.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/color_tokens.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/semantics.dart';
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
      expect(
        chevron.left,
        greaterThanOrEqualTo(kSidebarSectionHeaderInset),
        reason: 'scale $scale',
      );
      expect(
        chevron.right,
        lessThanOrEqualTo(kSidebarSectionHeaderInset + column),
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

  testWidgets('a trailing control sits on the title\'s line and leaves the '
      'header as tall as the others', (tester) async {
    tester.view.physicalSize = const Size(_windowWidth, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const controlKey = ValueKey<String>('trailing-control');
    const glyphKey = ValueKey<String>('trailing-glyph');
    var controlTaps = 0;
    var rowTaps = 0;
    var toggles = 0;

    for (final scale in [1.0, 2.0]) {
      for (final isFirst in [true, false]) {
        final reason = 'scale $scale, first $isFirst';
        Future<Rect> pumpHeader({required bool withControl}) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.light(TweakcnThemes.conduit),
              home: MediaQuery(
                data: MediaQueryData(
                  size: const Size(_windowWidth, 874),
                  textScaler: TextScaler.linear(scale),
                ),
                child: Scaffold(
                  body: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: _windowWidth,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SidebarSectionHeader(
                            title: 'Folders',
                            isFirst: isFirst,
                            isExpanded: true,
                            onToggle: () => toggles++,
                            trailing: withControl
                                ? GestureDetector(
                                    key: controlKey,
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () => controlTaps++,
                                    child: const Center(
                                      child: SizedBox.square(
                                        key: glyphKey,
                                        dimension: IconSize.small,
                                      ),
                                    ),
                                  )
                                : null,
                          ),
                          // The section's first row, right below the header.
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => rowTaps++,
                            child: const SizedBox(
                              width: _windowWidth,
                              height: TouchTarget.minimum,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          return tester.getRect(find.byType(SidebarSectionHeader));
        }

        final plain = await pumpHeader(withControl: false);
        final header = await pumpHeader(withControl: true);
        expect(header.height, plain.height, reason: reason);

        final glyph = tester.getRect(find.byKey(glyphKey));
        final title = tester.getRect(find.text('Folders'));
        expect(
          glyph.center.dy,
          moreOrLessEquals(title.center.dy, epsilon: 0.5),
          reason: reason,
        );
        // Over the rows' trailing controls, which end on their content edge.
        expect(
          glyph.center.dx,
          _windowWidth - kSidebarRowContentInset - TouchTarget.minimum / 2,
          reason: reason,
        );

        // The control is laid out a touch target wide and as tall as the
        // header, takes taps from the header's top edge to its bottom edge,
        // and the row below keeps its own.
        expect(
          tester.getSize(find.byKey(controlKey)),
          Size(TouchTarget.minimum, header.height),
          reason: reason,
        );
        final x = glyph.center.dx;
        for (final y in [header.top + 1, glyph.center.dy, header.bottom - 1]) {
          final before = controlTaps;
          await tester.tapAt(Offset(x, y));
          expect(controlTaps, before + 1, reason: '$reason, y $y');
        }
        final rowTapsBefore = rowTaps;
        await tester.tapAt(Offset(x, header.bottom + 1));
        expect(rowTaps, rowTapsBefore + 1, reason: reason);
        expect(toggles, 0, reason: reason);
      }
    }
  });

  testWidgets('on iOS, a compact icon button takes taps and is announced '
      'over the header\'s height', (tester) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);
    tester.view.physicalSize = const Size(_windowWidth, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    try {
      var presses = 0;
      var toggles = 0;

      for (final isFirst in [true, false]) {
        final reason = 'first $isFirst';
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(TweakcnThemes.conduit),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: _windowWidth,
                  // A sidebar list gives its headers unbounded height.
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SidebarSectionHeader(
                        title: 'Folders',
                        isFirst: isFirst,
                        isExpanded: true,
                        onToggle: () => toggles++,
                        trailing: ConduitIconButton(
                          icon: Icons.create_new_folder_outlined,
                          tooltip: 'New Folder',
                          isCompact: true,
                          onPressed: () => presses++,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        final header = tester.getRect(find.byType(SidebarSectionHeader));
        final x = tester.getCenter(find.byType(Icon)).dx;
        // The button is round, so its edges count along the symbol's column.
        for (final y in [header.top + 2, header.bottom - 2]) {
          final before = presses;
          await tester.tapAt(Offset(x, y));
          await tester.pumpAndSettle();
          expect(presses, before + 1, reason: '$reason, y $y');
        }

        // The symbol's node, which takes the tap, lies over the box that takes
        // the taps, not where the symbol is drawn.
        final node = tester.getSemantics(find.byType(Icon));
        expect(
          node.getSemanticsData().hasAction(SemanticsAction.tap),
          isTrue,
          reason: reason,
        );
        var rect = node.rect;
        for (SemanticsNode? n = node; n != null; n = n.parent) {
          if (n.transform case final transform?) {
            rect = MatrixUtils.transformRect(transform, rect);
          }
        }
        expect(
          rect,
          Rect.fromLTRB(
            _windowWidth - kSidebarRowContentInset - TouchTarget.minimum,
            header.top,
            _windowWidth - kSidebarRowContentInset,
            header.bottom,
          ),
          reason: reason,
        );
      }
      expect(toggles, 0);
    } finally {
      semantics.dispose();
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
