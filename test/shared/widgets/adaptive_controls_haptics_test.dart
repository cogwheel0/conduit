import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> platformCalls;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    platformCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          platformCalls.add(call);
          return null;
        });
  });

  tearDown(() {
    PreferencesStore.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Iterable<MethodCall> hapticCalls() =>
      platformCalls.where((call) => call.method == 'HapticFeedback.vibrate');

  testWidgets('switch changes emit one selection haptic', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    var value = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => AdaptiveSwitch(
              value: value,
              onChanged: (next) => setState(() => value = next),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(Switch));
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;

    expect(value, isTrue);
    expect(hapticCalls(), hasLength(1));
    expect(hapticCalls().single.arguments, 'HapticFeedbackType.selectionClick');
  });

  testWidgets('segmented changes emit one selection haptic', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => AdaptiveSegmentedControl(
              labels: const ['One', 'Two'],
              selectedIndex: selected,
              onValueChanged: (next) => setState(() => selected = next),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Two'));
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;

    expect(selected, 1);
    expect(hapticCalls(), hasLength(1));
    expect(hapticCalls().single.arguments, 'HapticFeedbackType.selectionClick');
  });

  testWidgets('checkbox changes emit one selection haptic', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    bool? value = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => AdaptiveCheckbox(
              value: value,
              onChanged: (next) => setState(() => value = next),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;

    expect(value, isTrue);
    expect(hapticCalls(), hasLength(1));
    expect(hapticCalls().single.arguments, 'HapticFeedbackType.selectionClick');
  });

  testWidgets('discrete slider emits haptics only when crossing ticks', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    var value = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => AdaptiveSlider(
              value: value,
              divisions: 4,
              onChanged: (next) => setState(() => value = next),
            ),
          ),
        ),
      ),
    );

    final slider = find.byType(Slider);
    await tester.drag(slider, const Offset(120, 0));
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;

    expect(value, greaterThan(0));
    expect(hapticCalls(), isNotEmpty);
    expect(
      hapticCalls().every(
        (call) => call.arguments == 'HapticFeedbackType.selectionClick',
      ),
      isTrue,
    );
  });
}
