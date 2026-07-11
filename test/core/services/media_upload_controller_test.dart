import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/attachment_upload_queue.dart';
import 'package:conduit/core/services/media_upload_controller.dart';
import 'package:conduit/features/chat/services/file_attachment_service.dart';
import 'package:conduit/features/direct_connections/direct_connections.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('direct upload stats the actual file before base64 encoding', () async {
    final directory = await Directory.systemTemp.createTemp(
      'conduit_direct_media_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final image = File('${directory.path}/oversized.png');
    await _truncate(image, kDirectMaxDecodedImageBytes + 1);
    var encodeCalls = 0;
    final container = _directContainer(
      encoder: (file) async {
        encodeCalls++;
        return 'data:image/png;base64,AQ==';
      },
    );
    addTearDown(container.dispose);

    await expectLater(
      container
          .read(mediaUploadControllerProvider)
          .upload(filePath: image.path, fileName: 'oversized.png', fileSize: 1),
      throwsA(isA<DirectChatInputException>()),
    );
    expect(encodeCalls, 0);
  });

  test('direct upload stats every pending image for aggregate limit', () async {
    final directory = await Directory.systemTemp.createTemp(
      'conduit_direct_media_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final first = File('${directory.path}/first.png');
    final second = File('${directory.path}/second.png');
    await _truncate(first, 11 * 1024 * 1024);
    await _truncate(second, 10 * 1024 * 1024);
    var encodeCalls = 0;
    final container = _directContainer(
      attachments: [
        _pendingImage(first, reportedBytes: 1),
        _pendingImage(second, reportedBytes: 1),
      ],
      encoder: (file) async {
        encodeCalls++;
        return 'data:image/png;base64,AQ==';
      },
    );
    addTearDown(container.dispose);

    await expectLater(
      container
          .read(mediaUploadControllerProvider)
          .upload(filePath: first.path, fileName: 'first.png', fileSize: 1),
      throwsA(isA<DirectChatInputException>()),
    );
    expect(encodeCalls, 0);
  });

  test('prepared direct data URL is validated against aggregate bytes', () {
    expect(
      () => validatePreparedDirectImageDataUrl(
        'data:image/png;base64,not-valid%',
        otherImageBytes: 0,
      ),
      throwsA(isA<DirectChatInputException>()),
    );
    expect(
      () => validatePreparedDirectImageDataUrl(
        'data:image/png;base64,AQIDBAUG',
        otherImageBytes: 5,
        maxDecodedImageBytes: 10,
      ),
      throwsA(isA<DirectChatInputException>()),
    );
    expect(
      validatePreparedDirectImageDataUrl(
        'data:image/png;base64,AQIDBAUG',
        otherImageBytes: 4,
        maxDecodedImageBytes: 10,
      ),
      6,
    );
  });

  test(
    'post-encode decoded bytes are rechecked against other images',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'conduit_direct_media_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final current = File('${directory.path}/current.png');
      final other = File('${directory.path}/other.png');
      await current.writeAsBytes([1]);
      await _truncate(other, 19 * 1024 * 1024);
      final expandedDataUrl =
          'data:image/png;base64,${base64Encode(Uint8List(2 * 1024 * 1024))}';
      final container = _directContainer(
        attachments: [
          _pendingImage(current, reportedBytes: 1),
          _pendingImage(other, reportedBytes: 1),
        ],
        encoder: (file) async => expandedDataUrl,
      );
      addTearDown(container.dispose);

      await expectLater(
        container
            .read(mediaUploadControllerProvider)
            .upload(
              filePath: current.path,
              fileName: 'current.png',
              fileSize: 1,
            ),
        throwsA(isA<DirectChatInputException>()),
      );
      expect(container.read(attachedFilesProvider).first.base64DataUrl, isNull);
    },
  );

  test('completed direct state stores validated decoded byte size', () async {
    final directory = await Directory.systemTemp.createTemp(
      'conduit_direct_media_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final image = File('${directory.path}/small.png');
    await image.writeAsBytes([1]);
    const dataUrl = 'data:image/png;base64,AQIDBAUG';
    final container = _directContainer(
      attachments: [_pendingImage(image, reportedBytes: 1)],
      encoder: (file) async => dataUrl,
    );
    addTearDown(container.dispose);

    await container
        .read(mediaUploadControllerProvider)
        .upload(filePath: image.path, fileName: 'small.png', fileSize: 1);

    final stored = container.read(attachedFilesProvider).single;
    expect(stored.status, FileUploadStatus.completed);
    expect(stored.fileSize, 6);
    expect(stored.base64DataUrl, dataUrl);
  });

  test('invalid encoder output is never stored as a direct image', () async {
    final directory = await Directory.systemTemp.createTemp(
      'conduit_direct_media_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final image = File('${directory.path}/small.png');
    await image.writeAsBytes([1, 2, 3]);
    final container = _directContainer(
      attachments: [_pendingImage(image, reportedBytes: 3)],
      encoder: (file) async => 'data:image/png;base64,invalid%',
    );
    addTearDown(container.dispose);

    await expectLater(
      container
          .read(mediaUploadControllerProvider)
          .upload(filePath: image.path, fileName: 'small.png', fileSize: 3),
      throwsA(isA<DirectChatInputException>()),
    );

    final stored = container.read(attachedFilesProvider).single;
    expect(stored.status, FileUploadStatus.failed);
    expect(stored.fileId, isNull);
    expect(stored.base64DataUrl, isNull);
  });

  test(
    'stale direct selection never falls through to OpenWebUI upload',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'conduit_direct_media_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final image = File('${directory.path}/small.png');
      await image.writeAsBytes([1, 2, 3]);

      final registry = DirectModelRegistry();
      final profile = DirectConnectionProfile(
        id: 'stale-media-profile',
        name: 'Stale media provider',
        adapterKey: kOllamaAdapterKey,
        baseUrl: 'http://localhost:11434',
      );
      final staleModel = registry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'vision', isMultimodal: true),
      ]).single;
      registry.removeProfile(profile.id);

      var uploadCalls = 0;
      final uploadQueue = AttachmentUploadQueue();
      await uploadQueue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async {
          uploadCalls++;
          return 'server-file-id';
        },
        database: () => null,
      );
      addTearDown(uploadQueue.dispose);

      final container = ProviderContainer(
        overrides: [
          selectedModelProvider.overrideWithValue(staleModel),
          directModelRegistryProvider.overrideWithValue(registry),
          attachmentUploadQueueProvider.overrideWithValue(uploadQueue),
          attachedFilesProvider.overrideWith(
            () => _SeededAttachedFilesNotifier([
              _pendingImage(image, reportedBytes: 3),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        container
            .read(mediaUploadControllerProvider)
            .upload(filePath: image.path, fileName: 'small.png', fileSize: 3),
        throwsA(isA<DirectChatInputException>()),
      );
      expect(uploadCalls, 0);
      expect(uploadQueue.queue, isEmpty);
    },
  );
}

ProviderContainer _directContainer({
  required DirectImageDataUrlEncoder encoder,
  List<FileUploadState> attachments = const [],
}) {
  final registry = DirectModelRegistry();
  final model = registry.replaceProfileModels(
    DirectConnectionProfile(
      id: 'media-profile',
      name: 'Media provider',
      adapterKey: kOllamaAdapterKey,
      baseUrl: 'http://localhost:11434',
    ),
    [DirectRemoteModel(id: 'vision', isMultimodal: true)],
  ).single;
  return ProviderContainer(
    overrides: [
      selectedModelProvider.overrideWithValue(model),
      directModelRegistryProvider.overrideWithValue(registry),
      directImageDataUrlEncoderProvider.overrideWithValue(encoder),
      attachedFilesProvider.overrideWith(
        () => _SeededAttachedFilesNotifier(attachments),
      ),
    ],
  );
}

FileUploadState _pendingImage(File file, {required int reportedBytes}) =>
    FileUploadState(
      file: file,
      fileName: file.uri.pathSegments.last,
      fileSize: reportedBytes,
      progress: 0,
      status: FileUploadStatus.pending,
      isImage: true,
    );

Future<void> _truncate(File file, int length) async {
  final handle = await file.open(mode: FileMode.write);
  try {
    await handle.truncate(length);
  } finally {
    await handle.close();
  }
}

final class _SeededAttachedFilesNotifier extends AttachedFilesNotifier {
  _SeededAttachedFilesNotifier(this.attachments);

  final List<FileUploadState> attachments;

  @override
  List<FileUploadState> build() => List.of(attachments);
}
