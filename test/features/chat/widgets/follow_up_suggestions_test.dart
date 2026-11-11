import 'dart:ui' show Tristate;

import 'package:conduit/features/chat/widgets/follow_up_suggestions.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildHarness(Widget child, {bool disableAnimations = false}) {
  return MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: child,
      ),
    ),
  );
}

void main() {
  testWidgets('trims, filters, limits, and forwards follow-up taps', (
    tester,
  ) async {
    String? selected;

    await tester.pumpWidget(
      _buildHarness(
        FollowUpSuggestionBar(
          suggestions: const ['  First  ', ' ', 'Second', 'Third', 'Fourth'],
          onSelected: (value) => selected = value,
          isBusy: false,
        ),
      ),
    );

    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
    expect(find.text('Third'), findsOneWidget);
    expect(find.text('Fourth'), findsNothing);

    await tester.tap(find.text('First'));
    await tester.pump();

    expect(selected, 'First');
  });

  testWidgets('uses explicit button semantics and disables busy follow-ups', (
    tester,
  ) async {
    String? selected;

    await tester.pumpWidget(
      _buildHarness(
        FollowUpSuggestionBar(
          suggestions: const ['Ask a follow-up'],
          onSelected: (value) => selected = value,
          isBusy: true,
        ),
      ),
    );

    final semanticsFinder = find.bySemanticsLabel('Ask a follow-up');
    expect(semanticsFinder, findsOneWidget);

    final semantics = tester.getSemantics(semanticsFinder);
    final data = semantics.getSemanticsData();
    expect(data.label, 'Ask a follow-up');
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.flagsCollection.isEnabled, Tristate.isFalse);

    await tester.tap(find.text('Ask a follow-up'));
    await tester.pump();

    expect(selected, isNull);
  });

  testWidgets('renders follow-ups immediately without entrance motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildHarness(
        FollowUpSuggestionBar(
          suggestions: const ['First', 'Second'],
          onSelected: (_) {},
          isBusy: false,
        ),
      ),
    );

    final followUpBar = find.byType(FollowUpSuggestionBar);
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
    expect(
      find.descendant(of: followUpBar, matching: find.byType(FadeTransition)),
      findsNothing,
    );
    expect(
      find.descendant(of: followUpBar, matching: find.byType(SlideTransition)),
      findsNothing,
    );
  });

  testWidgets('dims its text on press-down and restores it on release', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildHarness(
        FollowUpSuggestionBar(
          suggestions: const ['First'],
          onSelected: (_) {},
          isBusy: false,
        ),
      ),
    );

    double textAlpha() =>
        tester.widget<Text>(find.text('First')).style!.color!.a;
    final restAlpha = textAlpha();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('First')),
    );
    // Feedback lands with the finger, not after an animation.
    await tester.pump();
    expect(
      textAlpha(),
      closeTo(restAlpha * FollowUpSuggestionRow.pressedOpacity, 0.01),
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(textAlpha(), restAlpha);
  });

  testWidgets('plain rows under the reply: no heading and no card', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildHarness(
        FollowUpSuggestionBar(
          suggestions: const ['First', 'Second'],
          onSelected: (_) {},
          isBusy: false,
        ),
      ),
    );

    final bar = find.byType(FollowUpSuggestionBar);
    expect(find.text('Suggestions'), findsNothing);
    // The first suggestion starts the list.
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey<String>('follow-up-row:First')))
          .dy,
      tester.getTopLeft(bar).dy,
    );
    // Nothing is drawn behind or around the rows.
    expect(
      find.descendant(of: bar, matching: find.byType(DecoratedBox)),
      findsNothing,
    );
    expect(
      find.descendant(of: bar, matching: find.byType(Container)),
      findsNothing,
    );
  });

  testWidgets('rows are at least 44 pt tall, secondary to the reply, and '
      'show three lines ending on a whole word while VoiceOver and a tap get '
      'the whole prompt', (tester) async {
    const long =
        'Give me a 30-minute wind-down routine I can follow nightly, with '
        'step-by-step timings, what to skip on busy evenings, and how to '
        'adjust it when travelling across time zones for work';
    String? selected;
    await tester.pumpWidget(
      _buildHarness(
        SizedBox(
          width: 320,
          child: FollowUpSuggestionBar(
            suggestions: const ['Short', long],
            onSelected: (value) => selected = value,
            isBusy: false,
          ),
        ),
      ),
    );

    final shortRow = find.byKey(const ValueKey<String>('follow-up-row:Short'));
    expect(tester.getSize(shortRow).height, greaterThanOrEqualTo(44));

    final longRow = find.byKey(ValueKey<String>('follow-up-row:$long'));
    final longText = tester.widget<Text>(
      find.descendant(of: longRow, matching: find.byType(Text)),
    );
    final shown = longText.data!;
    // Three lines at most, cut after a whole word of the prompt.
    expect(longText.maxLines, FollowUpSuggestionRow.maxLines);
    expect(FollowUpSuggestionRow.maxLines, 3);
    expect(shown, endsWith('…'));
    final kept = shown.substring(0, shown.length - 1);
    expect(long.startsWith(kept), isTrue);
    expect(long[kept.length], anyOf(' ', ','));
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.descendant(of: longRow, matching: find.byType(Text)),
        matching: find.byType(RichText),
      ),
    );
    // The word-boundary cut fits by itself; the text's own ellipsis is
    // never needed.
    expect(paragraph.didExceedMaxLines, isFalse);
    // Secondary to the 17 pt answer above it.
    expect(longText.style!.fontSize, lessThan(17));
    final lineHeight = longText.style!.fontSize! * (longText.style!.height!);
    expect((paragraph.size.height / lineHeight).round(), 3);
    // The row hugs its three lines, with its padding around them.
    expect(
      tester.getSize(longRow).height,
      closeTo(
        paragraph.size.height + FollowUpSuggestionRow.padding.vertical,
        0.5,
      ),
    );

    // VoiceOver hears, and a tap sends, the whole suggestion.
    expect(find.bySemanticsLabel(long), findsOneWidget);
    await tester.tap(longRow);
    await tester.pump();
    expect(selected, long);
  });

  test('a long suggestion is cut on a word boundary, never mid-word', () {
    const style = TextStyle(fontSize: 15, height: 20 / 15);
    const prompt =
        'Compare the trail options by elevation gain, shade, and water stops '
        'for a family hike with two small children in late summer';
    final clamped = followUpSuggestionClampedText(
      prompt,
      style: style,
      maxWidth: 200,
      maxLines: 3,
    );
    expect(clamped, endsWith('…'));
    final kept = clamped.substring(0, clamped.length - 1);
    expect(prompt.startsWith(kept), isTrue);
    // The next character in the prompt starts a new word.
    expect(prompt[kept.length], anyOf(' ', ','));
    // No dangling comma before the ellipsis.
    expect(kept, isNot(endsWith(',')));
    // What fits is left alone.
    expect(
      followUpSuggestionClampedText(
        'Pack list?',
        style: style,
        maxWidth: 200,
        maxLines: 3,
      ),
      'Pack list?',
    );
  });

  testWidgets('suggestions are full-width rows led by a follow-up arrow', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildHarness(
        SizedBox(
          width: 360,
          child: FollowUpSuggestionBar(
            suggestions: const ['Short', 'A somewhat longer suggestion'],
            onSelected: (_) {},
            isBusy: false,
          ),
        ),
      ),
    );

    final row = find.byKey(const ValueKey<String>('follow-up-row:Short'));
    final other = find.byKey(
      const ValueKey<String>('follow-up-row:A somewhat longer suggestion'),
    );
    final bar = tester.getRect(find.byType(FollowUpSuggestionBar));
    // Every row spans the column, so their edges line up.
    expect(tester.getRect(row).left, bar.left);
    expect(tester.getRect(row).right, bar.right);
    expect(tester.getRect(other).right, bar.right);
    // The glyph leads the words, on the reply's own leading edge.
    final glyph = find.descendant(of: row, matching: find.byType(Icon));
    expect(glyph, findsOneWidget);
    expect(tester.getTopLeft(glyph).dx, bar.left);
    expect(
      tester.getCenter(glyph).dx,
      lessThan(tester.getTopLeft(find.text('Short')).dx),
    );
  });

  testWidgets('suggestions read as offers: regular-weight text in a lighter '
      'tone of the button colour, fading further while a reply runs', (
    tester,
  ) async {
    Future<void> pumpBar({required bool isBusy}) => tester.pumpWidget(
      _buildHarness(
        SizedBox(
          width: 360,
          child: FollowUpSuggestionBar(
            suggestions: const ['Plan a week of dinners'],
            onSelected: (_) {},
            isBusy: isBusy,
          ),
        ),
      ),
    );
    final row = find.byKey(
      const ValueKey<String>('follow-up-row:Plan a week of dinners'),
    );
    Color textColor() => tester
        .widget<Text>(find.descendant(of: row, matching: find.byType(Text)))
        .style!
        .color!;
    Color glyphColor() => tester
        .widget<Icon>(find.descendant(of: row, matching: find.byType(Icon)))
        .color!;

    await pumpBar(isBusy: false);
    final theme = tester.element(row).conduitTheme;
    expect(
      textColor(),
      theme.buttonPrimary.withValues(
        alpha: theme.buttonPrimary.a * FollowUpSuggestionRow.textTone,
      ),
    );
    expect(
      glyphColor(),
      theme.buttonPrimary.withValues(
        alpha: theme.buttonPrimary.a * FollowUpSuggestionRow.glyphTone,
      ),
    );
    expect(
      tester
          .widget<Text>(find.descendant(of: row, matching: find.byType(Text)))
          .style!
          .fontWeight,
      FontWeight.w400,
    );

    final restText = textColor().a;
    final restGlyph = glyphColor().a;
    await pumpBar(isBusy: true);
    expect(textColor().a, lessThan(restText));
    expect(glyphColor().a, lessThan(restGlyph));
  });

  testWidgets('rows meet, so their 44 pt targets leave no dead gap', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildHarness(
        FollowUpSuggestionBar(
          suggestions: const ['First', 'Second', 'Third'],
          onSelected: (_) {},
          isBusy: false,
        ),
      ),
    );

    Rect rowRect(String label) =>
        tester.getRect(find.byKey(ValueKey<String>('follow-up-row:$label')));
    final gap1 = rowRect('Second').top - rowRect('First').bottom;
    final gap2 = rowRect('Third').top - rowRect('Second').bottom;
    expect(gap1, 0);
    expect(gap2, 0);
  });
}
