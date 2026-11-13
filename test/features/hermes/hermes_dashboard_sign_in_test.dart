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
        .setMockDecodedMessageHandler<Object?>(_presentWebSignIn, null);
  });

  test('a sign-in over the sheet whose cookies cannot be recorded does not '
      'count, so Sign Out is not left a session it cannot delete', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(
          _presentWebSignIn,
          (_) async => <Object?>[true],
        );

    final signedIn = await const HermesDashboardSignIn().signIn(
      const HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        mode: HermesBackendMode.desktopGateway,
      ),
    );

    check(signedIn).isFalse();
  });
}
