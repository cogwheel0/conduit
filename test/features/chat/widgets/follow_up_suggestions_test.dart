import 'dart:ui' show Tristate;

import 'package:conduit/features/chat/widgets/follow_up_suggestions.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildHarness(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    home: Scaffold(body: child),
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
}
