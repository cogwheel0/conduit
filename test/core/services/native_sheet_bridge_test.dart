import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/platform/conduit_platform_apis.g.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _presentModelSelectorChannel = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.conduit.NativeSheetHostApi.presentModelSelector',
  NativeSheetHostApi.pigeonChannelCodec,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    NativeSheetBridge.instance.debugIsIOSOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(
          _presentModelSelectorChannel,
          null,
        );
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

        messenger.setMockDecodedMessageHandler<Object?>(
          _presentModelSelectorChannel,
          (message) async {
            final args = message! as List<Object?>;
            final request =
                args.single as PlatformNativeSheetModelSelectorRequest;
            presentCalls += 1;
            if (presentCalls == 1) {
              check(request.models.single.tags).deepEquals(['tag-a']);
              await firstPresentation.future;
              return wrapResponse(result: null);
            }
            check(request.models.single.tags).deepEquals(['tag-b']);
            return wrapResponse(
              error: PlatformException(code: 'ALREADY_PRESENTING'),
            );
          },
        );

        final firstFuture = NativeSheetBridge.instance.presentModelSelector(
          title: 'Models',
          models: const [
            NativeSheetModelOption(id: 'model-a', name: 'A', tags: ['tag-a']),
          ],
          onTogglePinned: (modelId) async {
            firstPins.add(modelId);
          },
        );
        await Future<void>.delayed(Duration.zero);

        final secondResult = await NativeSheetBridge.instance
            .presentModelSelector(
              title: 'Models again',
              models: const [
                NativeSheetModelOption(
                  id: 'model-b',
                  name: 'B',
                  tags: ['tag-b'],
                ),
              ],
              onTogglePinned: (modelId) async {
                secondPins.add(modelId);
              },
            );

        check(secondResult).isNull();
        NativeSheetBridge.instance.onModelPinToggled(
          PlatformNativeSheetModelPinToggledEvent(modelId: 'model-a'),
        );
        await Future<void>.delayed(Duration.zero);

        check(firstPins).deepEquals(['model-a']);
        check(secondPins).isEmpty();

        firstPresentation.complete(null);
        await firstFuture;
      },
    );
  });
}
