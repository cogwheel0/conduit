import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_native_better/cupertino_native_better.dart'
    show
        CNToolbar,
        CNToolbarButton,
        CNToolbarItemStyle,
        CNToolbarSegmentedGroup,
        CNToolbarSelectionMode,
        CNToolbarSpace;
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

/// Draws the bar as on iOS 26. The package itself picks its native toolbar
/// or its Flutter one from the real platform, so tests read the toolbar's
/// configuration rather than the view it creates.
void _simulateIOS26() {
  stubNativePlatformViews();
  PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
  PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
  PlatformUiCapabilities.debugNativeIOS26Override = true;
}

CNToolbar _toolbar(WidgetTester tester) =>
    tester.widget<CNToolbar>(find.byType(CNToolbar));

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

  group('iOS 26', () {
    setUp(_simulateIOS26);
    tearDown(PlatformUiCapabilities.resetDebugOverrides);

    testWidgets(
      'the bar is the system toolbar: a segmented group and a prominent action',
      (tester) async {
        const tint = Color(0xFF3366FF);
        const fill = Color(0xFF112233);
        const glyph = Color(0xFFFAFAFA);
        await tester.pumpWidget(
          _bar(
            const [_openWebUi, _hermes],
            selectedIndex: 1,
            tint: tint,
            actionBackground: fill,
            actionForeground: glyph,
          ),
        );
        expect(find.byType(NavigationBar), findsNothing);
        expect(find.byType(FloatingActionButton), findsNothing);

        final toolbar = _toolbar(tester);
        expect(toolbar.tint, tint);
        expect(toolbar.items, hasLength(3));
        final [tabs, space, action] = toolbar.items;

        tabs as CNToolbarSegmentedGroup;
        expect(tabs.id, isNotNull);
        expect(tabs.selectionMode, CNToolbarSelectionMode.selectOne);
        expect(
          [for (final s in tabs.segments) s.label],
          ['Open WebUI', 'Hermes'],
        );
        // The brand marks, not symbols, so each backend keeps its own.
        expect(
          [for (final s in tabs.segments) s.imageAsset?.assetPath],
          ['assets/icons/open_webui_tab.png', 'assets/icons/hermes_agent.png'],
        );
        expect([for (final s in tabs.segments) s.icon], [null, null]);
        expect(tabs.selectedIndices, {1});

        expect(space, isA<CNToolbarSpace>());
        expect((space as CNToolbarSpace).flexible, isTrue);

        action as CNToolbarButton;
        expect(action.id, isNotNull);
        expect(action.label, 'New Chat');
        expect(action.icon?.name, 'square.and.pencil');
        expect(action.icon?.color, glyph);
        expect(action.style, CNToolbarItemStyle.prominent);
        expect(action.tint, fill);
        expect(
          {for (final item in toolbar.items) item.id},
          hasLength(3),
          reason: 'each item keeps its own id across updates',
        );
        await _unmount(tester);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets('one backend leaves only the action', (tester) async {
      await tester.pumpWidget(_bar(const [_openWebUi]));
      final items = _toolbar(tester).items;
      expect(items.whereType<CNToolbarSegmentedGroup>(), isEmpty);
      expect(items.whereType<CNToolbarButton>().single.label, 'New Chat');

      // A second backend appears in the same toolbar.
      await tester.pumpWidget(_bar(const [_openWebUi, _hermes]));
      expect(find.byType(CNToolbar), findsOneWidget);
      expect(
        _toolbar(tester).items.whereType<CNToolbarSegmentedGroup>(),
        hasLength(1),
      );
      await _unmount(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('a segment reports its tab and the button runs the action', (
      tester,
    ) async {
      final taps = <int>[];
      var actions = 0;
      await tester.pumpWidget(
        _bar(
          const [_openWebUi, _hermes],
          onTap: taps.add,
          onAction: () => actions++,
        ),
      );
      final items = _toolbar(tester).items;
      items.whereType<CNToolbarSegmentedGroup>().single.onSelected!(1);
      expect(taps, [1]);
      items.whereType<CNToolbarButton>().single.onPressed!();
      expect(actions, 1);
      await _unmount(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets(
      'the toolbar sits on the safe area or the least gap, 44 points high',
      (tester) async {
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _bar(
            const [_openWebUi, _hermes],
            minimumBottomInset: 8,
            controlExtent: 66,
          ),
        );
        final window = tester.getSize(find.byType(Scaffold)).height;
        final toolbar = find.byType(CNToolbar);
        expect(tester.getBottomLeft(toolbar).dy, window - 8);
        // The toolbar keeps its height at every text size.
        expect(tester.getSize(toolbar).height, 44);
        expect(
          AdaptiveFloatingTabBar.extentOf(
            tester.element(toolbar),
            minimumBottomInset: 8,
            controlExtent: 66,
          ),
          8 + 44,
        );

        tester.view.viewPadding = FakeViewPadding(
          bottom: 34 * tester.view.devicePixelRatio,
        );
        await tester.pump();
        expect(tester.getBottomLeft(toolbar).dy, window - 34);
        expect(
          AdaptiveFloatingTabBar.extentOf(
            tester.element(toolbar),
            minimumBottomInset: 8,
            controlExtent: 66,
          ),
          34 + 44,
        );
        await _unmount(tester);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });
}
