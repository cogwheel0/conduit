import 'dart:ui' as ui;

import 'package:conduit/shared/widgets/markdown/renderer/markdown_text.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _span = TextSpan(
  style: TextStyle(fontSize: 17, height: 1.29),
  children: [
    TextSpan(text: 'Arrange the '),
    TextSpan(
      text: 'paper lanterns ',
      style: TextStyle(fontWeight: FontWeight.bold),
    ),
    TextSpan(
      text:
          'by the window and check the ribbon lengths before hanging '
          'the next row.',
    ),
  ],
);

Widget _harness({
  required Widget child,
  TargetPlatform platform = TargetPlatform.iOS,
  MediaQueryData media = const MediaQueryData(),
  TextDirection direction = TextDirection.ltr,
}) => MaterialApp(
  theme: ThemeData(platform: platform),
  home: Scaffold(
    body: MediaQuery(
      data: media,
      child: Directionality(
        textDirection: direction,
        child: SingleChildScrollView(child: child),
      ),
    ),
  ),
);

RenderParagraph _paragraph(WidgetTester tester, Key scope) =>
    tester.renderObject<RenderParagraph>(
      find
          .descendant(
            of: find.byKey(scope),
            matching: find.byWidgetPredicate((widget) => widget is RichText),
          )
          .first,
    );

void main() {
  setUp(
    () => PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS,
  );
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  for (final (label, media) in [
    ('default', const MediaQueryData()),
    (
      'larger bold text',
      const MediaQueryData(textScaler: TextScaler.linear(1.6), boldText: true),
    ),
    (
      'spacing overrides',
      const MediaQueryData(
        lineHeightScaleFactorOverride: 1.8,
        letterSpacingOverride: 1.5,
        wordSpacingOverride: 2,
      ),
    ),
  ]) {
    testWidgets('retains stock text layout: $label', (tester) async {
      const adapted = ValueKey('adapted');
      const stock = ValueKey('stock');
      await tester.pumpWidget(
        _harness(
          media: media,
          child: SelectionArea(
            child: Column(
              children: [
                const SizedBox(
                  key: adapted,
                  width: 300,
                  child: MarkdownText(_span),
                ),
                const SizedBox(key: stock, width: 300, child: Text.rich(_span)),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(adapted),
          matching: find.byWidgetPredicate(
            (widget) => widget is SelectionContainer && widget.child is Text,
          ),
        ),
        findsOneWidget,
      );
      final actual = _paragraph(tester, adapted);
      final reference = _paragraph(tester, stock);
      expect(actual.text, reference.text);
      expect(actual.size, reference.size);
      final range = TextSelection(
        baseOffset: 0,
        extentOffset: actual.text.toPlainText().length,
      );
      expect(
        actual
            .getBoxesForSelection(
              range,
              boxHeightStyle: ui.BoxHeightStyle.tight,
            )
            .map((box) => box.toRect()),
        reference.getBoxesForSelection(range).map((box) => box.toRect()),
      );
    });
  }

  for (final direction in TextDirection.values) {
    testWidgets('keeps inline-widget copy order in $direction text', (
      tester,
    ) async {
      const span = TextSpan(
        style: TextStyle(fontSize: 17, height: 1.29),
        children: [
          TextSpan(text: 'Lantern فانوس '),
          WidgetSpan(child: Text('ribbon')),
          TextSpan(text: ' blue أزرق'),
        ],
      );
      final selected = <String?>[null, null];
      await tester.pumpWidget(
        _harness(
          direction: direction,
          child: Column(
            children: [
              SelectionArea(
                key: const ValueKey('adapted-selection'),
                onSelectionChanged: (content) =>
                    selected[0] = content?.plainText,
                contextMenuBuilder: (context, state) => const SizedBox.shrink(),
                child: const SizedBox(width: 300, child: MarkdownText(span)),
              ),
              SelectionArea(
                key: const ValueKey('stock-selection'),
                onSelectionChanged: (content) =>
                    selected[1] = content?.plainText,
                contextMenuBuilder: (context, state) => const SizedBox.shrink(),
                child: const SizedBox(width: 300, child: Text.rich(span)),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final element in find.byType(SelectableRegion).evaluate()) {
        final state =
            (element as StatefulElement).state as SelectableRegionState;
        state.selectAll(SelectionChangedCause.toolbar);
        await tester.pumpAndSettle();
      }
      expect(selected[0], isNotNull);
      expect(selected[0], selected[1]);
      for (final (index, key) in [
        const ValueKey('adapted-selection'),
        const ValueKey('stock-selection'),
      ].indexed) {
        final container = tester.widget<SelectionContainer>(
          find
              .descendant(
                of: find.byKey(key),
                matching: find.byType(SelectionContainer),
              )
              .first,
        );
        container.delegate!.dispatchSelectionEvent(const ClearSelectionEvent());
        final paragraph = _paragraph(tester, key);
        container.delegate!.dispatchSelectionEvent(
          SelectParagraphSelectionEvent(
            globalPosition: paragraph.localToGlobal(const Offset(5, 8)),
          ),
        );
        await tester.pumpAndSettle();
        selected[index] = container.delegate!.getSelectedContent()?.plainText;
      }
      expect(selected[0], isNotNull);
      expect(
        selected[0],
        selected[1],
        reason: 'Paragraph selection must retain stock behavior.',
      );
    });
  }

  testWidgets('uses stock text selection on Android', (tester) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
    const scope = ValueKey('text');
    await tester.pumpWidget(
      _harness(
        platform: TargetPlatform.android,
        child: const SelectionArea(
          child: SizedBox(key: scope, width: 300, child: MarkdownText(_span)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(MarkdownText),
        matching: find.byWidgetPredicate(
          (widget) => widget is SelectionContainer && widget.child is Text,
        ),
      ),
      findsNothing,
    );
  });
}
