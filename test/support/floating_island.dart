import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_native_better/cupertino_native_better.dart'
    show CNFloatingIsland;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'native_platform_views.dart';

/// Simulates iOS 26 for the app's choices until the test ends. The package
/// still picks its native or Flutter island by the host, so tests hold on
/// both.
void useNativeIOS26() {
  stubNativePlatformViews();
  PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
  PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
  PlatformUiCapabilities.debugNativeIOS26Override = true;
  addTearDown(PlatformUiCapabilities.resetDebugOverrides);
}

/// The only floating island's configuration.
CNFloatingIsland floatingIsland(WidgetTester tester) =>
    tester.widget<CNFloatingIsland>(find.byType(CNFloatingIsland));

/// The island's glass: its size for the current state, at the bottom centre
/// of the island, which is where the native view and the Flutter one draw it.
Rect floatingIslandGlass(WidgetTester tester) {
  final config = floatingIsland(tester);
  final size = config.isExpanded
      ? Size(config.expandedWidth!, config.expandedHeight!)
      : Size(config.collapsedWidth!, config.collapsedHeight);
  final box = tester.getRect(find.byType(CNFloatingIsland));
  return Rect.fromLTWH(
    box.center.dx - size.width / 2,
    box.bottom - size.height,
    size.width,
    size.height,
  );
}

/// Expects [content] to lie on the island's glass.
void expectOnFloatingIslandGlass(WidgetTester tester, Finder content) {
  final glass = floatingIslandGlass(tester).inflate(0.5);
  final rect = tester.getRect(content);
  expect(
    glass.contains(rect.topLeft) && glass.contains(rect.bottomRight),
    isTrue,
    reason: '$content at $rect is off the glass at $glass',
  );
}
