import 'package:checks/checks.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/utility_components.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
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

  testWidgets('UtilitySelectionRow keeps native padding and keyboard access', (
    tester,
  ) async {
    var activations = 0;
    const leadingKey = ValueKey<String>('selection-leading');
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: Scaffold(
            body: UtilitySelectionRow(
              leading: const SizedBox.square(
                key: leadingKey,
                dimension: 40,
                child: Icon(Icons.cloud_outlined),
              ),
              title: 'Provider',
              subtitle: 'Connect directly',
              selected: false,
              onTap: () => activations++,
            ),
          ),
        ),
      ),
    );

    check(tester.getTopLeft(find.byKey(leadingKey)).dx).equals(Spacing.md);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    check(activations).equals(1);
  });

  testWidgets('UtilityStatusBanner announces its message once', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: UtilityStatusBanner(
              key: ValueKey<String>('status-banner'),
              message: 'Connection established',
              tone: UtilityStatusTone.success,
            ),
          ),
        ),
      );

      final node = tester.getSemantics(
        find.byKey(const ValueKey<String>('status-banner')),
      );
      check(node.label).equals('Connection established');
    } finally {
      semantics.dispose();
    }
  });
}
