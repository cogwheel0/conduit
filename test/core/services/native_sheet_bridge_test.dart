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

final _updateModelSelectorReasoningChannel = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.conduit.NativeSheetHostApi.updateModelSelectorReasoningEffort',
  NativeSheetHostApi.pigeonChannelCodec,
);

final _requestAppStoreReviewChannel = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.conduit.NativeSheetHostApi.requestAppStoreReview',
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
    messenger.setMockDecodedMessageHandler<Object?>(
      _updateModelSelectorReasoningChannel,
      null,
    );
    messenger.setMockDecodedMessageHandler<Object?>(
      _requestAppStoreReviewChannel,
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

  test('sign-out item serializes native checkbox copy', () {
    const item = NativeSheetItemConfig(
      id: 'sign-out',
      title: 'Sign Out',
      subtitle: 'End your session',
      placeholder: 'Clears preferences and connections.',
      destructive: true,
      options: [
        NativeSheetOptionConfig(
          id: 'keep-server-details',
          label: 'Keep server details',
          subtitle: 'Tokens are deleted',
        ),
      ],
    );

    final payload = item.toMap();
    check(payload['placeholder']).equals('Clears preferences and connections.');
    check(payload['destructive']).equals(true);
    check(payload['options'] as List<Object?>).deepEquals([
      {
        'id': 'keep-server-details',
        'label': 'Keep server details',
        'subtitle': 'Tokens are deleted',
        'sfSymbol': null,
        'enabled': true,
        'destructive': false,
        'ancestorHasMoreSiblings': <bool>[],
        'showBranch': false,
        'hasMoreSiblings': false,
      },
    ]);
  });

  test('native sign-out publishes the selected retention value', () async {
    final event = NativeSheetBridge.instance.events
        .where((event) => event is NativeSheetControlChanged)
        .cast<NativeSheetControlChanged>()
        .first;

    NativeSheetBridge.instance.onControlChanged(
      PlatformNativeSheetControlChangedEvent(id: 'sign-out', value: false),
    );

    final signOut = await event;
    check(signOut.id).equals('sign-out');
    check(signOut.value).equals(false);
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

  group('NativeSheetBridge.requestAppStoreReview', () {
    test('forwards native result on iOS', () async {
      NativeSheetBridge.instance.debugIsIOSOverride = true;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var calls = 0;
      messenger.setMockDecodedMessageHandler<Object?>(
        _requestAppStoreReviewChannel,
        (message) async {
          calls += 1;
          return wrapResponse(result: true);
        },
      );

      final requested = await NativeSheetBridge.instance
          .requestAppStoreReview();

      check(requested).isTrue();
      check(calls).equals(1);
    });

    test('preserves native false result on iOS', () async {
      NativeSheetBridge.instance.debugIsIOSOverride = true;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockDecodedMessageHandler<Object?>(
        _requestAppStoreReviewChannel,
        (message) async => wrapResponse(result: false),
      );

      final requested = await NativeSheetBridge.instance
          .requestAppStoreReview();

      check(requested).isFalse();
    });

    test('converts platform errors to false', () async {
      NativeSheetBridge.instance.debugIsIOSOverride = true;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockDecodedMessageHandler<Object?>(
        _requestAppStoreReviewChannel,
        (message) async =>
            wrapResponse(error: PlatformException(code: 'NO_FOREGROUND_SCENE')),
      );

      final requested = await NativeSheetBridge.instance
          .requestAppStoreReview();

      check(requested).isFalse();
    });

    test('does not send a platform message off iOS', () async {
      NativeSheetBridge.instance.debugIsIOSOverride = false;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var calls = 0;
      messenger.setMockDecodedMessageHandler<Object?>(
        _requestAppStoreReviewChannel,
        (message) async {
          calls += 1;
          return wrapResponse(result: true);
        },
      );

      final requested = await NativeSheetBridge.instance
          .requestAppStoreReview();

      check(requested).isFalse();
      check(calls).equals(0);
    });
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

    test('effort hydration updates controls and installs callback', () async {
      NativeSheetBridge.instance.debugIsIOSOverride = true;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final presentation = Completer<dynamic>();
      final changed = <String>[];
      messenger.setMockDecodedMessageHandler<Object?>(
        _presentModelSelectorChannel,
        (_) => presentation.future,
      );
      messenger.setMockDecodedMessageHandler<Object?>(
        _updateModelSelectorReasoningChannel,
        (message) async {
          final args = message! as List<Object?>;
          check(args[0]).equals('presentation-current');
          check(args[1]).equals('vendor_ultra');
          check(
            args[2]! as List<Object?>,
          ).deepEquals(['automatic', 'vendor_ultra']);
          check(args[3]).equals(true);
          return wrapResponse(empty: true);
        },
      );
      final presented = NativeSheetBridge.instance.presentModelSelector(
        presentationId: 'presentation-current',
        title: 'Models',
        models: const [NativeSheetModelOption(id: 'model-a', name: 'A')],
      );
      await Future<void>.delayed(Duration.zero);

      await NativeSheetBridge.instance.updateModelSelectorReasoningEffort(
        presentationId: 'presentation-current',
        value: 'vendor_ultra',
        options: const ['automatic', 'vendor_ultra'],
        allowsCustom: true,
        onReasoningEffortChanged: (value) async => changed.add(value),
      );
      NativeSheetBridge.instance.onReasoningEffortChanged(
        PlatformNativeSheetReasoningEffortChangedEvent(value: 'vendor_ultra'),
      );
      await Future<void>.delayed(Duration.zero);

      check(changed).deepEquals(['vendor_ultra']);
      presentation.complete(wrapResponse(result: null));
      await presented;
    });
  });
}
