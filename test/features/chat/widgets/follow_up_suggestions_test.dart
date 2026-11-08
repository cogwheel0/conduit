import 'dart:ui' show Tristate;

import 'package:conduit/features/chat/widgets/follow_up_suggestions.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
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
    double fillAlpha() =>
        ((tester.widget<AnimatedContainer>(highlightFinder).decoration!
                    as ShapeDecoration)
                .color!)
            .a;
    final restAlpha = fillAlpha();
    // At rest the row already sits on a fill, so it reads as a button.
    expect(restAlpha, greaterThan(0));

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

  testWidgets('rows are at least 44 pt tall, smaller than the reply text, and '
      'stop after two lines while the full prompt stays readable', (
    tester,
  ) async {
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

    final longText = tester.widget<Text>(find.text(long));
    expect(longText.maxLines, 2);
    expect(longText.overflow, TextOverflow.ellipsis);
    // Secondary to the 17 pt answer above it.
    expect(longText.style!.fontSize, lessThan(17));
    final lineHeight = longText.style!.fontSize! * (longText.style!.height!);
    expect(
      tester.getSize(find.text(long)).height,
      lessThanOrEqualTo(lineHeight * 2 + 1),
    );

    // VoiceOver hears, and a tap sends, the whole suggestion.
    expect(find.bySemanticsLabel(long), findsOneWidget);
    await tester.tap(find.text(long));
    await tester.pump();
    expect(selected, long);
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
