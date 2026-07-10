import 'package:conduit/shared/widgets/skeleton_loader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SkeletonLoader', () {
    testWidgets('renders with given width and height', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SkeletonLoader(width: 200, height: 20)),
        ),
      );

      expect(find.byType(SkeletonLoader), findsOneWidget);

      final container = tester.widget<Container>(
        find.descendant(
          of: find.byType(SkeletonLoader),
          matching: find.byType(Container),
        ),
      );
      expect(container.constraints?.maxWidth, 200);
      expect(container.constraints?.maxHeight, 20);
    });

    testWidgets('animation is running after pump', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SkeletonLoader(width: 100, height: 16)),
        ),
      );

      // Pump a few frames to verify the animation runs without error.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(SkeletonLoader), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('reduced motion renders a static placeholder', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(disableAnimations: true),
              child: SkeletonLoader(width: 100, height: 16),
            ),
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byType(SkeletonLoader),
          matching: find.byType(AnimatedBuilder),
        ),
        findsNothing,
      );
      final container = tester.widget<Container>(
        find.descendant(
          of: find.byType(SkeletonLoader),
          matching: find.byType(Container),
        ),
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color, isNotNull);
      expect(decoration.gradient, isNull);

      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  });

  group('SkeletonChatMessage', () {
    testWidgets('renders without errors', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SkeletonChatMessage())),
      );

      expect(find.byType(SkeletonChatMessage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('SkeletonListItem', () {
    testWidgets('renders without errors', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SkeletonListItem())),
      );

      expect(find.byType(SkeletonListItem), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
