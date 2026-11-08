import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart'
    show Uint8List, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    PlatformUiCapabilities.resetDebugOverrides();
    debugDefaultTargetPlatformOverride = null;
  });

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
