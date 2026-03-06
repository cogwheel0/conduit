import 'package:conduit/shared/widgets/model_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ModelAvatar', () {
    testWidgets('renders with label showing first character',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ModelAvatar(size: 40, label: 'GPT-4'),
            ),
          ),
        ),
      );

      // The fallback shows the uppercase first character of the label.
      expect(find.text('G'), findsOneWidget);
    });

    testWidgets('renders without label showing icon fallback',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ModelAvatar(size: 40),
            ),
          ),
        ),
      );

      // Without a label, the fallback shows an icon.
      expect(find.byIcon(Icons.psychology), findsOneWidget);
    });

    testWidgets('widget can be found by type', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ModelAvatar(size: 40, label: 'Test'),
            ),
          ),
        ),
      );

      expect(find.byType(ModelAvatar), findsOneWidget);
    });
  });
}
