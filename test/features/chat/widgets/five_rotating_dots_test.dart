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
}
