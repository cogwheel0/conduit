import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/platform/conduit_platform_apis.g.dart';
import 'package:conduit/features/chat/services/ios_native_paste_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _deliveryId = '123e4567-e89b-12d3-a456-426614174000';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = IosNativePasteService.instance;

  setUp(service.debugClearHandlers);
  tearDown(service.debugClearHandlers);

  test('declines native paste when no composer accepts ownership', () async {
    final accepted = await service.debugDispatchPaste(
      const IosNativeImagePaste([
        IosNativeImagePasteItem(
          filePath: '/tmp/conduit-native-paste/image.png',
          mimeType: 'image/png',
        ),
      ], deliveryId: _deliveryId),
    );

    check(accepted).isFalse();
  });

  test('waits for the accepting composer acknowledgement', () async {
    final owner = Object();
    final acknowledgement = Completer<bool>();
    var handlerStarted = false;
    service.registerHandler(
      owner: owner,
      handler: (payload, lease) async {
        handlerStarted = true;
        if (await acknowledgement.future) {
          lease.tryCommit(() {});
        }
      },
    );

    var deliveryCompleted = false;
    final delivery = service
        .debugDispatchPaste(
          const IosNativeImagePaste([], deliveryId: _deliveryId),
        )
        .whenComplete(() => deliveryCompleted = true);
    await Future<void>.delayed(Duration.zero);

    check(handlerStarted).isTrue();
    check(deliveryCompleted).isFalse();

    acknowledgement.complete(true);
    check(await delivery).isTrue();
    check(deliveryCompleted).isTrue();
  });

  test('times out a stalled consumer acknowledgement exactly once', () async {
    final owner = Object();
    final acknowledgement = Completer<bool>();
    var deliveryCompletions = 0;
    service.registerHandler(
      owner: owner,
      handler: (_, lease) async {
        if (await acknowledgement.future) {
          lease.tryCommit(() {});
        }
      },
    );

    final delivery = service
        .debugDispatchPaste(
          const IosNativeImagePaste([], deliveryId: _deliveryId),
          acknowledgementTimeout: const Duration(milliseconds: 10),
        )
        .whenComplete(() => deliveryCompletions++);

    check(await delivery).isFalse();
    check(deliveryCompletions).equals(1);

    acknowledgement.complete(true);
    await Future<void>.delayed(Duration.zero);
    check(deliveryCompletions).equals(1);
  });

  test(
    'a committed lease remains accepted when its handler later times out',
    () async {
      final handlerRelease = Completer<void>();
      var ownershipTransfers = 0;
      service.registerHandler(
        owner: Object(),
        handler: (_, lease) async {
          check(lease.tryCommit(() => ownershipTransfers++)).isTrue();
          await handlerRelease.future;
        },
      );

      final accepted = await service.debugDispatchPaste(
        const IosNativeImagePaste([], deliveryId: _deliveryId),
        acknowledgementTimeout: const Duration(milliseconds: 10),
      );

      check(accepted).isTrue();
      check(ownershipTransfers).equals(1);
      handlerRelease.complete();
    },
  );

  test(
    'an expired dispatch lease prevents a slow handler from committing',
    () async {
      final owner = Object();
      final resumeHandler = Completer<void>();
      final handlerFinished = Completer<void>();
      var ownershipTransfers = 0;
      var lateCommitAccepted = true;
      service.registerHandler(
        owner: owner,
        handler: (_, lease) async {
          await resumeHandler.future;
          lateCommitAccepted = lease.tryCommit(() => ownershipTransfers++);
          handlerFinished.complete();
        },
      );

      final accepted = await service.debugDispatchPaste(
        const IosNativeImagePaste([], deliveryId: _deliveryId),
        acknowledgementTimeout: const Duration(milliseconds: 10),
      );
      check(accepted).isFalse();

      resumeHandler.complete();
      await handlerFinished.future;
      check(lateCommitAccepted).isFalse();
      check(ownershipTransfers).equals(0);
    },
  );

  test(
    'a focused older consumer can accept after a newer one declines',
    () async {
      final calls = <String>[];
      service.registerHandler(
        owner: Object(),
        handler: (_, lease) async {
          calls.add('accepting');
          lease.tryCommit(() {});
        },
      );
      service.registerHandler(
        owner: Object(),
        handler: (_, lease) async {
          calls.add('declining');
        },
      );

      final accepted = await service.debugDispatchPaste(
        const IosNativeImagePaste([], deliveryId: _deliveryId),
      );

      check(accepted).isTrue();
      check(calls).deepEquals(['declining', 'accepting']);
    },
  );

  test('an older consumer can accept after a newer one throws', () async {
    final calls = <String>[];
    service.registerHandler(
      owner: Object(),
      handler: (_, lease) async {
        calls.add('older');
        lease.tryCommit(() {});
      },
    );
    service.registerHandler(
      owner: Object(),
      handler: (_, lease) async {
        calls.add('newer');
        throw StateError('consumer failed');
      },
    );

    final accepted = await service.debugDispatchPaste(
      const IosNativeImagePaste([], deliveryId: _deliveryId),
    );

    check(accepted).isTrue();
    check(calls).deepEquals(['newer', 'older']);
  });

  test('a failing committed transfer invalidates dispatch ownership', () async {
    final calls = <String>[];
    service.registerHandler(
      owner: Object(),
      handler: (_, lease) async {
        calls.add('older');
        lease.tryCommit(() {});
      },
    );
    service.registerHandler(
      owner: Object(),
      handler: (_, lease) async {
        calls.add('newer');
        lease.tryCommit(() => throw StateError('transfer failed'));
      },
    );

    final accepted = await service.debugDispatchPaste(
      const IosNativeImagePaste([], deliveryId: _deliveryId),
    );

    check(accepted).isFalse();
    check(calls).deepEquals(['newer']);
  });

  test(
    'unregistered consumers cannot acknowledge later paste events',
    () async {
      final owner = Object();
      service.registerHandler(
        owner: owner,
        handler: (_, lease) async {
          lease.tryCommit(() {});
        },
      );
      service.unregisterHandler(owner);

      check(
        await service.debugDispatchPaste(
          const IosNativeImagePaste([], deliveryId: _deliveryId),
        ),
      ).isFalse();
    },
  );

  test(
    'declines image payloads without a delivery ID before dispatch',
    () async {
      var handlerCalls = 0;
      service.registerHandler(
        owner: Object(),
        handler: (_, _) async => handlerCalls++,
      );

      final accepted = await service.debugDispatchPaste(
        const IosNativeImagePaste([]),
      );

      check(accepted).isFalse();
      check(handlerCalls).equals(0);
    },
  );

  test('accepts uppercase delivery IDs for dispatch', () async {
    var handlerCalls = 0;
    service.registerHandler(
      owner: Object(),
      handler: (_, lease) async {
        handlerCalls++;
        lease.tryCommit(() {});
      },
    );

    final accepted = await service.debugDispatchPaste(
      const IosNativeImagePaste(
        [],
        deliveryId: '123E4567-E89B-12D3-A456-426614174000',
      ),
    );

    check(accepted).isTrue();
    check(handlerCalls).equals(1);
  });

  test('propagates delivery IDs from platform and map payloads', () {
    final platformPayload = IosNativePastePayload.fromPlatform(
      PlatformNativePastePayload(
        kind: PlatformNativePasteKind.images,
        deliveryId: _deliveryId,
        items: <PlatformNativePasteImageItem>[
          PlatformNativePasteImageItem(
            mimeType: 'image/png',
            filePath: '/tmp/native.png',
          ),
        ],
      ),
    );
    final mapPayload = IosNativePastePayload.fromMap(<String, Object>{
      'kind': 'images',
      'deliveryId': _deliveryId,
      'items': <Map<String, String>>[
        <String, String>{
          'mimeType': 'image/png',
          'filePath': '/tmp/native.png',
        },
      ],
    });

    check(
      (platformPayload as IosNativeImagePaste).deliveryId,
    ).equals(_deliveryId);
    check((mapPayload as IosNativeImagePaste).deliveryId).equals(_deliveryId);
  });
}
