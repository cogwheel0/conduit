import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/features/navigation/widgets/responsive_drawer_layout.dart';

import 'responsive_drawer_layout_test_support.dart';

void main() {
  testWidgets('horizontal drag closes an open mobile drawer without haptic', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      drawerTestBuildHarness(size: drawerTestMobileSize, layoutKey: layoutKey),
    );
    await drawerTestOpenDrawer(tester, layoutKey);
    expect(layoutKey.currentState!.isOpen, isTrue);

    final calls = await drawerTestRecordPlatformCalls(() async {
      await tester.drag(
        find.byKey(const ValueKey('drawer')),
        const Offset(-400, 0),
      );
      await tester.pumpAndSettle();
    });

    expect(layoutKey.currentState!.isOpen, isFalse);
    expect(drawerTestSettleHapticCalls(calls), isEmpty);
  });

  testWidgets('initial mount fires zero haptics', (tester) async {
    final calls = await drawerTestRecordPlatformCalls(() async {
      await tester.pumpWidget(
        drawerTestBuildHarness(size: drawerTestMobileSize),
      );
      await tester.pumpAndSettle();
    });

    expect(drawerTestSettleHapticCalls(calls), isEmpty);
  });

  testWidgets('rebuild and resize at a settled endpoint fire zero haptics', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      drawerTestBuildHarness(size: drawerTestMobileSize, layoutKey: layoutKey),
    );
    await drawerTestOpenDrawer(tester, layoutKey);

    final calls = await drawerTestRecordPlatformCalls(() async {
      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestMobileSize,
          layoutKey: layoutKey,
        ),
      );
      await tester.pump();

      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestTabletSize,
          layoutKey: layoutKey,
        ),
      );
      await tester.pump();

      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestMobileSize,
          layoutKey: layoutKey,
        ),
      );
      await tester.pump();
    });

    expect(drawerTestSettleHapticCalls(calls), isEmpty);
  });

  testWidgets('programmatic open settles without haptic', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    final calls = await drawerTestRecordPlatformCalls(() async {
      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestMobileSize,
          layoutKey: layoutKey,
        ),
      );

      layoutKey.currentState!.open();
      await tester.pumpAndSettle();
    });

    expect(layoutKey.currentState!.isOpen, isTrue);
    expect(drawerTestSettleHapticCalls(calls), isEmpty);
  });

  testWidgets('programmatic close settles without haptic', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      drawerTestBuildHarness(size: drawerTestMobileSize, layoutKey: layoutKey),
    );
    await drawerTestOpenDrawer(tester, layoutKey);
    expect(layoutKey.currentState!.isOpen, isTrue);

    final calls = await drawerTestRecordPlatformCalls(() async {
      layoutKey.currentState!.close();
      await tester.pumpAndSettle();
    });

    expect(layoutKey.currentState!.isOpen, isFalse);
    expect(drawerTestSettleHapticCalls(calls), isEmpty);
  });

  testWidgets('open when already open fires zero haptics', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      drawerTestBuildHarness(size: drawerTestMobileSize, layoutKey: layoutKey),
    );
    await drawerTestOpenDrawer(tester, layoutKey);
    expect(layoutKey.currentState!.isOpen, isTrue);

    final calls = await drawerTestRecordPlatformCalls(() async {
      layoutKey.currentState!.open();
      await tester.pumpAndSettle();
    });

    expect(drawerTestSettleHapticCalls(calls), isEmpty);
  });

  testWidgets('close when already closed fires zero haptics', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      drawerTestBuildHarness(size: drawerTestMobileSize, layoutKey: layoutKey),
    );

    final calls = await drawerTestRecordPlatformCalls(() async {
      layoutKey.currentState!.close();
      await tester.pumpAndSettle();
    });

    expect(drawerTestSettleHapticCalls(calls), isEmpty);
  });

  testWidgets('same endpoint repeat settle emits no haptic', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    final calls = await drawerTestRecordPlatformCalls(() async {
      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestMobileSize,
          layoutKey: layoutKey,
        ),
      );

      layoutKey.currentState!.open();
      await tester.pumpAndSettle();

      await tester.drag(
        find.byKey(const ValueKey('drawer')),
        const Offset(-80, 0),
      );
      await tester.pumpAndSettle();
    });

    expect(layoutKey.currentState!.isOpen, isTrue);
    expect(drawerTestSettleHapticCalls(calls), isEmpty);
  });

  testWidgets(
    'drag leaving an endpoint before release settles without haptic',
    (tester) async {
      final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

      await drawerTestRecordPlatformCallsDuring((calls) async {
        await tester.pumpWidget(
          drawerTestBuildHarness(
            size: drawerTestMobileSize,
            layoutKey: layoutKey,
          ),
        );

        final gesture = await tester.startGesture(const Offset(10, 200));
        await gesture.moveBy(const Offset(360, 0));
        await tester.pump();
        await gesture.moveBy(const Offset(-200, 0));
        await tester.pump();

        await gesture.up();
        await tester.pump();

        expect(layoutKey.currentState!.isOpen, isFalse);
        expect(drawerTestSettleHapticCalls(calls), isEmpty);

        await tester.pumpAndSettle();

        expect(layoutKey.currentState!.isOpen, isTrue);
        expect(drawerTestSettleHapticCalls(calls), isEmpty);
      });
    },
  );

  testWidgets('drag cancel resets state so next open settles without haptic', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    final calls = await drawerTestRecordPlatformCalls(() async {
      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestMobileSize,
          layoutKey: layoutKey,
        ),
      );

      final gesture = await tester.startGesture(const Offset(10, 200));
      await gesture.moveBy(const Offset(160, 0));
      await tester.pump();
      await gesture.cancel();
      await tester.pump();

      layoutKey.currentState!.open();
      await tester.pumpAndSettle();
    });

    expect(layoutKey.currentState!.isOpen, isTrue);
    expect(drawerTestSettleHapticCalls(calls), isEmpty);
  });

  testWidgets('interrupted reversed settle emits no abandoned haptic', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    final calls = await drawerTestRecordPlatformCalls(() async {
      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestMobileSize,
          layoutKey: layoutKey,
        ),
      );

      layoutKey.currentState!.open();
      await tester.pump(const Duration(milliseconds: 16));

      layoutKey.currentState!.close();
      await tester.pumpAndSettle();
    });

    expect(layoutKey.currentState!.isOpen, isFalse);
    expect(drawerTestSettleHapticCalls(calls), isEmpty);
  });

  testWidgets('tablet layout emits zero mobile settle haptics', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    final calls = await drawerTestRecordPlatformCalls(() async {
      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestTabletSize,
          layoutKey: layoutKey,
        ),
      );

      layoutKey.currentState!.close();
      await tester.pumpAndSettle();

      layoutKey.currentState!.open();
      await tester.pumpAndSettle();
    });

    expect(drawerTestSettleHapticCalls(calls), isEmpty);
  });
}
