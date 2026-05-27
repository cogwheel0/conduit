import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/shared/widgets/responsive_drawer_layout.dart';

const _mobileSize = Size(390, 844);
const _tabletSize = Size(1024, 1366);
const _vibrateChannel = MethodChannel('vibrate');

class _RecordedPlatformCall {
  const _RecordedPlatformCall(this.method, this.arguments);

  final String method;
  final Object? arguments;

  @override
  String toString() => '_RecordedPlatformCall($method, $arguments)';
}

Future<List<_RecordedPlatformCall>> _recordPlatformCalls(
  Future<void> Function() action,
) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <_RecordedPlatformCall>[];

  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    calls.add(_RecordedPlatformCall(call.method, call.arguments));
    return null;
  });
  messenger.setMockMethodCallHandler(_vibrateChannel, (call) async {
    calls.add(_RecordedPlatformCall('vibrate:${call.method}', call.arguments));
    return null;
  });

  try {
    await action();
  } finally {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(_vibrateChannel, null);
  }

  return calls;
}

Future<void> _recordPlatformCallsDuring(
  Future<void> Function(List<_RecordedPlatformCall> calls) action,
) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <_RecordedPlatformCall>[];

  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    calls.add(_RecordedPlatformCall(call.method, call.arguments));
    return null;
  });
  messenger.setMockMethodCallHandler(_vibrateChannel, (call) async {
    calls.add(_RecordedPlatformCall('vibrate:${call.method}', call.arguments));
    return null;
  });

  try {
    await action(calls);
  } finally {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(_vibrateChannel, null);
  }
}

Iterable<_RecordedPlatformCall> _settleHapticCalls(
  List<_RecordedPlatformCall> calls,
) => calls.where(
  (call) =>
      (call.method == 'HapticFeedback.vibrate' &&
          call.arguments == 'HapticFeedbackType.mediumImpact') ||
      call.method == 'vibrate:medium',
);

Widget _buildHarness({
  required Size size,
  GlobalKey<ResponsiveDrawerLayoutState>? layoutKey,
  Widget? child,
  Widget? drawer,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: ResponsiveDrawerLayout(
        key: layoutKey,
        drawer:
            drawer ??
            const ColoredBox(
              key: ValueKey('drawer'),
              color: Colors.blue,
              child: SizedBox.expand(),
            ),
        child:
            child ??
            const ColoredBox(
              key: ValueKey('content'),
              color: Colors.orange,
              child: SizedBox.expand(),
            ),
      ),
    ),
  );
}

Widget _buildHorizontalScrollableContent({
  ScrollController? controller,
  Key? key,
}) {
  return ColoredBox(
    color: Colors.orange,
    child: SingleChildScrollView(
      key: key,
      controller: controller,
      scrollDirection: Axis.horizontal,
      child: const SizedBox(
        width: 1200,
        height: 844,
        child: ColoredBox(color: Colors.deepOrange),
      ),
    ),
  );
}

Future<void> _openDrawer(
  WidgetTester tester,
  GlobalKey<ResponsiveDrawerLayoutState> layoutKey,
) async {
  layoutKey.currentState!.open();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('drag settle open emits no sidebar haptic', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    final calls = await _recordPlatformCalls(() async {
      await tester.pumpWidget(
        _buildHarness(size: _mobileSize, layoutKey: layoutKey),
      );

      await tester.dragFrom(const Offset(10, 200), const Offset(260, 0));
      await tester.pumpAndSettle();
    });

    expect(layoutKey.currentState!.isOpen, isTrue);
    expect(_settleHapticCalls(calls), isEmpty);
  });

  testWidgets(
    'horizontal scrollable away from the leading edge wins the edge drag',
    (tester) async {
      final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();
      final scrollController = ScrollController(initialScrollOffset: 120);

      await tester.pumpWidget(
        _buildHarness(
          size: _mobileSize,
          layoutKey: layoutKey,
          child: _buildHorizontalScrollableContent(
            controller: scrollController,
            key: const ValueKey('horizontal-scrollable'),
          ),
        ),
      );
      await tester.pump();

      await tester.dragFrom(const Offset(10, 200), const Offset(180, 0));
      await tester.pumpAndSettle();

      expect(layoutKey.currentState!.isOpen, isFalse);
      expect(scrollController.offset, lessThan(120));
    },
  );

  testWidgets(
    'horizontal scrollable at the leading edge can still open the drawer',
    (tester) async {
      final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();
      final scrollController = ScrollController();

      await tester.pumpWidget(
        _buildHarness(
          size: _mobileSize,
          layoutKey: layoutKey,
          child: _buildHorizontalScrollableContent(
            controller: scrollController,
          ),
        ),
      );
      await tester.pump();

      await tester.dragFrom(const Offset(10, 200), const Offset(260, 0));
      await tester.pumpAndSettle();

      expect(layoutKey.currentState!.isOpen, isTrue);
    },
  );

  testWidgets('horizontal drag closes an open mobile drawer without haptic', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      _buildHarness(size: _mobileSize, layoutKey: layoutKey),
    );
    await _openDrawer(tester, layoutKey);
    expect(layoutKey.currentState!.isOpen, isTrue);

    final calls = await _recordPlatformCalls(() async {
      await tester.drag(
        find.byKey(const ValueKey('drawer')),
        const Offset(-400, 0),
      );
      await tester.pumpAndSettle();
    });

    expect(layoutKey.currentState!.isOpen, isFalse);
    expect(_settleHapticCalls(calls), isEmpty);
  });

  testWidgets('initial mount fires zero haptics', (tester) async {
    final calls = await _recordPlatformCalls(() async {
      await tester.pumpWidget(_buildHarness(size: _mobileSize));
      await tester.pumpAndSettle();
    });

    expect(_settleHapticCalls(calls), isEmpty);
  });

  testWidgets('rebuild and resize at a settled endpoint fire zero haptics', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      _buildHarness(size: _mobileSize, layoutKey: layoutKey),
    );
    await _openDrawer(tester, layoutKey);

    final calls = await _recordPlatformCalls(() async {
      await tester.pumpWidget(
        _buildHarness(size: _mobileSize, layoutKey: layoutKey),
      );
      await tester.pump();

      await tester.pumpWidget(
        _buildHarness(size: _tabletSize, layoutKey: layoutKey),
      );
      await tester.pump();

      await tester.pumpWidget(
        _buildHarness(size: _mobileSize, layoutKey: layoutKey),
      );
      await tester.pump();
    });

    expect(_settleHapticCalls(calls), isEmpty);
  });

  testWidgets('programmatic open settles without haptic', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    final calls = await _recordPlatformCalls(() async {
      await tester.pumpWidget(
        _buildHarness(size: _mobileSize, layoutKey: layoutKey),
      );

      layoutKey.currentState!.open();
      await tester.pumpAndSettle();
    });

    expect(layoutKey.currentState!.isOpen, isTrue);
    expect(_settleHapticCalls(calls), isEmpty);
  });

  testWidgets('programmatic close settles without haptic', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      _buildHarness(size: _mobileSize, layoutKey: layoutKey),
    );
    await _openDrawer(tester, layoutKey);
    expect(layoutKey.currentState!.isOpen, isTrue);

    final calls = await _recordPlatformCalls(() async {
      layoutKey.currentState!.close();
      await tester.pumpAndSettle();
    });

    expect(layoutKey.currentState!.isOpen, isFalse);
    expect(_settleHapticCalls(calls), isEmpty);
  });

  testWidgets('open when already open fires zero haptics', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      _buildHarness(size: _mobileSize, layoutKey: layoutKey),
    );
    await _openDrawer(tester, layoutKey);
    expect(layoutKey.currentState!.isOpen, isTrue);

    final calls = await _recordPlatformCalls(() async {
      layoutKey.currentState!.open();
      await tester.pumpAndSettle();
    });

    expect(_settleHapticCalls(calls), isEmpty);
  });

  testWidgets('close when already closed fires zero haptics', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      _buildHarness(size: _mobileSize, layoutKey: layoutKey),
    );

    final calls = await _recordPlatformCalls(() async {
      layoutKey.currentState!.close();
      await tester.pumpAndSettle();
    });

    expect(_settleHapticCalls(calls), isEmpty);
  });

  testWidgets('same endpoint repeat settle emits no haptic', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    final calls = await _recordPlatformCalls(() async {
      await tester.pumpWidget(
        _buildHarness(size: _mobileSize, layoutKey: layoutKey),
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
    expect(_settleHapticCalls(calls), isEmpty);
  });

  testWidgets(
    'drag leaving an endpoint before release settles without haptic',
    (tester) async {
      final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

      await _recordPlatformCallsDuring((calls) async {
        await tester.pumpWidget(
          _buildHarness(size: _mobileSize, layoutKey: layoutKey),
        );

        final gesture = await tester.startGesture(const Offset(10, 200));
        await gesture.moveBy(const Offset(360, 0));
        await tester.pump();
        await gesture.moveBy(const Offset(-200, 0));
        await tester.pump();

        await gesture.up();
        await tester.pump();

        expect(layoutKey.currentState!.isOpen, isFalse);
        expect(_settleHapticCalls(calls), isEmpty);

        await tester.pumpAndSettle();

        expect(layoutKey.currentState!.isOpen, isTrue);
        expect(_settleHapticCalls(calls), isEmpty);
      });
    },
  );

  testWidgets('drag cancel resets state so next open settles without haptic', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    final calls = await _recordPlatformCalls(() async {
      await tester.pumpWidget(
        _buildHarness(size: _mobileSize, layoutKey: layoutKey),
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
    expect(_settleHapticCalls(calls), isEmpty);
  });

  testWidgets('interrupted reversed settle emits no abandoned haptic', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    final calls = await _recordPlatformCalls(() async {
      await tester.pumpWidget(
        _buildHarness(size: _mobileSize, layoutKey: layoutKey),
      );

      layoutKey.currentState!.open();
      await tester.pump(const Duration(milliseconds: 16));

      layoutKey.currentState!.close();
      await tester.pumpAndSettle();
    });

    expect(layoutKey.currentState!.isOpen, isFalse);
    expect(_settleHapticCalls(calls), isEmpty);
  });

  testWidgets('tablet layout emits zero mobile settle haptics', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    final calls = await _recordPlatformCalls(() async {
      await tester.pumpWidget(
        _buildHarness(size: _tabletSize, layoutKey: layoutKey),
      );

      layoutKey.currentState!.close();
      await tester.pumpAndSettle();

      layoutKey.currentState!.open();
      await tester.pumpAndSettle();
    });

    expect(_settleHapticCalls(calls), isEmpty);
  });
}
