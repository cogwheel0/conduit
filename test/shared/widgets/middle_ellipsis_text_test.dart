import 'package:conduit/shared/widgets/middle_ellipsis_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MiddleEllipsisText', () {
    testWidgets('renders short text without error', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: MiddleEllipsisText('Hello'),
            ),
          ),
        ),
      );

      expect(find.text('Hello'), findsOneWidget);
    });

    testWidgets('renders with semantics label', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: MiddleEllipsisText(
                'Hello',
                semanticsLabel: 'Greeting text',
              ),
            ),
          ),
        ),
      );

      // The Text widget inside uses semanticsLabel, which we can
      // verify by finding the widget via its semantics label.
      expect(
        find.bySemanticsLabel('Greeting text'),
        findsOneWidget,
      );
    });

    testWidgets('handles empty text without throwing', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: MiddleEllipsisText(''),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(MiddleEllipsisText), findsOneWidget);
    });

    testWidgets('widget can be found by type', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: MiddleEllipsisText('Test'),
            ),
          ),
        ),
      );

      expect(find.byType(MiddleEllipsisText), findsOneWidget);
    });
  });
}
