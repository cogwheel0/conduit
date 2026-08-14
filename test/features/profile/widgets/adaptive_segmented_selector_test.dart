import 'package:checks/checks.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/features/profile/widgets/adaptive_segmented_selector.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
  }

  testWidgets('selection emits one haptic', (tester) async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      PreferencesStore.debugReset();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    var selected = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => AdaptiveSegmentedSelector<int>(
              value: selected,
              onChanged: (next) => setState(() => selected = next),
              options: const [
                (
                  value: 1,
                  label: 'One',
                  cupertinoIcon: CupertinoIcons.circle,
                  materialIcon: Icons.circle_outlined,
                  enabled: true,
                ),
                (
                  value: 2,
                  label: 'Two',
                  cupertinoIcon: CupertinoIcons.circle,
                  materialIcon: Icons.circle_outlined,
                  enabled: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Two'));
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;

    expect(selected, 2);
    final haptics = calls.where(
      (call) => call.method == 'HapticFeedback.vibrate',
    );
    expect(haptics, hasLength(1));
    expect(haptics.single.arguments, 'HapticFeedbackType.selectionClick');
  });
}
