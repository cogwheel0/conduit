import 'package:checks/checks.dart';
import 'package:conduit/features/profile/widgets/adaptive_segmented_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final platform in <TargetPlatform>[
    TargetPlatform.iOS,
    TargetPlatform.android,
  ]) {
    testWidgets(
      'does not select a disabled current value on ${platform.name}',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: AdaptiveSegmentedSelector<int>(
                value: 2,
                onChanged: (_) {},
                options: const [
                  (
                    value: 1,
                    label: 'Enabled',
                    cupertinoIcon: CupertinoIcons.circle,
                    materialIcon: Icons.circle_outlined,
                    enabled: true,
                  ),
                  (
                    value: 2,
                    label: 'Disabled',
                    cupertinoIcon: CupertinoIcons.circle,
                    materialIcon: Icons.circle_outlined,
                    enabled: false,
                  ),
                ],
              ),
            ),
          ),
        );

        if (platform == TargetPlatform.iOS) {
          final selector = tester.widget<CupertinoSlidingSegmentedControl<int>>(
            find.byType(CupertinoSlidingSegmentedControl<int>),
          );
          check(selector.groupValue).isNull();
        } else {
          final selector = tester.widget<SegmentedButton<int>>(
            find.byType(SegmentedButton<int>),
          );
          check(selector.selected).isEmpty();
          check(selector.emptySelectionAllowed).isTrue();
        }

        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('keeps labels and drops icons in compact ${platform.name}', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: const Center(
            child: SizedBox(
              width: 320,
              child: AdaptiveSegmentedSelector<int>(
                value: 1,
                onChanged: _ignoreSelection,
                options: [
                  (
                    value: 1,
                    label: 'Device',
                    cupertinoIcon: CupertinoIcons.device_phone_portrait,
                    materialIcon: Icons.phone_android,
                    enabled: true,
                  ),
                  (
                    value: 2,
                    label: 'Server',
                    cupertinoIcon: CupertinoIcons.cloud,
                    materialIcon: Icons.cloud,
                    enabled: true,
                  ),
                  (
                    value: 3,
                    label: 'Sherpa',
                    cupertinoIcon: CupertinoIcons.waveform,
                    materialIcon: Icons.graphic_eq,
                    enabled: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.text('Device'), findsOneWidget);
      expect(find.text('Server'), findsOneWidget);
      expect(find.text('Sherpa'), findsOneWidget);
      expect(find.byIcon(Icons.phone_android), findsNothing);
      expect(find.byIcon(Icons.cloud), findsNothing);
      expect(find.byIcon(Icons.graphic_eq), findsNothing);
      expect(find.byIcon(CupertinoIcons.device_phone_portrait), findsNothing);
      expect(find.byIcon(CupertinoIcons.cloud), findsNothing);
      expect(find.byIcon(CupertinoIcons.waveform), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}

void _ignoreSelection(int _) {}
