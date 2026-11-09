import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart'
    show Uint8List, debugDefaultTargetPlatformOverride;
import 'package:flutter/rendering.dart' show RenderEditable, RenderObject;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    PlatformUiCapabilities.resetDebugOverrides();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS keyboard overshoot preserves the composer and dialog', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 25;
    tester.view.physicalSize = const Size(834, 1210);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = TextEditingController(text: 'Unsent draft');
    addTearDown(controller.dispose);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => CupertinoPageScaffold(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: CupertinoTextField(controller: controller),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(AdaptiveApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    for (var cycle = 0; cycle < 3; cycle++) {
      final result = AdaptiveAlertDialog.inputShow(
        context: tester.element(find.byType(CupertinoPageScaffold)),
        title: 'Browser address',
        input: const AdaptiveAlertDialogInput(placeholder: 'URL'),
        actions: [AlertAction(title: 'Send', onPressed: () {})],
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(EditableText).last,
        'https://example.com',
      );
      for (final bottom in [320.0, -12.0, 0.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: bottom);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.getBottomRight(find.byType(CupertinoTextField).first).dy,
          bottom > 0 ? 1210 - bottom : 1210,
        );
      }
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(await result, 'https://example.com');
      expect(controller.text, 'Unsent draft');
      expect(find.byType(EditableText), findsOneWidget);
      // A failed padding update can orphan rendered copies even when the
      // widget tree still contains only one composer.
      var renderedEditors = 0;
      void visit(RenderObject node) {
        if (node is RenderEditable) renderedEditors++;
        node.visitChildren(visit);
      }

      tester.binding.renderViews.forEach(visit);
      expect(renderedEditors, 1);
    }
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

  test('popup adapter keeps subtitles native and item images in Flutter', () {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;

    final subtitled = AdaptivePopupMenuButton.text<int>(
      label: 'Subtitled',
      items: const [
        AdaptivePopupMenuItem<int>(
          label: 'One',
          subtitle: 'Metadata that must not be dropped',
          value: 41,
        ),
      ],
      onSelected: (_, _) {},
    );
    // UIMenu items can't show a round avatar from bytes.
    final withImage = AdaptivePopupMenuButton.text<int>(
      label: 'Avatar',
      items: [
        AdaptivePopupMenuItem<int>(
          label: 'One',
          imageBytes: Uint8List.fromList(const [0]),
          value: 41,
        ),
      ],
      onSelected: (_, _) {},
    );

    expect(subtitled, isA<CNPopupMenuButton>());
    final item =
        (subtitled as CNPopupMenuButton).items.single as CNPopupMenuItem;
    expect(item.subtitle, 'Metadata that must not be dropped');
    expect(withImage, isNot(isA<CNPopupMenuButton>()));
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
