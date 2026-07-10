import 'dart:ui' show Tristate;

import 'package:conduit/features/chat/widgets/follow_up_suggestions.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildHarness(Widget child, {bool disableAnimations = false}) {
  return MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(body: child),
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

  testWidgets('reveals follow-ups with a subtle staggered settle', (
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

    final firstFade = tester.widget<FadeTransition>(
      find.ancestor(
        of: find.text('First'),
        matching: find.byType(FadeTransition),
      ),
    );
    final firstSlide = tester.widget<SlideTransition>(
      find.ancestor(
        of: find.text('First'),
        matching: find.byType(SlideTransition),
      ),
    );
    final secondFade = tester.widget<FadeTransition>(
      find.ancestor(
        of: find.text('Second'),
        matching: find.byType(FadeTransition),
      ),
    );

    expect(firstFade.opacity.value, 0);
    expect(firstSlide.position.value.dy, closeTo(0.12, 0.001));
    expect(secondFade.opacity.value, 0);

    await tester.pump(const Duration(milliseconds: 90));

    expect(firstFade.opacity.value, greaterThan(secondFade.opacity.value));
    expect(firstSlide.position.value.dy, lessThan(0.12));

    await tester.pumpAndSettle();

    expect(firstFade.opacity.value, 1);
    expect(firstSlide.position.value, Offset.zero);
    expect(secondFade.opacity.value, 1);
  });

  testWidgets('reduced motion keeps the fade but removes position movement', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildHarness(
        FollowUpSuggestionBar(
          suggestions: const ['Ask a follow-up'],
          onSelected: (_) {},
          isBusy: false,
        ),
        disableAnimations: true,
      ),
    );

    final fade = tester.widget<FadeTransition>(
      find.ancestor(
        of: find.text('Ask a follow-up'),
        matching: find.byType(FadeTransition),
      ),
    );
    final slide = tester.widget<SlideTransition>(
      find.ancestor(
        of: find.text('Ask a follow-up'),
        matching: find.byType(SlideTransition),
      ),
    );

    expect(fade.opacity.value, 0);
    expect(slide.position.value, Offset.zero);

    await tester.pumpAndSettle();

    expect(fade.opacity.value, 1);
    expect(slide.position.value, Offset.zero);
  });
}
