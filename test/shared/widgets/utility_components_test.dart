import 'package:checks/checks.dart';
import 'package:conduit/shared/widgets/utility_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('UtilityValueRow keeps flexible value under its Row', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: UtilityValueRow(
                label: 'Server URL',
                value: 'https://open-webui.example/a/long/server/path',
              ),
            ),
          ),
        ),
      ),
    );

    check(tester.takeException()).isNull();
    expect(find.text('Server URL'), findsOneWidget);
    expect(
      find.text('https://open-webui.example/a/long/server/path'),
      findsOneWidget,
    );
  });
}
