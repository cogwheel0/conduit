import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  testWidgets(
    'Android chips keep selection, disabled state and separate deletion',
    (tester) async {
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
      var selected = false;
      var changes = 0;
      var deletes = 0;
      var enabled = true;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return AdaptiveChip.input(
                  label: const Text('Tag'),
                  selected: selected,
                  enabled: enabled,
                  onSelected: (value) => setState(() {
                    selected = value;
                    changes++;
                  }),
                  onDeleted: () => deletes++,
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Tag'));
      await tester.pumpAndSettle();
      expect(selected, isTrue);
      expect(changes, 1);
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is Tooltip && widget.message == 'Delete',
        ),
      );
      expect(deletes, 1);
      expect(changes, 1);
      update(() => enabled = false);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tag'));
      expect(changes, 1);
      expect(
        tester.widget<InputChip>(find.byType(InputChip)).onDeleted,
        isNull,
      );
    },
  );

  testWidgets('progress carries a known value and accessibility text', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AdaptiveProgressIndicator.linear(
            value: 0.4,
            minHeight: 3,
            semanticLabel: 'Upload',
            semanticValue: '40%',
          ),
        ),
      ),
    );
    final indicator = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(indicator.value, 0.4);
    expect(indicator.semanticsLabel, 'Upload');
    expect(indicator.semanticsValue, '40%');
  });
}
