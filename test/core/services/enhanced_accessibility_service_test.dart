import 'package:checks/checks.dart';
import 'package:conduit/core/services/enhanced_accessibility_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EnhancedAccessibilityService', () {
    testWidgets('lets MediaQuery scale text without rewriting font size', (
      tester,
    ) async {
      const baseStyle = TextStyle(fontSize: 18);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(4.0)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: EnhancedAccessibilityService.createAccessibleText(
              'Accessible',
              style: baseStyle,
            ),
          ),
        ),
      );

      final text = tester.widget<Text>(find.text('Accessible'));
      check(text.style?.fontSize).equals(18);
    });
  });
}
