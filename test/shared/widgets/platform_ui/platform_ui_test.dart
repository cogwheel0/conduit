import 'package:checks/checks.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/sidebar_ios26_scaffold.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  group('PlatformUiCapabilities', () {
    test('selects Flutter Material on Android regardless of iOS override', () {
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
      PlatformUiCapabilities.debugNativeIOS26Override = true;

      check(PlatformUiCapabilities.isAndroid).isTrue();
      check(PlatformUiCapabilities.usesNativeIOS26).isFalse();
    });

    test('selects Flutter Cupertino before iOS 26', () {
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 25;
      PlatformUiCapabilities.debugNativeIOS26Override = true;

      check(PlatformUiCapabilities.isIOS).isTrue();
      check(PlatformUiCapabilities.usesNativeIOS26).isFalse();
    });

    test('version detection failure cannot be forced into native controls', () {
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 0;
      PlatformUiCapabilities.debugNativeIOS26Override = true;

      check(PlatformUiCapabilities.usesNativeIOS26).isFalse();
    });

    test('selects native package controls on iOS 26', () {
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
      PlatformUiCapabilities.debugNativeIOS26Override = true;

      check(PlatformUiCapabilities.usesNativeIOS26).isTrue();
    });

    test('parses supported iOS version formats conservatively', () {
      check(
        PlatformUiCapabilities.parseIOSMajorVersion(
          'Version 26.1 (Build 23B74)',
        ),
      ).equals(26);
      check(PlatformUiCapabilities.parseIOSMajorVersion('25.4')).equals(25);
      check(
        PlatformUiCapabilities.parseIOSMajorVersion(
          'Darwin Kernel Version 26.0.0',
        ),
      ).isNull();
      check(PlatformUiCapabilities.parseIOSMajorVersion('unknown')).isNull();
    });
  });

  testWidgets('application root follows the Flutter platform family', (
    tester,
  ) async {
    final router = GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => const SizedBox.shrink())],
    );
    addTearDown(router.dispose);

    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(AdaptiveApp.router(routerConfig: router));
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(CupertinoApp), findsNothing);

    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 25;
    await tester.pumpWidget(AdaptiveApp.router(routerConfig: router));
    expect(find.byType(CupertinoApp), findsOneWidget);
    expect(find.byType(MaterialApp), findsNothing);
  });

  testWidgets('switch adapter constructs native controls only on iOS 26', (
    tester,
  ) async {
    Widget host() => CupertinoApp(
      home: CupertinoPageScaffold(
        child: Material(
          type: MaterialType.transparency,
          child: AdaptiveSwitch(value: true, onChanged: (_) {}),
        ),
      ),
    );

    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 25;
    await tester.pumpWidget(host());
    expect(find.byType(CupertinoSwitch), findsOneWidget);
    expect(find.byType(CNSwitch), findsNothing);

    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    await tester.pumpWidget(host());
    expect(find.byType(CNSwitch), findsOneWidget);
  });

  testWidgets('primary control adapters stay Flutter before iOS 26', (
    tester,
  ) async {
    Widget host() => MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            AdaptiveButton(onPressed: () {}, label: 'Continue'),
            AdaptiveSlider(value: 0.5, onChanged: (_) {}),
            AdaptiveSegmentedControl(
              labels: const ['One', 'Two'],
              selectedIndex: 0,
              onValueChanged: (_) {},
            ),
          ],
        ),
      ),
    );

    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 25;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    await tester.pumpWidget(host());
    expect(find.byType(CupertinoButton), findsOneWidget);
    expect(find.byType(CupertinoSlider), findsOneWidget);
    expect(find.byType(CupertinoSlidingSegmentedControl<int>), findsOneWidget);
    expect(find.byType(CNButton), findsNothing);
    expect(find.byType(CNSlider), findsNothing);
    expect(find.byType(CNSegmentedControl), findsNothing);

    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    await tester.pumpWidget(host());
    expect(find.byType(CNButton), findsOneWidget);
    expect(find.byType(CNSlider), findsOneWidget);
    expect(find.byType(CNSegmentedControl), findsOneWidget);
  });

  testWidgets('glass backdrop constructs a native surface only on iOS 26', (
    tester,
  ) async {
    Widget host() => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          height: 56,
          child: AdaptiveGlassBackdrop(borderRadius: BorderRadius.circular(24)),
        ),
      ),
    );

    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    await tester.pumpWidget(host());
    expect(find.byType(CNButton), findsNothing);

    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 25;
    await tester.pumpWidget(host());
    expect(find.byType(CNButton), findsNothing);

    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(CNButton), findsNothing);
    final nativeBackdrop = tester.widget<LiquidGlassContainer>(
      find.byType(LiquidGlassContainer),
    );
    expect(nativeBackdrop.config.effect, CNGlassEffect.regular);
    expect(nativeBackdrop.config.shape, CNGlassEffectShape.rect);
    expect(nativeBackdrop.config.cornerRadius, 24);
    expect(nativeBackdrop.config.interactive, isFalse);
  });

  testWidgets('iOS 26 sidebar toolbar actions use standard touch targets', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;

    await tester.pumpWidget(
      CupertinoApp(
        home: SidebarIos26Scaffold(
          body: const SizedBox.expand(),
          actions: [
            AdaptiveAppBarAction(
              iosSymbol: 'magnifyingglass',
              icon: CupertinoIcons.search,
              onPressed: () {},
            ),
            AdaptiveAppBarAction(
              iosSymbol: 'square.and.pencil',
              icon: CupertinoIcons.create,
              onPressed: () {},
            ),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final buttons = tester.widgetList<CNButton>(find.byType(CNButton)).toList();
    expect(buttons, hasLength(2));
    for (final button in buttons) {
      expect(button.config.minHeight, 44);
      expect(button.config.width, 44);
    }
  });

  testWidgets('iOS 26 sidebar header uses the shared navigation bar', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;

    await tester.pumpWidget(
      const CupertinoApp(
        home: SidebarIos26Scaffold(
          body: SizedBox.expand(),
          leading: SizedBox.square(dimension: 44),
        ),
      ),
    );

    final scaffold = tester.widget<CupertinoPageScaffold>(
      find.byType(CupertinoPageScaffold),
    );
    expect(
      scaffold.navigationBar,
      isA<ConduitAdaptiveCupertinoNavigationBar>(),
    );
  });

  testWidgets('iOS 26 sidebar tab bar uses the standard icon extent', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;

    await tester.pumpWidget(
      CupertinoApp(
        home: SidebarIos26Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: AdaptiveBottomNavigationBar(
            items: const [
              AdaptiveNavigationDestination(
                icon: 'bubble.left',
                label: 'Chats',
              ),
              AdaptiveNavigationDestination(icon: 'doc.text', label: 'Notes'),
            ],
            selectedIndex: 0,
            onTap: (_) {},
          ),
        ),
      ),
    );

    final tabBar = tester.widget<CNTabBar>(find.byType(CNTabBar));
    expect(tabBar.iconSize, kCupertinoNativeControlSymbolExtent);
  });

  testWidgets('compatible iOS 26 toolbar menus join their action group', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    var selectionCount = 0;

    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: ConduitNativeToolbarActionGroup(
            actions: [
              ConduitNativeToolbarAction(
                iosSymbol: 'square.and.pencil',
                accessibilityLabel: 'New chat',
                onPressed: () {},
              ),
              ConduitNativeToolbarAction(
                iosSymbol: 'ellipsis',
                accessibilityLabel: 'More',
                menuItems: [
                  ConduitNativeToolbarMenuItem(
                    label: 'Edit',
                    iosSymbol: 'pencil',
                    onSelected: () => selectionCount += 1,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    final group = tester.widget<CNGlassButtonGroup>(
      find.byType(CNGlassButtonGroup),
    );
    expect(group.buttons, hasLength(2));
    expect(group.buttons.last.isPopup, isTrue);
    group.buttons.last.onMenuSelected!(0);
    expect(selectionCount, 1);
  });

  testWidgets('a single iOS 26 toolbar action stays circular', (tester) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;

    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: ConduitNativeToolbarActionGroup(
            actions: [
              ConduitNativeToolbarAction(
                iosSymbol: 'eye',
                accessibilityLabel: 'Temporary chat',
                onPressed: () {},
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(CNGlassButtonGroup), findsNothing);
    final button = tester.widget<CNButton>(find.byType(CNButton));
    expect(button.config.width, TouchTarget.minimum);
    expect(button.config.minHeight, TouchTarget.minimum);
    expect(button.config.padding, EdgeInsets.zero);
    expect(button.config.borderRadius, TouchTarget.minimum / 2);
  });

  testWidgets('rich iOS 26 toolbar menus retain the native popup adapter', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;

    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: ConduitNativeToolbarActionGroup(
            actions: [
              ConduitNativeToolbarAction(
                iosSymbol: 'person.2',
                accessibilityLabel: 'Members',
                onPressed: () {},
              ),
              ConduitNativeToolbarAction(
                iosSymbol: 'ellipsis',
                accessibilityLabel: 'More',
                menuItems: [
                  ConduitNativeToolbarMenuItem(
                    label: 'Delete',
                    iosSymbol: 'trash',
                    isDestructive: true,
                    onSelected: () {},
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(CNGlassButtonGroup), findsNothing);
    expect(find.byType(CNButton), findsOneWidget);
    expect(find.byType(CNPopupMenuButton), findsOneWidget);
  });

  testWidgets('chat-style destructive menus can remain in one glass group', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    var selectionCount = 0;

    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: ConduitNativeToolbarActionGroup(
            groupDestructiveMenus: true,
            actions: [
              ConduitNativeToolbarAction(
                iosSymbol: 'square.and.pencil',
                accessibilityLabel: 'New chat',
                onPressed: () {},
              ),
              ConduitNativeToolbarAction(
                iosSymbol: 'ellipsis',
                accessibilityLabel: 'More',
                menuItems: [
                  ConduitNativeToolbarMenuItem(
                    label: 'Delete',
                    iosSymbol: 'trash',
                    isDestructive: true,
                    onSelected: () => selectionCount += 1,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    final group = tester.widget<CNGlassButtonGroup>(
      find.byType(CNGlassButtonGroup),
    );
    expect(group.buttons, hasLength(2));
    expect(group.buttons.last.isPopup, isTrue);
    group.buttons.last.onMenuSelected!(0);
    expect(selectionCount, 1);
  });

  testWidgets('gesture-sensitive slider callbacks use the local fallback', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;

    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: AdaptiveSlider(
            value: 0.5,
            onChanged: (_) {},
            onChangeStart: (_) {},
          ),
        ),
      ),
    );

    expect(find.byType(CupertinoSlider), findsOneWidget);
    expect(find.byType(CNSlider), findsNothing);
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
}
