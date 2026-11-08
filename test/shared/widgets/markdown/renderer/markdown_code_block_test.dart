import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/markdown/markdown_config.dart';
import 'package:conduit/shared/widgets/markdown/renderer/block_renderer.dart';
import 'package:conduit/shared/widgets/markdown/renderer/conduit_markdown_widget.dart';
import 'package:conduit/shared/widgets/markdown/renderer/horizontal_overflow_fade.dart';
import 'package:conduit/shared/widgets/markdown/renderer/markdown_style.dart';
import 'package:conduit/shared/widgets/web_content_embed.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('iOS code copy confirms in place with a light haptic', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
    PlatformUiCapabilities.debugNativeIOS26Override = false;
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);
    final copied = <String>[];
    final haptics = <Object?>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      } else if (call.method == 'HapticFeedback.vibrate') {
        haptics.add(call.arguments);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    const sample = 'print("sample");';
    await tester.pumpWidget(
      ProviderScope(
        child: CupertinoApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => LegacyDesignCompatibility(child: child!),
          home: const CupertinoPageScaffold(
            child: ConduitMarkdownWidget(data: '```dart\n$sample\n```'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(ConduitMarkdownWidget));
    expect(ScaffoldMessenger.maybeOf(context), isNull);
    final copiedLabel = AppLocalizations.of(context)!.codeCopied;

    // The fenced block's trailing newline is not part of the copied code.
    await tester.tap(find.byIcon(CupertinoIcons.doc_on_doc));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(copied.single, sample);
    expect(haptics, ['HapticFeedbackType.lightImpact']);
    expect(tester.takeException(), isNull);
    expect(find.text(copiedLabel), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.checkmark_alt), findsOneWidget);

    await tester.pump(CodeBlockHeader.copiedConfirmationDuration);
    await tester.pumpAndSettle();
    expect(find.text(copiedLabel), findsNothing);
    expect(find.byIcon(CupertinoIcons.doc_on_doc), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  Widget buildHarness(
    String data, {
    MarkdownHeavyBlockPolicy heavyBlockPolicy = MarkdownHeavyBlockPolicy.eager,
  }) {
    return ProviderScope(
      child: MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: ConduitMarkdownWidget(
              data: data,
              heavyBlockPolicy: heavyBlockPolicy,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('inline SVG preview waits for eager heavy-block policy', (
    tester,
  ) async {
    const content = '```svg\n<svg><circle cx="5" cy="5" r="4" /></svg>\n```';

    await tester.pumpWidget(
      buildHarness(content, heavyBlockPolicy: MarkdownHeavyBlockPolicy.defer),
    );
    await tester.pumpAndSettle();
    expect(find.byType(WebContentEmbed), findsNothing);
    expect(find.textContaining('<svg>', findRichText: true), findsOneWidget);

    await tester.pumpWidget(buildHarness(content));
    await tester.pumpAndSettle();
    expect(find.byType(WebContentEmbed), findsNothing);
    expect(find.text('Load SVG preview'), findsOneWidget);

    await tester.tap(find.text('Load SVG preview'));
    await tester.pumpAndSettle();
    expect(find.byType(WebContentEmbed), findsOneWidget);
  });

  testWidgets('changed inline SVG requires a new explicit activation', (
    tester,
  ) async {
    const first = '```svg\n<svg><circle r="4" /></svg>\n```';
    const second = '```svg\n<svg><rect width="8" height="8" /></svg>\n```';

    await tester.pumpWidget(buildHarness(first));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Load SVG preview'));
    await tester.pumpAndSettle();
    expect(find.byType(WebContentEmbed), findsOneWidget);

    await tester.pumpWidget(buildHarness(second));
    await tester.pumpAndSettle();
    expect(find.byType(WebContentEmbed), findsNothing);
    expect(find.text('Load SVG preview'), findsOneWidget);
  });

  testWidgets('large JSON code blocks stay collapsed until expanded', (
    tester,
  ) async {
    final lines = <String>['{'];
    for (var index = 0; index < 68; index++) {
      lines.add('  "key$index": $index,');
    }
    lines.add('  "tail": true');
    lines.add('}');

    final content = ['```json', ...lines, '```'].join('\n');

    await tester.pumpWidget(buildHarness(content));
    await tester.pumpAndSettle();

    expect(find.textContaining('Show '), findsOneWidget);
    expect(find.textContaining('"key0"', findRichText: true), findsOneWidget);
    expect(find.textContaining('"key60"', findRichText: true), findsNothing);

    await tester.tap(find.textContaining('Show '));
    await tester.pumpAndSettle();

    expect(find.text('Show Less'), findsOneWidget);
    expect(find.textContaining('"key60"', findRichText: true), findsOneWidget);
  });

  testWidgets('highlighted code text respects system text scaling', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2.5)),
            child: const Scaffold(
              body: SingleChildScrollView(
                child: ConduitMarkdownWidget(
                  data: '```dart\nfinal x = 1;\n```',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scaledCodeRichText = tester
        .widgetList<RichText>(find.byType(RichText))
        .where((widget) => widget.text.toPlainText().contains('final x = 1;'));

    expect(scaledCodeRichText, isNotEmpty);
    expect(scaledCodeRichText.first.textScaler.scale(10), 25);
  });

  group('code block header and lines', () {
    const longLine =
        'print("a line long enough to run well past the right edge of the '
        'code block on any phone, so it has to scroll or wrap")';

    RenderParagraph codeParagraph(WidgetTester tester, String prefix) => tester
        .renderObjectList<RenderParagraph>(find.byType(RichText))
        .singleWhere(
          (paragraph) => paragraph.text.toPlainText().startsWith(prefix),
        );

    Finder wrapToggle() => find.byIcon(Icons.wrap_text_rounded);

    testWidgets('the header names the language properly', (tester) async {
      for (final (fence, label) in [
        ('python', 'Python'),
        ('js', 'JavaScript'),
        ('cpp', 'C++'),
        ('', 'Plain Text'),
      ]) {
        await tester.pumpWidget(buildHarness('```$fence\nx = 1\n```'));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(CodeBlockHeader),
            matching: find.text(label),
          ),
          findsOneWidget,
          reason: 'fence "$fence"',
        );
      }
    });

    testWidgets('code is regular weight with semibold keywords', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildHarness('```python\ndef total(rows):\n    return 1\n```'),
      );
      await tester.pumpAndSettle();

      final code = codeParagraph(tester, 'def total');
      final root = code.text.style!;
      expect(root.fontWeight, FontWeight.w400);
      expect(root.fontSize, 13);
      // The effective style of the run "def", inherited through nesting.
      TextStyle? styleOf(InlineSpan span, TextStyle inherited, String text) {
        if (span is! TextSpan) return null;
        final style = inherited.merge(span.style);
        if (span.text == text) return style;
        for (final child in span.children ?? const <InlineSpan>[]) {
          final found = styleOf(child, style, text);
          if (found != null) return found;
        }
        return null;
      }

      expect(
        styleOf(code.text, const TextStyle(), 'def')?.fontWeight,
        FontWeight.w600,
      );
      expect(
        styleOf(code.text, const TextStyle(), 'total')?.fontWeight,
        FontWeight.w400,
      );
    });

    Finder overflowFade() => find.descendant(
      of: find.byType(CodeBlockCard),
      matching: find.byType(HorizontalOverflowFade),
    );
    // The fade's state exposes its edges and indicator opacity for tests.
    dynamic fadeState(WidgetTester tester) => tester.state(overflowFade());
    Color indicatorColor(WidgetTester tester) => ConduitMarkdownStyle.fromTheme(
      tester.element(find.byType(CodeBlockCard)),
    ).scrollIndicatorColor;

    testWidgets('short lines show no wrap toggle or scroll indicator', (
      tester,
    ) async {
      await tester.pumpWidget(buildHarness('```python\nx = 1\n```'));
      await tester.pumpAndSettle();

      expect(wrapToggle(), findsNothing);
      expect(overflowFade(), isNot(paints..rrect()));
      expect((fadeState(tester).edges as HorizontalFadeEdges).isFading, false);
    });

    testWidgets('a long line fades out inside the padding, not at the edge', (
      tester,
    ) async {
      await tester.pumpWidget(buildHarness('```python\n$longLine\n```'));
      await tester.pumpAndSettle();

      final fade = tester.widget<HorizontalOverflowFade>(overflowFade());
      // Clear of the card's edge by the code's own padding, then a short
      // fade, so no glyph is cut at the border.
      final code = codeParagraph(tester, 'print(');
      final card = tester.getRect(find.byType(CodeBlockCard));
      final padding = code.localToGlobal(Offset.zero).dx - card.left;
      expect(fade.edgeInset, closeTo(padding, 1));
      expect(fade.fadeExtent, inInclusiveRange(8, 12));
      final edges = fadeState(tester).edges as HorizontalFadeEdges;
      expect(edges.right, 1);
      expect(edges.left, 0);

      // Scrolled to the end, the fade moves to the leading edge.
      await tester.dragFrom(card.center, const Offset(-2000, 0));
      await tester.pumpAndSettle();
      final scrolled = fadeState(tester).edges as HorizontalFadeEdges;
      expect(scrolled.right, 0);
      expect(scrolled.left, 1);

      // The last line keeps its bottom padding above the card's edge.
      final text = codeParagraph(tester, 'print(');
      final textBottom = text.localToGlobal(Offset(0, text.size.height)).dy;
      expect(card.bottom - textBottom, inInclusiveRange(11, 13));
    });

    testWidgets(
      'the indicator shows on appear and while scrolling, then hides',
      (tester) async {
        await tester.pumpWidget(buildHarness('```python\n$longLine\n```'));
        // It flashes once when the long line first overflows.
        var flashed = false;
        for (var i = 0; i < 40 && !flashed; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          if (overflowFade().evaluate().isNotEmpty &&
              (fadeState(tester).scrollIndicatorOpacity as double) >= 1) {
            flashed = true;
            expect(
              overflowFade(),
              paints..rrect(color: indicatorColor(tester)),
            );
          }
        }
        expect(flashed, isTrue);
        await tester.pumpAndSettle();
        expect(fadeState(tester).scrollIndicatorOpacity, 0);
        expect(overflowFade(), isNot(paints..rrect()));

        // Held visible for as long as a drag lasts.
        final card = tester.getRect(find.byType(CodeBlockCard));
        final gesture = await tester.startGesture(card.center);
        await gesture.moveBy(const Offset(-40, 0));
        await tester.pump();
        await gesture.moveBy(const Offset(-40, 0));
        await tester.pump(const Duration(milliseconds: 200));
        expect(fadeState(tester).scrollIndicatorOpacity, 1);
        await tester.pump(const Duration(seconds: 3));
        expect(fadeState(tester).scrollIndicatorOpacity, 1);
        final thumb = overflowFade();
        expect(thumb, paints..rrect(color: indicatorColor(tester)));

        // Lingers briefly after the content settles, then fades away.
        await gesture.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(fadeState(tester).scrollIndicatorOpacity, 1);
        await tester.pumpAndSettle();
        expect(fadeState(tester).scrollIndicatorOpacity, 0);
        expect(overflowFade(), isNot(paints..rrect()));
      },
    );

    testWidgets('the indicator is thin and clear of the last line', (
      tester,
    ) async {
      await tester.pumpWidget(buildHarness('```python\n$longLine\n```'));
      await tester.pumpAndSettle();

      final box = tester.renderObject<RenderBox>(overflowFade());
      final code = codeParagraph(tester, 'print(');
      final textBottom = code
          .localToGlobal(Offset(0, code.size.height), ancestor: box)
          .dy;
      const thickness = HorizontalOverflowFade.scrollIndicatorThickness;
      expect(thickness, lessThanOrEqualTo(3));
      final thumbTop =
          box.size.height -
          HorizontalOverflowFade.scrollIndicatorBottomGap -
          thickness;
      expect(thumbTop - textBottom, greaterThanOrEqualTo(6));
    });

    testWidgets('a long line can wrap', (tester) async {
      await tester.pumpWidget(buildHarness('```python\n$longLine\n```'));
      await tester.pumpAndSettle();

      final card = tester.getRect(find.byType(CodeBlockCard));
      final unwrapped = codeParagraph(tester, 'print(');
      expect(unwrapped.size.width, greaterThan(card.width));
      expect(wrapToggle(), findsOneWidget);
      expect(
        tester.getSemantics(wrapToggle()),
        matchesSemantics(
          label: 'Wrap Lines',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasToggledState: true,
          isToggled: false,
          hasTapAction: true,
        ),
      );

      await tester.tap(wrapToggle());
      await tester.pumpAndSettle();

      final wrapped = codeParagraph(tester, 'print(');
      expect(wrapped.size.width, lessThan(card.width));
      expect(wrapped.size.height, greaterThan(unwrapped.size.height * 2));
      expect(
        find.descendant(
          of: find.byType(CodeBlockCard),
          matching: find.byType(SingleChildScrollView),
        ),
        findsNothing,
      );
      // The toggle stays so the lines can be unwrapped again.
      expect(wrapToggle(), findsOneWidget);

      await tester.tap(wrapToggle());
      await tester.pumpAndSettle();
      expect(
        codeParagraph(tester, 'print(').size.width,
        greaterThan(card.width),
      );
    });

    testWidgets('wrapped lines continue under their own indentation', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildHarness(
          '```python\ndef plan():\n    $longLine\n\n    return 1\n```',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(wrapToggle());
      await tester.pumpAndSettle();

      final header = codeParagraph(tester, 'def plan');
      final body = codeParagraph(tester, 'print(');
      final tail = codeParagraph(tester, 'return 1');
      final column = header.text.style!.fontSize!; // Ahem: 1em per glyph.
      double left(RenderParagraph p) => p.localToGlobal(Offset.zero).dx;
      // The indented line and every wrapped continuation of it start four
      // columns in, not back at the left edge.
      expect(left(body) - left(header), closeTo(column * 4, 0.5));
      expect(body.size.height, greaterThan(column * 2));
      expect(left(tail), closeTo(left(body), 0.5));
      // The blank line between them keeps a line of space.
      expect(
        tail.localToGlobal(Offset.zero).dy -
            (body.localToGlobal(Offset.zero).dy + body.size.height),
        greaterThan(column),
      );
    });
  });
}
