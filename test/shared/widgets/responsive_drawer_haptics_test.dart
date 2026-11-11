import 'package:material_ui/material_ui.dart';
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

  group('settle haptics', () {
    testWidgets('tap once on fully opening and once on fully closing', (
      tester,
    ) async {
      final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();
      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestMobileSize,
          layoutKey: layoutKey,
          settleHaptics: true,
        ),
      );

      await drawerTestRecordPlatformCallsDuring((calls) async {
        layoutKey.currentState!.open();
        await tester.pump(const Duration(milliseconds: 16));
        // Not while the drawer is still on its way.
        expect(drawerTestLightSettleHapticCalls(calls), isEmpty);
        await tester.pumpAndSettle();
        expect(layoutKey.currentState!.isOpen, isTrue);
        expect(drawerTestLightSettleHapticCalls(calls), hasLength(1));

        layoutKey.currentState!.close();
        await tester.pumpAndSettle();
        expect(layoutKey.currentState!.isOpen, isFalse);
        expect(drawerTestLightSettleHapticCalls(calls), hasLength(2));
      });
    });

    testWidgets('tap as the drawer lands, before its spring comes to rest', (
      tester,
    ) async {
      final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();
      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestMobileSize,
          layoutKey: layoutKey,
          settleHaptics: true,
        ),
      );

      await drawerTestRecordPlatformCallsDuring((calls) async {
        Future<void> pumpFor(Duration duration) async {
          for (var elapsed = Duration.zero; elapsed < duration;) {
            await tester.pump(const Duration(milliseconds: 16));
            elapsed += const Duration(milliseconds: 16);
          }
        }

        // The spring is within a point of the end by about 230 ms and only
        // rests at about 490 ms.
        layoutKey.currentState!.open();
        await pumpFor(const Duration(milliseconds: 300));
        expect(drawerTestLightSettleHapticCalls(calls), hasLength(1));
        await tester.pumpAndSettle();
        expect(drawerTestLightSettleHapticCalls(calls), hasLength(1));

        layoutKey.currentState!.close();
        await pumpFor(const Duration(milliseconds: 300));
        expect(drawerTestLightSettleHapticCalls(calls), hasLength(2));
        await tester.pumpAndSettle();
        expect(drawerTestLightSettleHapticCalls(calls), hasLength(2));
      });
    });

    testWidgets('stay quiet when the drawer springs back where it was', (
      tester,
    ) async {
      final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();
      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestMobileSize,
          layoutKey: layoutKey,
          settleHaptics: true,
        ),
      );
      await drawerTestOpenDrawer(tester, layoutKey);

      final calls = await drawerTestRecordPlatformCalls(() async {
        await tester.drag(
          find.byKey(const ValueKey('drawer')),
          const Offset(-80, 0),
        );
        await tester.pumpAndSettle();
        layoutKey.currentState!.open();
        await tester.pumpAndSettle();
      });

      expect(layoutKey.currentState!.isOpen, isTrue);
      expect(drawerTestLightSettleHapticCalls(calls), isEmpty);
    });

    testWidgets('skip an opening reversed before it finishes', (tester) async {
      final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();
      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestMobileSize,
          layoutKey: layoutKey,
          settleHaptics: true,
        ),
      );

      final calls = await drawerTestRecordPlatformCalls(() async {
        layoutKey.currentState!.open();
        await tester.pump(const Duration(milliseconds: 16));
        layoutKey.currentState!.close();
        await tester.pumpAndSettle();
      });

      expect(layoutKey.currentState!.isOpen, isFalse);
      expect(drawerTestLightSettleHapticCalls(calls), isEmpty);
    });

    testWidgets('a drag held fully open taps once it is let go', (
      tester,
    ) async {
      final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();
      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestMobileSize,
          layoutKey: layoutKey,
          settleHaptics: true,
        ),
      );

      await drawerTestRecordPlatformCallsDuring((calls) async {
        final gesture = await tester.startGesture(const Offset(10, 200));
        await gesture.moveBy(const Offset(200, 0));
        await tester.pump();
        await gesture.moveBy(const Offset(400, 0));
        await tester.pump();
        expect(drawerTestLightSettleHapticCalls(calls), isEmpty);

        await gesture.up();
        await tester.pumpAndSettle();
        expect(layoutKey.currentState!.isOpen, isTrue);
        expect(drawerTestLightSettleHapticCalls(calls), hasLength(1));
      });
    });

    testWidgets('are off unless asked for', (tester) async {
      final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();
      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestMobileSize,
          layoutKey: layoutKey,
        ),
      );

      final calls = await drawerTestRecordPlatformCalls(() async {
        layoutKey.currentState!.open();
        await tester.pumpAndSettle();
        layoutKey.currentState!.close();
        await tester.pumpAndSettle();
      });

      expect(drawerTestSettleHapticCalls(calls), isEmpty);
    });
  });
}
