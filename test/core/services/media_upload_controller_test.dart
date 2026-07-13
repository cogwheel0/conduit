import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/attachment_upload_queue.dart';
import 'package:conduit/core/services/media_upload_controller.dart';
import 'package:conduit/features/chat/services/file_attachment_service.dart';
import 'package:conduit/features/direct_connections/direct_connections.dart';
import 'package:conduit/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/services/hermes_local_document_service.dart';
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

  test('failed images do not consume the direct image count', () async {
    final directory = await Directory.systemTemp.createTemp(
      'conduit_direct_media_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final current = File('${directory.path}/current.png');
    await current.writeAsBytes([1]);
    final failed = [
      for (var index = 0; index < kDirectMaxImages; index++)
        _failedImage(File('${directory.path}/deleted-$index.png')),
    ];
    var encodeCalls = 0;
    final container = _directContainer(
      attachments: [...failed, _pendingImage(current, reportedBytes: 1)],
      encoder: (file) async {
        encodeCalls++;
        return 'data:image/png;base64,AQ==';
      },
    );
    addTearDown(container.dispose);

    await container
        .read(mediaUploadControllerProvider)
        .upload(filePath: current.path, fileName: 'current.png', fileSize: 1);

    expect(encodeCalls, 1);
    final stored = container
        .read(attachedFilesProvider)
        .where((attachment) => attachment.file.path == current.path)
        .single;
    expect(stored.status, FileUploadStatus.completed);
  });

  test('missing failed image staging file is never statted', () async {
    final directory = await Directory.systemTemp.createTemp(
      'conduit_direct_media_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final current = File('${directory.path}/current.png');
    await current.writeAsBytes([1]);
    final deleted = File('${directory.path}/already-deleted.png');
    expect(await deleted.exists(), isFalse);
    final container = _directContainer(
      attachments: [
        _failedImage(deleted),
        _pendingImage(current, reportedBytes: 1),
      ],
      encoder: (file) async => 'data:image/png;base64,AQ==',
    );
    addTearDown(container.dispose);

    await container
        .read(mediaUploadControllerProvider)
        .upload(filePath: current.path, fileName: 'current.png', fileSize: 1);

    final stored = container
        .read(attachedFilesProvider)
        .where((attachment) => attachment.file.path == current.path)
        .single;
    expect(stored.status, FileUploadStatus.completed);
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

  test('server-owned direct-like model uses OpenWebUI upload', () async {
    final directory = await Directory.systemTemp.createTemp(
      'conduit_server_media_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final image = File('${directory.path}/small.png');
    await image.writeAsBytes([1, 2, 3]);

    const serverModel = Model(
      id: 'direct:server:bW9kZWw',
      name: 'Server-owned direct-like model',
      metadata: {'backend': 'direct'},
    );
    var uploadCalls = 0;
    var encodeCalls = 0;
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
        apiServiceProvider.overrideWithValue(null),
        selectedModelProvider.overrideWithValue(serverModel),
        directModelRegistryProvider.overrideWithValue(DirectModelRegistry()),
        directImageDataUrlEncoderProvider.overrideWithValue((file) async {
          encodeCalls++;
          return 'data:image/png;base64,AQID';
        }),
        attachmentUploadQueueProvider.overrideWithValue(uploadQueue),
        attachedFilesProvider.overrideWith(
          () => _SeededAttachedFilesNotifier([
            _pendingImage(image, reportedBytes: 3),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(mediaUploadControllerProvider)
        .upload(filePath: image.path, fileName: 'small.png', fileSize: 3);

    expect(uploadCalls, 1);
    expect(encodeCalls, 0);
    final stored = container.read(attachedFilesProvider).single;
    expect(stored.fileId, 'server-file-id');
    expect(stored.base64DataUrl, isNull);
  });

  test('queued image follows a model switch to OpenWebUI', () async {
    final directory = await Directory.systemTemp.createTemp(
      'conduit_direct_media_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final first = File('${directory.path}/first.png');
    final second = File('${directory.path}/second.png');
    await first.writeAsBytes([1]);
    await second.writeAsBytes([2]);

    final registry = DirectModelRegistry();
    final directModel = registry.replaceProfileModels(
      DirectConnectionProfile(
        id: 'switch-media-profile',
        name: 'Switch media provider',
        adapterKey: kOllamaAdapterKey,
        baseUrl: 'http://localhost:11434',
      ),
      [DirectRemoteModel(id: 'vision', isMultimodal: true)],
    ).single;
    const openWebUiModel = Model(id: 'server-model', name: 'Server model');

    final firstEncodingStarted = Completer<void>();
    final allowFirstEncoding = Completer<void>();
    var encodeCalls = 0;
    var uploadCalls = 0;
    final uploadQueue = AttachmentUploadQueue();
    await uploadQueue.initialize(
      onUpload: (filePath, fileName, {cancelToken}) async {
        uploadCalls++;
        return 'server-file-$uploadCalls';
      },
      database: () => null,
    );
    addTearDown(uploadQueue.dispose);

    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(null),
        directModelRegistryProvider.overrideWithValue(registry),
        directImageDataUrlEncoderProvider.overrideWithValue((file) async {
          encodeCalls++;
          if (encodeCalls == 1) {
            firstEncodingStarted.complete();
            await allowFirstEncoding.future;
          }
          return 'data:image/png;base64,AQ==';
        }),
        attachmentUploadQueueProvider.overrideWithValue(uploadQueue),
        attachedFilesProvider.overrideWith(
          () => _SeededAttachedFilesNotifier([
            _pendingImage(first, reportedBytes: 1),
            _pendingImage(second, reportedBytes: 1),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(selectedModelProvider.notifier).set(directModel);

    final firstUpload = container
        .read(mediaUploadControllerProvider)
        .upload(filePath: first.path, fileName: 'first.png', fileSize: 1);
    await firstEncodingStarted.future;
    final secondUpload = container
        .read(mediaUploadControllerProvider)
        .upload(filePath: second.path, fileName: 'second.png', fileSize: 1);
    await Future<void>.delayed(Duration.zero);

    container.read(selectedModelProvider.notifier).set(openWebUiModel);
    allowFirstEncoding.complete();
    await Future.wait([firstUpload, secondUpload]);

    expect(encodeCalls, 1);
    expect(uploadCalls, 1);
    final byPath = {
      for (final attachment in container.read(attachedFilesProvider))
        attachment.file.path: attachment,
    };
    expect(byPath[first.path]?.fileId, startsWith('data:image/'));
    expect(byPath[second.path]?.fileId, 'server-file-1');
    expect(byPath[second.path]?.base64DataUrl, isNull);
  });

  group('Hermes attachment preparation', () {
    test('file service remains available without an OpenWebUI API', () {
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          reviewerModeProvider.overrideWithValue(false),
          selectedModelProvider.overrideWith(
            () => _SeededSelectedModel(hermesSyntheticModel()),
          ),
          directModelRegistryProvider.overrideWithValue(DirectModelRegistry()),
        ],
      );
      addTearDown(container.dispose);

      expect(
        container.read(fileAttachmentServiceProvider),
        isA<FileAttachmentService>(),
      );
    });

    test('image preparation fails closed without capability', () async {
      final directory = await Directory.systemTemp.createTemp(
        'conduit_hermes_media_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final image = File('${directory.path}/photo.png');
      await image.writeAsBytes([1, 2, 3]);
      var encodeCalls = 0;
      final queue = await _recordingUploadQueue();
      addTearDown(queue.dispose);
      final container = await _hermesContainer(
        capabilities: const HermesCapabilities(),
        attachments: [_pendingImage(image, reportedBytes: 3)],
        encoder: (file) async {
          encodeCalls++;
          return 'data:image/png;base64,AQID';
        },
        uploadQueue: queue,
      );
      addTearDown(container.dispose);

      await expectLater(
        container
            .read(mediaUploadControllerProvider)
            .upload(filePath: image.path, fileName: 'photo.png', fileSize: 3),
        throwsA(isA<HermesChatInputException>()),
      );

      expect(encodeCalls, 0);
      expect(queue.queue, isEmpty);
      expect(
        container.read(attachedFilesProvider).single.status,
        FileUploadStatus.failed,
      );
    });

    test('advertised image capability stores a local data URL', () async {
      final directory = await Directory.systemTemp.createTemp(
        'conduit_hermes_media_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final image = File('${directory.path}/photo.png');
      await image.writeAsBytes([1, 2, 3]);
      const dataUrl = 'data:image/png;base64,AQID';
      final queue = await _recordingUploadQueue();
      addTearDown(queue.dispose);
      final container = await _hermesContainer(
        capabilities: const HermesCapabilities(inputImages: true),
        attachments: [_pendingImage(image, reportedBytes: 3)],
        encoder: (file) async => dataUrl,
        uploadQueue: queue,
      );
      addTearDown(container.dispose);

      await container
          .read(mediaUploadControllerProvider)
          .upload(filePath: image.path, fileName: 'photo.png', fileSize: 3);

      final stored = container.read(attachedFilesProvider).single;
      expect(stored.status, FileUploadStatus.completed);
      expect(stored.fileId, dataUrl);
      expect(stored.base64DataUrl, dataUrl);
      expect(stored.fileSize, 3);
      expect(queue.queue, isEmpty);
    });

    test('a fifth active image is rejected before encoding', () async {
      final directory = await Directory.systemTemp.createTemp(
        'conduit_hermes_media_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final images = <File>[];
      for (var index = 0; index < kHermesMaxInlineImages + 1; index++) {
        final image = File('${directory.path}/photo-$index.png');
        await image.writeAsBytes([index]);
        images.add(image);
      }
      var encodeCalls = 0;
      final container = await _hermesContainer(
        capabilities: const HermesCapabilities(inputImages: true),
        attachments: [
          for (final image in images) _pendingImage(image, reportedBytes: 1),
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
            .upload(
              filePath: images.first.path,
              fileName: 'photo-0.png',
              fileSize: 1,
            ),
        throwsA(isA<HermesChatInputException>()),
      );

      expect(encodeCalls, 0);
    });

    test('aggregate image size uses local file stats', () async {
      final directory = await Directory.systemTemp.createTemp(
        'conduit_hermes_media_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final first = File('${directory.path}/first.png');
      final second = File('${directory.path}/second.png');
      await _truncate(first, 3 * 1024 * 1024 + 1);
      await _truncate(second, 3 * 1024 * 1024);
      var encodeCalls = 0;
      final container = await _hermesContainer(
        capabilities: const HermesCapabilities(inputImages: true),
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
        throwsA(isA<HermesChatInputException>()),
      );

      expect(encodeCalls, 0);
    });

    test('local document gets an opaque token and never uploads', () async {
      final directory = await Directory.systemTemp.createTemp(
        'conduit_hermes_media_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final document = File('${directory.path}/private-notes.txt');
      await document.writeAsString('private on-device notes');
      var uploadCalls = 0;
      final queue = await _recordingUploadQueue(onUpload: () => uploadCalls++);
      addTearDown(queue.dispose);
      final container = await _hermesContainer(
        capabilities: const HermesCapabilities(),
        attachments: [_pendingDocument(document, reportedBytes: 1)],
        encoder: (file) async => throw StateError('not an image'),
        uploadQueue: queue,
      );
      addTearDown(container.dispose);

      await container
          .read(mediaUploadControllerProvider)
          .upload(
            filePath: document.path,
            fileName: 'private-notes.txt',
            fileSize: 1,
          );

      final stored = container.read(attachedFilesProvider).single;
      expect(stored.status, FileUploadStatus.completed);
      expect(stored.fileId, matches(RegExp(r'^hermes-local:[a-f0-9]{64}$')));
      expect(stored.fileId, isNot(contains(document.path)));
      expect(stored.fileId, isNot(contains('private-notes')));
      expect(stored.fileSize, await document.length());
      expect(stored.base64DataUrl, isNull);
      expect(stored.isImage, isFalse);
      expect(uploadCalls, 0);
      expect(queue.queue, isEmpty);
    });

    test('oversized local document is rejected before preparation', () async {
      final directory = await Directory.systemTemp.createTemp(
        'conduit_hermes_media_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final document = File('${directory.path}/oversized.txt');
      await _truncate(document, kHermesMaxLocalDocumentBytes + 1);
      var uploadCalls = 0;
      final queue = await _recordingUploadQueue(onUpload: () => uploadCalls++);
      addTearDown(queue.dispose);
      final container = await _hermesContainer(
        capabilities: const HermesCapabilities(),
        attachments: [_pendingDocument(document, reportedBytes: 1)],
        encoder: (file) async => throw StateError('not an image'),
        uploadQueue: queue,
      );
      addTearDown(container.dispose);

      await expectLater(
        container
            .read(mediaUploadControllerProvider)
            .upload(
              filePath: document.path,
              fileName: 'oversized.txt',
              fileSize: 1,
            ),
        throwsA(isA<HermesChatInputException>()),
      );

      expect(uploadCalls, 0);
      expect(queue.queue, isEmpty);
    });

    test('queued preparation refuses a model-switch fallthrough', () async {
      final directory = await Directory.systemTemp.createTemp(
        'conduit_hermes_media_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final first = File('${directory.path}/first.png');
      final second = File('${directory.path}/second.png');
      await first.writeAsBytes([1]);
      await second.writeAsBytes([2]);
      final firstEncodingStarted = Completer<void>();
      final allowFirstEncoding = Completer<void>();
      var encodeCalls = 0;
      var uploadCalls = 0;
      final queue = await _recordingUploadQueue(onUpload: () => uploadCalls++);
      addTearDown(queue.dispose);
      final container = await _hermesContainer(
        capabilities: const HermesCapabilities(inputImages: true),
        attachments: [
          _pendingImage(first, reportedBytes: 1),
          _pendingImage(second, reportedBytes: 1),
        ],
        encoder: (file) async {
          encodeCalls++;
          if (encodeCalls == 1) {
            firstEncodingStarted.complete();
            await allowFirstEncoding.future;
          }
          return 'data:image/png;base64,AQ==';
        },
        uploadQueue: queue,
      );
      addTearDown(container.dispose);

      final firstUpload = container
          .read(mediaUploadControllerProvider)
          .upload(filePath: first.path, fileName: 'first.png', fileSize: 1);
      await firstEncodingStarted.future;
      final secondUpload = container
          .read(mediaUploadControllerProvider)
          .upload(filePath: second.path, fileName: 'second.png', fileSize: 1);
      final secondFailure = expectLater(
        secondUpload,
        throwsA(isA<HermesChatInputException>()),
      );
      await Future<void>.delayed(Duration.zero);

      container
          .read(selectedModelProvider.notifier)
          .set(const Model(id: 'server-model', name: 'Server model'));
      allowFirstEncoding.complete();
      await firstUpload;
      await secondFailure;

      expect(encodeCalls, 1);
      expect(uploadCalls, 0);
      expect(queue.queue, isEmpty);
      final byPath = {
        for (final attachment in container.read(attachedFilesProvider))
          attachment.file.path: attachment,
      };
      expect(byPath[first.path]?.status, FileUploadStatus.completed);
      expect(byPath[first.path]?.fileId, startsWith('data:image/'));
      expect(byPath[second.path]?.status, FileUploadStatus.failed);
      expect(byPath[second.path]?.fileId, isNull);
    });
  });
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

Future<ProviderContainer> _hermesContainer({
  required HermesCapabilities capabilities,
  required List<FileUploadState> attachments,
  required DirectImageDataUrlEncoder encoder,
  AttachmentUploadQueue? uploadQueue,
}) async {
  final container = ProviderContainer(
    overrides: [
      apiServiceProvider.overrideWithValue(null),
      selectedModelProvider.overrideWith(
        () => _SeededSelectedModel(hermesSyntheticModel()),
      ),
      hermesCapabilitiesProvider.overrideWith((ref) async => capabilities),
      directImageDataUrlEncoderProvider.overrideWithValue(encoder),
      if (uploadQueue != null)
        attachmentUploadQueueProvider.overrideWithValue(uploadQueue),
      attachedFilesProvider.overrideWith(
        () => _SeededAttachedFilesNotifier(attachments),
      ),
    ],
  );
  await container.read(hermesCapabilitiesProvider.future);
  return container;
}

Future<AttachmentUploadQueue> _recordingUploadQueue({
  void Function()? onUpload,
}) async {
  final queue = AttachmentUploadQueue();
  await queue.initialize(
    onUpload: (filePath, fileName, {cancelToken}) async {
      onUpload?.call();
      return 'unexpected-server-file';
    },
    database: () => null,
  );
  return queue;
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

FileUploadState _pendingDocument(File file, {required int reportedBytes}) =>
    FileUploadState(
      file: file,
      fileName: file.uri.pathSegments.last,
      fileSize: reportedBytes,
      progress: 0,
      status: FileUploadStatus.pending,
      isImage: false,
    );

FileUploadState _failedImage(File file) => FileUploadState(
  file: file,
  fileName: file.uri.pathSegments.last,
  fileSize: kDirectMaxDecodedImageBytes,
  progress: 0,
  status: FileUploadStatus.failed,
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

final class _SeededSelectedModel extends SelectedModel {
  _SeededSelectedModel(this.model);

  final Model? model;

  @override
  Model? build() => model;
}
