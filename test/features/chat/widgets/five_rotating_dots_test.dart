import 'package:conduit/features/chat/widgets/five_rotating_dots.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders five static dots when animation is disabled', (
    tester,
  ) async {
    const color = Color(0xFFAA3355);

    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: FiveRotatingDots(color: color, size: 28, animate: false),
        ),
      ),
    );

    final dots = find.byWidgetPredicate((widget) {
      if (widget is! Container) {
        return false;
      }
      final decoration = widget.decoration;
      return decoration is BoxDecoration &&
          decoration.shape == BoxShape.circle &&
          decoration.color == color;
    });

    expect(dots, findsNWidgets(5));

    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('animated dots keep fixed layout and reuse a cached ring', (
    tester,
  ) async {
    const color = Color(0xFF3355AA);
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: FiveRotatingDots(color: color, size: 28)),
      ),
    );

    final dotFinder = find.byWidgetPredicate((widget) {
      if (widget is! Container) return false;
      final decoration = widget.decoration;
      return decoration is BoxDecoration &&
          decoration.shape == BoxShape.circle &&
          decoration.color == color;
    });
    final initialSizes = List<Size>.generate(
      5,
      (index) => tester.getSize(dotFinder.at(index)),
      growable: false,
    );
    final builder = tester.widget<AnimatedBuilder>(
      find.byType(AnimatedBuilder),
    );
    expect(builder.child, isNotNull);

    await tester.pump(const Duration(milliseconds: 550));

    final laterSizes = List<Size>.generate(
      5,
      (index) => tester.getSize(dotFinder.at(index)),
      growable: false,
    );
    expect(laterSizes, initialSizes);
    expect(dotFinder, findsNWidgets(5));
  });

  testWidgets(
    'animation can be disabled and resumed without replacing ticker',
    (tester) async {
      Widget build({required bool animate}) => Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: FiveRotatingDots(
            color: const Color(0xFF3355AA),
            size: 28,
            animate: animate,
          ),
        ),
      );

      await tester.pumpWidget(build(animate: true));
      await tester.pump(const Duration(milliseconds: 100));
      final animationBefore = tester
          .widget<AnimatedBuilder>(find.byType(AnimatedBuilder))
          .animation;
      await tester.pumpWidget(build(animate: false));
      await tester.pump();
      await tester.pumpWidget(build(animate: true));
      await tester.pump(const Duration(milliseconds: 100));
      final animationAfter = tester
          .widget<AnimatedBuilder>(find.byType(AnimatedBuilder))
          .animation;

      expect(identical(animationAfter, animationBefore), isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
