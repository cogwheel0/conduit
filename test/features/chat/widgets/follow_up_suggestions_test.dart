import 'dart:ui' show Tristate;

import 'package:conduit/features/chat/widgets/follow_up_suggestions.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildHarness(Widget child, {bool disableAnimations = false}) {
  return MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
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

  testWidgets('highlights on press-down and clears on release', (
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

    final highlightFinder = find.byKey(
      const ValueKey<String>('follow-up-highlight:First'),
    );
    double highlightAlpha() =>
        ((tester.widget<AnimatedContainer>(highlightFinder).decoration!
                    as BoxDecoration)
                .color!)
            .a;
    expect(highlightAlpha(), 0);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('First')),
    );
    await tester.pump();
    expect(highlightAlpha(), greaterThan(0));
    // Feedback lands with the finger, not after an animation.
    expect(
      tester.widget<AnimatedContainer>(highlightFinder).duration,
      Duration.zero,
    );

    await gesture.up();
    await tester.pump();
    expect(highlightAlpha(), 0);
  });

  testWidgets('rows are at least 44 pt tall and show the whole suggestion', (
    tester,
  ) async {
    const long =
        'Give me a 30-minute wind-down routine I can follow nightly, with '
        'step-by-step timings and what to skip on busy evenings';
    await tester.pumpWidget(
      _buildHarness(
        SizedBox(
          width: 320,
          child: FollowUpSuggestionBar(
            suggestions: const ['Short', long],
            onSelected: (_) {},
            isBusy: false,
          ),
        ),
      ),
    );

    final shortRow = find.byKey(const ValueKey<String>('follow-up-row:Short'));
    expect(tester.getSize(shortRow).height, greaterThanOrEqualTo(44));

    final longText = tester.widget<Text>(find.text(long));
    expect(longText.maxLines, isNull);
    expect(longText.overflow, isNot(TextOverflow.ellipsis));
    // Wrapped, not cut: several lines tall.
    expect(tester.getSize(find.text(long)).height, greaterThan(50));
  });

  testWidgets('the reply glyph sits on the first line of a wrapped row', (
    tester,
  ) async {
    const long =
        'Suggest a simple seven-day schedule for someone aiming for an '
        'earlier bedtime, including weekends and a nap plan';
    await tester.pumpWidget(
      _buildHarness(
        SizedBox(
          width: 300,
          child: FollowUpSuggestionBar(
            suggestions: const [long],
            onSelected: (_) {},
            isBusy: false,
          ),
        ),
      ),
    );

    final row = find.byKey(const ValueKey<String>('follow-up-row:$long'));
    final glyph = find.descendant(of: row, matching: find.byType(Icon));
    final text = find.text(long);
    final glyphCenter = tester.getCenter(glyph).dy;
    final textTop = tester.getTopLeft(text).dy;
    final textHeight = tester.getSize(text).height;
    expect(textHeight, greaterThan(40));
    // Within the first line, well above the text block's centre.
    expect(glyphCenter, lessThan(textTop + 24));
  });
}
