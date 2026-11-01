import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('app.cogwheel.conduit/text_magnifier');
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late List<MethodCall> calls;
  late List<Object?> haptics;

  setUp(() {
    calls = [];
    haptics = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments);
        }
        return null;
      },
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return true;
    });
  });

  tearDown(() {
    PlatformUiCapabilities.resetDebugOverrides();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  ValueNotifier<MagnifierInfo> geometry() => ValueNotifier(
    const MagnifierInfo(
      globalGesturePosition: Offset(140, 500),
      caretRect: Rect.fromLTWH(138, 490, 2, 20),
      fieldBounds: Rect.fromLTWH(20, 480, 350, 80),
      currentLineBoundaries: Rect.fromLTWH(30, 490, 300, 20),
    ),
  );

  Future<void> pumpMagnifier(
    WidgetTester tester,
    ValueNotifier<MagnifierInfo> info,
  ) => tester.pumpWidget(
    CupertinoApp(
      home: Stack(
        children: [
          IosTextMagnifier(
            controller: MagnifierController(),
            magnifierInfo: info,
          ),
        ],
      ),
    ),
  );

  test(
    'field configuration preserves platform defaults without native support',
    () {
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
      expect(nativeIosTextMagnifierConfiguration, isNull);
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 25;
      expect(nativeIosTextMagnifierConfiguration, isNull);
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 27;
      PlatformUiCapabilities.debugNativeIOS26Override = false;
      expect(nativeIosTextMagnifierConfiguration, isNull);
      PlatformUiCapabilities.debugNativeIOS26Override = true;
      expect(
        nativeIosTextMagnifierConfiguration,
        same(IosTextMagnifier.configuration),
      );
    },
  );

  testWidgets(
    'shared input retains editing and formatting with the native loupe',
    (tester) async {
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 27;
      PlatformUiCapabilities.debugNativeIOS26Override = true;
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      String? changed;
      await tester.pumpWidget(
        CupertinoApp(
          home: CupertinoPageScaffold(
            child: AdaptiveTextField(
              controller: controller,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 4,
              onChanged: (value) => changed = value,
            ),
          ),
        ),
      );
      final field = tester.widget<CupertinoTextField>(
        find.byType(CupertinoTextField),
      );
      expect(
        field.magnifierConfiguration,
        same(IosTextMagnifier.configuration),
      );
      expect(field.keyboardType, TextInputType.number);
      await tester.enterText(find.byType(CupertinoTextField), '12a345');
      expect(controller.text, '1234');
      expect(changed, '1234');
      expect(controller.selection, const TextSelection.collapsed(offset: 4));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('native loupe gives one selection haptic per gesture', (
    tester,
  ) async {
    final info = geometry();
    addTearDown(info.dispose);
    await pumpMagnifier(tester, info);
    await tester.pump();
    expect(haptics, ['HapticFeedbackType.selectionClick']);
    info.value = MagnifierInfo.empty;
    await tester.pump();
    expect(haptics, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(haptics, hasLength(1));
    await pumpMagnifier(tester, info);
    await tester.pump();
    expect(haptics, List.filled(2, 'HapticFeedbackType.selectionClick'));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('forwards full-view geometry and ends the owned session', (
    tester,
  ) async {
    final info = geometry();
    addTearDown(info.dispose);
    await pumpMagnifier(tester, info);
    await tester.pump();

    final begin = calls.first;
    expect(begin.method, 'begin');
    expect(begin.arguments, {
      'session': isA<int>(),
      'viewWidth': 800.0,
      'viewHeight': 600.0,
      'x': 140.0,
      'y': 500.0,
      'caretX': 138.0,
      'caretY': 490.0,
      'caretWidth': 2.0,
      'caretHeight': 20.0,
    });
    expect(find.byType(CupertinoTextMagnifier), findsNothing);

    info.value = const MagnifierInfo(
      globalGesturePosition: Offset(200, 520),
      caretRect: Rect.fromLTWH(198, 510, 2, 20),
      fieldBounds: Rect.fromLTWH(20, 480, 350, 80),
      currentLineBoundaries: Rect.fromLTWH(30, 510, 300, 20),
    );
    await tester.pump();
    expect(calls.last.method, 'move');
    expect(calls.last.arguments['x'], 200.0);
    expect(calls.last.arguments['caretY'], 510.0);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(calls.last.method, 'end');
    expect(calls.last.arguments['session'], begin.arguments['session']);
    final count = calls.length;
    info.value = MagnifierInfo.empty;
    await tester.pump();
    expect(calls.length, count);
  });

  testWidgets('keeps full-view coordinates current after a resize', (
    tester,
  ) async {
    final info = geometry();
    addTearDown(info.dispose);
    addTearDown(tester.view.resetPhysicalSize);
    await pumpMagnifier(tester, info);
    await tester.pump();
    tester.view.physicalSize =
        const Size(1000, 700) * tester.view.devicePixelRatio;
    await tester.pump();
    info.value = MagnifierInfo.empty;
    await tester.pump();
    expect(calls.last.arguments['viewWidth'], 1000.0);
    expect(calls.last.arguments['viewHeight'], 700.0);
    expect(calls.where((call) => call.method == 'begin'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  for (final failure in ['declined', 'missing', 'platform']) {
    testWidgets('retains Cupertino fallback when native loupe is $failure', (
      tester,
    ) async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        if (failure == 'missing') throw MissingPluginException();
        if (failure == 'platform') throw PlatformException(code: 'unavailable');
        return false;
      });
      final info = geometry();
      addTearDown(info.dispose);
      await pumpMagnifier(tester, info);
      await tester.pump();
      expect(find.byType(CupertinoTextMagnifier), findsOneWidget);
      expect(haptics, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('uses latest geometry after a delayed begin reply', (
    tester,
  ) async {
    final reply = Completer<bool>();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return call.method == 'begin' ? reply.future : true;
    });
    final info = geometry();
    addTearDown(info.dispose);
    await pumpMagnifier(tester, info);
    info.value = MagnifierInfo.empty;
    expect(calls.length, 1);
    expect(haptics, isEmpty);
    reply.complete(true);
    await tester.pump();
    expect(haptics, ['HapticFeedbackType.selectionClick']);
    expect(calls.last.method, 'move');
    expect(calls.last.arguments['x'], 0.0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('app deactivation restores a lens without another finger move', (
    tester,
  ) async {
    final info = geometry();
    addTearDown(info.dispose);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpMagnifier(tester, info);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.byType(CupertinoTextMagnifier), findsOneWidget);
    expect(calls.last.method, 'end');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byType(CupertinoTextMagnifier), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    final count = calls.length;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(calls.length, count);
    expect(tester.takeException(), isNull);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('a delayed begin cannot revive a deactivated native lens', (
    tester,
  ) async {
    final reply = Completer<bool>();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return call.method == 'begin' ? reply.future : true;
    });
    final info = geometry();
    addTearDown(info.dispose);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpMagnifier(tester, info);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    reply.complete(true);
    await tester.pump();
    expect(find.byType(CupertinoTextMagnifier), findsOneWidget);
    expect(calls.where((call) => call.method == 'move'), isEmpty);
    expect(haptics, isEmpty);
    expect(calls.last.method, 'end');
    expect(calls.last.arguments['session'], calls.first.arguments['session']);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('a delayed reply cannot revive a disposed overlay', (
    tester,
  ) async {
    final reply = Completer<bool>();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return call.method == 'begin' ? reply.future : true;
    });
    final info = geometry();
    addTearDown(info.dispose);
    await pumpMagnifier(tester, info);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    reply.complete(true);
    await tester.pump();
    expect(calls.map((call) => call.method), ['begin', 'end']);
    expect(haptics, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a lost native session falls back and releases the loupe', (
    tester,
  ) async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return call.method != 'move';
    });
    final info = geometry();
    addTearDown(info.dispose);
    await pumpMagnifier(tester, info);
    await tester.pump();
    await tester.pump();
    expect(find.byType(CupertinoTextMagnifier), findsOneWidget);
    expect(calls.map((call) => call.method), ['begin', 'move', 'end']);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('long-press moves the caret without resizing or changing text', (
    tester,
  ) async {
    final controller = TextEditingController(
      text: 'Place a violet flag beside the wooden bridge.',
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      CupertinoApp(
        home: Center(
          child: SizedBox(
            width: 320,
            child: CupertinoTextField(
              controller: controller,
              maxLines: null,
              magnifierConfiguration: IosTextMagnifier.configuration,
            ),
          ),
        ),
      ),
    );
    final field = find.byType(CupertinoTextField);
    await tester.tap(field);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 100));
    expect(haptics, isEmpty);
    final before = tester.getRect(field);
    final text = controller.text;
    final gesture = await tester.startGesture(before.center);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await tester.pump();
    expect(calls.where((call) => call.method == 'begin'), isNotEmpty);
    expect(haptics, ['HapticFeedbackType.selectionClick']);
    final initialOffset = controller.selection.extentOffset;
    await gesture.moveBy(const Offset(-45, 0));
    await tester.pump();
    expect(controller.selection.isCollapsed, isTrue);
    expect(controller.selection.extentOffset, lessThan(initialOffset));
    expect(tester.getRect(field), before);
    expect(controller.text, text);
    expect(haptics, hasLength(1));
    await gesture.up();
    await tester.pump();
    await tester.pump();
    expect(calls.last.method, 'end');
    expect(haptics, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
