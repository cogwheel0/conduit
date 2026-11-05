import 'dart:ui' as ui;

import 'package:conduit/shared/widgets/markdown/renderer/markdown_text.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _highlight = Color(0xFF2979FF);
const _scope = ValueKey('text');
const _area = ValueKey('selection');
const _prose =
    'Arrange the paper lanterns beside the window, then measure '
    'the blue and gold ribbons before hanging the next row.';

Widget _harness(InlineSpan span, TextDirection direction) => MaterialApp(
  theme: ThemeData(
    platform: TargetPlatform.iOS,
    textSelectionTheme: const TextSelectionThemeData(
      selectionColor: _highlight,
    ),
  ),
  home: Scaffold(
    body: Directionality(
      textDirection: direction,
      child: SingleChildScrollView(
        child: SelectionArea(
          key: _area,
          contextMenuBuilder: (context, state) => const SizedBox.shrink(),
          child: SizedBox(key: _scope, width: 300, child: MarkdownText(span)),
        ),
      ),
    ),
  ),
);

RenderParagraph _paragraph(WidgetTester tester) =>
    tester.renderObject<RenderParagraph>(
      find
          .descendant(
            of: find.byKey(_scope),
            matching: find.byWidgetPredicate((widget) => widget is RichText),
          )
          .first,
    );

SelectionContainerDelegate _selection(WidgetTester tester) => tester
    .widget<SelectionContainer>(
      find
          .descendant(
            of: find.byKey(_area),
            matching: find.byType(SelectionContainer),
          )
          .first,
    )
    .delegate!;

void _expectNativeHighlight(WidgetTester tester) {
  final paragraph = _paragraph(tester);
  final root = tester.renderObject<RenderBox>(
    find.descendant(
      of: find.byKey(_scope),
      matching: find.byType(MarkdownText),
    ),
  );
  final actual = <Rect>[];
  expect(
    root,
    paints..everything((method, arguments) {
      if (method == #drawRect &&
          (arguments[1] as Paint).color.toARGB32() == _highlight.toARGB32()) {
        final rect = arguments[0] as Rect;
        if (!rect.isEmpty) actual.add(rect);
      }
      return true;
    }),
  );
  final transform = paragraph.getTransformTo(root);
  final expected = <Rect>[
    for (final range in paragraph.selections)
      for (final box in paragraph.getBoxesForSelection(
        range,
        boxHeightStyle: ui.BoxHeightStyle.includeLineSpacingMiddle,
      ))
        if (!box.toRect().isEmpty)
          MatrixUtils.transformRect(transform, box.toRect()),
  ];
  expect(actual, expected);
}

void main() {
  setUp(
    () => PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS,
  );
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  final fixtures = <String, (InlineSpan, TextDirection)>{
    'prose': (
      const TextSpan(
        text: _prose,
        style: TextStyle(fontSize: 17, height: 1.29),
      ),
      TextDirection.ltr,
    ),
    'mixed font sizes': (
      const TextSpan(
        style: TextStyle(fontSize: 17, height: 1.29),
        children: [
          TextSpan(text: 'Arrange the '),
          TextSpan(text: 'paper lanterns ', style: TextStyle(fontSize: 28)),
          TextSpan(text: _prose),
        ],
      ),
      TextDirection.ltr,
    ),
    'RTL': (
      const TextSpan(
        text: 'رتب الفوانيس الورقية قرب النافذة ثم قس الأشرطة الزرقاء والذهبية قبل تعليق الصف التالي.',
        style: TextStyle(fontSize: 17, height: 1.29),
      ),
      TextDirection.rtl,
    ),
    'mixed scripts': (
      const TextSpan(
        text:
            'Blue فانوس paper 👩🏽‍🎨 lanterns أزرق and gold ribbons: $_prose',
        style: TextStyle(fontSize: 17, height: 1.29),
      ),
      TextDirection.ltr,
    ),
    'inline widget': (
      const TextSpan(
        style: TextStyle(fontSize: 17, height: 1.29),
        children: [
          TextSpan(text: 'Arrange the paper lanterns beside the '),
          WidgetSpan(child: Text('ribbon', selectionColor: Color(0xFFAA00FF))),
          TextSpan(
            text: ' then measure the blue and gold ribbons before hanging the next row.',
          ),
        ],
      ),
      TextDirection.ltr,
    ),
  };
  for (final entry in fixtures.entries) {
    for (final mode in ['all', 'partial', 'reversed']) {
      testWidgets('matches native highlight geometry for ${entry.key}: $mode', (
        tester,
      ) async {
        await tester.pumpWidget(_harness(entry.value.$1, entry.value.$2));
        await tester.pumpAndSettle();
        if (mode == 'all') {
          tester
              .state<SelectableRegionState>(find.byType(SelectableRegion))
              .selectAll(SelectionChangedCause.keyboard);
        } else {
          final paragraph = _paragraph(tester);
          final length = paragraph.text
              .toPlainText(includeSemanticsLabels: false)
              .length;
          Offset caret(int offset) => paragraph.localToGlobal(
            paragraph.getOffsetForCaret(
                  TextPosition(offset: offset),
                  Rect.zero,
                ) +
                Offset(0, paragraph.preferredLineHeight / 2),
          );
          final a = caret(mode == 'partial' ? 2 : length - 3);
          final b = caret(mode == 'partial' ? length - 3 : 2);
          final delegate = _selection(tester);
          delegate.dispatchSelectionEvent(
            SelectionEdgeUpdateEvent.forStart(globalPosition: a),
          );
          delegate.dispatchSelectionEvent(
            SelectionEdgeUpdateEvent.forEnd(globalPosition: b),
          );
        }
        await tester.pumpAndSettle();
        expect(_paragraph(tester).selections, isNotEmpty);
        _expectNativeHighlight(tester);
        _selection(tester).dispatchSelectionEvent(const ClearSelectionEvent());
        await tester.pumpAndSettle();
        expect(_paragraph(tester).selections, isEmpty);
        _expectNativeHighlight(tester);
      });
    }
  }

  testWidgets('keeps highlight boundaries at bidirectional run edges', (
    tester,
  ) async {
    const text = 'Blue أزرق gold ذهبي ribbon.';
    await tester.pumpWidget(
      _harness(
        const TextSpan(
          text: text,
          style: TextStyle(fontSize: 17, height: 1.29),
        ),
        TextDirection.ltr,
      ),
    );
    await tester.pumpAndSettle();
    final paragraph = _paragraph(tester);
    Offset caret(int index) => paragraph.localToGlobal(
      paragraph.getOffsetForCaret(TextPosition(offset: index), Rect.zero) +
          Offset(0, paragraph.preferredLineHeight / 2),
    );
    for (var index = 1; index < text.length; index++) {
      for (final (start, end) in [(0, index), (index, text.length)]) {
        final delegate = _selection(tester);
        delegate.dispatchSelectionEvent(const ClearSelectionEvent());
        delegate.dispatchSelectionEvent(
          SelectionEdgeUpdateEvent.forStart(globalPosition: caret(start)),
        );
        delegate.dispatchSelectionEvent(
          SelectionEdgeUpdateEvent.forEnd(globalPosition: caret(end)),
        );
        await tester.pumpAndSettle();
        _expectNativeHighlight(tester);
      }
    }
  });

  testWidgets('keeps offscreen selection geometry while scrolling', (
    tester,
  ) async {
    final text = List.generate(
      200,
      (index) => 'Lantern row $index: $_prose',
    ).join('\n');
    await tester.pumpWidget(
      _harness(
        TextSpan(
          text: text,
          style: const TextStyle(fontSize: 17, height: 1.29),
        ),
        TextDirection.ltr,
      ),
    );
    await tester.pumpAndSettle();
    tester
        .state<SelectableRegionState>(find.byType(SelectableRegion))
        .selectAll(SelectionChangedCause.keyboard);
    await tester.pumpAndSettle();
    _expectNativeHighlight(tester);
    tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position
        .jumpTo(1200);
    await tester.pumpAndSettle();
    _expectNativeHighlight(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps an inline widget selection inside that widget', (
    tester,
  ) async {
    const purple = Color(0xFFAA00FF);
    const span = TextSpan(
      style: TextStyle(fontSize: 17, height: 1.29),
      children: [
        TextSpan(text: 'Blue '),
        WidgetSpan(child: Text('ribbon', selectionColor: purple)),
        TextSpan(text: ' lanterns.'),
      ],
    );
    await tester.pumpWidget(_harness(span, TextDirection.ltr));
    await tester.pumpAndSettle();
    final child = tester.renderObject<RenderParagraph>(
      find.byWidgetPredicate(
        (widget) => widget is RichText && widget.text.toPlainText() == 'ribbon',
      ),
    );
    expect(child.selectionColor, purple);
    _selection(tester).dispatchSelectionEvent(
      SelectWordSelectionEvent(
        globalPosition: child.localToGlobal(child.size.center(Offset.zero)),
      ),
    );
    await tester.pumpAndSettle();
    expect(child.selections, isNotEmpty);
    expect(_paragraph(tester).selections, isEmpty);
    _expectNativeHighlight(tester);
  });
}
