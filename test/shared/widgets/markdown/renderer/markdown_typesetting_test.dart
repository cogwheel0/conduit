import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/markdown/markdown_config.dart';
import 'package:conduit/shared/widgets/markdown/renderer/block_renderer.dart';
import 'package:conduit/shared/widgets/markdown/renderer/horizontal_overflow_fade.dart';
import 'package:conduit/shared/widgets/markdown/renderer/markdown_style.dart';
import 'package:conduit/shared/widgets/markdown/streaming_markdown_widget.dart';
import 'package:flutter/rendering.dart' show RenderParagraph, RenderTable;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Typesetting of assistant replies: one spacing rhythm between blocks,
/// nested lists indented under their parent, single spaces around bold and
/// inline code, and tables framed inside the text column.
void main() {
  Widget harness(String content, {double width = 360}) => ProviderScope(
    child: MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: SingleChildScrollView(
              // Same path as chat replies: one sub-document per root block.
              child: StreamingMarkdownWidget(
                content: content,
                isStreaming: false,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  late ConduitMarkdownStyle style;

  Future<void> pump(
    WidgetTester tester,
    String content, {
    double? width,
  }) async {
    await tester.pumpWidget(harness(content, width: width ?? 360));
    await tester.pumpAndSettle();
    style = ConduitMarkdownStyle.fromTheme(
      tester.element(find.byType(StreamingMarkdownWidget)),
    );
  }

  /// The rich-text paragraph whose plain text starts with [prefix].
  RenderParagraph paragraphStartingWith(WidgetTester tester, String prefix) {
    final matches = tester
        .renderObjectList<RenderParagraph>(find.byType(RichText))
        .where((paragraph) => paragraph.text.toPlainText().startsWith(prefix))
        .toList();
    expect(matches, hasLength(1), reason: 'paragraph starting "$prefix"');
    return matches.single;
  }

  /// Global rect of a paragraph's first glyph line box.
  Rect firstLineRect(RenderParagraph paragraph) {
    final box = paragraph
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 1),
        )
        .first
        .toRect();
    return box.shift(paragraph.localToGlobal(Offset.zero));
  }

  Rect globalRect(RenderBox box) => box.localToGlobal(Offset.zero) & box.size;

  Rect paragraphRect(WidgetTester tester, String prefix) =>
      globalRect(paragraphStartingWith(tester, prefix));

  group('inline spacing', () {
    testWidgets('bold text in a tight list item keeps a single space', (
      tester,
    ) async {
      await pump(tester, '- **Use a jar** and mark the level.');

      final text = paragraphStartingWith(tester, 'Use a jar').text;
      expect(text.toPlainText(), 'Use a jar and mark the level.');
    });

    testWidgets('inline code in a list item keeps a single space', (
      tester,
    ) async {
      await pump(tester, '1. Pass `newline=""` so quoted fields parse.');

      final text = paragraphStartingWith(tester, 'Pass').text;
      // The code chip is one placeholder character between single spaces.
      expect(text.toPlainText(), 'Pass ￼ so quoted fields parse.');
    });

    testWidgets('inline code sits on the text baseline in the label colour', (
      tester,
    ) async {
      await pump(tester, 'Let `csv.DictReader` stream it.');

      final chips = <WidgetSpan>[];
      paragraphStartingWith(tester, 'Let').text.visitChildren((span) {
        if (span is WidgetSpan) chips.add(span);
        return true;
      });
      final chip = chips.single;
      expect(chip.alignment, PlaceholderAlignment.baseline);
      expect(chip.baseline, TextBaseline.alphabetic);
      final code = tester.widget<Text>(find.text('csv.DictReader'));
      expect(code.style?.color, style.textPrimary);
      expect(code.style?.fontSize, lessThan(style.body.fontSize!));
    });
  });

  group('lists', () {
    testWidgets('nested list starts at the parent text, close beneath it', (
      tester,
    ) async {
      await pump(tester, '1. Parent step\n   - Child detail\n2. Next step');

      final parent = firstLineRect(paragraphStartingWith(tester, 'Parent'));
      final child = firstLineRect(paragraphStartingWith(tester, 'Child'));
      final next = firstLineRect(paragraphStartingWith(tester, 'Next'));

      // The child's text is indented one marker column (~20pt) past the
      // parent's text.
      expect(child.left - parent.left, inInclusiveRange(18, 24));
      // Its bullet sits in that column, starting at the parent's text.
      final bullet = globalRect(tester.renderObject(find.text('◦')));
      expect(bullet.left, closeTo(parent.left, 0.5));
      // 6-8pt between the parent line box and its first child.
      final gap =
          paragraphRect(tester, 'Child').top -
          paragraphRect(tester, 'Parent').bottom;
      expect(gap, inInclusiveRange(6, 8));
      // The next sibling item lines up with the parent again.
      expect(next.left, closeTo(parent.left, 0.5));
    });

    testWidgets('unindented bullets after a numbered step nest under it', (
      tester,
    ) async {
      await pump(
        tester,
        '1) Anchor a sleep window\n'
        '- Sleep right after the shift.\n'
        '- Keep the block steady.\n'
        '\n'
        '2) Control light',
      );

      final parent = firstLineRect(paragraphStartingWith(tester, 'Anchor'));
      final child = firstLineRect(paragraphStartingWith(tester, 'Sleep'));
      expect(child.left, greaterThan(parent.left + 16));
      final gap =
          paragraphRect(tester, 'Sleep').top -
          paragraphRect(tester, 'Anchor').bottom;
      expect(gap, inInclusiveRange(6, 8));
      expect(find.text('2.'), findsOneWidget);
    });

    testWidgets('tight list items are separated by the tight item gap', (
      tester,
    ) async {
      await pump(tester, '- First item\n- Second item');

      final gap =
          paragraphRect(tester, 'Second').top -
          paragraphRect(tester, 'First').bottom;
      expect(gap, closeTo(style.listItemSpacing, 0.5));
    });
  });

  group('vertical rhythm', () {
    testWidgets('code blocks have the same space above and below', (
      tester,
    ) async {
      await pump(
        tester,
        'Intro paragraph.\n\n```python\nprint("hi")\n```\n\nAfter paragraph.',
      );

      final card = globalRect(
        tester.renderObject(
          find
              .ancestor(
                of: find.byType(CodeBlockHeader),
                matching: find.byType(Container),
              )
              .last,
        ),
      );
      final above = card.top - paragraphRect(tester, 'Intro').bottom;
      final below = paragraphRect(tester, 'After').top - card.bottom;
      expect(above, closeTo(style.paragraphSpacing, 0.5));
      expect(below, closeTo(style.paragraphSpacing, 0.5));
    });

    testWidgets('code has even inner padding and no trailing blank line', (
      tester,
    ) async {
      await pump(tester, '```python\nprint("hi")\n```');

      final code = tester
          .renderObjectList<RenderParagraph>(find.byType(RichText))
          .singleWhere(
            (paragraph) => paragraph.text.toPlainText() == 'print("hi")',
          );
      final header = globalRect(
        tester.renderObject(find.byType(CodeBlockHeader)),
      );
      final card = globalRect(
        tester.renderObject(
          find
              .ancestor(
                of: find.byType(CodeBlockHeader),
                matching: find.byType(Container),
              )
              .last,
        ),
      );
      final text = globalRect(code);
      final top = text.top - header.bottom;
      final bottom = card.bottom - text.bottom;
      // Within a hairline border of each other.
      expect((top - bottom).abs(), lessThanOrEqualTo(1));
      expect(top, inInclusiveRange(11, 13));
    });

    testWidgets('headings have more space above than below', (tester) async {
      await pump(tester, 'Intro paragraph.\n\n## Section\n\nBody text.');

      final above =
          paragraphRect(tester, 'Section').top -
          paragraphRect(tester, 'Intro').bottom;
      final below =
          paragraphRect(tester, 'Body').top -
          paragraphRect(tester, 'Section').bottom;
      expect(
        above,
        closeTo(style.paragraphSpacing + style.headingTopSpacing, 0.5),
      );
      expect(below, closeTo(style.headingBottomSpacing, 0.5));
      expect(above, greaterThan(below * 2));
    });

    testWidgets('a reply that opens with a heading starts flush', (
      tester,
    ) async {
      await pump(tester, '## Section\n\nBody text.');

      final top = paragraphRect(tester, 'Section').top;
      final origin = tester.getTopLeft(find.byType(StreamingMarkdownWidget)).dy;
      expect(top, closeTo(origin, 0.5));
    });

    testWidgets('lists, quotes and tables share the paragraph gap', (
      tester,
    ) async {
      await pump(
        tester,
        'Intro paragraph.\n\n- Item\n\nMiddle paragraph.\n\n'
        '> Quoted line\n\nAfter quote.',
      );

      double gap(String upper, String lower) =>
          paragraphRect(tester, lower).top -
          paragraphRect(tester, upper).bottom;
      expect(gap('Intro', 'Item'), closeTo(style.paragraphSpacing, 0.5));
      expect(gap('Item', 'Middle'), closeTo(style.paragraphSpacing, 0.5));
      expect(gap('Middle', 'Quoted'), closeTo(style.paragraphSpacing, 0.5));
      expect(gap('Quoted', 'After'), closeTo(style.paragraphSpacing, 0.5));
    });
  });

  group('tables', () {
    const narrowTable = '| Day | Ratio |\n| --- | --- |\n| 1 | 0 : 50 |';
    const wideTable =
        '| Crop | Spacing | Sun | Days to harvest (from sowing or transplant) |\n'
        '| --- | --- | --- | --- |\n'
        '| Radish | 5 cm | Full sun or light shade | 25-30 |';

    testWidgets('a narrow table fills the column inside a rounded frame', (
      tester,
    ) async {
      await pump(tester, narrowTable);

      final frame = globalRect(
        tester.renderObject(find.byType(MarkdownTableFrame)),
      );
      final column = globalRect(
        tester.renderObject(find.byType(StreamingMarkdownWidget)),
      );
      expect(frame.left, closeTo(column.left, 0.5));
      expect(frame.right, closeTo(column.right, 0.5));
      final table = globalRect(tester.renderObject(find.byType(Table)));
      expect(table.width, closeTo(frame.width, 0.5));

      final fade = tester.state(find.byType(HorizontalOverflowFade)) as dynamic;
      expect((fade.edges as HorizontalFadeEdges).isFading, isFalse);
    });

    testWidgets('rows are 36-40pt tall', (tester) async {
      await pump(tester, narrowTable);

      final row = paragraphRect(tester, '1');
      final rowHeight = row.height + MarkdownTableFrame.cellPadding.vertical;
      expect(rowHeight, inInclusiveRange(36, 40));
    });

    Finder chrome() => find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_TableChrome',
    );
    Finder indicator() => find.descendant(
      of: find.byType(MarkdownTableFrame),
      matching: find.byType(RawScrollbar),
    );
    Color indicatorColor() =>
        style.textPrimary.withValues(alpha: style.isDark ? 0.34 : 0.26);

    testWidgets('a long column takes the room its narrow neighbour leaves', (
      tester,
    ) async {
      await pump(
        tester,
        '| Day | Note |\n| --- | --- |\n'
        '| 1 | Mix flour and water then cover loosely |',
      );

      final frame = globalRect(
        tester.renderObject(find.byType(MarkdownTableFrame)),
      );
      final table = globalRect(tester.renderObject(find.byType(Table)));
      expect(table.width, closeTo(frame.width, 0.5));
      // The narrow column keeps its natural one-line width; the long one
      // wraps across everything else instead of scrolling.
      final day = paragraphStartingWith(tester, 'Day');
      expect(day.size.height, closeTo(style.tableHeader.fontSize!, 6));
      final note = paragraphStartingWith(tester, 'Mix flour');
      expect(note.size.height, greaterThan(style.tableCell.fontSize! * 2));
      final fade = tester.state(find.byType(HorizontalOverflowFade)) as dynamic;
      expect((fade.edges as HorizontalFadeEdges).isFading, isFalse);
      expect(indicator(), isNot(paints..rrect(color: indicatorColor())));
    });

    testWidgets('competing columns share the frame without scrolling', (
      tester,
    ) async {
      await pump(
        tester,
        '| Day | Feed ratio (starter : flour : water) | What to look for |\n'
        '| --- | --- | --- |\n'
        '| 1 | 0 : 50 g : 50 g | Just mix and cover loosely |\n'
        '| 4-6 | 25 : 50 : 50, twice a day | Rises and falls predictably |',
        width: 600,
      );

      final frame = globalRect(
        tester.renderObject(find.byType(MarkdownTableFrame)),
      );
      final renderTable = tester.renderObject<RenderTable>(find.byType(Table));
      expect(renderTable.size.width, closeTo(frame.width, 0.5));
      // No scroll track under a table that fits.
      expect(renderTable.size.height, closeTo(frame.height, 0.5));
      final widths = [
        for (var x = 0; x < renderTable.columns; x++)
          renderTable.column(x).first.size.width,
      ];
      // The short column is exactly as wide as its content.
      expect(
        widths[0],
        closeTo(
          paragraphStartingWith(tester, '4-6').size.width +
              MarkdownTableFrame.cellPadding.horizontal,
          0.5,
        ),
      );
      // Neither long column crowds out the other.
      for (final width in widths.skip(1)) {
        expect(
          width,
          lessThanOrEqualTo(frame.width * MarkdownTableFrame.maxColumnFraction),
        );
      }
      // Nothing is clipped: every cell's text fits inside its column.
      for (final paragraph in tester.renderObjectList<RenderParagraph>(
        find.descendant(
          of: find.byType(Table),
          matching: find.byType(RichText),
        ),
      )) {
        expect(
          paragraph.size.width,
          lessThanOrEqualTo(paragraph.constraints.maxWidth),
        );
        expect(paragraph.didExceedMaxLines, isFalse);
      }
      final fade = tester.state(find.byType(HorizontalOverflowFade)) as dynamic;
      expect((fade.edges as HorizontalFadeEdges).isFading, isFalse);
    });

    testWidgets('a table too wide to fit scrolls inside an intact frame', (
      tester,
    ) async {
      await pump(tester, wideTable);

      final frame = globalRect(
        tester.renderObject(find.byType(MarkdownTableFrame)),
      );
      final column = globalRect(
        tester.renderObject(find.byType(StreamingMarkdownWidget)),
      );
      // The frame keeps the column's margins; the table scrolls inside it.
      expect(frame.right, closeTo(column.right, 0.5));
      final renderTable = tester.renderObject<RenderTable>(find.byType(Table));
      expect(renderTable.size.width, greaterThan(frame.width));

      // The long header wraps instead of stretching its column.
      final header = paragraphStartingWith(tester, 'Days to harvest');
      expect(header.size.height, greaterThan(style.tableHeader.fontSize! * 2));
      // Short heads sit on the same last line as the wrapped one.
      expect(
        paragraphRect(tester, 'Crop').bottom,
        closeTo(globalRect(header).bottom, 0.5),
      );

      // The border is drawn over the scrolling content, outside the fade.
      expect(
        find.ancestor(
          of: find.byType(HorizontalOverflowFade),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox &&
                widget.position == DecorationPosition.foreground &&
                (widget.decoration as BoxDecoration).border != null,
          ),
        ),
        findsOneWidget,
      );
      final headerBand = Rect.fromLTWH(
        0,
        0,
        frame.width,
        renderTable.getRowBox(0).bottom,
      );
      expect(
        chrome(),
        paints..rect(rect: headerBand, color: style.tableHeaderBackground),
      );
      expect(indicator(), paints..rrect(color: indicatorColor()));
      // The indicator runs in its own track below the last row.
      final lastRowBottom = renderTable.getRowBox(renderTable.rows - 1).bottom;
      expect(
        frame.height - lastRowBottom,
        closeTo(
          HorizontalOverflowFade.scrollIndicatorThickness +
              HorizontalOverflowFade.scrollIndicatorBottomGap,
          0.5,
        ),
      );

      final fade = tester.state(find.byType(HorizontalOverflowFade)) as dynamic;
      expect((fade.edges as HorizontalFadeEdges).right, 1);
      expect((fade.edges as HorizontalFadeEdges).left, 0);

      await tester.dragFrom(frame.center, const Offset(-1000, 0));
      await tester.pumpAndSettle();
      expect((fade.edges as HorizontalFadeEdges).right, 0);
      expect((fade.edges as HorizontalFadeEdges).left, 1);
      // Scrolled to the end, the header band and rules still span the frame.
      expect(
        chrome(),
        paints..rect(rect: headerBand, color: style.tableHeaderBackground),
      );
      expect(indicator(), paints..rrect(color: indicatorColor()));
    });
  });

  group('table column widths', () {
    List<double> solve(
      List<double> minWidths,
      List<double> maxWidths, {
      double available = 352,
    }) => MarkdownTableFrame.solveColumnWidths(
      minWidths: minWidths,
      maxWidths: maxWidths,
      availableWidth: available,
    );
    double sum(List<double> values) => values.fold(0, (a, b) => a + b);

    test('content that fits fills the width in proportion', () {
      final widths = solve([40, 60], [60, 120]);
      expect(sum(widths), closeTo(352, 0.01));
      expect(widths[1] / widths[0], closeTo(2, 0.01));
    });

    test('a narrow column keeps its natural width', () {
      final widths = solve([52, 82, 104], [52, 264, 209]);
      expect(widths[0], 52);
      expect(sum(widths), closeTo(352, 0.01));
      expect(widths[1], lessThanOrEqualTo(352 * 0.45));
      expect(widths[2], lessThanOrEqualTo(352 * 0.45));
      expect(widths[1], greaterThanOrEqualTo(112));
      expect(widths[2], greaterThanOrEqualTo(112));
    });

    test('one long column grows past the cap when nothing competes', () {
      final widths = solve([52, 80], [52, 600]);
      expect(widths, [52, 300]);
    });

    test('capped columns share leftover room by how much more they want', () {
      // Both long columns start at the cap (270) with 20pt to spare; the one
      // that wants 130pt more gets more of it than the one that wants 30pt.
      final widths = solve([40, 60, 60], [40, 400, 300], available: 600);
      expect(sum(widths), closeTo(600, 0.01));
      expect(widths[1] - 270, closeTo(20 * 130 / 160, 0.01));
      expect(widths[2] - 270, closeTo(20 * 30 / 160, 0.01));
    });

    test('columns that cannot fit readably scroll, wrapping less', () {
      final widths = solve([60, 60, 60, 60], [100, 150, 200, 300]);
      expect(sum(widths), greaterThan(352));
      // Narrower than the scrolling cap: natural width, on one line.
      expect(widths.take(3), [100, 150, 200]);
      // Longer: capped at 60% of the frame, wrapping inside it.
      expect(widths[3], closeTo(352 * 0.6, 0.01));
    });

    test('a column is never narrower than its longest word', () {
      final widths = solve([240, 60], [300, 400]);
      expect(widths[0], greaterThanOrEqualTo(240));
    });
  });

  group('number ranges', () {
    testWidgets('a range never breaks after its dash', (tester) async {
      await pump(tester, 'x');
      final glyph = style.body.fontSize!;
      // Wide enough for "Doubles within 4–" but not for "4–6".
      await pump(tester, 'Doubles within 4–6 hours', width: glyph * 17.5);

      final paragraph = paragraphStartingWith(tester, 'Doubles');
      final text = paragraph.text.toPlainText();
      final four = text.indexOf('4');
      final six = text.indexOf('6');
      double lineOf(int offset) => paragraph
          .getOffsetForCaret(TextPosition(offset: offset), Rect.zero)
          .dy;
      expect(lineOf(four), greaterThan(lineOf(0)), reason: 'range wraps');
      expect(lineOf(six), lineOf(four), reason: '4–6 stays on one line');
      // The joiners take no room.
      final range = paragraph
          .getBoxesForSelection(
            TextSelection(baseOffset: four, extentOffset: six + 1),
          )
          .map((box) => box.toRect().width)
          .reduce((a, b) => a + b);
      expect(range, closeTo(glyph * 3, 0.5));
    });

    testWidgets('copied text keeps the range as written', (tester) async {
      await pump(tester, '| Day | Note |\n| --- | --- |\n| 4–6 | Doubles |');

      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      expect(
        paragraphStartingWith(tester, '4').text.toPlainText(),
        contains('\u2060'),
      );
      final region = tester.state<SelectableRegionState>(
        find.byType(SelectableRegion),
      );
      region.selectAll(SelectionChangedCause.keyboard);
      await tester.pump();
      // The Copy item of the selection menu.
      region.contextMenuButtonItems
          .singleWhere((item) => item.type == ContextMenuButtonType.copy)
          .onPressed!();
      await tester.pump();

      expect(copied, isNotEmpty);
      expect(copied.last, contains('4–6'));
      expect(copied.last, isNot(contains('\u2060')));
      await tester.pumpAndSettle();
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('copied text keeps the range as written on Android', (
      tester,
    ) async {
      await pump(tester, 'Doubles within 4–6 hours');

      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      final region = tester.state<SelectableRegionState>(
        find.byType(SelectableRegion),
      );
      region.selectAll(SelectionChangedCause.keyboard);
      await tester.pump();
      // The Copy item of the selection menu.
      region.contextMenuButtonItems
          .singleWhere((item) => item.type == ContextMenuButtonType.copy)
          .onPressed!();
      await tester.pump();

      expect(copied.last, 'Doubles within 4–6 hours');
      await tester.pumpAndSettle();
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });
}
