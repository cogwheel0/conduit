import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _en = AppLocalizationsEn();
final _chats = List.generate(
  6,
  (i) => ChatSwitcherChat(id: '$i', title: 'Chat $i'),
);
const _button = ValueKey('chat-switcher-button');
const _picker = ValueKey('chat-switcher-picker');

void main() {
  late List<ChatSwitcherChat> opened;
  late List<MethodCall> haptics;
  late int created;
  setUp(() {
    opened = [];
    haptics = [];
    created = 0;
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') haptics.add(call);
          return null;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
  Future<void> mount(
    WidgetTester tester, {
    List<ChatSwitcherChat>? chats,
    bool left = false,
    bool reducedMotion = false,
    double textScale = 1,
    GlobalKey<ChatQuickSwitcherState>? key,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(390, 844),
            disableAnimations: reducedMotion,
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: ChatQuickSwitcher(
              key: key,
              chats: chats ?? _chats,
              alignLeft: left,
              bottomOffset: 100,
              onNewChat: () => created++,
              onSelected: opened.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<TestGesture> hold(WidgetTester tester) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(_button)),
    );
    await tester.pump();
    expect(find.text(_en.chatSwitcherPress), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(_picker), findsOneWidget);
    expect(find.text(_en.chatSwitcherHold), findsOneWidget);
    return gesture;
  }

  testWidgets('tap creates exactly one chat', (tester) async {
    await mount(tester);
    expect(find.text(_en.chatSwitcherReady), findsNothing);
    final semantics = tester.widget<Semantics>(
      find
          .ancestor(of: find.byKey(_button), matching: find.byType(Semantics))
          .first,
    );
    expect(semantics.properties.hint, _en.chatSwitcherHint);
    await tester.tap(find.byKey(_button));
    await tester.pumpAndSettle();
    expect(created, 1);
    expect(opened, isEmpty);
    expect(find.byKey(_picker), findsNothing);
  });
  testWidgets('preview commits only on release at mid-screen', (tester) async {
    await mount(tester);
    final origin = tester.getCenter(find.byKey(_button));
    final gesture = await hold(tester);
    await gesture.moveTo(Offset(origin.dx, 422));
    await tester.pump();
    expect(opened, isEmpty);
    expect(created, 0);
    expect(find.text(_en.chatSwitcherRelease), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(opened.single.id, '0');
    expect(created, 0);
  });
  testWidgets('selection uses subtle native feedback instead of vibration', (
    tester,
  ) async {
    await mount(tester);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final origin = tester.getCenter(find.byKey(_button));
      final gesture = await hold(tester);
      await gesture.moveTo(Offset(origin.dx, 422));
      await tester.pump();
      expect(
        haptics.map((call) => call.arguments),
        contains('HapticFeedbackType.selectionClick'),
      );
      expect(
        haptics.map((call) => call.arguments),
        everyElement(
          anyOf(
            'HapticFeedbackType.selectionClick',
            'HapticFeedbackType.lightImpact',
          ),
        ),
      );
      await gesture.cancel();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
  testWidgets('bottom chat stays selected across a comfortable slide', (
    tester,
  ) async {
    await mount(tester);
    final origin = tester.getCenter(find.byKey(_button));
    final gesture = await hold(tester);
    await gesture.moveTo(origin - const Offset(0, 100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(opened.single.id, '5');
  });
  for (final outward in [false, true]) {
    testWidgets(
      '${outward ? 'outward slide' : 'return to plus'} cancels with clear feedback',
      (tester) async {
        await mount(tester);
        final origin = tester.getCenter(find.byKey(_button));
        final gesture = await hold(tester);
        await gesture.moveTo(Offset(origin.dx, 422));
        await tester.pump();
        await gesture.moveTo(outward ? Offset(origin.dx + 35, 422) : origin);
        await tester.pumpAndSettle();
        expect(find.text(_en.chatSwitcherCancel), findsOneWidget);
        expect(find.byIcon(Icons.close_rounded), findsOneWidget);
        await gesture.up();
        await tester.pump();
        expect(find.text(_en.chatSwitcherCancelled), findsOneWidget);
        expect(opened, isEmpty);
        expect(created, 0);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(find.byKey(_picker), findsNothing);
        expect(find.text(_en.chatSwitcherReady), findsNothing);
      },
    );
  }
  testWidgets('holding at plus cancels instead of creating', (tester) async {
    await mount(tester);
    final gesture = await hold(tester);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(created, 0);
    expect(opened, isEmpty);
    await tester.pump(const Duration(seconds: 1));
  });
  testWidgets('left-handed mode mirrors outward cancellation', (tester) async {
    await mount(tester, left: true);
    final origin = tester.getCenter(find.byKey(_button));
    expect(origin.dx, lessThan(100));
    final gesture = await hold(tester);
    await gesture.moveTo(Offset(origin.dx, 422));
    await gesture.moveTo(Offset(origin.dx - 35, 422));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(created, 0);
    await tester.pump(const Duration(seconds: 1));
  });
  testWidgets('pointer interruption never opens a highlighted chat', (
    tester,
  ) async {
    await mount(tester);
    final origin = tester.getCenter(find.byKey(_button));
    final gesture = await hold(tester);
    await gesture.moveTo(Offset(origin.dx, 422));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(created, 0);
    await tester.pump(const Duration(seconds: 1));
  });
  testWidgets('a changed account/list invalidates the preview', (tester) async {
    final key = GlobalKey<ChatQuickSwitcherState>();
    await mount(tester, key: key);
    final origin = tester.getCenter(find.byKey(_button));
    final gesture = await hold(tester);
    await gesture.moveTo(Offset(origin.dx, 422));
    await mount(tester, key: key, chats: const []);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(created, 0);
    expect(find.byKey(_picker), findsNothing);
  });
  testWidgets('reduced motion and large text keep cancellation clear', (
    tester,
  ) async {
    await mount(tester, reducedMotion: true, textScale: 2);
    final state = tester.state<ChatQuickSwitcherState>(
      find.byType(ChatQuickSwitcher),
    );
    final gesture = await hold(tester);
    expect(state.dismiss(), isTrue);
    await gesture.up();
    await tester.pump();
    expect(find.byKey(_picker), findsNothing);
    expect(find.text(_en.chatSwitcherCancelled), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 1));
  });
}
