import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoActivityIndicator;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  testWidgets(
    'Android chips keep selection, disabled state and separate deletion',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
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
                    semanticLabel: 'Tag action',
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
        expect(
          tester.getSemantics(find.bySemanticsLabel('Tag action')),
          isSemantics(
            label: 'Tag action',
            isButton: true,
            isSelected: true,
            hasTapAction: true,
          ),
        );
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
      } finally {
        semantics.dispose();
      }
    },
  );

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('button names retain activation on ${platform.name}', (
      tester,
    ) async {
      PlatformUiCapabilities.debugPlatformOverride = platform;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 25;
      final semantics = tester.ensureSemantics();
      try {
        var presses = 0;
        var enabled = true;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return AdaptiveButton(
                    label: 'Visible',
                    semanticLabel: 'Submit',
                    enabled: enabled,
                    onPressed: () => presses++,
                  );
                },
              ),
            ),
          ),
        );
        expect(
          tester.getSemantics(find.bySemanticsLabel('Submit')),
          isSemantics(label: 'Submit', isButton: true, hasTapAction: true),
        );
        await tester.tap(find.text('Visible'));
        await tester.pumpAndSettle();
        expect(presses, 1);
        update(() => enabled = false);
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(find.bySemanticsLabel('Submit')),
          isSemantics(label: 'Submit', isButton: true),
        );
        await tester.tap(find.text('Visible'));
        await tester.pumpAndSettle();
        expect(presses, 1);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets(
      'segments reject missing or duplicate choices on ${platform.name}',
      (tester) async {
        for (final segments in <List<AdaptiveSegment<int>>>[
          [],
          [const AdaptiveSegment(value: 1, label: Text('Only'))],
          [
            const AdaptiveSegment(value: 1, label: Text('One')),
            const AdaptiveSegment(value: 1, label: Text('Duplicate')),
          ],
        ]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(platform: platform),
              home: Scaffold(
                body: AdaptiveValueSegmentedControl<int>(
                  segments: segments,
                  value: 1,
                  onChanged: (_) {},
                ),
              ),
            ),
          );
          expect(tester.takeException(), isArgumentError);
        }
      },
    );

    testWidgets(
      'typed segments preserve labels and selection rules on ${platform.name}',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          var selected = 1;
          var enabled = true;
          final changes = <int>[];
          late StateSetter update;
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(platform: platform),
              home: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) {
                    update = setState;
                    return AdaptiveValueSegmentedControl<int>(
                      value: selected,
                      segments: const [
                        AdaptiveSegment(
                          value: 1,
                          label: Text('One'),
                          icon: Icon(Icons.looks_one),
                          semanticLabel: 'First option',
                        ),
                        AdaptiveSegment(
                          value: 2,
                          label: Text('Two'),
                          semanticLabel: 'Second option',
                        ),
                        AdaptiveSegment(
                          value: 3,
                          label: Text('Disabled'),
                          enabled: false,
                        ),
                      ],
                      onChanged: enabled
                          ? (next) => setState(() {
                              selected = next;
                              changes.add(next);
                            })
                          : null,
                    );
                  },
                ),
              ),
            ),
          );
          expect(find.bySemanticsLabel('First option'), findsOneWidget);
          expect(find.byIcon(Icons.looks_one), findsOneWidget);
          expect(find.bySemanticsLabel('Second option'), findsOneWidget);
          expect(
            tester.getSemantics(find.bySemanticsLabel('Disabled')),
            isSemantics(isButton: true, isEnabled: false),
          );
          await tester.tap(find.text('Two'));
          await tester.pumpAndSettle();
          expect(selected, 2);
          expect(changes, [2]);
          expect(
            tester.getSemantics(find.bySemanticsLabel('Second option')),
            isSemantics(isSelected: true),
          );
          await tester.tap(find.text('Two'));
          await tester.tap(find.text('Disabled'));
          await tester.pumpAndSettle();
          expect(changes, [2]);
          update(() => enabled = false);
          await tester.pumpAndSettle();
          await tester.tap(find.text('One'));
          await tester.pumpAndSettle();
          expect(selected, 2);
          expect(changes, [2]);
        } finally {
          semantics.dispose();
        }
      },
    );
  }

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

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('activity progress keeps its radius on ${platform.name}', (
      tester,
    ) async {
      PlatformUiCapabilities.debugPlatformOverride = platform;
      const color = Color(0xFF3366CC);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: const Scaffold(
            body: Center(
              child: AdaptiveProgressIndicator.activity(
                radius: 8,
                color: color,
              ),
            ),
          ),
        ),
      );
      final spinner = find.byType(CupertinoActivityIndicator);
      final indicator = tester.widget<CupertinoActivityIndicator>(spinner);
      expect(indicator.radius, 8);
      expect(indicator.color, color);
      expect(tester.getSize(spinner), const Size.square(16));
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  }
}
