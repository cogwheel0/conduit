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
    // The same two squares as the reply actions' Copy.
    await tester.tap(find.byIcon(CupertinoIcons.square_on_square));
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
    expect(find.byIcon(CupertinoIcons.square_on_square), findsOneWidget);
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

    // The code's paragraphs (not the header's), top to bottom.
    List<RenderParagraph> codeParagraphs(WidgetTester tester) {
      final header = tester
          .renderObjectList<RenderParagraph>(
            find.descendant(
              of: find.byType(CodeBlockHeader),
              matching: find.byType(RichText),
            ),
          )
          .toSet();
      return tester
          .renderObjectList<RenderParagraph>(
            find.descendant(
              of: find.byType(CodeBlockCard),
              matching: find.byType(RichText),
            ),
          )
          .where((paragraph) => !header.contains(paragraph))
          .toList()
        ..sort(
          (a, b) => a
              .localToGlobal(Offset.zero)
              .dy
              .compareTo(b.localToGlobal(Offset.zero).dy),
        );
    }

    // The paragraph right below [paragraph] in the code.
    RenderParagraph nextParagraph(
      WidgetTester tester,
      RenderParagraph paragraph,
    ) {
      final paragraphs = codeParagraphs(tester);
      return paragraphs[paragraphs.indexOf(paragraph) + 1];
    }

    double left(RenderParagraph p) => p.localToGlobal(Offset.zero).dx;
    double top(RenderParagraph p) => p.localToGlobal(Offset.zero).dy;
    double bottom(RenderParagraph p) =>
        p.localToGlobal(Offset(0, p.size.height)).dy;

    Finder wrapToggle() => find.byIcon(Icons.wrap_text_rounded);
    Finder codeScrollView() => find.descendant(
      of: find.byType(CodeBlockCard),
      matching: find.byType(SingleChildScrollView),
    );

    // An iPhone 17 Pro's window: compact.
    void usePhoneWindow(WidgetTester tester) {
      tester.view.physicalSize = const Size(1206, 2622);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
    }

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
      // Clear of the card's edge by the code's own padding, then a fade a
      // few characters wide, so a cut line visibly runs on rather than
      // stopping flush at the padding.
      final code = codeParagraph(tester, 'print(');
      final card = tester.getRect(find.byType(CodeBlockCard));
      final padding = code.localToGlobal(Offset.zero).dx - card.left;
      expect(fade.edgeInset, closeTo(padding, 1));
      expect(fade.fadeExtent, greaterThanOrEqualTo(20));
      final edges = fadeState(tester).edges as HorizontalFadeEdges;
      expect(edges.right, 1);
      expect(edges.left, 0);

      // Scrolled to the end, the fade moves to the leading edge, and the
      // line's end rests as far from the card's edge as the trailing fade
      // stays clear of it.
      await tester.dragFrom(
        tester.getCenter(overflowFade()),
        const Offset(-2000, 0),
      );
      await tester.pumpAndSettle();
      final scrolled = fadeState(tester).edges as HorizontalFadeEdges;
      expect(scrolled.right, 0);
      expect(scrolled.left, 1);
      final text = codeParagraph(tester, 'print(');
      final textEnd = text.localToGlobal(Offset(text.size.width, 0)).dx;
      expect(fade.endEdgeInset, closeTo(card.right - textEnd, 1));
      expect(fade.endEdgeInset, greaterThan(padding));
    });

    testWidgets('lines keep their leading between them, not around them', (
      tester,
    ) async {
      // One and three lines, unwrapped and wrapped. (The vertical rhythm
      // tests own the padding itself.)
      final gaps = <String, (double, double)>{};
      for (final wrap in [false, true]) {
        final heights = <int, double>{};
        for (final lines in [1, 3]) {
          final source = [
            longLine,
            for (var i = 1; i < lines; i++) 'x = $i',
          ].join('\n');
          // A fresh card each time, unwrapped.
          await tester.pumpWidget(const SizedBox());
          await tester.pumpWidget(buildHarness('```python\n$source\n```'));
          await tester.pumpAndSettle();
          if (wrap) {
            await tester.tap(wrapToggle());
            await tester.pumpAndSettle();
          }
          final header = tester.getRect(find.byType(CodeBlockHeader));
          final card = tester.getRect(find.byType(CodeBlockCard));
          // Unwrapped code is one paragraph; wrapped code one per line,
          // and a wrapped line's continuation another.
          final paragraphs = codeParagraphs(tester);
          final first = paragraphs.first;
          final last = paragraphs.last;
          expect(first.text.toPlainText(), startsWith('print('));
          final codeTop = top(first);
          final codeBottom = bottom(last);
          gaps['$wrap/$lines'] = (
            codeTop - header.bottom,
            card.bottom - codeBottom,
          );
          heights[lines] = wrap ? codeBottom - codeTop : first.size.height;
        }
        final style = codeParagraph(tester, 'print(').text.style!;
        final lineHeight = style.fontSize! * style.height!;
        if (!wrap) {
          // No line's worth of leading above the first line or below the
          // last, where it read as a blank line under the header.
          expect(heights[1], lessThan(lineHeight));
        }
        // Between lines the pitch is unchanged (within the paragraph's
        // rounding of each line's height).
        expect(
          heights[3]! - heights[1]!,
          closeTo(lineHeight * 2, 1.5),
          reason: 'wrap: $wrap',
        );
      }
      // Wrapped code sits in the card exactly as unwrapped code does.
      for (final lines in [1, 3]) {
        final (top, bottom) = gaps['false/$lines']!;
        final (wrappedTop, wrappedBottom) = gaps['true/$lines']!;
        expect(wrappedTop, closeTo(top, 0.5), reason: 'lines: $lines');
        expect(wrappedBottom, closeTo(bottom, 0.5), reason: 'lines: $lines');
      }
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
        final gesture = await tester.startGesture(
          tester.getCenter(overflowFade()),
        );
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
      // Clear of the last line's descenders.
      expect(thumbTop - textBottom, greaterThanOrEqualTo(4));
    });

    testWidgets('the indicator flashes when the block first comes into view', (
      tester,
    ) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SingleChildScrollView(
                controller: scroll,
                child: const Column(
                  children: [
                    SizedBox(height: 2000),
                    ConduitMarkdownWidget(
                      data: '```python\n$longLine\n```',
                      heavyBlockPolicy: MarkdownHeavyBlockPolicy.eager,
                    ),
                    SizedBox(height: 2000),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Laid out below the fold: it overflows, but nobody saw a flash.
      expect((fadeState(tester).edges as HorizontalFadeEdges).right, 1);
      expect(fadeState(tester).scrollIndicatorOpacity, 0);

      // Scrolled into view, it shows where the line sits, then hides.
      scroll.jumpTo(1700);
      await tester.pump();
      var flashed = false;
      for (var i = 0; i < 20 && !flashed; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        flashed = (fadeState(tester).scrollIndicatorOpacity as double) >= 1;
      }
      expect(flashed, isTrue);
      await tester.pumpAndSettle();
      expect(fadeState(tester).scrollIndicatorOpacity, 0);

      // Only the first time.
      scroll.jumpTo(0);
      await tester.pump();
      scroll.jumpTo(1700);
      await tester.pump(const Duration(milliseconds: 300));
      expect(fadeState(tester).scrollIndicatorOpacity, 0);
    });

    testWidgets('the indicator waits for a hidden view to show', (
      tester,
    ) async {
      // Like a transcript kept invisible until it settles at its position.
      final hidden = ValueNotifier(true);
      addTearDown(hidden.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: hidden,
                builder: (context, isHidden, child) =>
                    Opacity(opacity: isHidden ? 0 : 1, child: child),
                child: const SingleChildScrollView(
                  child: ConduitMarkdownWidget(
                    data: '```python\n$longLine\n```',
                    heavyBlockPolicy: MarkdownHeavyBlockPolicy.eager,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect((fadeState(tester).edges as HorizontalFadeEdges).right, 1);
      expect(fadeState(tester).scrollIndicatorOpacity, 0);

      hidden.value = false;
      await tester.pump();
      var flashed = false;
      for (var i = 0; i < 20 && !flashed; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        flashed = (fadeState(tester).scrollIndicatorOpacity as double) >= 1;
      }
      expect(flashed, isTrue);
    });

    testWidgets('a card showing another block takes that block\'s choice', (
      tester,
    ) async {
      // The test window is wide, so lines scroll unless a reader wraps them.
      final stateId = ValueNotifier<String>('block-a');
      addTearDown(stateId.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SingleChildScrollView(
                child: ValueListenableBuilder<String>(
                  valueListenable: stateId,
                  builder: (context, id, _) => CodeBlockCard(
                    code: longLine,
                    language: 'python',
                    stateId: id,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(wrapToggle());
      await tester.pumpAndSettle();
      expect(codeScrollView(), findsNothing, reason: 'block a wraps');

      stateId.value = 'block-b';
      await tester.pumpAndSettle();
      expect(codeScrollView(), findsOneWidget, reason: 'block b scrolls');

      stateId.value = 'block-a';
      await tester.pumpAndSettle();
      expect(codeScrollView(), findsNothing, reason: 'block a wraps again');
    });

    testWidgets('a long line can wrap in a wide window', (tester) async {
      // The test window is 800 pt wide: wide, so lines scroll by default.
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

      // The line's first row, then its continuation below it.
      final head = codeParagraph(tester, 'print(');
      final tail = nextParagraph(tester, head);
      expect(
        head.text.toPlainText() + tail.text.toPlainText(),
        longLine,
        reason: 'the line is split once, losing nothing',
      );
      expect(head.size.width, lessThan(card.width));
      expect(tail.size.width, lessThan(card.width));
      expect(
        head.size.height + tail.size.height,
        greaterThan(unwrapped.size.height * 2),
      );
      expect(codeScrollView(), findsNothing);
      // The toggle stays, now on, so the lines can be unwrapped again.
      expect(wrapToggle(), findsOneWidget);
      expect(
        tester.getSemantics(wrapToggle()),
        matchesSemantics(
          label: 'Wrap Lines',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasToggledState: true,
          isToggled: true,
          hasTapAction: true,
        ),
      );

      await tester.tap(wrapToggle());
      await tester.pumpAndSettle();
      expect(
        codeParagraph(tester, 'print(').size.width,
        greaterThan(card.width),
      );
    });

    testWidgets('wrapped lines hang under their own indentation', (
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
      final continuation = nextParagraph(tester, body);
      final tail = codeParagraph(tester, 'return 1');
      final column = header.text.style!.fontSize!; // Ahem: 1em per glyph.
      // The indented line starts four columns in, and its continuation two
      // further, so it reads as the same statement rather than the next.
      expect(left(body) - left(header), closeTo(column * 4, 0.5));
      expect(left(continuation) - left(body), closeTo(column * 2, 0.5));
      expect(top(continuation), closeTo(bottom(body), 0.5));
      // The next line starts back at the indentation.
      expect(left(tail), closeTo(left(body), 0.5));
      // The blank line between them keeps a line of space.
      expect(top(tail) - bottom(continuation), greaterThan(column));
    });

    testWidgets('a continuation is marked, so it never reads as nested code', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildHarness('```python\ndef plan():\n    $longLine\n    x = 1\n```'),
      );
      await tester.pumpAndSettle();
      final marks = find.byKey(
        const ValueKey<String>('code-continuation-mark'),
      );
      // Lines that fit carry no mark.
      expect(marks, findsNothing);
      await tester.tap(wrapToggle());
      await tester.pumpAndSettle();

      // Only the wrapped line's continuation is marked, in the hang between
      // the line's indentation and its continued text.
      expect(marks, findsOneWidget);
      final body = codeParagraph(tester, 'print(');
      final continuation = nextParagraph(tester, body);
      final mark = tester.getRect(marks);
      expect(mark.left, closeTo(left(body), 0.5));
      expect(mark.right, closeTo(left(continuation), 0.5));
      expect(mark.top, closeTo(top(continuation), 0.5));
      expect(mark.bottom, closeTo(bottom(continuation), 0.5));
      // It is not code: no text to read out or copy.
      for (final paragraph in codeParagraphs(tester)) {
        expect(paragraph.text.toPlainText(), isNot(contains('\u21B3')));
      }
      expect(
        find.descendant(of: marks, matching: find.byType(RichText)),
        findsNothing,
      );
    });

    testWidgets('code wraps by default in a phone window', (tester) async {
      usePhoneWindow(tester);
      await tester.pumpWidget(
        buildHarness('```python\ndef plan():\n    $longLine\n```'),
      );
      await tester.pumpAndSettle();

      final card = tester.getRect(find.byType(CodeBlockCard));
      expect(codeScrollView(), findsNothing);
      // No fade or indicator: nothing is hidden past an edge.
      expect(
        find.descendant(
          of: find.byType(CodeBlockCard),
          matching: find.byType(HorizontalOverflowFade),
        ),
        findsNothing,
      );
      for (final paragraph in codeParagraphs(tester)) {
        expect(
          paragraph.localToGlobal(Offset(paragraph.size.width, 0)).dx,
          lessThanOrEqualTo(card.right),
        );
      }
      // The toggle shows wrapping on, and turns it off for this block.
      expect(
        tester.getSemantics(wrapToggle()),
        matchesSemantics(
          label: 'Wrap Lines',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasToggledState: true,
          isToggled: true,
          hasTapAction: true,
        ),
      );
      await tester.tap(wrapToggle());
      await tester.pumpAndSettle();
      expect(codeScrollView(), findsOneWidget);
      expect(
        codeParagraph(tester, 'def plan').size.width,
        greaterThan(card.width),
      );
    });

    testWidgets('a phone window shows no toggle when every line fits', (
      tester,
    ) async {
      usePhoneWindow(tester);
      await tester.pumpWidget(buildHarness('```python\nx = 1\n```'));
      await tester.pumpAndSettle();
      expect(codeScrollView(), findsNothing);
      expect(wrapToggle(), findsNothing);
    });

    testWidgets('a block keeps its wrap choice when it scrolls back', (
      tester,
    ) async {
      usePhoneWindow(tester);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ListView(
                controller: scroll,
                children: const [
                  ConduitMarkdownWidget(
                    data: '```python\n$longLine\n```',
                    heavyBlockPolicy: MarkdownHeavyBlockPolicy.eager,
                    stateScopeId: 'message-1',
                  ),
                  SizedBox(height: 5000),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(wrapToggle());
      await tester.pumpAndSettle();
      expect(codeScrollView(), findsOneWidget);

      // Far enough that the list drops the block, then back.
      scroll.jumpTo(4000);
      await tester.pumpAndSettle();
      expect(find.byType(CodeBlockCard), findsNothing);
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(codeScrollView(), findsOneWidget);
    });

    testWidgets('Copy copies the source as written while lines wrap', (
      tester,
    ) async {
      usePhoneWindow(tester);
      final copied = <String>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      const source = 'def plan():\n\t$longLine\n\n    return 1';
      await tester.pumpWidget(buildHarness('```python\n$source\n```'));
      await tester.pumpAndSettle();
      expect(codeScrollView(), findsNothing);

      await tester.tap(find.byIcon(Icons.content_copy_rounded));
      await tester.pump();
      expect(copied.single, source);
      await tester.pumpAndSettle(CodeBlockHeader.copiedConfirmationDuration);
    });
  });
}
