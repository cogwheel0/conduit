import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
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
    debugDefaultTargetPlatformOverride = null;
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

  testWidgets('iOS switch relies on one system haptic', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    var value = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
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

    await tester.tap(find.byType(CupertinoSwitch));
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;

    expect(value, isTrue);
    expect(hapticCalls(), hasLength(1));
    expect(hapticCalls().single.arguments, 'HapticFeedbackType.lightImpact');
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

  testWidgets('iOS slider edge produces one system haptic', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    var value = 0.5;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => AdaptiveSlider(
              value: value,
              divisions: 2,
              onChanged: (next) => setState(() => value = next),
            ),
          ),
        ),
      ),
    );

    final slider = find.byType(CupertinoSlider);
    await tester.drag(slider, const Offset(500, 0));
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;

    expect(value, 1);
    expect(hapticCalls(), hasLength(1));
    expect(hapticCalls().single.arguments, 'HapticFeedbackType.mediumImpact');
  });

  testWidgets('Cupertino popup fallback emits one selection haptic', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 25;
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);
    var selected = false;
    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: AdaptivePopupMenuButton.text<int>(
            label: 'Menu',
            items: const [AdaptivePopupMenuItem<int>(label: 'Select')],
            onSelected: (_, _) => selected = true,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Menu'));
    await tester.pumpAndSettle();
    platformCalls.clear();
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();

    expect(selected, isTrue);
    expect(hapticCalls(), hasLength(1));
    expect(hapticCalls().single.arguments, 'HapticFeedbackType.selectionClick');
  });

  testWidgets('native popup owns its selection haptic', (tester) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);
    var selected = false;
    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: AdaptivePopupMenuButton.text<int>(
            label: 'Menu',
            items: const [AdaptivePopupMenuItem<int>(label: 'Select')],
            onSelected: (_, _) => selected = true,
          ),
        ),
      ),
    );
    platformCalls.clear();

    tester
        .widget<CNPopupMenuButton>(find.byType(CNPopupMenuButton))
        .onSelected(0);

    expect(selected, isTrue);
    expect(hapticCalls(), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
