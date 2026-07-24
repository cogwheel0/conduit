import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/platform/conduit_platform_apis.g.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _presentProfileMenuChannel = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.conduit.NativeSheetHostApi.presentProfileMenu',
  NativeSheetHostApi.pigeonChannelCodec,
);

final _presentModelSelectorChannel = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.conduit.NativeSheetHostApi.presentModelSelector',
  NativeSheetHostApi.pigeonChannelCodec,
);

final _updateModelSelectorChannel = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.conduit.NativeSheetHostApi.updateModelSelectorModels',
  NativeSheetHostApi.pigeonChannelCodec,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    NativeSheetBridge.instance.debugIsIOSOverride = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler<Object?>(
      _presentProfileMenuChannel,
      null,
    );
    messenger.setMockDecodedMessageHandler<Object?>(
      _presentModelSelectorChannel,
      null,
    );
    messenger.setMockDecodedMessageHandler<Object?>(
      _updateModelSelectorChannel,
      null,
    );
  });

  test('sheet item serializes generic dismiss action metadata', () {
    const item = NativeSheetItemConfig(
      id: 'workspace-row',
      title: 'Workspace',
      dismissOnSelect: true,
      actionId: 'open-workspace',
      actionValue: 'models',
    );

    check(item.toMap()).deepEquals({
      'id': 'workspace-row',
      'title': 'Workspace',
      'subtitle': null,
      'sfSymbol': 'circle',
      'destructive': false,
      'dismissOnSelect': true,
      'actionId': 'open-workspace',
      'actionValue': 'models',
      'url': null,
      'kind': 'navigation',
      'value': null,
      'placeholder': null,
      'options': <Object?>[],
    });
  });

  test('sheet item serializes a branded icon asset', () {
    const item = NativeSheetItemConfig(
      id: 'hermes',
      title: 'Hermes Agent',
      sfSymbol: 'sparkles',
      iconAsset: 'assets/icons/hermes_agent.png',
    );

    check(item.toMap()['iconAsset']).equals('assets/icons/hermes_agent.png');
  });

  test('profile menu propagates item metadata to platform', () async {
    NativeSheetBridge.instance.debugIsIOSOverride = true;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler<Object?>(
      _presentProfileMenuChannel,
      (message) async {
        final args = message! as List<Object?>;
        final config = args.single as PlatformNativeProfileSheetConfig;
        check(config.profile.avatarIsTemplate).isTrue();
        final item = config.sections.single.items.single;
        check(item.dismissOnSelect).isTrue();
        check(item.actionId).equals('open-workspace');
        check(item.actionValue).equals('models');
        check(item.iconAsset).equals('assets/icons/hermes_agent.png');
        return wrapResponse(result: true);
      },
    );

    final presented = await NativeSheetBridge.instance.presentProfileMenu(
      const NativeProfileSheetConfig(
        profile: NativeProfileSheetUser(
          displayName: 'User',
          email: 'user@example.com',
          initials: 'U',
          avatarIsTemplate: true,
        ),
        editProfileLabel: 'Edit',
        menuItems: [],
        detailSheets: [],
        sections: [
          NativeSheetSectionConfig(
            items: [
              NativeSheetItemConfig(
                id: 'workspace-row',
                title: 'Workspace',
                dismissOnSelect: true,
                actionId: 'open-workspace',
                actionValue: 'models',
                iconAsset: 'assets/icons/hermes_agent.png',
              ),
            ],
          ),
        ],
      ),
    );

    check(presented).isTrue();
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
              check(request.presentationId).equals('presentation-a');
              check(request.models.single.tags).deepEquals(['tag-a']);
              check(
                request.models.single.avatarBytes!.toList(),
              ).deepEquals([1, 2, 3]);
              await firstPresentation.future;
              return wrapResponse(result: null);
            }
            check(request.presentationId).equals('presentation-b');
            check(request.models.single.tags).deepEquals(['tag-b']);
            return wrapResponse(
              error: PlatformException(code: 'ALREADY_PRESENTING'),
            );
          },
        );

        final firstFuture = NativeSheetBridge.instance.presentModelSelector(
          presentationId: 'presentation-a',
          title: 'Models',
          models: [
            NativeSheetModelOption(
              id: 'model-a',
              name: 'A',
              avatarBytes: Uint8List.fromList([1, 2, 3]),
              tags: ['tag-a'],
            ),
          ],
          onTogglePinned: (modelId) async {
            firstPins.add(modelId);
          },
        );
        await Future<void>.delayed(Duration.zero);

        final secondResult = await NativeSheetBridge.instance
            .presentModelSelector(
              presentationId: 'presentation-b',
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

    test(
      'successful selector clears a previously active effort handler',
      () async {
        NativeSheetBridge.instance.debugIsIOSOverride = true;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final firstPresentation = Completer<dynamic>();
        var presentCalls = 0;
        final firstEfforts = <String>[];
        final secondEfforts = <String>[];

        messenger.setMockDecodedMessageHandler<Object?>(
          _presentModelSelectorChannel,
          (message) async {
            presentCalls += 1;
            if (presentCalls == 1) {
              await firstPresentation.future;
            }
            return wrapResponse(result: null);
          },
        );

        final firstFuture = NativeSheetBridge.instance.presentModelSelector(
          presentationId: 'presentation-a',
          title: 'Models',
          models: const [NativeSheetModelOption(id: 'model-a', name: 'A')],
          onReasoningEffortChanged: (value) async {
            firstEfforts.add(value);
          },
        );
        await Future<void>.delayed(Duration.zero);

        await NativeSheetBridge.instance.presentModelSelector(
          presentationId: 'presentation-b',
          title: 'Models again',
          models: const [NativeSheetModelOption(id: 'model-b', name: 'B')],
          onReasoningEffortChanged: (value) async {
            secondEfforts.add(value);
          },
        );
        NativeSheetBridge.instance.onReasoningEffortChanged(
          PlatformNativeSheetReasoningEffortChangedEvent(value: 'high'),
        );
        await Future<void>.delayed(Duration.zero);

        check(firstEfforts).isEmpty();
        check(secondEfforts).isEmpty();

        firstPresentation.complete(null);
        await firstFuture;
      },
    );

    test('hydration update carries its selector presentation ID', () async {
      NativeSheetBridge.instance.debugIsIOSOverride = true;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockDecodedMessageHandler<Object?>(
        _updateModelSelectorChannel,
        (message) async {
          final args = message! as List<Object?>;
          check(args[0]).equals('presentation-current');
          final models = args[1]! as List<Object?>;
          final model = models.single as PlatformNativeSheetModelOption;
          check(model.id).equals('model-a');
          check(model.avatarBytes!.toList()).deepEquals([4, 5, 6]);
          return wrapResponse(empty: true);
        },
      );

      await NativeSheetBridge.instance.updateModelSelectorModels([
        NativeSheetModelOption(
          id: 'model-a',
          name: 'A',
          avatarBytes: Uint8List.fromList([4, 5, 6]),
        ),
      ], presentationId: 'presentation-current');
    });
  });
}
