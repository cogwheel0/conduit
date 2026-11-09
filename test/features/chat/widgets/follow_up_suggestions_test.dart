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

  testWidgets('highlights on press-down and clears on release', (tester) async {
    await tester.pumpWidget(
      _buildHarness(
        FollowUpSuggestionBar(
          suggestions: const ['First'],
          onSelected: (_) {},
          isBusy: false,
        ),
      ),
    );

    final highlightFinder = find.byKey(
      const ValueKey<String>('follow-up-highlight:First'),
    );
    ShapeDecoration decoration() =>
        tester.widget<AnimatedContainer>(highlightFinder).decoration!
            as ShapeDecoration;
    double fillAlpha() => decoration().color!.a;
    final restAlpha = fillAlpha();
    // At rest the row is an outline with no fill: an option to tap, not a
    // sent message, which sits on a fill.
    expect(restAlpha, 0);
    final side = (decoration().shape as RoundedSuperellipseBorder).side;
    expect(side.width, FollowUpSuggestionRow.outlineWidth);
    expect(side.color.a, greaterThan(0));

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('First')),
    );
    await tester.pump();
    expect(fillAlpha(), greaterThan(restAlpha));
    // Feedback lands with the finger, not after an animation.
    expect(
      tester.widget<AnimatedContainer>(highlightFinder).duration,
      Duration.zero,
    );

    await gesture.up();
    await tester.pump();
    expect(fillAlpha(), restAlpha);
  });

  testWidgets('a heading names the group and reads as a heading', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _buildHarness(
        // Inside a reply's own node, as in the chat, the heading still
        // stands alone instead of joining the reply's text.
        Semantics(
          container: true,
          label: 'The reply',
          child: FollowUpSuggestionBar(
            suggestions: const ['First'],
            onSelected: (_) {},
            isBusy: false,
          ),
        ),
      ),
    );

    expect(find.text('Suggestions'), findsOneWidget);
    final data = tester
        .getSemantics(find.text('Suggestions'))
        .getSemanticsData();
    expect(data.label, 'Suggestions');
    expect(data.flagsCollection.isHeader, isTrue);
    // The heading sits above the first suggestion, not beside it.
    expect(
      tester.getBottomLeft(find.text('Suggestions')).dy,
      lessThanOrEqualTo(
        tester
            .getTopLeft(
              find.byKey(const ValueKey<String>('follow-up-row:First')),
            )
            .dy,
      ),
    );
    semantics.dispose();
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
    // The row hugs its three lines: padding and outline around them.
    expect(
      tester.getSize(longRow).height,
      closeTo(
        paragraph.size.height +
            FollowUpSuggestionRow.padding.vertical +
            FollowUpSuggestionRow.outlineWidth * 2,
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

  testWidgets('suggestions are full-width rows led by a follow-up arrow, '
      'with even edges', (tester) async {
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
    // One radius for every row: a set of equal cards.
    final decoration =
        tester
                .widget<AnimatedContainer>(
                  find.byKey(
                    const ValueKey<String>('follow-up-highlight:Short'),
                  ),
                )
                .decoration!
            as ShapeDecoration;
    final shape = decoration.shape as RoundedSuperellipseBorder;
    expect(
      (shape.borderRadius as BorderRadius).topLeft.x,
      FollowUpSuggestionRow.cornerRadius,
    );
    // The glyph leads the words.
    final glyph = find.descendant(of: row, matching: find.byType(Icon));
    expect(glyph, findsOneWidget);
    expect(
      tester.getCenter(glyph).dx,
      lessThan(tester.getTopLeft(find.text('Short')).dx),
    );
  });

  testWidgets('suggestions read as live buttons: label-colour text and a '
      'secondary arrow, both dimmed while a reply runs', (tester) async {
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
    expect(textColor(), theme.textPrimary);
    expect(glyphColor(), theme.textSecondary);
    // The heading stays a quieter, smaller label above the rows.
    final heading = tester.widget<Text>(find.text('Suggestions'));
    expect(heading.style!.color, theme.textSecondary);
    expect(
      heading.style!.fontWeight!.value,
      greaterThan(FontWeight.w500.value),
    );

    await pumpBar(isBusy: true);
    expect(textColor().a, lessThan(theme.textPrimary.a));
    expect(glyphColor().a, lessThan(theme.textSecondary.a));
  });

  testWidgets('suggestions keep an even gap between them', (tester) async {
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
    expect(gap1, FollowUpSuggestionBar.rowGap);
    expect(gap2, FollowUpSuggestionBar.rowGap);
  });
}
