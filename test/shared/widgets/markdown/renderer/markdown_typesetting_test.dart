import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/markdown/markdown_config.dart';
import 'package:conduit/shared/widgets/markdown/renderer/block_renderer.dart';
import 'package:conduit/shared/widgets/markdown/renderer/horizontal_overflow_fade.dart';
import 'package:conduit/shared/widgets/markdown/renderer/markdown_style.dart';
import 'package:conduit/shared/widgets/markdown/streaming_markdown_widget.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
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

    testWidgets('a wide table scrolls, wraps long headers and fades its edge', (
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
      final table = globalRect(tester.renderObject(find.byType(Table)));
      expect(table.width, greaterThan(frame.width));

      // The long header wraps at the column cap instead of stretching.
      final header = paragraphStartingWith(tester, 'Days to harvest');
      expect(
        header.size.width,
        lessThanOrEqualTo(MarkdownTableFrame.maxColumnWidth),
      );
      expect(header.size.height, greaterThan(style.tableHeader.fontSize! * 2));
      // Short heads sit on the same last line as the wrapped one.
      expect(
        paragraphRect(tester, 'Crop').bottom,
        closeTo(globalRect(header).bottom, 0.5),
      );

      final fade = tester.state(find.byType(HorizontalOverflowFade)) as dynamic;
      expect((fade.edges as HorizontalFadeEdges).right, 1);
      expect((fade.edges as HorizontalFadeEdges).left, 0);

      await tester.dragFrom(frame.center, const Offset(-1000, 0));
      await tester.pumpAndSettle();
      expect((fade.edges as HorizontalFadeEdges).right, 0);
      expect((fade.edges as HorizontalFadeEdges).left, 1);
    });
  });
}
