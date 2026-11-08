import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/native_platform_views.dart';

const _openWebUi = AdaptiveFloatingTab(
  label: 'Open WebUI',
  icon: Icon(Icons.circle),
  nativeAsset: 'assets/icons/open_webui_tab.png',
);
const _hermes = AdaptiveFloatingTab(
  label: 'Hermes',
  icon: Icon(Icons.square),
  nativeAsset: 'assets/icons/hermes_agent.png',
);

Widget _bar(
  List<AdaptiveFloatingTab> tabs, {
  int selectedIndex = 0,
  ValueChanged<int>? onTap,
  VoidCallback? onAction,
  Color? tint,
  Color? actionForeground,
  Color? actionBackground,
  double controlExtent = kAdaptiveFloatingBarDefaultExtent,
  double edgeInset = 16,
  double minimumBottomInset = 16,
}) => MaterialApp(
  builder: (context, child) => LegacyDesignCompatibility(child: child!),
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: AdaptiveFloatingTabBar(
        tabs: tabs,
        selectedIndex: selectedIndex,
        selectedItemColor: tint,
        tabsSemanticLabel: 'Backend',
        actionForegroundColor: actionForeground,
        actionBackgroundColor: actionBackground,
        onTap: onTap ?? (_) {},
        action: AdaptiveFloatingBarAction(
          label: 'New Chat',
          icon: Icons.edit,
          sfSymbol: 'square.and.pencil',
          onPressed: onAction ?? () {},
        ),
        itemWidth: 72,
        controlExtent: controlExtent,
        edgeInset: edgeInset,
        minimumBottomInset: minimumBottomInset,
      ),
    ),
  ),
);

/// Draws the bar as on iOS [major], 26 or later. The package itself picks
/// its native tab bar or its Flutter one from the real platform, so tests
/// read the tab bar's configuration rather than the view it creates.
void _simulateIOS(int major) {
  stubNativePlatformViews();
  PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
  PlatformUiCapabilities.debugIOSMajorVersionOverride = major;
  PlatformUiCapabilities.debugNativeIOS26Override = true;
}

/// A phone window, where UIKit stacks each tab's icon above its label, with
/// the home indicator's safe area.
void _phoneWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(402, 874) * 3;
  tester.view.devicePixelRatio = 3;
  tester.view.viewPadding = const FakeViewPadding(bottom: 34 * 3);
  addTearDown(tester.view.reset);
}

/// A full-width iPad window, where UIKit puts each tab's icon beside its
/// label.
void _tabletWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(834, 1210) * 2;
  tester.view.devicePixelRatio = 2;
  tester.view.viewPadding = const FakeViewPadding(bottom: 20 * 2);
  addTearDown(tester.view.reset);
}

CNTabBar _tabBar(WidgetTester tester) =>
    tester.widget<CNTabBar>(find.byType(CNTabBar));

NativeGlassIconButton _action(WidgetTester tester) =>
    tester.widget<NativeGlassIconButton>(find.byType(NativeGlassIconButton));

/// Removes the bar and lets the timers its controls started run out, on the
/// native toolbar and the package's Flutter one alike.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  group('Material', () {
    testWidgets('the bar leaves only the action for one backend', (
      tester,
    ) async {
      await tester.pumpWidget(_bar(const []));
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(FloatingActionButton), findsOneWidget);

      await tester.pumpWidget(_bar(const [_openWebUi, _hermes]));
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.destinations, hasLength(2));
      expect(bar.labelBehavior, NavigationDestinationLabelBehavior.alwaysHide);
      expect(
        tester.getCenter(find.byType(NavigationBar)).dx,
        lessThan(tester.getCenter(find.byType(FloatingActionButton)).dx),
      );
    });

    testWidgets('the bar and its round action take the control size', (
      tester,
    ) async {
      await tester.pumpWidget(
        _bar(const [_openWebUi, _hermes], controlExtent: 50, edgeInset: 12),
      );
      expect(tester.getSize(find.byType(NavigationBar)).height, 50);
      expect(
        tester.getSize(find.byType(FloatingActionButton)),
        const Size.square(50),
      );
      expect(
        tester
            .widget<FloatingActionButton>(find.byType(FloatingActionButton))
            .shape,
        isA<CircleBorder>(),
      );
      final window = tester.getSize(find.byType(Scaffold)).width;
      expect(tester.getTopLeft(find.byType(NavigationBar)).dx, 12);
      expect(
        tester.getTopRight(find.byType(FloatingActionButton)).dx,
        window - 12,
      );
      expect(
        AdaptiveFloatingTabBar.extentOf(
          tester.element(find.byType(NavigationBar)),
          controlExtent: 50,
        ),
        // The test window has no bottom safe area.
        16 + 50,
      );
    });

    testWidgets('the bar sits on the safe area or the least gap', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _bar(const [_openWebUi, _hermes], minimumBottomInset: 8),
      );
      final window = tester.getSize(find.byType(Scaffold)).height;
      final bar = find.byType(NavigationBar);
      expect(tester.getBottomLeft(bar).dy, window - 8);
      expect(
        tester.getBottomLeft(find.byType(FloatingActionButton)).dy,
        window - 8,
      );
      expect(
        AdaptiveFloatingTabBar.extentOf(
          tester.element(bar),
          minimumBottomInset: 8,
        ),
        8 + 44,
      );

      tester.view.viewPadding = FakeViewPadding(
        bottom: 34 * tester.view.devicePixelRatio,
      );
      await tester.pump();
      expect(tester.getBottomLeft(bar).dy, window - 34);
      expect(
        AdaptiveFloatingTabBar.extentOf(
          tester.element(bar),
          minimumBottomInset: 8,
        ),
        34 + 44,
      );
    });
  });

  group('iOS 27', () {
    setUp(() => _simulateIOS(27));
    tearDown(PlatformUiCapabilities.resetDebugOverrides);

    testWidgets(
      'the tabs are a 54 point tab bar of icons beside a glass New Chat',
      (tester) async {
        _phoneWindow(tester);
        const tint = Color(0xFF3366FF);
        const glyph = Color(0xFF202020);
        await tester.pumpWidget(
          _bar(
            const [_openWebUi, _hermes],
            selectedIndex: 1,
            tint: tint,
            actionForeground: glyph,
          ),
        );
        expect(find.byType(NavigationBar), findsNothing);
        expect(find.byType(FloatingActionButton), findsNothing);

        final tabBar = _tabBar(tester);
        // Icons only: the brand marks, so each backend keeps its own.
        expect([for (final item in tabBar.items) item.label], [null, null]);
        expect(
          [for (final item in tabBar.items) item.imageAsset?.assetPath],
          ['assets/icons/open_webui_tab.png', 'assets/icons/hermes_agent.png'],
        );
        expect(tabBar.iconSize, 22);
        expect(tabBar.currentIndex, 1);
        expect(tabBar.tint, tint);
        // One capsule of tabs: New Chat is not one of them.
        expect(tabBar.split, isFalse);
        // 14 points for the selection pill, the 54 point platter, and the
        // 21 points UIKit leaves below it.
        expect(tabBar.height, 14 + 54 + 21);

        final action = _action(tester);
        expect(action.symbol.name, 'square.and.pencil');
        expect(action.symbol.color, glyph);
        expect(action.dimension, 54);
        expect(action.symbol.size, 18 * 54 / 44);
        await _unmount(tester);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets('screen readers find the tabs as one adjustable control', (
      tester,
    ) async {
      _phoneWindow(tester);
      final semantics = tester.ensureSemantics();
      final taps = <int>[];
      await tester.pumpWidget(
        _bar(const [_openWebUi, _hermes], onTap: taps.add),
      );
      final backend = find.semantics.byLabel('Backend');
      expect(
        tester.getSemantics(find.bySemanticsLabel('Backend')),
        matchesSemantics(
          label: 'Backend',
          value: 'Open WebUI',
          increasedValue: 'Hermes',
          hasIncreaseAction: true,
        ),
      );
      // Adjusting it chooses the next tab, as a tap does.
      tester.semantics.increase(backend);
      expect(taps, [1]);

      await tester.pumpWidget(
        _bar(const [_openWebUi, _hermes], selectedIndex: 1, onTap: taps.add),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Backend')),
        matchesSemantics(
          label: 'Backend',
          value: 'Hermes',
          decreasedValue: 'Open WebUI',
          hasDecreaseAction: true,
        ),
      );
      tester.semantics.decrease(backend);
      expect(taps, [1, 0]);
      semantics.dispose();
      await _unmount(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets(
      'a tab reports its index, and New Chat runs without selecting',
      (tester) async {
        _phoneWindow(tester);
        final semantics = tester.ensureSemantics();
        final taps = <int>[];
        var actions = 0;
        await tester.pumpWidget(
          _bar(
            const [_openWebUi, _hermes],
            onTap: taps.add,
            onAction: () => actions++,
          ),
        );
        _tabBar(tester).onTap(1);
        expect(taps, [1]);

        _action(tester).onPressed();
        await tester.pump();
        expect(actions, 1);
        expect(taps, [1]);
        expect(_tabBar(tester).currentIndex, 0);
        // A button of its own, read as one control.
        expect(
          tester.getSemantics(find.bySemanticsLabel('New Chat')),
          matchesSemantics(
            label: 'New Chat',
            isButton: true,
            hasTapAction: true,
          ),
        );
        semantics.dispose();
        await _unmount(tester);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets('one backend leaves only New Chat', (tester) async {
      _phoneWindow(tester);
      await tester.pumpWidget(_bar(const [_openWebUi]));
      expect(find.byType(CNTabBar), findsNothing);
      expect(_action(tester).dimension, 54);

      // A second backend brings the tab bar in beside it.
      await tester.pumpWidget(_bar(const [_openWebUi, _hermes]));
      expect(find.byType(CNTabBar), findsOneWidget);
      await _unmount(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('on a phone New Chat sits on the 54 point platter', (
      tester,
    ) async {
      _phoneWindow(tester);
      await tester.pumpWidget(
        _bar(const [_openWebUi], controlExtent: 66, minimumBottomInset: 8),
      );
      final window = tester.getSize(find.byType(Scaffold));
      final action = find.byType(NativeGlassIconButton);
      // UIKit leaves 21 points under a phone's platter, at every text size
      // and in landscape.
      expect(tester.getBottomRight(action).dy, window.height - 21);
      expect(tester.getBottomRight(action).dx, window.width - 16);
      expect(tester.getSize(action), const Size.square(54));
      expect(
        AdaptiveFloatingTabBar.extentOf(
          tester.element(action),
          controlExtent: 66,
          minimumBottomInset: 8,
        ),
        54 + 21,
      );
      await _unmount(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets(
      'in an iPad window the tab bar keeps UIKit\'s smaller inline platter',
      (tester) async {
        _tabletWindow(tester);
        await tester.pumpWidget(_bar(const [_openWebUi, _hermes]));
        final window = tester.getSize(find.byType(Scaffold));
        final action = find.byType(NativeGlassIconButton);
        expect(_tabBar(tester).height, isNull);
        expect(tester.getBottomRight(action).dy, window.height - 20);
        expect(tester.getSize(action), const Size.square(44));
        expect(_action(tester).symbol.size, 18);
        expect(
          AdaptiveFloatingTabBar.extentOf(tester.element(action)),
          44 + 20,
        );
        await _unmount(tester);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });

  group('iOS 26', () {
    setUp(() => _simulateIOS(26));
    tearDown(PlatformUiCapabilities.resetDebugOverrides);

    testWidgets('a phone keeps the 62 point platter UIKit gives the tab bar', (
      tester,
    ) async {
      // The package keeps an iOS 26 tab bar at its own height.
      _phoneWindow(tester);
      await tester.pumpWidget(_bar(const [_openWebUi, _hermes]));
      final window = tester.getSize(find.byType(Scaffold));
      final action = find.byType(NativeGlassIconButton);
      expect(_tabBar(tester).height, isNull);
      expect(_tabBar(tester).iconSize, 22);
      expect(tester.getSize(action), const Size.square(62));
      expect(tester.getBottomRight(action).dy, window.height - 21);
      expect(AdaptiveFloatingTabBar.extentOf(tester.element(action)), 62 + 21);
      await _unmount(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });
}
