import 'package:conduit/shared/widgets/sheet_handle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SheetHandle', () {
    testWidgets('renders as a centered widget', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SheetHandle(),
          ),
        ),
      );

      expect(find.byType(Center), findsOneWidget);
    });

    testWidgets('widget can be found by type', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SheetHandle(),
          ),
        ),
      );

      expect(find.byType(SheetHandle), findsOneWidget);
    });
  });
}
