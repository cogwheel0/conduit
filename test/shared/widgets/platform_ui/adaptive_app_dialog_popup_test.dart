import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    PlatformUiCapabilities.resetDebugOverrides();
    debugDefaultTargetPlatformOverride = null;
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'input survives keyboard dismissal during the closing animation on $platform',
      (tester) async {
        PlatformUiCapabilities.debugPlatformOverride = platform;
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: SizedBox())),
        );
        final result = AdaptiveAlertDialog.inputShow(
          context: tester.element(find.byType(Scaffold)),
          title: 'Keyboard shortcut',
          input: const AdaptiveAlertDialogInput(
            placeholder: 'Shortcut',
            autocorrect: false,
            maxLines: 3,
          ),
          actions: [AlertAction(title: 'Send', onPressed: () {})],
        );
        await tester.pumpAndSettle();
        final field = tester.widget<EditableText>(find.byType(EditableText));
        expect(field.autocorrect, isFalse);
        expect(field.enableSuggestions, isFalse);
        expect(field.smartDashesType, SmartDashesType.disabled);
        expect(field.smartQuotesType, SmartQuotesType.disabled);
        expect(field.maxLines, 3);
        const text = 'First line\nLiteral "quotes" -- and a second line.';
        await tester.enterText(find.byType(EditableText), text);
        final controller = tester
            .widget<EditableText>(find.byType(EditableText))
            .controller;
        tester.view.viewInsets = const FakeViewPadding(bottom: 250);
        addTearDown(tester.view.resetViewInsets);
        await tester.pump();
        await tester.tap(find.text('Send'));
        await tester.pump();
        // The route still owns an EditableText while reversing its transition.
        void listener() {}
        expect(() => controller.addListener(listener), returnsNormally);
        controller.removeListener(listener);
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        expect(await result, text);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Cupertino app applies an explicit dark theme at its root', (
    tester,
  ) async {
    final router = GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => const SizedBox.shrink())],
    );
    addTearDown(router.dispose);
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 25;

    await tester.pumpWidget(
      AdaptiveApp.router(
        routerConfig: router,
        themeMode: ThemeMode.dark,
        cupertinoDarkTheme: const CupertinoThemeData(
          brightness: Brightness.dark,
        ),
      ),
    );

    expect(
      tester.widget<CupertinoApp>(find.byType(CupertinoApp)).theme?.brightness,
      Brightness.dark,
    );
  });

  testWidgets('input dialogs keep disabled actions non-interactive', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 25;
    await tester.pumpWidget(
      const CupertinoApp(home: CupertinoPageScaffold(child: SizedBox())),
    );

    final result = AdaptiveAlertDialog.inputShow(
      context: tester.element(find.byType(CupertinoPageScaffold)),
      title: 'Rename',
      input: const AdaptiveAlertDialogInput(placeholder: 'Name'),
      actions: [
        AlertAction(title: 'Disabled', enabled: false, onPressed: () {}),
        AlertAction(
          title: 'Cancel',
          style: AlertActionStyle.cancel,
          onPressed: () {},
        ),
      ],
    );
    await tester.pumpAndSettle();

    final disabled = tester.widget<CupertinoDialogAction>(
      find.widgetWithText(CupertinoDialogAction, 'Disabled'),
    );
    expect(disabled.onPressed, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  test('popup adapter preserves rich values by selecting Flutter fallback', () {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;

    final native = AdaptivePopupMenuButton.text<int>(
      label: 'Simple',
      items: const [AdaptivePopupMenuItem<int>(label: 'One', value: 41)],
      onSelected: (_, _) {},
    );
    final rich = AdaptivePopupMenuButton.text<int>(
      label: 'Rich',
      items: const [
        AdaptivePopupMenuItem<int>(
          label: 'One',
          subtitle: 'Metadata that must not be dropped',
          value: 41,
        ),
      ],
      onSelected: (_, _) {},
    );

    expect(native, isA<CNPopupMenuButton>());
    expect(rich, isNot(isA<CNPopupMenuButton>()));
  });

  testWidgets('disabled Cupertino popup items are non-interactive', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 25;

    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: AdaptivePopupMenuButton.text<int>(
            label: 'Menu',
            items: const [
              AdaptivePopupMenuItem<int>(label: 'Disabled', enabled: false),
            ],
            onSelected: (_, _) {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('Menu'));
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(CupertinoActionSheetAction, 'Disabled'),
      findsNothing,
    );
    final semantics = tester.widget<Semantics>(
      find.byKey(const ValueKey<String>('disabled-cupertino-popup-item-0')),
    );
    expect(semantics.properties.enabled, isFalse);
    expect(semantics.properties.onTap, isNull);
  });

  testWidgets('Flutter popup fallbacks map SF Symbol item icons', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdaptivePopupMenuButton.text<int>(
            label: 'Menu',
            items: const [
              AdaptivePopupMenuItem<int>(label: 'Delete', icon: 'trash'),
            ],
            onSelected: (_, _) {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('Menu'));
    await tester.pumpAndSettle();

    expect(find.byIcon(CupertinoIcons.delete), findsOneWidget);
  });

  testWidgets('Flutter popup fallbacks preserve item keys', (tester) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdaptivePopupMenuButton.text<int>(
            label: 'Menu',
            items: const [
              AdaptivePopupMenuItem<int>(
                key: Key('second-action'),
                label: 'Second',
                value: 2,
              ),
            ],
            onSelected: (_, _) {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('Menu'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('second-action')), findsOneWidget);
  });
}
