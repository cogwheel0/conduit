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
  TextDirection textDirection = TextDirection.ltr,
}) => MaterialApp(
  builder: (context, child) => LegacyDesignCompatibility(child: child!),
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: Directionality(
        textDirection: textDirection,
        child: AdaptiveFloatingTabBar(
          tabs: tabs,
          selectedIndex: selectedIndex,
          selectedItemColor: tint,
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
      'the tabs are a 44 point tab bar of icons beside a glass New Chat',
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
        // VoiceOver reads each icon by its backend's name, as a tab.
        expect(
          [for (final item in tabBar.items) item.semanticLabel],
          ['Open WebUI', 'Hermes'],
        );
        expect(tabBar.iconSize, 20);
        expect(tabBar.currentIndex, 1);
        expect(tabBar.tint, tint);
        // One capsule of tabs: New Chat is not one of them.
        expect(tabBar.split, isFalse);
        // 14 points for the selection pill, the 44 point platter, and the
        // 21 points UIKit leaves below it.
        expect(tabBar.height, 14 + 44 + 21);

        final action = _action(tester);
        expect(action.symbol.name, 'square.and.pencil');
        expect(action.symbol.color, glyph);
        expect(action.dimension, 44);
        expect(action.symbol.size, 18);
        await _unmount(tester);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets('screen readers reach each tab by its backend\'s name', (
      tester,
    ) async {
      _phoneWindow(tester);
      final semantics = tester.ensureSemantics();
      final taps = <int>[];
      await tester.pumpWidget(
        _bar(const [_openWebUi, _hermes], onTap: taps.add),
      );
      // The tab bar's own tabs, not a stand-in over them that would hide
      // the native ones from VoiceOver.
      expect(find.bySemanticsLabel('Open WebUI'), findsOneWidget);
      expect(find.bySemanticsLabel('Hermes'), findsOneWidget);
      expect(find.bySemanticsLabel('Backend'), findsNothing);
      // Activating a tab chooses it, as a tap does. These are the package's
      // Flutter tabs: the native ones are checked on a device.
      tester.semantics.tap(find.semantics.byLabel('Hermes'));
      expect(taps, [1]);
      await tester.pumpWidget(
        _bar(const [_openWebUi, _hermes], selectedIndex: 1, onTap: taps.add),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Hermes')),
        isSemantics(isSelected: true),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Open WebUI')),
        isSemantics(isSelected: false),
      );
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
      expect(_action(tester).dimension, 44);

      // A second backend brings the tab bar in beside it.
      await tester.pumpWidget(_bar(const [_openWebUi, _hermes]));
      expect(find.byType(CNTabBar), findsOneWidget);
      await _unmount(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('on a phone New Chat sits on the 44 point platter', (
      tester,
    ) async {
      _phoneWindow(tester);
      await tester.pumpWidget(
        _bar(const [_openWebUi], controlExtent: 66, minimumBottomInset: 8),
      );
      final window = tester.getSize(find.byType(Scaffold));
      final action = find.byType(NativeGlassIconButton);
      // New Chat sits on the 34 point safe area, as the composer does.
      expect(tester.getBottomRight(action).dy, window.height - 34);
      expect(tester.getBottomRight(action).dx, window.width - 16);
      expect(tester.getSize(action), const Size.square(44));
      expect(
        AdaptiveFloatingTabBar.extentOf(
          tester.element(action),
          controlExtent: 66,
          minimumBottomInset: 8,
        ),
        34 + 44,
      );

      // With two backends the platter's bottom lands on New Chat's: UIKit
      // keeps 21 points below it inside the tab bar, so the bar ends 21
      // points lower.
      await tester.pumpWidget(
        _bar(
          const [_openWebUi, _hermes],
          controlExtent: 66,
          minimumBottomInset: 8,
        ),
      );
      expect(tester.getBottomRight(action).dy, window.height - 34);
      expect(
        tester.getBottomLeft(find.byType(CNTabBar)).dy,
        window.height - 34 + 21,
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
        // The window's 20 point safe area, which is also the strip UIKit
        // keeps below an inline platter, so the tab bar ends at the bottom.
        expect(tester.getBottomRight(action).dy, window.height - 20);
        expect(tester.getBottomLeft(find.byType(CNTabBar)).dy, window.height);
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
    testWidgets('the platter starts where the header\'s leading button does', (
      tester,
    ) async {
      _phoneWindow(tester);
      await tester.pumpWidget(_bar(const [_openWebUi, _hermes]));
      final window = tester.getSize(find.byType(Scaffold));
      final tabBar = find.byType(CNTabBar);
      // UIKit keeps 21 points on each side of a stacked platter, which is
      // 16 points plus 86 for each tab wide: the bar starts 21 points
      // before the edge inset and is exactly that wide, so the platter
      // starts at the inset.
      expect(tester.getTopLeft(tabBar).dx, 16 - 21);
      expect(tester.getSize(tabBar).width, 16 + 86 * 2 + 2 * 21);
      // New Chat ends where the header's trailing button does, and the
      // room left over is between them.
      expect(
        tester.getTopRight(find.byType(NativeGlassIconButton)).dx,
        window.width - 16,
      );
      await _unmount(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('a right-to-left window mirrors the platter and New Chat', (
      tester,
    ) async {
      _phoneWindow(tester);
      await tester.pumpWidget(
        _bar(const [_openWebUi, _hermes], textDirection: TextDirection.rtl),
      );
      final window = tester.getSize(find.byType(Scaffold));
      expect(
        tester.getTopRight(find.byType(CNTabBar)).dx,
        window.width - (16 - 21),
      );
      expect(tester.getTopLeft(find.byType(NativeGlassIconButton)).dx, 16);
      await _unmount(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('an iPad window starts the inline platter at the inset too', (
      tester,
    ) async {
      _tabletWindow(tester);
      await tester.pumpWidget(_bar(const [_openWebUi, _hermes]));
      final tabBar = find.byType(CNTabBar);
      // UIKit keeps 38 points beside an inline platter, 4 points plus 70
      // for each tab wide.
      expect(tester.getTopLeft(tabBar).dx, 16 - 38);
      expect(tester.getSize(tabBar).width, 4 + 70 * 2 + 2 * 38);
      await _unmount(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('widening the window lays the tab bar out for the new window', (
      tester,
    ) async {
      _phoneWindow(tester);
      await tester.pumpWidget(_bar(const [_openWebUi, _hermes]));
      // Let the tab bar report the size it was given.
      await tester.pump();
      await tester.pump();
      expect(_tabBar(tester).height, 14 + 44 + 21);
      expect(_action(tester).dimension, 44);
      final phoneTabBar = tester.state(find.byType(CNTabBar));

      // An iPad window, where UIKit lays the tab bar out inline. The size
      // the phone's tab bar reported was only the height it was given, so
      // it must not keep the bar stacked.
      _tabletWindow(tester);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(_tabBar(tester).height, isNull);
      expect(_action(tester).dimension, 44);
      expect(
        AdaptiveFloatingTabBar.extentOf(
          tester.element(find.byType(NativeGlassIconButton)),
        ),
        44 + 20,
      );
      // The same tab bar, which measures itself again rather than being
      // created anew and flashing.
      expect(tester.state(find.byType(CNTabBar)), same(phoneTabBar));

      // And back.
      _phoneWindow(tester);
      await tester.pump();
      await tester.pump();
      expect(_tabBar(tester).height, 14 + 44 + 21);
      expect(_action(tester).dimension, 44);
      expect(tester.state(find.byType(CNTabBar)), same(phoneTabBar));
      await _unmount(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });

  group('iOS 26', () {
    setUp(() => _simulateIOS(26));
    tearDown(PlatformUiCapabilities.resetDebugOverrides);

    testWidgets('a phone gets the 44 point platter as on iOS 27', (
      tester,
    ) async {
      // The package sizes a bar of icons only on iOS 26 too.
      _phoneWindow(tester);
      await tester.pumpWidget(_bar(const [_openWebUi, _hermes]));
      final window = tester.getSize(find.byType(Scaffold));
      final action = find.byType(NativeGlassIconButton);
      expect(_tabBar(tester).height, 14 + 44 + 21);
      expect(_tabBar(tester).iconSize, 20);
      expect(tester.getSize(action), const Size.square(44));
      expect(tester.getBottomRight(action).dy, window.height - 34);
      expect(
        tester.getBottomLeft(find.byType(CNTabBar)).dy,
        window.height - 34 + 21,
      );
      expect(AdaptiveFloatingTabBar.extentOf(tester.element(action)), 34 + 44);
      await _unmount(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });
}
