import 'dart:ui' show SemanticsAction;

import 'package:checks/checks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/features/navigation/widgets/responsive_drawer_layout.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';

import 'responsive_drawer_layout_test_support.dart';

void main() {
  testWidgets('mobile drawer composes chrome only while visible', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestMobileSize,
        layoutKey: layoutKey,
        drawer: const DrawerTestDrawerCompositionProbe(),
      ),
    );
    check(find.text('drawer-chrome-inactive').evaluate()).length.equals(1);

    layoutKey.currentState!.open();
    await tester.pump();
    check(find.text('drawer-chrome-active').evaluate()).length.equals(1);
    await tester.pumpAndSettle();

    layoutKey.currentState!.close();
    await tester.pump();
    check(find.text('drawer-chrome-active').evaluate()).length.equals(1);
    await tester.pumpAndSettle();
    check(find.text('drawer-chrome-inactive').evaluate()).length.equals(1);
  });

  testWidgets('reversed opening releases chrome after closing', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestMobileSize,
        layoutKey: layoutKey,
        drawer: const DrawerTestDrawerCompositionProbe(),
      ),
    );

    layoutKey.currentState!.open();
    await tester.pump();
    check(find.text('drawer-chrome-active').evaluate()).length.equals(1);

    layoutKey.currentState!.close();
    await tester.pumpAndSettle();
    check(find.text('drawer-chrome-inactive').evaluate()).length.equals(1);
  });

  testWidgets('persistent tablet drawer always composes chrome', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestTabletSize,
        layoutKey: layoutKey,
        drawer: const DrawerTestDrawerCompositionProbe(),
        tabletDismissible: false,
      ),
    );

    check(find.text('drawer-chrome-active').evaluate()).length.equals(1);
    layoutKey.currentState!.close();
    await tester.pumpAndSettle();
    check(find.text('drawer-chrome-active').evaluate()).length.equals(1);
    layoutKey.currentState!.open();
    await tester.pumpAndSettle();
    check(find.text('drawer-chrome-active').evaluate()).length.equals(1);
  });

  testWidgets('tablet divider tracks drag and commits only when released', (
    tester,
  ) async {
    final committedWidths = <double>[];
    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestTabletSize,
        tabletResizable: true,
        onTabletDrawerWidthChanged: committedWidths.add,
      ),
    );

    final handle = find.byKey(
      const ValueKey<String>('tablet-sidebar-resize-handle'),
    );
    expect(handle, findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('tablet-drawer-panel'))).width,
      320,
    );

    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();

    expect(
      tester.getSize(find.byKey(const ValueKey('tablet-drawer-panel'))).width,
      closeTo(420, 0.1),
    );
    expect(committedWidths, isEmpty);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(committedWidths, [closeTo(420, 0.1)]);
  });

  testWidgets(
    'tablet preferred width clamps without overwriting and restores',
    (tester) async {
      final committedWidths = <double>[];
      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestTabletSize,
          tabletResizable: true,
          onTabletDrawerWidthChanged: committedWidths.add,
        ),
      );
      final handle = find.byKey(
        const ValueKey<String>('tablet-sidebar-resize-handle'),
      );
      final resizeGesture = await tester.startGesture(tester.getCenter(handle));
      await resizeGesture.moveBy(const Offset(160, 0));
      await tester.pump();
      await resizeGesture.up();
      await tester.pumpAndSettle();
      expect(committedWidths, [480]);

      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestTabletSize,
          layoutWidth: 700,
          tabletResizable: true,
          onTabletDrawerWidthChanged: committedWidths.add,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byKey(const ValueKey('tablet-drawer-panel'))).width,
        closeTo(380, 0.1),
      );
      expect(committedWidths, [480]);

      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestTabletSize,
          layoutWidth: 600,
          tabletResizable: true,
          onTabletDrawerWidthChanged: committedWidths.add,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byKey(const ValueKey('tablet-drawer-panel'))).width,
        320,
      );
      expect(committedWidths, [480]);

      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestTabletSize,
          tabletResizable: true,
          onTabletDrawerWidthChanged: committedWidths.add,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byKey(const ValueKey('tablet-drawer-panel'))).width,
        closeTo(480, 0.1),
      );
      expect(committedWidths, [480]);
    },
  );

  testWidgets('tablet divider cancel restores the uncommitted width', (
    tester,
  ) async {
    final committedWidths = <double>[];
    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestTabletSize,
        tabletResizable: true,
        onTabletDrawerWidthChanged: committedWidths.add,
      ),
    );
    final panel = find.byKey(const ValueKey<String>('tablet-drawer-panel'));
    final handle = find.byKey(
      const ValueKey<String>('tablet-sidebar-resize-handle'),
    );

    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();
    expect(tester.getSize(panel).width, closeTo(420, 0.1));
    await gesture.cancel();
    await tester.pumpAndSettle();

    expect(tester.getSize(panel).width, 320);
    expect(committedWidths, isEmpty);
  });

  testWidgets('tablet divider reverses immediately after clamped overshoot', (
    tester,
  ) async {
    await tester.pumpWidget(
      drawerTestBuildHarness(size: drawerTestTabletSize, tabletResizable: true),
    );
    final panel = find.byKey(const ValueKey<String>('tablet-drawer-panel'));
    final handle = find.byKey(
      const ValueKey<String>('tablet-sidebar-resize-handle'),
    );

    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(300, 0));
    await tester.pump();
    expect(tester.getSize(panel).width, 480);
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();
    expect(tester.getSize(panel).width, 380);
    await gesture.moveBy(const Offset(-50, 0));
    await tester.pump();
    expect(tester.getSize(panel).width, 330);
    await gesture.cancel();
    await tester.pumpAndSettle();
  });

  testWidgets('tablet divider double tap resets width to 320', (tester) async {
    final committedWidths = <double>[];
    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestTabletSize,
        tabletDrawerWidth: 440,
        tabletResizable: true,
        onTabletDrawerWidthChanged: committedWidths.add,
      ),
    );

    final handle = find.byKey(
      const ValueKey<String>('tablet-sidebar-resize-handle'),
    );
    await tester.tap(handle);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(handle);
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const ValueKey('tablet-drawer-panel'))).width,
      closeTo(320, 0.1),
    );
    expect(committedWidths, [320]);
  });

  testWidgets('tablet divider reset is inert at the default width', (
    tester,
  ) async {
    final committedWidths = <double>[];
    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestTabletSize,
        tabletResizable: true,
        onTabletDrawerWidthChanged: committedWidths.add,
      ),
    );

    final handle = find.byKey(
      const ValueKey<String>('tablet-sidebar-resize-handle'),
    );
    await tester.tap(handle);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(handle);
    await tester.pumpAndSettle();

    expect(committedWidths, isEmpty);
  });

  testWidgets('tablet divider follows the trailing edge in RTL', (
    tester,
  ) async {
    final committedWidths = <double>[];
    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestTabletSize,
        tabletResizable: true,
        textDirection: TextDirection.rtl,
        onTabletDrawerWidthChanged: committedWidths.add,
      ),
    );

    final panel = find.byKey(const ValueKey<String>('tablet-drawer-panel'));
    final handle = find.byKey(
      const ValueKey<String>('tablet-sidebar-resize-handle'),
    );
    final layoutWidth = tester
        .getSize(find.byType(ResponsiveDrawerLayout))
        .width;
    expect(tester.getTopRight(panel).dx, layoutWidth);
    expect(tester.getCenter(handle).dx, closeTo(layoutWidth - 320, 0.1));

    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();
    expect(tester.getSize(panel).width, closeTo(420, 0.1));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(committedWidths, [closeTo(420, 0.1)]);
  });

  testWidgets('tablet divider mirrors keyboard increments in RTL', (
    tester,
  ) async {
    final committedWidths = <double>[];
    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestTabletSize,
        tabletResizable: true,
        textDirection: TextDirection.rtl,
        onTabletDrawerWidthChanged: committedWidths.add,
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const ValueKey('tablet-drawer-panel'))).width,
      340,
    );
    expect(committedWidths, [340]);
  });

  testWidgets('tablet divider exposes boundary and adjustable semantics', (
    tester,
  ) async {
    await tester.pumpWidget(
      drawerTestBuildHarness(size: drawerTestTabletSize, tabletResizable: true),
    );
    final semanticsHandle = tester.ensureSemantics();
    try {
      final panel = tester.widget<AnimatedContainer>(
        find.byKey(const ValueKey<String>('tablet-drawer-panel')),
      );
      final decoration = panel.decoration! as BoxDecoration;
      final border = decoration.border! as BorderDirectional;
      expect(border.end.width, BorderWidth.thin);

      final node = tester.getSemantics(
        find.byKey(const ValueKey<String>('tablet-sidebar-resize-handle')),
      );
      expect(node.label, 'Resize sidebar');
      expect(node.value, '320 points');
      expect(node.increasedValue, '340 points');
      expect(node.decreasedValue, '320 points');
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.increase),
        isTrue,
      );
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.decrease),
        isTrue,
      );
    } finally {
      semanticsHandle.dispose();
    }
  });

  testWidgets('tablet divider supports keyboard width increments', (
    tester,
  ) async {
    final committedWidths = <double>[];
    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestTabletSize,
        tabletResizable: true,
        onTabletDrawerWidthChanged: committedWidths.add,
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const ValueKey('tablet-drawer-panel'))).width,
      340,
    );
    expect(committedWidths, [340]);
  });

  testWidgets('tablet divider coalesces repeated keyboard commits', (
    tester,
  ) async {
    final committedWidths = <double>[];
    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestTabletSize,
        tabletResizable: true,
        onTabletDrawerWidthChanged: committedWidths.add,
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 199));
    expect(committedWidths, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));

    expect(
      tester.getSize(find.byKey(const ValueKey('tablet-drawer-panel'))).width,
      360,
    );
    expect(committedWidths, [360]);
  });

  testWidgets('pointer resize supersedes a pending keyboard commit', (
    tester,
  ) async {
    final committedWidths = <double>[];
    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestTabletSize,
        tabletResizable: true,
        onTabletDrawerWidthChanged: committedWidths.add,
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    final handle = find.byKey(
      const ValueKey<String>('tablet-sidebar-resize-handle'),
    );
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(committedWidths, [440]);
    await tester.pump(const Duration(milliseconds: 200));
    expect(committedWidths, [440]);
  });

  testWidgets('dismissed tablet drawer releases chrome after closing', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestTabletSize,
        layoutKey: layoutKey,
        drawer: const DrawerTestDrawerCompositionProbe(),
      ),
    );

    check(find.text('drawer-chrome-active').evaluate()).length.equals(1);
    layoutKey.currentState!.close();
    await tester.pump(const Duration(milliseconds: 100));
    check(find.text('drawer-chrome-active').evaluate()).length.equals(1);
    await tester.pumpAndSettle();
    check(find.text('drawer-chrome-inactive').evaluate()).length.equals(1);

    layoutKey.currentState!.open();
    await tester.pump();
    check(find.text('drawer-chrome-active').evaluate()).length.equals(1);
    await tester.pumpAndSettle();
    check(find.text('drawer-chrome-active').evaluate()).length.equals(1);
  });

  testWidgets('initially dismissed tablet drawer omits native chrome', (
    tester,
  ) async {
    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestTabletSize,
        drawer: const DrawerTestDrawerCompositionProbe(),
        tabletInitiallyDocked: false,
      ),
    );

    check(find.text('drawer-chrome-inactive').evaluate()).length.equals(1);
  });

  testWidgets('breakpoint change during tablet close releases chrome', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestTabletSize,
        layoutKey: layoutKey,
        drawer: const DrawerTestDrawerCompositionProbe(),
      ),
    );
    layoutKey.currentState!.close();
    await tester.pump(const Duration(milliseconds: 100));
    check(find.text('drawer-chrome-active').evaluate()).length.equals(1);

    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestMobileSize,
        layoutKey: layoutKey,
        drawer: const DrawerTestDrawerCompositionProbe(),
      ),
    );
    await tester.pump();

    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestTabletSize,
        layoutKey: layoutKey,
        drawer: const DrawerTestDrawerCompositionProbe(),
      ),
    );
    await tester.pumpAndSettle();
    check(find.text('drawer-chrome-inactive').evaluate()).length.equals(1);
  });
}
