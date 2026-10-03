import 'package:checks/checks.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// The workspace editors keep the root navigator's context to report a save
/// after their page may be gone. That context sits above the navigator's
/// overlay, so the iOS banner threw "No Overlay widget found" and a prompt
/// the server had saved was reported as "Couldn't save".
void main() {
  setUp(() {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
  });

  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  testWidgets('an iOS banner shows from a root navigator context', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );

    AdaptiveSnackBar.show(
      navigatorKey.currentContext!,
      message: 'Prompt saved',
      type: AdaptiveSnackBarType.success,
    );
    await tester.pump();

    check(tester.takeException()).isNull();
    check(find.text('Prompt saved').evaluate()).isNotEmpty();

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
