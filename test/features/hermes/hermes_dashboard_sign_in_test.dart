import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/features/hermes/services/hermes_dashboard_sign_in.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:conduit/platform/webview_cookie_helper.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _presentWebSignIn = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.conduit.NativeSheetHostApi.presentWebSignIn',
  NativeSheetHostApi.pigeonChannelCodec,
);

final _dismiss = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.conduit.NativeSheetHostApi.dismiss',
  NativeSheetHostApi.pigeonChannelCodec,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    NativeSheetBridge.instance
      ..debugIsIOSOverride = true
      ..debugSettingsSheetOpen = true;
    // The web view's cookie store, which this test has none of, cannot be
    // read: the sign-in's cookies cannot be recorded.
    debugIsWebViewSupportedOverride = true;
  });

  tearDown(() {
    NativeSheetBridge.instance
      ..debugIsIOSOverride = null
      ..debugSettingsSheetOpen = false;
    debugIsWebViewSupportedOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockDecodedMessageHandler<Object?>(_presentWebSignIn, null)
      ..setMockDecodedMessageHandler<Object?>(_dismiss, null);
  });

  test('a sign-in over the sheet whose cookies cannot be recorded does not '
      'count, so Sign Out is not left a session it cannot delete', () async {
    var presented = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(_presentWebSignIn, (_) async {
          presented = true;
          return <Object?>[true];
        });

    final signedIn = await const HermesDashboardSignIn().signIn(
      const HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        mode: HermesBackendMode.desktopGateway,
      ),
    );

    // Presented and signed in, then refused for want of its cookies.
    check(presented).isTrue();
    check(signedIn).isFalse();
  });

  testWidgets('a sign-in that needs the Flutter page waits for Settings to '
      'have gone', (tester) async {
    var dismissed = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(_dismiss, (_) async {
          dismissed++;
          return <Object?>[true];
        });
    var finished = false;
    final signingIn = const HermesDashboardSignIn()
        .signIn(
          HermesConfig(
            enabled: true,
            baseUrl: 'https://hermes.example',
            mode: HermesBackendMode.desktopGateway,
            // Only the Flutter page sends access headers.
            desktopCredentials: HermesDesktopCredentials(
              accessHeaders: const {'CF-Access-Client-Id': 'synthetic-id'},
            ),
          ),
        )
        .whenComplete(() => finished = true);

    // Asked to close, the sheet is still leaving, past the wait for it.
    await tester.pump(const Duration(seconds: 3));
    check(dismissed).equals(1);
    check(finished).isFalse();

    NativeSheetBridge.instance.onDismissed();
    await tester.pump();
    await signingIn;
    check(finished).isTrue();
  });
}
