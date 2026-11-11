import 'dart:async';

import 'package:conduit/features/navigation/widgets/conversation_tile.dart'
    show kSidebarRowContentInset;
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
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/native_platform_views.dart';
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
    expect(tester.getCenter(profile).dx, lessThan(tester.getCenter(search).dx));
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

  testWidgets('the sliding layout keeps its narrow rows to titles: no dates, '
      'no Chats title, and New Chat below', (tester) async {
    final date = DateTime(2026, 1, 1);
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        currentUser: _user,
        conversations: [
          for (var i = 0; i < 3; i++)
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

    expect(find.text('Example 0'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('conversation-updated-stamp')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('chats-large-title')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('sidebar-collapsed-title')),
      findsNothing,
    );
    // The destinations are the sidebar's own rows, with no rule under them.
    final destinations = find.byKey(
      const ValueKey<String>('sidebar-destinations'),
    );
    // Their symbols start on the rows' content edge, where a read chat's
    // title starts, the names after them.
    final notesRow = find.byKey(
      const ValueKey<String>('sidebar-destination-notes'),
    );
    final notesSymbol = find.descendant(
      of: notesRow,
      matching: find.byType(Icon),
    );
    expect(tester.getTopLeft(notesSymbol).dx, kSidebarRowContentInset);
    expect(
      tester.getTopLeft(find.text('Notes')).dx,
      greaterThan(tester.getTopRight(notesSymbol).dx),
    );
    expect(
      find.descendant(of: destinations, matching: find.byType(ListTile)),
      findsNothing,
    );
    expect(
      find.descendant(of: destinations, matching: find.byType(Divider)),
      findsNothing,
    );
    // New Chat is below, in the bottom bar; the header keeps only Search.
    final search = find.byKey(const ValueKey<String>('sidebar-search-button'));
    final create = find.byKey(const ValueKey<String>('sidebar-create-button'));
    expect(
      tester.getTopLeft(create).dy,
      greaterThan(tester.getBottomLeft(find.text('Example 2')).dy),
    );
    expect(
      tester.getCenter(create).dy,
      greaterThan(tester.getCenter(search).dy),
    );
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
      greaterThan(
        tester.getBottomLeft(sidebarTestDestinationLabel('Notes')).dy,
      ),
    );
    final history = find.descendant(
      of: find.byKey(const ValueKey<String>('sidebar-chat-history')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(history.first).position;
    expect(position.maxScrollExtent, 0);
  });

  // On the default target platform, as the other sidebar tests. Under an iOS
  // target, Linux CI draws the package's Flutter fallback for every native
  // control in the sidebar, and one of them overflows its row by a few
  // pixels. The bar follows PlatformUiCapabilities, so its configuration is
  // checked either way.
  testWidgets('iOS 26 draws the backends as the system tab bar beside a '
      'glass New Chat', (tester) async {
    final semantics = tester.ensureSemantics();
    stubNativePlatformViews();
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);
    final haptics = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        currentUser: _user,
        hermesEnabled: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    final searchButton = find.byKey(
      const ValueKey<String>('sidebar-search-button'),
    );
    final search = tester.widget<CNButton>(
      find.descendant(of: searchButton, matching: find.byType(CNButton)),
    );
    expect(search.icon?.name, 'magnifyingglass');
    expect(search.config.style, CNButtonStyle.glass);

    final bar = find.byKey(const ValueKey<String>('sidebar-backend-selector'));
    // The only tab bar holds the backends; the destinations stay in the pane.
    expect(find.byType(CNTabBar), findsOneWidget);
    CNTabBar tabBar() => tester.widget<CNTabBar>(
      find.descendant(of: bar, matching: find.byType(CNTabBar)),
    );
    final theme = tester.element(bar).conduitTheme;

    // Icons only; screen readers read each tab by its backend's name.
    expect([for (final item in tabBar().items) item.label], [null, null]);
    expect(
      [for (final item in tabBar().items) item.semanticLabel],
      ['Open WebUI', 'Hermes'],
    );
    expect(
      [for (final item in tabBar().items) item.imageAsset?.assetPath],
      ['assets/icons/open_webui_tab.png', 'assets/icons/hermes_agent.png'],
    );
    expect(tabBar().currentIndex, 0);
    expect(tabBar().tint, theme.buttonPrimary);
    expect(tabBar().split, isFalse);

    final button = find.descendant(
      of: bar,
      matching: find.byType(NativeGlassIconButton),
    );
    final action = tester.widget<NativeGlassIconButton>(button);
    expect(action.symbol.name, 'square.and.pencil');
    expect(action.symbol.color, theme.textPrimary);

    // The test window is as wide as a tablet's, where UIKit lays the tab bar
    // out inline, on a 44 point platter. The window has no safe area, so
    // New Chat sits the chat composer's least gap of 8 points up, takes the
    // platter's size, ends under the header's search button, and the
    // history keeps their room clear.
    final surface = find.byKey(const ValueKey<String>('sidebar-page-surface'));
    expect(tester.getSize(button), const Size.square(44));
    expect(
      tester.getBottomRight(button).dy,
      tester.getBottomLeft(surface).dy - Spacing.sm,
    );
    expect(tester.getTopRight(button).dx, tester.getTopRight(searchButton).dx);
    final layout = tester.widget<SidebarTabLayoutScope>(
      find.byType(SidebarTabLayoutScope).first,
    );
    expect(layout.floatingChromeInsets?.bottom, Spacing.sm + 44);

    // Choosing the other backend switches the history and taps once.
    tabBar().onTap(1);
    await tester.pump();
    final container = ProviderScope.containerOf(tester.element(bar));
    expect(container.read(sidebarHistoryTabProvider), SidebarTabId.hermes);
    expect(tabBar().currentIndex, 1);
    expect(haptics, ['HapticFeedbackType.selectionClick']);
    // The tab bar reports the selected backend again; it changes nothing and
    // stays quiet.
    tabBar().onTap(1);
    await tester.pump();
    expect(container.read(sidebarHistoryTabProvider), SidebarTabId.hermes);
    expect(haptics, hasLength(1));
    // New Chat stays the action of the Hermes history, outside the tabs.
    expect(tabBar().items, hasLength(2));
    expect(
      tester.widget<NativeGlassIconButton>(button).symbol.name,
      'square.and.pencil',
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
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
      expect(pill.labelBehavior, NavigationDestinationLabelBehavior.alwaysHide);
      expect(pill.selectedIndex, 0);
      final create = find.byKey(
        const ValueKey<String>('sidebar-create-button'),
      );
      expect(
        find.descendant(
          of: create,
          matching: find.byType(FloatingActionButton),
        ),
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
        tester
            .getSize(find.byKey(const ValueKey<String>('sidebar-backend-tabs')))
            .height,
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

  testWidgets('destinations lead only the Open WebUI history', (tester) async {
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

  testWidgets('a long Hermes connection name stays clear of the profile in '
      'a narrow header', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const name = 'Research gateway in the shared lab rack';
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        currentUser: _user,
        hermesOnly: true,
        hermesEnabled: true,
        extraOverrides: [
          hermesConnectionsProvider.overrideWithValue(const [
            HermesConnectionProfile(
              id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              name: name,
              baseUrl: 'https://lab.example',
              documentTrustPrincipalId: 'aaaaaaaa-0000-4000-8000-000000000000',
            ),
            HermesConnectionProfile(
              id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              name: 'Home agent',
              baseUrl: 'https://home.example',
              documentTrustPrincipalId: 'bbbbbbbb-0000-4000-8000-000000000000',
            ),
          ]),
          hermesActiveConnectionIdProvider.overrideWithValue(
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          ),
          hermesActiveConnectionNameProvider.overrideWithValue(name),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final switcher = find.byKey(
      const ValueKey<String>('hermes-connection-switcher'),
    );
    final profile = find.byType(SidebarProfileAppBarLeading);
    expect(switcher.hitTestable(), findsOneWidget);
    expect(profile.hitTestable(), findsOneWidget);
    // Centred in the bar, and shortened before it reaches the profile.
    final bar = tester.getRect(
      find.byKey(const ValueKey('sidebar-page-surface')),
    );
    final pill = tester.getRect(switcher);
    expect(pill.left, greaterThan(tester.getRect(profile).right));
    expect(pill.center.dx, moreOrLessEquals(bar.center.dx, epsilon: 1));
    final semantics = tester.ensureSemantics();
    try {
      expect(
        tester.getSemantics(switcher),
        isSemantics(hint: 'Switch Connection'),
      );
    } finally {
      semantics.dispose();
    }
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
