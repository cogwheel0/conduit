import 'dart:ui' show Tristate;

import 'package:conduit/features/chat/widgets/follow_up_suggestions.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/material.dart';
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

  testWidgets('responds on press-down and reverses on release', (tester) async {
    await tester.pumpWidget(
      _buildHarness(
        FollowUpSuggestionBar(
          suggestions: const ['First'],
          onSelected: (_) {},
          isBusy: false,
        ),
      ),
    );

    final scaleFinder = find.byKey(
      const ValueKey<String>('follow-up-press-scale:First'),
    );
    expect(tester.widget<AnimatedScale>(scaleFinder).scale, 1);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('First')),
    );
    await tester.pump();
    expect(tester.widget<AnimatedScale>(scaleFinder).scale, 0.98);

    await gesture.up();
    await tester.pump();
    expect(tester.widget<AnimatedScale>(scaleFinder).scale, 1);
  });

  testWidgets('reduced motion keeps press feedback spatially static', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildHarness(
        FollowUpSuggestionBar(
          suggestions: const ['First'],
          onSelected: (_) {},
          isBusy: false,
        ),
        disableAnimations: true,
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('First')),
    );
    await tester.pump();
    final scale = tester.widget<AnimatedScale>(
      find.byKey(const ValueKey<String>('follow-up-press-scale:First')),
    );
    expect(scale.scale, 1);
    expect(scale.duration, Duration.zero);
    await gesture.up();
  });
}
