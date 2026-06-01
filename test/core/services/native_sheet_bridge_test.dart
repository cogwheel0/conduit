import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _nativeSheetChannel = MethodChannel('conduit/native_sheet');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    NativeSheetBridge.instance.debugIsIOSOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_nativeSheetChannel, null);
  });

  group('NativeSheetBridge.presentModelSelector', () {
    test(
      'failed overlapping selector call restores active pin handler',
      () async {
        NativeSheetBridge.instance.debugIsIOSOverride = true;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final firstPresentation = Completer<dynamic>();
        var presentCalls = 0;
        final firstPins = <String>[];
        final secondPins = <String>[];

        messenger.setMockMethodCallHandler(_nativeSheetChannel, (call) {
          check(call.method).equals('presentModelSelector');
          presentCalls += 1;
          if (presentCalls == 1) {
            return firstPresentation.future;
          }
          throw PlatformException(code: 'ALREADY_PRESENTING');
        });

        final firstFuture = NativeSheetBridge.instance.presentModelSelector(
          title: 'Models',
          models: const [NativeSheetModelOption(id: 'model-a', name: 'A')],
          onTogglePinned: (modelId) async {
            firstPins.add(modelId);
          },
        );
        await Future<void>.delayed(Duration.zero);

        final secondResult = await NativeSheetBridge.instance
            .presentModelSelector(
              title: 'Models again',
              models: const [NativeSheetModelOption(id: 'model-b', name: 'B')],
              onTogglePinned: (modelId) async {
                secondPins.add(modelId);
              },
            );

        check(secondResult).isNull();
        await messenger.handlePlatformMessage(
          _nativeSheetChannel.name,
          _nativeSheetChannel.codec.encodeMethodCall(
            const MethodCall('onModelPinToggled', {'modelId': 'model-a'}),
          ),
          null,
        );

        check(firstPins).deepEquals(['model-a']);
        check(secondPins).isEmpty();

        firstPresentation.complete(null);
        await firstFuture;
      },
    );
  });
}
