import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// The yes/no questions on iOS 26: a destructive one is a system action sheet,
/// any other one a system alert.
void main() {
  const sheetChannel = MethodChannel('cn_action_sheet');
  const alertChannel = MethodChannel('cn_alert');
  const triggerKey = Key('sample-trigger');
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  final sheetCalls = <MethodCall>[];
  final alertCalls = <MethodCall>[];
  final haptics = <Object?>[];
  Object? sheetReply;
  Object? alertReply;

  setUp(() {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    sheetCalls.clear();
    alertCalls.clear();
    haptics.clear();
    sheetReply = null;
    alertReply = null;
    messenger.setMockMethodCallHandler(sheetChannel, (call) async {
      sheetCalls.add(call);
      return sheetReply;
    });
    messenger.setMockMethodCallHandler(alertChannel, (call) async {
      alertCalls.add(call);
      return alertReply;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') haptics.add(call.arguments);
      return null;
    });
  });

  tearDown(() {
    for (final channel in [
      sheetChannel,
      alertChannel,
      SystemChannels.platform,
    ]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    PlatformUiCapabilities.resetDebugOverrides();
  });

  /// An iPhone-sized screen, or an iPad-sized one, with a home indicator.
  void useScreen(WidgetTester tester, {required Size points}) {
    const ratio = 3.0;
    tester.view.devicePixelRatio = ratio;
    tester.view.physicalSize = points * ratio;
    tester.view.viewPadding = const FakeViewPadding(bottom: 34 * ratio);
    tester.view.display.devicePixelRatio = ratio;
    tester.view.display.size = points * ratio;
    addTearDown(tester.view.reset);
    addTearDown(tester.view.display.reset);
  }

  /// The context of a laid-out button-sized widget, as a call site has.
  Future<BuildContext> pumpTrigger(
    WidgetTester tester, {
    ThemeMode themeMode = ThemeMode.light,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.light),
        darkTheme: ThemeData(brightness: Brightness.dark),
        themeMode: themeMode,
        builder: (context, child) => LegacyDesignCompatibility(child: child!),
        home: const Scaffold(
          body: Padding(
            padding: EdgeInsets.only(left: 40, top: 120),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(key: triggerKey, width: 90, height: 44),
            ),
          ),
        ),
      ),
    );
    return tester.element(find.byKey(triggerKey));
  }

  testWidgets(
    'a destructive question is an action sheet over the control that asked',
    (tester) async {
      useScreen(tester, points: const Size(402, 874));
      final trigger = await pumpTrigger(tester, themeMode: ThemeMode.dark);
      sheetReply = 0;

      final answer = ThemedDialogs.confirm(
        trigger,
        title: 'Remove the sample list?',
        message: 'Its entries go with it.',
        confirmText: 'Remove',
        cancelText: 'Keep',
        isDestructive: true,
        anchorContext: trigger,
      );
      await tester.pumpAndSettle();

      expect(await answer, isTrue);
      expect(alertCalls, isEmpty);
      expect(sheetCalls.single.method, 'show');
      expect(sheetCalls.single.arguments, {
        'title': 'Remove the sample list?',
        'message': 'Its entries go with it.',
        'cancelLabel': 'Keep',
        'isDark': true,
        // The sheet follows the app's text direction, not the system's.
        'rtl': false,
        'actions': [
          {'label': 'Remove', 'destructive': true, 'enabled': true},
        ],
        'anchorRect': {'x': 40.0, 'y': 120.0, 'width': 90.0, 'height': 44.0},
      });
      expect(haptics, ['HapticFeedbackType.mediumImpact']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'an unanchored action sheet rises from the bottom of an iPhone and '
    'answers false when closed',
    (tester) async {
      useScreen(tester, points: const Size(402, 874));
      final context = await pumpTrigger(tester);

      final answer = ThemedDialogs.confirm(
        context,
        title: 'Discard the draft?',
        message: 'The draft is not saved.',
        isDestructive: true,
      );
      await tester.pumpAndSettle();

      expect(await answer, isFalse);
      final payload = sheetCalls.single.arguments as Map;
      // Bottom centre, above the home indicator: iOS 26 would otherwise
      // centre the sheet like an alert.
      expect(payload['anchorRect'], {
        'x': 201.0,
        'y': 840.0,
        'width': 0.0,
        'height': 0.0,
      });
      expect(haptics, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'an unanchored action sheet on an iPad keeps the package placement',
    (tester) async {
      useScreen(tester, points: const Size(820, 1180));
      final context = await pumpTrigger(tester);

      final answer = ThemedDialogs.confirm(
        context,
        title: 'Discard the draft?',
        message: 'The draft is not saved.',
        isDestructive: true,
      );
      await tester.pumpAndSettle();

      expect(await answer, isFalse);
      expect(sheetCalls.single.arguments as Map, isNot(contains('anchorRect')));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  for (final barrierDismissible in [true, false]) {
    testWidgets('another question is a system alert '
        '(barrierDismissible: $barrierDismissible)', (tester) async {
      final context = await pumpTrigger(tester);
      Future<bool> ask() => ThemedDialogs.confirm(
        context,
        title: 'Archive the samples?',
        message: 'They can be brought back later.',
        confirmText: 'Archive',
        cancelText: 'Not now',
        barrierDismissible: barrierDismissible,
        anchorContext: context,
      );

      alertReply = {'index': 1};
      final confirmed = ask();
      await tester.pumpAndSettle();
      expect(await confirmed, isTrue);

      alertReply = {'index': 0};
      final cancelled = ask();
      await tester.pumpAndSettle();
      expect(await cancelled, isFalse);

      expect(sheetCalls, isEmpty);
      expect(alertCalls, hasLength(2));
      final payload = alertCalls.first.arguments as Map;
      expect(payload['title'], 'Archive the samples?');
      expect(payload['message'], 'They can be brought back later.');
      expect(payload['actions'], [
        {
          'label': 'Not now',
          'style': 'cancel',
          'enabled': true,
          'preferred': false,
        },
        {
          'label': 'Archive',
          'style': 'default',
          'enabled': true,
          'preferred': true,
        },
      ]);
      expect(haptics, [
        'HapticFeedbackType.selectionClick',
        'HapticFeedbackType.selectionClick',
      ]);
      expect(find.byType(AlertDialog), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  }
}
