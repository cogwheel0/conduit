import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _dismissChannel = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.conduit.NativeSheetHostApi.dismiss',
  NativeSheetHostApi.pigeonChannelCodec,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bridge = NativeSheetBridge.instance;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    bridge.debugIsIOSOverride = true;
    bridge.debugSettingsSheetOpen = true;
  });

  tearDown(() {
    bridge
      ..debugIsIOSOverride = null
      ..debugSettingsSheetOpen = false;
    messenger.setMockDecodedMessageHandler<Object?>(_dismissChannel, null);
  });

  test('closing Settings waits until the sheet has gone', () async {
    messenger.setMockDecodedMessageHandler<Object?>(
      _dismissChannel,
      (_) async => <Object?>[true],
    );
    var closed = false;
    final closing = bridge.dismissSettings().then((value) => closed = value);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);

    // The sheet's dismissal finished.
    bridge.onDismissed();
    await closing;

    expect(closed, isTrue);
    expect(bridge.settingsSheetOpen, isFalse);
  });

  test('a sheet that does not close says so', () async {
    messenger.setMockDecodedMessageHandler<Object?>(
      _dismissChannel,
      (_) async => <Object?>[false],
    );

    expect(await bridge.dismissSettings(), isFalse);
    expect(bridge.settingsSheetOpen, isTrue);
  });
}
