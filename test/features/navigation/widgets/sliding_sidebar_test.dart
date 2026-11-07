import 'dart:async';

import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit/features/hermes/widgets/hermes_sessions_tab.dart';
import 'package:conduit/features/navigation/widgets/drawer_shell_page.dart';
import 'package:conduit/features/navigation/widgets/responsive_drawer_layout.dart';
import 'package:conduit/features/navigation/providers/sidebar_providers.dart';
import 'package:conduit/features/navigation/widgets/sidebar_user_pill.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/chrome_gradient_fade.dart';
import 'package:conduit/shared/widgets/sidebar_layout_contract.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'sidebar_page_test_support.dart';

const _user = User(
  id: 'demo',
  username: 'demo',
  name: 'Demo Account',
  email: 'demo@example.test',
  role: 'user',
);

void main() {
  testWidgets('the existing tabbed layout remains the default', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        slidingSidebarEnabled: false,
        shellChat: const Scaffold(body: Text('Chat content')),
      ),
    );
    await tester.pumpAndSettle();
    final drawer = tester.widget<ResponsiveDrawerLayout>(
      find.byType(ResponsiveDrawerLayout),
    );
    expect(drawer.maxFraction, 1.0);
    expect(drawer.roundPushedContent, isFalse);
    expect(drawer.settleHaptics, isFalse);
    expect(
      find.byKey(const ValueKey<String>('sidebar-destinations')),
      findsNothing,
    );
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the tabbed layout dims the chat behind its open drawer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        slidingSidebarEnabled: false,
        shellChat: const Scaffold(body: Text('Chat content')),
      ),
    );
    await tester.pumpAndSettle();
    Iterable<Color> translucentLayers() => tester
        .widgetList<ColoredBox>(
          find.descendant(
            of: find.byType(ResponsiveDrawerLayout),
            matching: find.byType(ColoredBox),
          ),
        )
        .map((box) => box.color)
        .where((color) => color.a > 0 && color.a < 1);
    expect(translucentLayers(), isEmpty);
    await sidebarTestOpenSidebar(tester);
    expect(translucentLayers(), isNotEmpty);
  });

  testWidgets(
    'phone menu leaves a curved, tappable slice of the chat visible',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      List<String> accessibleLabels() => tester.semantics
          .simulatedAccessibilityTraversal()
          .map((node) => node.getSemanticsData().label)
          .toList();
      try {
        await tester.pumpWidget(
          sidebarTestBuildHarness(
            controllers: SidebarTestSidebarHarnessControllers(),
            shellChat: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () =>
                        SidebarDrawerControllerScope.maybeOf(context)!.open(),
                    child: const Text('Open menu'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final layout = tester.widget<ResponsiveDrawerLayout>(
          find.descendant(
            of: find.byType(DrawerShellPage),
            matching: find.byType(ResponsiveDrawerLayout),
          ),
        );
        expect(layout.maxFraction, lessThan(1));
        expect(layout.settleHaptics, isTrue);
        expect(accessibleLabels(), contains('Open menu'));
        await tester.tap(find.text('Open menu'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<PushedContentFrame>(find.byType(PushedContentFrame))
              .radius,
          greaterThan(0),
        );
        expect(accessibleLabels(), isNot(contains('Open menu')));
        final chatX = tester.getTopLeft(find.text('Open menu')).dx;
        expect(chatX, greaterThan(300));
        await tester.tapAt(const Offset(380, 420));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(find.text('Open menu')).dx, lessThan(chatX));
        expect(accessibleLabels(), contains('Open menu'));
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('the open chat turns grey inside a glass edge', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        theme: AppTheme.dark(TweakcnThemes.conduit),
        shellChat: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () =>
                    SidebarDrawerControllerScope.maybeOf(context)!.open(),
                child: const Text('Open menu'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final frame = find.byType(PushedContentFrame);
    final theme = tester.element(frame).conduitTheme;
    PushedContentFrame current() => tester.widget<PushedContentFrame>(frame);
    expect(current().veil.a, 0);
    expect(current().edge.a, 0);

    await tester.tap(find.text('Open menu'));
    await tester.pumpAndSettle();
    // A dark page lightens to grey beside the drawer, instead of going black,
    // while its text dims.
    final page = Color.alphaBlend(current().veil, theme.surfaceBackground);
    final text = Color.alphaBlend(current().veil, theme.textPrimary);
    expect(
      page.computeLuminance(),
      greaterThan(theme.surfaceBackground.computeLuminance()),
    );
    expect(
      text.computeLuminance(),
      lessThan(theme.textPrimary.computeLuminance()),
    );
    expect(current().edgeWidth, greaterThan(0));
    expect(current().edge.a, greaterThan(0));
    expect(current().backdrop, theme.surfaceBackground);
    // A rounded clip around the chat's native controls makes iOS draw the
    // veil above them twice, so the corners are painted instead.
    expect(
      find.ancestor(
        of: find.text('Open menu'),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is ClipRSuperellipse ||
              widget is ClipRRect ||
              widget is ClipPath ||
              widget is ClipOval,
        ),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  for (final (fillsScreen, radius) in [(true, 55.0), (false, 36.0)]) {
    testWidgets(
      'open content takes the screen corner radius (fills screen: $fillsScreen)',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        tester.view.display.size = fillsScreen
            ? const Size(390, 844)
            : const Size(1024, 1366);
        addTearDown(tester.view.reset);
        addTearDown(tester.view.display.reset);
        PlatformUiCapabilities.debugDisplayCornerRadiusOverride = 55;
        addTearDown(PlatformUiCapabilities.resetDebugOverrides);
        await tester.pumpWidget(
          sidebarTestBuildHarness(
            controllers: SidebarTestSidebarHarnessControllers(),
            shellChat: const Scaffold(body: Text('Chat content')),
          ),
        );
        await tester.pumpAndSettle();
        double corner() => tester
            .widget<PushedContentFrame>(find.byType(PushedContentFrame))
            .radius;
        expect(corner(), 0);
        await sidebarTestOpenSidebar(tester);
        expect(corner(), radius);
      },
    );
  }

  for (final open in [true, false]) {
    testWidgets('status-bar tap scrolls the open sidebar to the top ($open)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final date = DateTime(2026, 1, 1);
      await tester.pumpWidget(
        sidebarTestBuildHarness(
          controllers: SidebarTestSidebarHarnessControllers(),
          shellChat: const Scaffold(body: Text('Chat content')),
          conversations: [
            for (var i = 0; i < 40; i++)
              Conversation(
                id: 'demo-$i',
                title: 'Example $i',
                createdAt: date,
                updatedAt: date,
              ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      if (open) await sidebarTestOpenSidebar(tester);
      final history = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(
                const PageStorageKey<String>('chats_drawer_scroll'),
                skipOffstage: false,
              ),
              matching: find.byType(Scrollable, skipOffstage: false),
              skipOffstage: false,
            )
            .first,
      );
      history.position.jumpTo(400);
      await tester.pump();

      tester.simulateStatusBarTap();
      await tester.pumpAndSettle();

      expect(history.position.pixels, open ? 0 : 400);
    });
  }

  testWidgets('a page pushed over the open sidebar keeps the status bar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final date = DateTime(2026, 1, 1);
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        shellChat: const Scaffold(body: Text('Chat content')),
        appearancePage: const Scaffold(body: Text('Appearance settings')),
        conversations: [
          for (var i = 0; i < 40; i++)
            Conversation(
              id: 'demo-$i',
              title: 'Example $i',
              createdAt: date,
              updatedAt: date,
            ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await sidebarTestOpenSidebar(tester);
    final history = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(const PageStorageKey<String>('chats_drawer_scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    history.position.jumpTo(400);
    unawaited(NavigationService.router.push(Routes.appearanceSettings));
    await tester.pumpAndSettle();
    expect(find.text('Appearance settings'), findsOneWidget);

    tester.simulateStatusBarTap();
    await tester.pumpAndSettle();
    // A scroll started while covered would finish once the page closes.
    NavigationService.router.pop();
    await tester.pumpAndSettle();

    expect(find.text('Appearance settings'), findsNothing);
    expect(history.position.pixels, 400);
  });

  testWidgets('offscreen sidebar defers native header controls until opened', (
    tester,
  ) async {
    final child = sidebarTestBuildHarness(
      controllers: SidebarTestSidebarHarnessControllers(),
    );
    await tester.pumpWidget(
      DrawerChromeCompositionScope(composeNativeChrome: false, child: child),
    );
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey<String>('sidebar-search-button'));
    expect(search, findsNothing);
    expect(
      find.byKey(const ValueKey<String>('sidebar-create-button')),
      findsNothing,
    );
    expect(find.byType(SidebarProfileAppBarLeading), findsNothing);
    await tester.pumpWidget(
      DrawerChromeCompositionScope(composeNativeChrome: true, child: child),
    );
    await tester.pumpAndSettle();
    expect(search, findsOneWidget);
  });

  testWidgets('header and bottom bar float over the scrolling history', (
    tester,
  ) async {
    final date = DateTime(2026, 1, 1);
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        currentUser: _user,
        conversations: List.generate(
          40,
          (i) => Conversation(
            id: 'demo-$i',
            title: 'Example $i',
            createdAt: date,
            updatedAt: date,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final profile = find.byType(SidebarProfileAppBarLeading);
    final search = find.byKey(const ValueKey<String>('sidebar-search-button'));
    final create = find.byKey(const ValueKey<String>('sidebar-create-button'));
    final destinations = find.byKey(
      const ValueKey<String>('sidebar-destinations'),
    );
    final history = find.byKey(
      const PageStorageKey<String>('chats_drawer_scroll'),
    );
    expect(find.text('Conduit'), findsNothing);
    expect(sidebarTestTooltip('New Chat'), findsOneWidget);
    expect(tester.getCenter(profile).dy, tester.getCenter(search).dy);
    expect(
      tester.getCenter(profile).dx,
      lessThan(tester.getCenter(search).dx),
    );
    expect(find.byType(ConduitChromeGradientFade), findsNWidgets(2));
    // The destinations lead the history, which runs under both bars.
    expect(
      find.descendant(of: history, matching: destinations),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(destinations).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(search).dy),
    );
    final surface = find.byKey(const ValueKey<String>('sidebar-page-surface'));
    expect(tester.getRect(history).top, tester.getRect(surface).top);
    expect(tester.getRect(history).bottom, tester.getRect(surface).bottom);
    expect(
      tester.getBottomLeft(create).dy,
      greaterThan(tester.getBottomLeft(find.text('Example 0')).dy),
    );

    final searchBefore = tester.getTopLeft(search);
    final createBefore = tester.getTopLeft(create);
    final destinationsBefore = tester.getTopLeft(destinations).dy;
    await tester.drag(history, const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(search), searchBefore);
    expect(tester.getTopLeft(create), createBefore);
    expect(tester.getTopLeft(destinations).dy, lessThan(destinationsBefore));
  });

  testWidgets('the sliding layout takes the tabbed sidebar surface', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        currentUser: _user,
        theme: AppTheme.light(TweakcnThemes.conduit),
        shellChat: const Scaffold(body: Text('Chat content')),
      ),
    );
    await tester.pumpAndSettle();
    final surface = find.byKey(const ValueKey<String>('sidebar-page-surface'));
    final theme = tester.element(surface).conduitTheme;
    expect(theme.surfaceBackground, isNot(theme.surfaceContainerHighest));
    expect(tester.widget<Material>(surface).color, theme.surfaceBackground);
    final fades = tester.widgetList<ConduitChromeGradientFade>(
      find.descendant(
        of: surface,
        matching: find.byType(ConduitChromeGradientFade),
      ),
    );
    expect(fades, hasLength(2));
    for (final fade in fades) {
      expect(fade.backgroundColor, theme.surfaceBackground);
    }
    // The backdrop shows at the open chat's rounded corners, beside the
    // sidebar.
    final backdrop = tester.widget<ColoredBox>(
      find
          .descendant(
            of: find.byType(ResponsiveDrawerLayout),
            matching: find.byType(ColoredBox),
          )
          .first,
    );
    expect(backdrop.color, theme.surfaceBackground);
  });

  testWidgets('history scrollbars run between the header and bottom bar', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final ratio = tester.view.devicePixelRatio;
    tester.view.padding = FakeViewPadding(top: 47 * ratio, bottom: 34 * ratio);
    tester.view.viewPadding = FakeViewPadding(
      top: 47 * ratio,
      bottom: 34 * ratio,
    );
    final date = DateTime(2026, 1, 1);
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        currentUser: _user,
        hermesEnabled: true,
        conversations: List.generate(
          40,
          (i) => Conversation(
            id: 'demo-$i',
            title: 'Example $i',
            createdAt: date,
            updatedAt: date,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final header = tester
        .widgetList<ConduitChromeGradientFade>(
          find.byType(ConduitChromeGradientFade),
        )
        .singleWhere((fade) => fade.edge == ConduitChromeFadeEdge.top);
    expect(header.contentHeight, greaterThan(47));
    final surface = tester.getRect(
      find.byKey(const ValueKey<String>('sidebar-page-surface')),
    );
    final bar = tester.getRect(
      find.byKey(const ValueKey<String>('sidebar-create-button')),
    );

    // The Open WebUI history, and the Hermes one behind it.
    final wrappers = find.byType(SidebarTabScrollbar, skipOffstage: false);
    final scrollbars = find.descendant(
      of: wrappers,
      matching: find.byWidgetPredicate(
        (widget) => widget is RawScrollbar,
        skipOffstage: false,
      ),
    );
    expect(scrollbars, findsNWidgets(2));
    for (final scrollbar in scrollbars.evaluate()) {
      final painter =
          tester
                  .widget<CustomPaint>(
                    find
                        .descendant(
                          of: find.byWidget(
                            scrollbar.widget,
                            skipOffstage: false,
                          ),
                          matching: find.byType(
                            CustomPaint,
                            skipOffstage: false,
                          ),
                        )
                        .first,
                  )
                  .foregroundPainter!
              as ScrollbarPainter;
      final padding = painter.padding.resolve(TextDirection.ltr);
      expect(padding.top, header.contentHeight);
      expect(padding.bottom, surface.bottom - bar.top);
    }
    // The lists keep their own padding.
    for (final wrapper in wrappers.evaluate()) {
      expect(
        MediaQuery.paddingOf(
          tester.element(
            find
                .descendant(
                  of: find.byWidget(wrapper.widget, skipOffstage: false),
                  matching: find.byType(CustomScrollView, skipOffstage: false),
                )
                .first,
          ),
        ),
        MediaQuery.paddingOf(wrapper),
      );
    }
  });

  testWidgets('destinations stay above an empty history', (tester) async {
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
      ),
    );
    await tester.pumpAndSettle();
    final empty = find.text('No conversations yet');
    expect(empty, findsOneWidget);
    expect(
      tester.getTopLeft(empty).dy,
      greaterThan(tester.getBottomLeft(sidebarTestDestinationLabel('Notes')).dy),
    );
    final history = find.descendant(
      of: find.byKey(const ValueKey<String>('sidebar-chat-history')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(history.first).position;
    expect(position.maxScrollExtent, 0);
  });

  testWidgets('iOS 26 draws the bottom bar as one native view', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);
    AdaptiveFloatingTabBar.debugIconRenderer = (_, asset, _, _) =>
        SynchronousFuture(Uint8List.fromList(asset.codeUnits));
    addTearDown(AdaptiveFloatingTabBar.debugReset);
    final updates = <Map<Object?, Object?>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (_) async => null,
    );
    const channel = MethodChannel('conduit/floating_tab_bar_4242');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'update') {
        updates.add(call.arguments as Map<Object?, Object?>);
      }
      return null;
    });
    try {
      await tester.pumpWidget(
        sidebarTestBuildHarness(
          controllers: SidebarTestSidebarHarnessControllers(),
          currentUser: _user,
          hermesEnabled: true,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      final search = tester.widget<CNButton>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('sidebar-search-button')),
          matching: find.byType(CNButton),
        ),
      );
      expect(search.icon?.name, 'magnifyingglass');
      expect(search.config.style, CNButtonStyle.glass);
      expect(find.byType(CNTabBar), findsNothing);

      final bar = find.byKey(const ValueKey<String>('sidebar-backend-selector'));
      final view = tester.widget<UiKitView>(
        find.descendant(of: bar, matching: find.byType(UiKitView)),
      );
      expect(view.viewType, 'conduit/floating_tab_bar');
      final params = view.creationParams as Map;
      final tabs = (params['tabs'] as List).cast<Map>();
      expect([for (final tab in tabs) tab['label']], ['Open WebUI', 'Hermes']);
      expect([
        for (final tab in tabs) String.fromCharCodes(tab['image'] as Uint8List),
      ], ['assets/icons/open_webui_tab.png', 'assets/icons/hermes_agent.png']);
      expect(params['selectedIndex'], 0);
      expect(params['actionSymbol'], 'square.and.pencil');
      expect(params['actionLabel'], 'New Chat');
      // The bar is drawn at the size of the header's search button.
      final searchButton = find.byKey(
        const ValueKey<String>('sidebar-search-button'),
      );
      expect(params['controlExtent'], tester.getSize(searchButton).height);
      expect(params['actionSymbolSize'], search.icon?.size);
      expect(
        params['edgeInset'],
        tester
                .getTopRight(
                  find.byKey(const ValueKey<String>('sidebar-page-surface')),
                )
                .dx -
            tester.getTopRight(searchButton).dx,
      );
      // The chat composer's gap, so the bar lines up with it.
      expect(params['bottomInset'], Spacing.sm);

      view.onPlatformViewCreated!(4242);
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('select', 1),
        ),
        (_) {},
      );
      await tester.pump();
      final container = ProviderScope.containerOf(tester.element(bar));
      expect(container.read(sidebarHistoryTabProvider), SidebarTabId.hermes);
      expect(updates.last['selectedIndex'], 1);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    }
  });

  testWidgets('native tab icons render at their point size', (tester) async {
    final icons = await tester.runAsync(
      () => Future.wait([
        AdaptiveFloatingTabBar.renderNativeIcon(
          rootBundle,
          'assets/icons/open_webui_tab.png',
          22,
          3,
        ),
        AdaptiveFloatingTabBar.renderNativeIcon(
          rootBundle,
          'assets/icons/hermes_agent.png',
          26,
          3,
        ),
      ]),
    );
    final sizes = [
      for (final icon in icons!)
        (() {
          final png = ByteData.sublistView(icon);
          expect(png.getUint32(0), 0x89504E47);
          return (png.getUint32(16), png.getUint32(20));
        })(),
    ];
    expect(sizes.first, (66, 66));
    expect(sizes.last.$2, 78);
  });

  testWidgets('Material backend tabs are an icon-only pill beside a FAB', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        sidebarTestBuildHarness(
          controllers: SidebarTestSidebarHarnessControllers(),
          hermesEnabled: true,
        ),
      );
      await tester.pumpAndSettle();
      final pill = tester.widget<NavigationBar>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('sidebar-backend-tabs')),
          matching: find.byType(NavigationBar),
        ),
      );
      expect(
        pill.labelBehavior,
        NavigationDestinationLabelBehavior.alwaysHide,
      );
      expect(pill.selectedIndex, 0);
      final create = find.byKey(const ValueKey<String>('sidebar-create-button'));
      expect(
        find.descendant(of: create, matching: find.byType(FloatingActionButton)),
        findsOneWidget,
      );
      expect(
        tester.getCenter(create).dy,
        tester.getCenter(sidebarTestBackendTab('Hermes')).dy,
      );
      // New Chat and the pill match the header's search button.
      final search = find.byKey(
        const ValueKey<String>('sidebar-search-button'),
      );
      expect(tester.getSize(create), tester.getSize(search));
      expect(
        tester.getSize(find.byKey(const ValueKey<String>('sidebar-backend-tabs'))).height,
        tester.getSize(search).height,
      );
      expect(tester.getTopRight(create).dx, tester.getTopRight(search).dx);
      // The chat composer's gap, so the bar lines up with it.
      final surface = find.byKey(
        const ValueKey<String>('sidebar-page-surface'),
      );
      expect(
        tester.getBottomRight(create).dy,
        tester.getBottomRight(surface).dy - Spacing.sm,
      );
      expect(
        tester.getCenter(sidebarTestBackendTab('Hermes')).dx,
        lessThan(tester.getCenter(create).dx),
      );
      await tester.tap(sidebarTestBackendTab('Hermes'));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(tester.element(create));
      expect(container.read(sidebarHistoryTabProvider), SidebarTabId.hermes);
      expect(find.byType(HermesSessionsTab).hitTestable(), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('destinations lead only the Open WebUI history', (
    tester,
  ) async {
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        hermesEnabled: true,
      ),
    );
    await tester.pumpAndSettle();
    final destinations = find.byKey(
      const ValueKey<String>('sidebar-destinations'),
    );
    expect(destinations.hitTestable(), findsOneWidget);
    await tester.tap(sidebarTestBackendTab('Hermes'));
    await tester.pumpAndSettle();
    expect(find.byType(HermesSessionsTab).hitTestable(), findsOneWidget);
    expect(destinations.hitTestable(), findsNothing);
    // Search filters the Open WebUI history, not Hermes sessions.
    expect(
      find.byKey(const ValueKey<String>('sidebar-search-button')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(HermesSessionsTab),
        matching: find.byKey(const ValueKey<String>('sidebar-destinations')),
      ),
      findsNothing,
    );
  });

  testWidgets('a single backend leaves only New Chat in the bottom bar', (
    tester,
  ) async {
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('sidebar-backend-tabs')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('sidebar-create-button')),
      findsOneWidget,
    );
  });

  for (final size in [const Size(320, 568), const Size(844, 390)]) {
    testWidgets('sidebar controls stay reachable at 2x text in $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controllers = SidebarTestSidebarHarnessControllers();
      await tester.pumpWidget(
        sidebarTestBuildHarness(
          controllers: controllers,
          currentUser: _user,
          textScale: 2,
          hermesEnabled: true,
        ),
      );
      await tester.pumpAndSettle();
      for (final label in ['Notes', 'Terminal', 'Channels']) {
        final destination = sidebarTestDestinationLabel(label);
        await tester.ensureVisible(destination);
        await tester.pumpAndSettle();
        expect(destination.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      expect(
        find.byType(SidebarProfileAppBarLeading).hitTestable(),
        findsOneWidget,
      );
      expect(
        find
            .byKey(const ValueKey<String>('sidebar-create-button'))
            .hitTestable(),
        findsOneWidget,
      );
    });
  }
}
