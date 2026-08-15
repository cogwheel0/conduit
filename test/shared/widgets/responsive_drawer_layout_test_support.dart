import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/features/navigation/widgets/responsive_drawer_layout.dart';
import 'package:conduit/shared/widgets/horizontal_gesture_ownership.dart';
import 'package:conduit/shared/widgets/sidebar_layout_contract.dart';

const drawerTestMobileSize = Size(390, 844);
const drawerTestTabletSize = Size(1024, 1366);
const drawerTestVibrateChannel = MethodChannel('vibrate');
const drawerTestWideMarkdownTable = '''
| Provider | Management experience | Deployment options | Access control |
| --- | --- | --- | --- |
| Example Identity Provider | Polished administrative interface | Docker Compose, Helm, and Kubernetes | OAuth, OIDC, SAML, and role-based access control |
''';

class DrawerTestRecordedPlatformCall {
  const DrawerTestRecordedPlatformCall(this.method, this.arguments);

  final String method;
  final Object? arguments;

  @override
  String toString() => 'DrawerTestRecordedPlatformCall($method, $arguments)';
}

Future<List<DrawerTestRecordedPlatformCall>> drawerTestRecordPlatformCalls(
  Future<void> Function() action,
) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <DrawerTestRecordedPlatformCall>[];

  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    calls.add(DrawerTestRecordedPlatformCall(call.method, call.arguments));
    return null;
  });
  messenger.setMockMethodCallHandler(drawerTestVibrateChannel, (call) async {
    calls.add(
      DrawerTestRecordedPlatformCall('vibrate:${call.method}', call.arguments),
    );
    return null;
  });

  try {
    await action();
  } finally {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(drawerTestVibrateChannel, null);
  }

  return calls;
}

Future<void> drawerTestRecordPlatformCallsDuring(
  Future<void> Function(List<DrawerTestRecordedPlatformCall> calls) action,
) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <DrawerTestRecordedPlatformCall>[];

  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    calls.add(DrawerTestRecordedPlatformCall(call.method, call.arguments));
    return null;
  });
  messenger.setMockMethodCallHandler(drawerTestVibrateChannel, (call) async {
    calls.add(
      DrawerTestRecordedPlatformCall('vibrate:${call.method}', call.arguments),
    );
    return null;
  });

  try {
    await action(calls);
  } finally {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(drawerTestVibrateChannel, null);
  }
}

Iterable<DrawerTestRecordedPlatformCall> drawerTestSettleHapticCalls(
  List<DrawerTestRecordedPlatformCall> calls,
) => calls.where(
  (call) =>
      (call.method == 'HapticFeedback.vibrate' &&
          call.arguments == 'HapticFeedbackType.mediumImpact') ||
      call.method == 'vibrate:medium',
);

Widget drawerTestBuildHarness({
  required Size size,
  GlobalKey<ResponsiveDrawerLayoutState>? layoutKey,
  Widget? child,
  Widget? drawer,
  double edgeFraction = 0.5,
  VoidCallback? onOpenStart,
  bool tabletDismissible = true,
  bool tabletInitiallyDocked = true,
  double tabletDrawerWidth = 320,
  bool tabletResizable = false,
  ValueChanged<double>? onTabletDrawerWidthChanged,
  TextDirection textDirection = TextDirection.ltr,
  double? layoutWidth,
}) {
  final content = Directionality(
    textDirection: textDirection,
    child: MediaQuery(
      data: MediaQueryData(size: size),
      child: ResponsiveDrawerLayout(
        key: layoutKey,
        edgeFraction: edgeFraction,
        onOpenStart: onOpenStart,
        tabletDismissible: tabletDismissible,
        tabletInitiallyDocked: tabletInitiallyDocked,
        tabletDrawerWidth: tabletDrawerWidth,
        tabletResizable: tabletResizable,
        onTabletDrawerWidthChanged: onTabletDrawerWidthChanged,
        tabletResizeSemanticsLabel: 'Resize sidebar',
        tabletResizeSemanticsHint: 'Double tap to reset',
        tabletResizeSemanticsValueBuilder: (width) => '${width.round()} points',
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
  return MaterialApp(
    home: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: layoutWidth, child: content),
    ),
  );
}

class DrawerTestDrawerCompositionProbe extends StatelessWidget {
  const DrawerTestDrawerCompositionProbe({super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      DrawerChromeCompositionScope.shouldCompose(context)
          ? 'drawer-chrome-active'
          : 'drawer-chrome-inactive',
    );
  }
}

Widget drawerTestBuildEagerGestureOwner() {
  return RawGestureDetector(
    behavior: HitTestBehavior.opaque,
    gestures: <Type, GestureRecognizerFactory>{
      EagerGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
            EagerGestureRecognizer.new,
            (_) {},
          ),
    },
    child: const ColoredBox(
      key: ValueKey('eager-gesture-owner'),
      color: Colors.orange,
      child: SizedBox.expand(),
    ),
  );
}

Future<void> drawerTestLongPressDrag(
  WidgetTester tester,
  Offset start,
  Offset delta,
) async {
  final gesture = await tester.startGesture(start);
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
  await gesture.moveBy(delta);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> drawerTestWithTargetPlatform(
  TargetPlatform platform,
  Future<void> Function() action,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await action();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Widget drawerTestBuildHorizontalScrollableContent({
  ScrollController? controller,
  Key? key,
}) {
  return ColoredBox(
    color: Colors.orange,
    child: HorizontalScrollGestureBoundary(
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
    ),
  );
}

Future<void> drawerTestOpenDrawer(
  WidgetTester tester,
  GlobalKey<ResponsiveDrawerLayoutState> layoutKey,
) async {
  layoutKey.currentState!.open();
  await tester.pumpAndSettle();
}
