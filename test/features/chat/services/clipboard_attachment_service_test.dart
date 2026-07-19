import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/services/clipboard_attachment_service.dart';
import 'package:conduit/features/chat/services/file_attachment_service.dart';
import 'package:conduit/features/chat/services/ios_native_paste_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _deliveryId = '123e4567-e89b-12d3-a456-426614174000';
const _otherDeliveryId = '987e6543-e21b-12d3-a456-426614174000';
const _itemId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
const _markerPrefix = '.conduit-native-paste-v2-';

typedef _NativePasteFixture = ({
  Directory stagingDirectory,
  File pendingMarker,
  File dartOwnedMarker,
  File reclaimingMarker,
  File item,
});

Future<_NativePasteFixture> _createNativePasteFixture(
  Directory temporaryDirectory, {
  String deliveryId = _deliveryId,
  String itemDeliveryId = _deliveryId,
}) async {
  final separator = Platform.pathSeparator;
  final stagingDirectory = Directory(
    '${temporaryDirectory.path}${separator}conduit-native-paste',
  );
  await stagingDirectory.create();
  final pendingMarker = File(
    '${stagingDirectory.path}$separator$_markerPrefix$deliveryId.pending',
  );
  final dartOwnedMarker = File(
    '${stagingDirectory.path}$separator$_markerPrefix$deliveryId.dart-owned',
  );
  final reclaimingMarker = File(
    '${stagingDirectory.path}$separator$_markerPrefix$deliveryId.reclaiming',
  );
  final item = File(
    '${stagingDirectory.path}$separator$itemDeliveryId-$_itemId-paste.png',
  );
  await pendingMarker.create();
  await item.writeAsBytes(<int>[1, 2, 3]);
  return (
    stagingDirectory: stagingDirectory,
    pendingMarker: pendingMarker,
    dartOwnedMarker: dartOwnedMarker,
    reclaimingMarker: reclaimingMarker,
    item: item,
  );
}

void main() {
  late Directory temporaryDirectory;
  late ClipboardAttachmentService service;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'conduit-clipboard-test-',
    );
    service = ClipboardAttachmentService(
      temporaryDirectory: () async => temporaryDirectory,
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('preserves every same-format image in a batch', () async {
    final firstBytes = Uint8List.fromList([1, 2, 3, 4]);
    final secondBytes = Uint8List.fromList([5, 6, 7, 8]);

    final attachments = await Future.wait([
      service.createAttachmentFromImageData(
        imageData: firstBytes,
        mimeType: 'image/png',
        suggestedFileName: 'pasted',
      ),
      service.createAttachmentFromImageData(
        imageData: secondBytes,
        mimeType: 'image/png',
        suggestedFileName: 'pasted',
      ),
    ]);

    check(attachments.every((attachment) => attachment != null)).isTrue();
    final first = attachments[0]!;
    final second = attachments[1]!;
    check(first.file.path == second.file.path).isFalse();
    check(await first.file.readAsBytes()).deepEquals(firstBytes);
    check(await second.file.readAsBytes()).deepEquals(secondBytes);
  });

  test('composer ownership failures escape synchronously', () {
    final attachment = LocalAttachment(
      file: File('${temporaryDirectory.path}/owned.png'),
      displayName: 'owned.png',
    );
    var uploadCalls = 0;
    var rollbackCalls = 0;

    check(
      () => acceptPastedAttachments(
        attachments: <LocalAttachment>[attachment],
        addFiles: (_) => throw StateError('composer unavailable'),
        upload: (_, _) async => uploadCalls++,
        rollback: (_) async => rollbackCalls++,
        logScope: 'clipboard/test',
      ),
    ).throws<StateError>();

    check(uploadCalls).equals(0);
    check(rollbackCalls).equals(0);
  });

  test('preflight failure rolls back the complete accepted batch', () async {
    final validFile = File('${temporaryDirectory.path}/valid.png');
    await validFile.writeAsBytes([1, 2, 3]);
    final validAttachment = LocalAttachment(
      file: validFile,
      displayName: 'valid.png',
    );
    final missingAttachment = LocalAttachment(
      file: File('${temporaryDirectory.path}/missing.png'),
      displayName: 'missing.png',
    );
    final rolledBack = <String>[];
    var uploadCalls = 0;

    await check(
      acceptPastedAttachments(
        attachments: <LocalAttachment>[validAttachment, missingAttachment],
        addFiles: (_) {},
        upload: (_, _) async => uploadCalls++,
        rollback: (attachment) async {
          rolledBack.add(attachment.displayName);
        },
        logScope: 'clipboard/test',
      ),
    ).throws<FileSystemException>();

    check(uploadCalls).equals(0);
    check(rolledBack).deepEquals(<String>['valid.png', 'missing.png']);
  });

  test('one synchronous upload failure does not block the batch', () async {
    final firstFile = File('${temporaryDirectory.path}/first.png');
    final secondFile = File('${temporaryDirectory.path}/second.png');
    await firstFile.writeAsBytes([1]);
    await secondFile.writeAsBytes([2]);
    final uploaded = <String>[];

    await acceptPastedAttachments(
      attachments: <LocalAttachment>[
        LocalAttachment(file: firstFile, displayName: 'first.png'),
        LocalAttachment(file: secondFile, displayName: 'second.png'),
      ],
      addFiles: (_) {},
      upload: (attachment, _) {
        uploaded.add(attachment.displayName);
        if (attachment.displayName == 'first.png') {
          throw StateError('synchronous upload setup failure');
        }
        return Future<void>.value();
      },
      rollback: (_) async {},
      logScope: 'clipboard/test',
    );
    await Future<void>.delayed(Duration.zero);

    check(uploaded).deepEquals(<String>['first.png', 'second.png']);
  });

  test('accepts only files in the native paste staging directory', () async {
    final stagingDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}conduit-native-paste',
    );
    await stagingDirectory.create();
    final stagedFile = File(
      '${stagingDirectory.path}${Platform.pathSeparator}paste.png',
    );
    await stagedFile.writeAsBytes([1, 2, 3]);
    final outsideFile = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}outside.png',
    );
    await outsideFile.writeAsBytes([4, 5, 6]);

    final accepted = await service.createAttachmentFromStagedFile(
      filePath: stagedFile.path,
      mimeType: 'image/png',
    );
    final rejected = await service.createAttachmentFromStagedFile(
      filePath: outsideFile.path,
      mimeType: 'image/png',
    );

    check(accepted).isNotNull();
    check(rejected).isNull();
    check(await outsideFile.exists()).isTrue();
  });

  test('rejects a staging-file symlink that escapes its owner', () async {
    final stagingDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}conduit-native-paste',
    );
    await stagingDirectory.create();
    final outsideFile = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}outside.png',
    );
    await outsideFile.writeAsBytes([7, 8, 9]);
    final link = Link(
      '${stagingDirectory.path}${Platform.pathSeparator}linked.png',
    );
    await link.create(outsideFile.path);

    final attachment = await service.createAttachmentFromStagedFile(
      filePath: link.path,
      mimeType: 'image/png',
    );

    check(attachment).isNull();
    check(await outsideFile.exists()).isTrue();
  });

  test('rejects a staging-root symlink that escapes its owner', () async {
    final outsideDirectory = await Directory.systemTemp.createTemp(
      'conduit-clipboard-outside-',
    );
    addTearDown(() => outsideDirectory.delete(recursive: true));
    final outsideFile = File('${outsideDirectory.path}/paste.png');
    await outsideFile.writeAsBytes([7, 8, 9]);
    final stagingLink = Link(
      '${temporaryDirectory.path}${Platform.pathSeparator}conduit-native-paste',
    );
    await stagingLink.create(outsideDirectory.path);

    final attachment = await service.createAttachmentFromStagedFile(
      filePath: '${stagingLink.path}${Platform.pathSeparator}paste.png',
      mimeType: 'image/png',
    );

    check(attachment).isNull();
    check(await outsideFile.exists()).isTrue();
  });

  test('deletes an owned staged file with an unsupported MIME type', () async {
    final stagingDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}conduit-native-paste',
    );
    await stagingDirectory.create();
    final stagedFile = File(
      '${stagingDirectory.path}${Platform.pathSeparator}paste.bin',
    );
    await stagedFile.writeAsBytes([1, 2, 3]);

    final attachment = await service.createAttachmentFromStagedFile(
      filePath: stagedFile.path,
      mimeType: 'application/octet-stream',
    );

    check(attachment).isNull();
    check(await stagedFile.exists()).isFalse();
  });

  test(
    'preserves an unsupported file outside the owned staging root',
    () async {
      final outsideFile = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}outside.bin',
      );
      await outsideFile.writeAsBytes([4, 5, 6]);

      final attachment = await service.createAttachmentFromStagedFile(
        filePath: outsideFile.path,
        mimeType: 'application/octet-stream',
      );

      check(attachment).isNull();
      check(await outsideFile.exists()).isTrue();
    },
  );

  test('claims a valid marker-backed native paste synchronously', () async {
    final fixture = await _createNativePasteFixture(temporaryDirectory);
    final prepared = await service.prepareNativePasteAttachments(
      deliveryId: _deliveryId,
      items: <IosNativeImagePasteItem>[
        IosNativeImagePasteItem(
          filePath: fixture.item.path,
          mimeType: 'image/png',
        ),
      ],
    );
    check(prepared).isNotNull();

    var callbackCalls = 0;
    service.claimNativePasteSync(prepared!, (attachments) {
      callbackCalls++;
      check(fixture.pendingMarker.existsSync()).isFalse();
      check(fixture.dartOwnedMarker.existsSync()).isTrue();
      check(attachments).length.equals(1);
      check(
        attachments.single.file.path,
      ).equals(fixture.item.resolveSymbolicLinksSync());
    });

    check(callbackCalls).equals(1);
    check(fixture.item.existsSync()).isTrue();
    check(fixture.dartOwnedMarker.existsSync()).isTrue();
  });

  test('rejects an item owned by a different delivery ID', () async {
    final fixture = await _createNativePasteFixture(
      temporaryDirectory,
      itemDeliveryId: _otherDeliveryId,
    );

    final prepared = await service.prepareNativePasteAttachments(
      deliveryId: _deliveryId,
      items: <IosNativeImagePasteItem>[
        IosNativeImagePasteItem(
          filePath: fixture.item.path,
          mimeType: 'image/png',
        ),
      ],
    );

    check(prepared).isNull();
    check(fixture.pendingMarker.existsSync()).isTrue();
    check(fixture.item.existsSync()).isTrue();
  });

  test(
    'rejects a payload that omits an item from its delivery batch',
    () async {
      final fixture = await _createNativePasteFixture(temporaryDirectory);
      final omittedItem = File(
        '${fixture.stagingDirectory.path}${Platform.pathSeparator}'
        '$_deliveryId-bbbbbbbb-cccc-4ddd-8eee-ffffffffffff-paste.png',
      );
      await omittedItem.writeAsBytes(<int>[4, 5, 6]);

      final prepared = await service.prepareNativePasteAttachments(
        deliveryId: _deliveryId,
        items: <IosNativeImagePasteItem>[
          IosNativeImagePasteItem(
            filePath: fixture.item.path,
            mimeType: 'image/png',
          ),
        ],
      );

      check(prepared).isNull();
      check(fixture.pendingMarker.existsSync()).isTrue();
      check(fixture.item.existsSync()).isTrue();
      check(omittedItem.existsSync()).isTrue();
    },
  );

  test('rejects a native paste item outside the direct staging root', () async {
    final fixture = await _createNativePasteFixture(temporaryDirectory);
    final outsideFile = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}'
      '$_deliveryId-$_itemId-paste.png',
    );
    await outsideFile.writeAsBytes(<int>[4, 5, 6]);

    final prepared = await service.prepareNativePasteAttachments(
      deliveryId: _deliveryId,
      items: <IosNativeImagePasteItem>[
        IosNativeImagePasteItem(
          filePath: outsideFile.path,
          mimeType: 'image/png',
        ),
      ],
    );

    check(prepared).isNull();
    check(fixture.pendingMarker.existsSync()).isTrue();
    check(outsideFile.existsSync()).isTrue();
  });

  test('rejects a symlinked native paste item', () async {
    final fixture = await _createNativePasteFixture(temporaryDirectory);
    final outsideFile = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}outside.png',
    );
    await outsideFile.writeAsBytes(<int>[7, 8, 9]);
    await fixture.item.delete();
    final itemLink = Link(fixture.item.path);
    await itemLink.create(outsideFile.path);

    final prepared = await service.prepareNativePasteAttachments(
      deliveryId: _deliveryId,
      items: <IosNativeImagePasteItem>[
        IosNativeImagePasteItem(filePath: itemLink.path, mimeType: 'image/png'),
      ],
    );

    check(prepared).isNull();
    check(itemLink.existsSync()).isTrue();
    check(outsideFile.existsSync()).isTrue();
  });

  test('rejects a native paste delivery with no pending marker', () async {
    final fixture = await _createNativePasteFixture(temporaryDirectory);
    await fixture.pendingMarker.delete();

    final prepared = await service.prepareNativePasteAttachments(
      deliveryId: _deliveryId,
      items: <IosNativeImagePasteItem>[
        IosNativeImagePasteItem(
          filePath: fixture.item.path,
          mimeType: 'image/png',
        ),
      ],
    );

    check(prepared).isNull();
    check(fixture.item.existsSync()).isTrue();
  });

  test('rejects a native paste delivery already being reclaimed', () async {
    final fixture = await _createNativePasteFixture(temporaryDirectory);
    await fixture.pendingMarker.rename(fixture.reclaimingMarker.path);

    final prepared = await service.prepareNativePasteAttachments(
      deliveryId: _deliveryId,
      items: <IosNativeImagePasteItem>[
        IosNativeImagePasteItem(
          filePath: fixture.item.path,
          mimeType: 'image/png',
        ),
      ],
    );

    check(prepared).isNull();
    check(fixture.reclaimingMarker.existsSync()).isTrue();
    check(fixture.item.existsSync()).isTrue();
  });

  test('rolls a failed synchronous claim back to pending', () async {
    final fixture = await _createNativePasteFixture(temporaryDirectory);
    final prepared = await service.prepareNativePasteAttachments(
      deliveryId: _deliveryId,
      items: <IosNativeImagePasteItem>[
        IosNativeImagePasteItem(
          filePath: fixture.item.path,
          mimeType: 'image/png',
        ),
      ],
    );
    check(prepared).isNotNull();

    check(
      () => service.claimNativePasteSync(
        prepared!,
        (_) => throw StateError('composer unavailable'),
      ),
    ).throws<StateError>();

    check(fixture.pendingMarker.existsSync()).isTrue();
    check(fixture.dartOwnedMarker.existsSync()).isFalse();
    check(fixture.item.existsSync()).isTrue();
  });
}
