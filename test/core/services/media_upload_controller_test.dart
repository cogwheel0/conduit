import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/core/auth/api_auth_interceptor.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/models/file_info.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/attachment_upload_queue.dart';
import 'package:conduit/core/services/media_upload_controller.dart';
import 'package:conduit/core/services/share_staging_cleanup.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/chat/services/file_attachment_service.dart';
import 'package:conduit/features/direct_connections/direct_connections.dart';
import 'package:conduit/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/services/hermes_local_document_service.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

AppDatabase? _testUploadDatabase;

AppDatabase _resolveTestUploadDatabase() =>
    _testUploadDatabase ??= AppDatabase(NativeDatabase.memory());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _testUploadDatabase = null;
    addTearDown(() async {
      await _testUploadDatabase?.close();
    });
  });

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
    'enqueue acceptance does not wait for terminal network upload',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'conduit_enqueued_media_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final document = File('${directory.path}/notes.txt');
      await document.writeAsString('queued');
      final attachment = LocalAttachment(
        file: document,
        displayName: 'notes.txt',
      );
      final uploadStarted = Completer<void>();
      final finishUpload = Completer<String>();
      final queue = AttachmentUploadQueue();
      await queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) {
          if (!uploadStarted.isCompleted) uploadStarted.complete();
          return finishUpload.future;
        },
        database: _resolveTestUploadDatabase,
      );
      addTearDown(queue.dispose);
      addTearDown(() {
        if (!finishUpload.isCompleted) finishUpload.complete('teardown-file');
      });
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          selectedModelProvider.overrideWith(() => _SeededSelectedModel(null)),
          attachmentUploadQueueProvider.overrideWithValue(queue),
          attachedFilesProvider.overrideWith(
            () => _SeededAttachedFilesNotifier([]),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(mediaUploadControllerProvider)
          .enqueueUpload(
            filePath: document.path,
            fileName: 'notes.txt',
            fileSize: 6,
            publishAttachment: attachment,
          )
          .timeout(const Duration(seconds: 1));
      await uploadStarted.future.timeout(const Duration(seconds: 1));

      expect(finishUpload.isCompleted, isFalse);
      expect(container.read(attachedFilesProvider), hasLength(1));
      expect(
        queue.queue.single.status,
        anyOf(QueuedAttachmentStatus.pending, QueuedAttachmentStatus.uploading),
      );

      final terminalProcessed = queue.queueStream.firstWhere(
        (items) => items.isEmpty,
      );
      finishUpload.complete('server-file');
      await terminalProcessed.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'duplicate same-path enqueue shares one queue row and terminal cleanup',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'conduit_duplicate_media_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final document = File('${directory.path}/notes.txt');
      await document.writeAsString('queued');
      final attachment = LocalAttachment(
        file: document,
        displayName: 'notes.txt',
      );
      final uploadStarted = Completer<void>();
      final finishUpload = Completer<String>();
      var uploadCalls = 0;
      final queue = AttachmentUploadQueue();
      await queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) {
          uploadCalls++;
          if (!uploadStarted.isCompleted) uploadStarted.complete();
          return finishUpload.future;
        },
        database: _resolveTestUploadDatabase,
      );
      addTearDown(queue.dispose);
      addTearDown(() {
        if (!finishUpload.isCompleted) finishUpload.complete('teardown-file');
      });
      final cleanedPaths = <String>[];
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          selectedModelProvider.overrideWith(() => _SeededSelectedModel(null)),
          attachmentUploadQueueProvider.overrideWithValue(queue),
          terminalAttachmentCleanupProvider.overrideWithValue((
            filePath, {
            required beforeDeleteAdmission,
            required canDelete,
          }) async {
            await beforeDeleteAdmission();
            if (!canDelete()) return true;
            cleanedPaths.add(filePath);
            return true;
          }),
          attachedFilesProvider.overrideWith(
            () => _SeededAttachedFilesNotifier([]),
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(mediaUploadControllerProvider);
      final firstAcceptance = controller.enqueueUpload(
        filePath: document.path,
        fileName: 'notes.txt',
        fileSize: 6,
        publishAttachment: attachment,
      );
      final duplicateAcceptance = controller.enqueueUpload(
        filePath: document.path,
        fileName: 'notes.txt',
        fileSize: 6,
        publishAttachment: attachment,
      );

      await Future.wait([
        firstAcceptance.timeout(const Duration(seconds: 1)),
        duplicateAcceptance.timeout(const Duration(seconds: 1)),
      ]);
      await uploadStarted.future.timeout(const Duration(seconds: 1));

      expect(uploadCalls, 1);
      expect(queue.queue, hasLength(1));
      expect(container.read(attachedFilesProvider), hasLength(1));

      final terminalProcessed = queue.queueStream.firstWhere(
        (items) => items.isEmpty,
      );
      finishUpload.complete('server-file');
      await terminalProcessed.timeout(const Duration(seconds: 1));

      expect(uploadCalls, 1);
      expect(cleanedPaths, [document.path]);
    },
  );

  test('retry after terminal failure starts a new upload generation', () async {
    final directory = await Directory.systemTemp.createTemp(
      'conduit_failed_retry_generation_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final document = File('${directory.path}/notes.txt');
    await document.writeAsString('retry me');
    var uploadCalls = 0;
    final queue = AttachmentUploadQueue(maxRetries: 1);
    await queue.initialize(
      onUpload: (filePath, fileName, {cancelToken}) async {
        uploadCalls++;
        if (uploadCalls == 1) throw StateError('first terminal failure');
        return 'server-file';
      },
      database: _resolveTestUploadDatabase,
    );
    addTearDown(queue.dispose);
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(null),
        selectedModelProvider.overrideWith(() => _SeededSelectedModel(null)),
        attachmentUploadQueueProvider.overrideWithValue(queue),
        attachedFilesProvider.overrideWith(
          () => _SeededAttachedFilesNotifier([]),
        ),
      ],
    );
    addTearDown(container.dispose);
    final failed = queue.queueStream.firstWhere(
      (items) =>
          items.any((item) => item.status == QueuedAttachmentStatus.failed),
    );

    await container
        .read(mediaUploadControllerProvider)
        .enqueueUpload(
          filePath: document.path,
          fileName: 'notes.txt',
          fileSize: 8,
          publishAttachment: LocalAttachment(
            file: document,
            displayName: 'notes.txt',
          ),
        );
    await failed.timeout(const Duration(seconds: 1));
    final completed = queue.queueStream.firstWhere(
      (items) =>
          items.any((item) => item.status == QueuedAttachmentStatus.completed),
    );

    await container
        .read(mediaUploadControllerProvider)
        .enqueueUpload(
          filePath: document.path,
          fileName: 'notes.txt',
          fileSize: 8,
        );
    await completed.timeout(const Duration(seconds: 1));
    for (
      var attempt = 0;
      attempt < 100 &&
          container.read(attachedFilesProvider).single.status !=
              FileUploadStatus.completed;
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(uploadCalls, 2);
    expect(
      container.read(attachedFilesProvider).single.status,
      FileUploadStatus.completed,
    );
  });

  test(
    'completed and cancelled distinct paths prune generation state',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'conduit_generation_pruning_',
      );
      addTearDown(() => directory.delete(recursive: true));
      var uploadCalls = 0;
      final queue = AttachmentUploadQueue();
      await queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async {
          uploadCalls++;
          return 'server-$uploadCalls';
        },
        database: _resolveTestUploadDatabase,
      );
      addTearDown(queue.dispose);
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          selectedModelProvider.overrideWith(() => _SeededSelectedModel(null)),
          attachmentUploadQueueProvider.overrideWithValue(queue),
          attachedFilesProvider.overrideWith(
            () => _SeededAttachedFilesNotifier([]),
          ),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(mediaUploadControllerProvider);
      final notifier =
          container.read(attachedFilesProvider.notifier)
              as _SeededAttachedFilesNotifier;

      const successfulPaths = 24;
      for (var index = 0; index < successfulPaths; index++) {
        final document = File('${directory.path}/success-$index.txt');
        await document.writeAsString('success-$index');
        notifier.replaceAttachments([
          _pendingDocument(document, reportedBytes: await document.length()),
        ]);
        await controller.upload(
          filePath: document.path,
          fileName: document.uri.pathSegments.last,
          fileSize: await document.length(),
        );
        expect(controller.debugTrackedPathGenerationCount, 0);
      }

      const cancelledPaths = 24;
      for (var index = 0; index < cancelledPaths; index++) {
        final document = File('${directory.path}/cancel-$index.txt');
        await document.writeAsString('cancel-$index');
        notifier.replaceAttachments([
          _pendingDocument(document, reportedBytes: await document.length()),
        ]);
        final upload = controller.upload(
          filePath: document.path,
          fileName: document.uri.pathSegments.last,
          fileSize: await document.length(),
        );
        final cancelled = expectLater(
          upload,
          throwsA(isA<MediaUploadCancelledException>()),
        );
        await controller.cancelUploadsForFile(document.path);
        await cancelled;
        expect(controller.debugTrackedPathGenerationCount, 0);
      }

      expect(uploadCalls, successfulPaths);
      expect(controller.debugTrackedPathGenerationCount, 0);
    },
  );

  test(
    'cancel finalization failure still settles the upload generation',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await database.customStatement('''
        CREATE TRIGGER reject_cancelled_attachment_delete
        BEFORE DELETE ON attachment_queue
        BEGIN
          SELECT RAISE(ABORT, 'injected cancelled delete failure');
        END;
      ''');
      final directory = await Directory.systemTemp.createTemp(
        'conduit_cancel_finalization_rollback_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final document = File('${directory.path}/notes.txt');
      await document.writeAsString('queued');
      final uploadStarted = Completer<void>();
      final releaseUpload = Completer<String>();
      addTearDown(() {
        if (!releaseUpload.isCompleted) releaseUpload.complete('teardown');
      });
      final queue = AttachmentUploadQueue();
      await queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) {
          uploadStarted.complete();
          return releaseUpload.future;
        },
        database: () => database,
      );
      addTearDown(queue.dispose);
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          selectedModelProvider.overrideWith(() => _SeededSelectedModel(null)),
          attachmentUploadQueueProvider.overrideWithValue(queue),
          attachedFilesProvider.overrideWith(
            () => _SeededAttachedFilesNotifier([
              _pendingDocument(document, reportedBytes: 6),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(mediaUploadControllerProvider);
      final upload = controller.upload(
        filePath: document.path,
        fileName: 'notes.txt',
        fileSize: 6,
      );
      await uploadStarted.future.timeout(const Duration(seconds: 1));

      await expectLater(
        controller.cancelUploadsForFile(document.path),
        throwsA(anything),
      );
      await upload
          .then<void>((_) {}, onError: (Object _, StackTrace _) {})
          .timeout(const Duration(seconds: 1));

      expect(controller.debugTrackedPathGenerationCount, 0);
      final durableRows = await database.attachmentQueueDao.getAll();
      expect(durableRows, hasLength(1));
      expect(durableRows.single.status, QueuedAttachmentStatus.cancelled.name);
    },
  );

  test(
    'failed held-row delete cannot replay a same-path replacement on restore',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await database.customStatement('''
        CREATE TRIGGER reject_held_attachment_delete
        BEFORE DELETE ON attachment_queue
        BEGIN
          SELECT RAISE(ABORT, 'injected held-row delete failure');
        END;
      ''');
      final stagingDirectory = Directory(
        '${Directory.systemTemp.path}/conduit-app-intents',
      );
      await stagingDirectory.create();
      final document = File(
        '${stagingDirectory.path}/'
        '123e4567-e89b-12d3-a456-426614174106-intent.txt',
      );
      await document.writeAsBytes([1]);
      addTearDown(() async {
        if (await document.exists()) await document.delete();
      });

      late MediaUploadController controller;
      Future<void>? cancellation;
      final cancellationRequested = Completer<void>();
      final sourceCleanupEntered = Completer<void>();
      final releaseSourceCleanup = Completer<void>();
      addTearDown(() {
        if (!releaseSourceCleanup.isCompleted) releaseSourceCleanup.complete();
      });
      var cancellationStarted = false;
      var initialUploadCalls = 0;
      final queue = AttachmentUploadQueue(idGenerator: () => 'retired-row');
      await queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async {
          initialUploadCalls++;
          return 'unexpected';
        },
        database: () => database,
        onQueueChanged: (items) {
          if (cancellationStarted ||
              !items.any((item) => item.id == 'retired-row')) {
            return;
          }
          cancellationStarted = true;
          cancellation = controller.cancelUploadsForFile(document.path);
          cancellationRequested.complete();
        },
      );
      addTearDown(queue.dispose);
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          selectedModelProvider.overrideWith(() => _SeededSelectedModel(null)),
          attachmentUploadQueueProvider.overrideWithValue(queue),
          mediaUploadCleanupBarrierProvider.overrideWithValue((filePath) async {
            if (filePath != document.path) return;
            if (!sourceCleanupEntered.isCompleted) {
              sourceCleanupEntered.complete();
            }
            await releaseSourceCleanup.future;
          }),
          attachedFilesProvider.overrideWith(
            () => _SeededAttachedFilesNotifier([
              _pendingDocument(document, reportedBytes: 1),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);
      controller = container.read(mediaUploadControllerProvider);

      final retiredUpload = controller.upload(
        filePath: document.path,
        fileName: 'intent.txt',
        fileSize: 1,
      );
      final retiredUploadCancelled = expectLater(
        retiredUpload,
        throwsA(isA<MediaUploadCancelledException>()),
      );
      await cancellationRequested.future.timeout(const Duration(seconds: 1));
      await sourceCleanupEntered.future.timeout(const Duration(seconds: 1));
      final rowAtSourceCleanup =
          (await database.attachmentQueueDao.getAll()).single;
      expect(rowAtSourceCleanup.status, QueuedAttachmentStatus.cancelled.name);
      expect(await document.readAsBytes(), [1]);
      releaseSourceCleanup.complete();
      await cancellation!.timeout(const Duration(seconds: 1));
      await retiredUploadCancelled;

      expect(initialUploadCalls, 0);
      final cancelledRows = await database.attachmentQueueDao.getAll();
      expect(cancelledRows, hasLength(1));
      expect(
        cancelledRows.single.status,
        QueuedAttachmentStatus.cancelled.name,
      );

      // A replacement generation reuses the native path while the failed
      // DELETE leaves the retired durable row for restart recovery.
      await document.writeAsBytes([2]);
      await database.attachmentQueueDao.upsert(
        AttachmentUploadQueue.companionFromLegacyJson({
          'id': 'replacement-row',
          'filePath': document.path,
          'fileName': 'intent.txt',
          'fileSize': 1,
          'enqueuedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
          'retryCount': 0,
          'nextRetryAt': DateTime.utc(2100, 1, 1).toIso8601String(),
          'status': QueuedAttachmentStatus.pending.name,
        }),
      );
      await database.customStatement(
        'DROP TRIGGER reject_held_attachment_delete',
      );
      queue.dispose();

      var restoredUploadCalls = 0;
      final restored = AttachmentUploadQueue();
      addTearDown(restored.dispose);
      await restored.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async {
          restoredUploadCalls++;
          return 'unexpected';
        },
        database: () => database,
      );
      await restored.processQueue();

      expect(restoredUploadCalls, 0);
      expect(await document.readAsBytes(), [2]);
      expect(
        restored.queue.map((item) => item.id),
        containsAll(<String>['replacement-row', 'retired-row']),
      );
      final restoredRows = await database.attachmentQueueDao.getAll();
      expect(
        restoredRows.map((row) => row.id),
        containsAll(<String>['replacement-row', 'retired-row']),
      );

      await restored.acknowledgeTerminal('retired-row');

      expect(restored.queue.map((item) => item.id), ['replacement-row']);
      expect(
        (await database.attachmentQueueDao.getAll()).map((row) => row.id),
        ['replacement-row'],
      );
      expect(await document.readAsBytes(), [2]);
    },
  );

  test(
    'uncertain held-row cancellation retains its durable conversion temp',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await database.customStatement('''
        CREATE TRIGGER reject_uncertain_attachment_delete
        BEFORE DELETE ON attachment_queue
        BEGIN
          SELECT RAISE(ABORT, 'injected uncertain delete failure');
        END;
      ''');
      await database.customStatement('''
        CREATE TRIGGER reject_uncertain_attachment_cancel
        BEFORE UPDATE OF status ON attachment_queue
        WHEN NEW.status = 'cancelled'
        BEGIN
          SELECT RAISE(ABORT, 'injected uncertain cancel failure');
        END;
      ''');
      final directory = await Directory.systemTemp.createTemp(
        'conduit_uncertain_conversion_',
      );
      final conversionDirectory = await Directory.systemTemp.createTemp(
        'conduit_img_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
        if (await conversionDirectory.exists()) {
          await conversionDirectory.delete(recursive: true);
        }
      });
      final original = File('${directory.path}/photo.bmp');
      final converted = File('${conversionDirectory.path}/converted.jpg');
      await original.writeAsBytes([1]);
      await converted.writeAsBytes([9, 8, 7]);

      late MediaUploadController controller;
      Future<void>? cancellation;
      final cancellationRequested = Completer<void>();
      var cancellationStarted = false;
      final queue = AttachmentUploadQueue(idGenerator: () => 'uncertain-row');
      await queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async => 'unexpected',
        database: () => database,
        onQueueChanged: (items) {
          if (cancellationStarted ||
              !items.any((item) => item.id == 'uncertain-row')) {
            return;
          }
          cancellationStarted = true;
          cancellation = controller.cancelUploadsForFile(original.path);
          cancellationRequested.complete();
        },
      );
      addTearDown(queue.dispose);
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          selectedModelProvider.overrideWith(() => _SeededSelectedModel(null)),
          attachmentUploadQueueProvider.overrideWithValue(queue),
          imageUploadConverterProvider.overrideWithValue(
            (_) async => converted.path,
          ),
          attachedFilesProvider.overrideWith(
            () => _SeededAttachedFilesNotifier([
              _pendingImage(original, reportedBytes: 1),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);
      controller = container.read(mediaUploadControllerProvider);

      final upload = controller.upload(
        filePath: original.path,
        fileName: 'photo.bmp',
        fileSize: 1,
        mimeType: 'image/bmp',
      );
      final cancelledUpload = expectLater(
        upload,
        throwsA(isA<MediaUploadCancelledException>()),
      );
      await cancellationRequested.future.timeout(const Duration(seconds: 1));
      await cancellation!.timeout(const Duration(seconds: 1));
      await cancelledUpload;

      expect(await converted.readAsBytes(), [9, 8, 7]);
      expect(await conversionDirectory.exists(), isTrue);
      expect(controller.debugTrackedPathGenerationCount, 0);
      final durableRows = await database.attachmentQueueDao.getAll();
      expect(durableRows, hasLength(1));
      expect(durableRows.single.status, QueuedAttachmentStatus.pending.name);
      expect(durableRows.single.filePath, converted.path);
    },
  );

  test(
    'durable queue ownership survives synchronous publication failure',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final directory = await Directory.systemTemp.createTemp(
        'conduit_owned_queue_media_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final document = File('${directory.path}/notes.txt');
      await document.writeAsString('queued');
      final uploadStarted = Completer<void>();
      final finishUpload = Completer<String>();
      final queue = AttachmentUploadQueue();
      await queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) {
          if (!uploadStarted.isCompleted) uploadStarted.complete();
          return finishUpload.future;
        },
        database: () => database,
      );
      addTearDown(queue.dispose);
      addTearDown(() {
        if (!finishUpload.isCompleted) finishUpload.complete('teardown-file');
      });
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          selectedModelProvider.overrideWith(() => _SeededSelectedModel(null)),
          attachmentUploadQueueProvider.overrideWithValue(queue),
          attachedFilesProvider.overrideWith(
            _ThrowingAttachedFilesNotifier.new,
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(mediaUploadControllerProvider)
          .enqueueUpload(
            filePath: document.path,
            fileName: 'notes.txt',
            fileSize: 6,
            publishAttachment: LocalAttachment(
              file: document,
              displayName: 'notes.txt',
            ),
          )
          .timeout(const Duration(seconds: 1));
      await uploadStarted.future.timeout(const Duration(seconds: 1));

      expect(queue.queue, hasLength(1));
      expect(container.read(attachedFilesProvider), isEmpty);
      final durableRows = await database.attachmentQueueDao.getAll();
      expect(durableRows, hasLength(1));
      expect(durableRows.single.filePath, document.path);

      final terminalProcessed = queue.queueStream.firstWhere(
        (items) => items.isEmpty,
      );
      finishUpload.complete('server-file');
      await terminalProcessed.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'owned publication retains its failed state for explicit recovery',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'conduit_owned_media_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final image = File('${directory.path}/oversized.png');
      await _truncate(image, kDirectMaxDecodedImageBytes + 1);
      final container = _directContainer(
        encoder: (_) async => 'data:image/png;base64,AQ==',
      );
      addTearDown(container.dispose);

      await expectLater(
        container
            .read(mediaUploadControllerProvider)
            .enqueueUpload(
              filePath: image.path,
              fileName: 'oversized.png',
              fileSize: 1,
              publishAttachment: LocalAttachment(
                file: image,
                displayName: 'oversized.png',
              ),
            ),
        throwsA(isA<DirectChatInputException>()),
      );

      final failed = container.read(attachedFilesProvider).single;
      expect(failed.file.path, image.path);
      expect(failed.status, FileUploadStatus.failed);
    },
  );

  test(
    'native share refuses memory-only direct ownership before publication',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'conduit_native_direct_ownership_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final image = File('${directory.path}/native.png');
      await image.writeAsBytes([1, 2, 3]);
      final container = _directContainer(
        encoder: (_) async => 'data:image/png;base64,AQID',
      );
      addTearDown(container.dispose);

      await expectLater(
        container
            .read(mediaUploadControllerProvider)
            .enqueueNativeShareUpload(
              filePath: image.path,
              fileName: 'native.png',
              fileSize: 3,
              identity: const NativeShareUploadIdentity(
                payloadId: 'native-direct',
                itemOrdinal: 0,
              ),
              publishAttachment: LocalAttachment(
                file: image,
                displayName: 'native.png',
              ),
            ),
        throwsA(isA<NativeShareDurableOwnershipUnavailable>()),
      );

      expect(container.read(attachedFilesProvider), isEmpty);
    },
  );

  test(
    'native share receipt key survives re-delivered re-encoded bytes',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final stagingDirectory = Directory(
        '${Directory.systemTemp.path}/conduit-app-intents',
      );
      await stagingDirectory.create();
      final staged = File(
        '${stagingDirectory.path}/'
        '123e4567-e89b-12d3-a456-426614174130-shared.txt',
      );
      await staged.writeAsBytes([1, 2, 3]);
      addTearDown(() async {
        if (await staged.exists()) await staged.delete();
      });
      var uploadCalls = 0;
      final queue = AttachmentUploadQueue();
      await queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async {
          uploadCalls++;
          return 'server-file';
        },
        database: () => database,
      );
      addTearDown(queue.dispose);

      ProviderContainer buildContainer() => ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          selectedModelProvider.overrideWith(() => _SeededSelectedModel(null)),
          attachmentUploadQueueProvider.overrideWithValue(queue),
          attachedFilesProvider.overrideWith(
            () => _SeededAttachedFilesNotifier([]),
          ),
        ],
      );
      const identity = NativeShareUploadIdentity(
        payloadId: 'native-rejoin',
        itemOrdinal: 0,
      );

      final firstContainer = buildContainer();
      addTearDown(firstContainer.dispose);
      final firstAcceptance = await firstContainer
          .read(mediaUploadControllerProvider)
          .enqueueNativeShareUpload(
            filePath: staged.path,
            fileName: 'shared.txt',
            fileSize: 3,
            identity: identity,
            publishAttachment: LocalAttachment(
              file: staged,
              displayName: 'shared.txt',
            ),
          );
      // Terminal cleanup releases the staged bytes; the held receipt row stays
      // because the native payload has not been acknowledged yet.
      for (var attempt = 0; attempt < 100 && await staged.exists(); attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await staged.exists(), isFalse);
      expect(uploadCalls, 1);
      expect(queue.queue.single.receiptHeld, isTrue);

      // Simulated restart: the unacknowledged payload is re-delivered and
      // in-place conversion re-encodes it to different bytes at the same
      // staged pathname. The durable key must not depend on those bytes.
      await staged.writeAsBytes([9, 8, 7, 6]);
      final restartContainer = buildContainer();
      addTearDown(restartContainer.dispose);
      final rejoinAcceptance = await restartContainer
          .read(mediaUploadControllerProvider)
          .enqueueNativeShareUpload(
            filePath: staged.path,
            fileName: 'shared.txt',
            fileSize: 4,
            identity: identity,
            publishAttachment: LocalAttachment(
              file: staged,
              displayName: 'shared.txt',
            ),
          );

      expect(rejoinAcceptance.receiptKey, firstAcceptance.receiptKey);
      expect(uploadCalls, 1);
      expect(queue.queue, hasLength(1));
      expect(queue.queue.single.fileId, 'server-file');

      await restartContainer
          .read(mediaUploadControllerProvider)
          .releaseNativeShareReceipts([rejoinAcceptance.receiptKey]);
      expect(queue.queue, isEmpty);
      expect(await database.attachmentQueueDao.getAll(), isEmpty);
    },
  );

  test(
    'orphaned terminal receipts release only when native storage is drained',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final queue = AttachmentUploadQueue();
      await queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async => 'server-file',
        database: () => database,
      );
      addTearDown(queue.dispose);
      final completed = queue.queueStream.firstWhere(
        (items) => items.any(
          (item) => item.status == QueuedAttachmentStatus.completed,
        ),
      );
      await queue.enqueueOrJoin(
        filePath: '/tmp/orphaned-receipt',
        fileName: 'orphaned-receipt',
        fileSize: 1,
        durableKey: 'native-share-v2:orphan:0',
        receiptHeld: true,
      );
      await completed.timeout(const Duration(seconds: 1));
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          attachmentUploadQueueProvider.overrideWithValue(queue),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(mediaUploadControllerProvider);

      // A payload that is still pending natively must keep its receipts: they
      // are the dedupe fence for its re-delivery.
      final kept = await controller.releaseOrphanedNativeShareReceipts(
        confirmNoPendingNativePayloads: () async => false,
      );
      expect(kept, 0);
      expect(queue.queue.single.receiptHeld, isTrue);

      final released = await controller.releaseOrphanedNativeShareReceipts(
        confirmNoPendingNativePayloads: () async => true,
      );
      expect(released, 1);
      expect(queue.queue, isEmpty);
      expect(await database.attachmentQueueDao.getAll(), isEmpty);
    },
  );

  test('active receipt-held rows are never garbage collected', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final queue = AttachmentUploadQueue();
    await queue.initialize(
      onUpload: (filePath, fileName, {cancelToken}) async => 'server-file',
      database: () => database,
    );
    addTearDown(queue.dispose);
    await queue.enqueueOrJoin(
      filePath: '/tmp/live-receipt',
      fileName: 'live-receipt',
      fileSize: 1,
      holdForOwner: true,
      durableKey: 'native-share-v2:live:0',
      receiptHeld: true,
    );
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(null),
        attachmentUploadQueueProvider.overrideWithValue(queue),
      ],
    );
    addTearDown(container.dispose);

    final released = await container
        .read(mediaUploadControllerProvider)
        .releaseOrphanedNativeShareReceipts(
          confirmNoPendingNativePayloads: () async => true,
        );

    expect(released, 0);
    expect(queue.queue.single.receiptHeld, isTrue);
    expect(queue.queue.single.status, QueuedAttachmentStatus.pending);
  });

  test(
    'pre-enqueue failure preserves native paste staging for explicit retry',
    () async {
      final stagingDirectory = Directory(
        '${Directory.systemTemp.path}/conduit-native-paste',
      );
      await stagingDirectory.create();
      final image = File(
        '${stagingDirectory.path}/'
        '123e4567-e89b-12d3-a456-426614174097-paste.png',
      );
      await image.writeAsBytes([1, 2, 3]);
      addTearDown(() async {
        if (await image.exists()) await image.delete();
      });
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          selectedModelProvider.overrideWith(() => _SeededSelectedModel(null)),
          attachmentUploadQueueProvider.overrideWithValue(null),
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
            .enqueueUpload(
              filePath: image.path,
              fileName: 'paste.png',
              fileSize: 3,
            ),
        throwsA(isA<Exception>()),
      );

      expect(await image.exists(), isTrue);
      final failed = container.read(attachedFilesProvider).single;
      expect(failed.status, FileUploadStatus.failed);
      expect(failed.file.path, image.path);
    },
  );

  test(
    'removal while queue readiness is pending never enqueues or uploads',
    () async {
      final stagingDirectory = Directory(
        '${Directory.systemTemp.path}/conduit-native-paste',
      );
      await stagingDirectory.create();
      final image = File(
        '${stagingDirectory.path}/'
        '123e4567-e89b-12d3-a456-426614174103-paste.png',
      );
      await image.writeAsBytes([1, 2, 3]);
      addTearDown(() async {
        if (await image.exists()) await image.delete();
      });
      var uploadCalls = 0;
      final allowInitialLoad = Completer<void>();
      final queue = AttachmentUploadQueue(
        initialLoadBarrier: () => allowInitialLoad.future,
      );
      addTearDown(queue.dispose);
      final initialized = queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async {
          uploadCalls++;
          return 'must-not-upload';
        },
        database: _resolveTestUploadDatabase,
      );
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          selectedModelProvider.overrideWith(() => _SeededSelectedModel(null)),
          attachmentUploadQueueProvider.overrideWithValue(queue),
          attachedFilesProvider.overrideWith(
            () => _SeededAttachedFilesNotifier([
              _pendingImage(image, reportedBytes: 3),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);

      final upload = container
          .read(mediaUploadControllerProvider)
          .upload(filePath: image.path, fileName: 'paste.png', fileSize: 3);
      final uploadExpectation = expectLater(
        upload,
        throwsA(isA<MediaUploadCancelledException>()),
      );
      await Future<void>.delayed(Duration.zero);
      final removal = container
          .read(mediaUploadControllerProvider)
          .removeAttachment(image.path);
      // Composer removal remains synchronous even though queue retirement and
      // staging cleanup are asynchronous.
      expect(container.read(attachedFilesProvider), isEmpty);
      await removal;

      allowInitialLoad.complete();
      await initialized;

      await uploadExpectation;
      expect(uploadCalls, 0);
      expect(queue.queue, isEmpty);
      expect(
        await _resolveTestUploadDatabase().attachmentQueueDao.getAll(),
        isEmpty,
      );
      expect(container.read(attachedFilesProvider), isEmpty);
      expect(await image.exists(), isFalse);
    },
  );

  test('attached-files notifier removal is state-only', () async {
    final stagingDirectory = Directory(
      '${Directory.systemTemp.path}/conduit-native-paste',
    );
    await stagingDirectory.create();
    final image = File(
      '${stagingDirectory.path}/'
      '123e4567-e89b-12d3-a456-426614174108-paste.png',
    );
    await image.writeAsBytes([1]);
    addTearDown(() async {
      if (await image.exists()) await image.delete();
    });
    final container = ProviderContainer(
      overrides: [
        attachedFilesProvider.overrideWith(
          () => _SeededAttachedFilesNotifier([
            _pendingImage(image, reportedBytes: 1),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(attachedFilesProvider.notifier).removeFile(image.path);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(attachedFilesProvider), isEmpty);
    expect(await image.readAsBytes(), [1]);
  });

  test(
    'composer clear tombstones a durable upload before source cleanup',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final stagingDirectory = Directory(
        '${Directory.systemTemp.path}/conduit-native-paste',
      );
      await stagingDirectory.create();
      final image = File(
        '${stagingDirectory.path}/'
        '123e4567-e89b-12d3-a456-426614174109-paste.png',
      );
      await image.writeAsBytes([1]);
      addTearDown(() async {
        if (await image.exists()) await image.delete();
      });

      final uploadStarted = Completer<void>();
      final releaseUpload = Completer<String>();
      final cleanupEntered = Completer<void>();
      final releaseCleanup = Completer<void>();
      addTearDown(() {
        if (!releaseUpload.isCompleted) releaseUpload.complete('teardown');
        if (!releaseCleanup.isCompleted) releaseCleanup.complete();
      });
      final queue = AttachmentUploadQueue();
      await queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) {
          if (!uploadStarted.isCompleted) uploadStarted.complete();
          return releaseUpload.future;
        },
        database: () => database,
      );
      addTearDown(queue.dispose);
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          selectedModelProvider.overrideWith(() => _SeededSelectedModel(null)),
          attachmentUploadQueueProvider.overrideWithValue(queue),
          mediaUploadCleanupBarrierProvider.overrideWithValue((filePath) async {
            if (!cleanupEntered.isCompleted) cleanupEntered.complete();
            await releaseCleanup.future;
          }),
          attachedFilesProvider.overrideWith(
            () => _SeededAttachedFilesNotifier([
              _pendingImage(image, reportedBytes: 1),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(mediaUploadControllerProvider);
      final upload = controller.upload(
        filePath: image.path,
        fileName: 'paste.png',
        fileSize: 1,
      );
      await uploadStarted.future.timeout(const Duration(seconds: 1));

      final clearing = controller.clearAttachments();
      expect(container.read(attachedFilesProvider), isEmpty);
      await cleanupEntered.future.timeout(const Duration(seconds: 1));

      final tombstonedRows = await database.attachmentQueueDao.getAll();
      expect(tombstonedRows, hasLength(1));
      expect(
        tombstonedRows.single.status,
        QueuedAttachmentStatus.cancelled.name,
      );
      expect(await image.readAsBytes(), [1]);

      releaseCleanup.complete();
      await clearing.timeout(const Duration(seconds: 1));
      await upload.timeout(const Duration(seconds: 1));
      expect(await database.attachmentQueueDao.getAll(), isEmpty);
      expect(await image.exists(), isFalse);

      releaseUpload.complete('late-server-file');
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'ownership snapshot preserves a replacement at the same pathname',
    () async {
      final stagingDirectory = Directory(
        '${Directory.systemTemp.path}/conduit-native-paste',
      );
      await stagingDirectory.create();
      final image = File(
        '${stagingDirectory.path}/'
        '123e4567-e89b-12d3-a456-426614174113-paste.png',
      );
      await image.writeAsBytes([1]);
      addTearDown(() async {
        if (await image.exists()) await image.delete();
      });
      final oldAttachment = _pendingImage(image, reportedBytes: 1);
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          selectedModelProvider.overrideWith(() => _SeededSelectedModel(null)),
          attachedFilesProvider.overrideWith(
            () => _SeededAttachedFilesNotifier([oldAttachment]),
          ),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(mediaUploadControllerProvider);
      final ownership = controller.captureAttachmentOwnership();

      container.read(attachedFilesProvider.notifier).addFiles([
        LocalAttachment(file: image, displayName: 'replacement.png'),
      ]);
      final replacement = container.read(attachedFilesProvider).last;
      await controller.retireAttachmentOwnership(ownership);

      final remaining = container.read(attachedFilesProvider);
      expect(remaining, hasLength(1));
      expect(identical(remaining.single, replacement), isTrue);
      expect(await image.readAsBytes(), [1]);
    },
  );

  test(
    'ownership snapshot removes both original and inflight successor states',
    () async {
      final stagingDirectory = Directory(
        '${Directory.systemTemp.path}/conduit-native-paste',
      );
      await stagingDirectory.create();
      final image = File(
        '${stagingDirectory.path}/'
        '123e4567-e89b-12d3-a456-426614174118-paste.png',
      );
      await image.writeAsBytes([1]);
      addTearDown(() async {
        if (await image.exists()) await image.delete();
      });
      final original = _pendingImage(image, reportedBytes: 1);
      final encodingStarted = Completer<void>();
      final releaseEncoding = Completer<String?>();
      final container = _directContainer(
        attachments: [original],
        encoder: (_) {
          encodingStarted.complete();
          return releaseEncoding.future;
        },
      );
      addTearDown(container.dispose);
      final controller = container.read(mediaUploadControllerProvider);

      final upload = controller.upload(
        filePath: image.path,
        fileName: 'paste.png',
        fileSize: 1,
      );
      await encodingStarted.future;
      final ownership = controller.captureAttachmentOwnership();
      releaseEncoding.complete('data:image/png;base64,AQ==');
      await upload;

      final successor = container.read(attachedFilesProvider).single;
      final notifier =
          container.read(attachedFilesProvider.notifier)
              as _SeededAttachedFilesNotifier;
      notifier.replaceAttachments([successor, original]);
      await controller.retireAttachmentOwnership(ownership);

      expect(container.read(attachedFilesProvider), isEmpty);
      expect(await image.exists(), isFalse);
    },
  );

  test(
    'cancelled direct preparation cannot mutate a re-added same path',
    () async {
      final stagingDirectory = Directory(
        '${Directory.systemTemp.path}/conduit-native-paste',
      );
      await stagingDirectory.create();
      final image = File(
        '${stagingDirectory.path}/'
        '123e4567-e89b-12d3-a456-426614174104-paste.png',
      );
      await image.writeAsBytes([1]);
      addTearDown(() async {
        if (await image.exists()) await image.delete();
      });

      const staleDataUrl = 'data:image/png;base64,AQ==';
      const replacementDataUrl = 'data:image/png;base64,Ag==';
      final firstEncodingStarted = Completer<void>();
      final releaseFirstEncoding = Completer<String?>();
      final secondEncodingStarted = Completer<void>();
      final releaseSecondEncoding = Completer<String?>();
      var encodeCalls = 0;
      final container = _directContainer(
        attachments: [_pendingImage(image, reportedBytes: 1)],
        encoder: (_) {
          encodeCalls++;
          if (encodeCalls == 1) {
            firstEncodingStarted.complete();
            return releaseFirstEncoding.future;
          }
          secondEncodingStarted.complete();
          return releaseSecondEncoding.future;
        },
      );
      addTearDown(container.dispose);
      addTearDown(() {
        if (!releaseFirstEncoding.isCompleted) {
          releaseFirstEncoding.complete(staleDataUrl);
        }
        if (!releaseSecondEncoding.isCompleted) {
          releaseSecondEncoding.complete(replacementDataUrl);
        }
      });

      final controller = container.read(mediaUploadControllerProvider);
      final oldUpload = controller.upload(
        filePath: image.path,
        fileName: 'paste.png',
        fileSize: 1,
      );
      final oldUploadCancelled = expectLater(
        oldUpload,
        throwsA(isA<MediaUploadCancelledException>()),
      );
      await firstEncodingStarted.future.timeout(const Duration(seconds: 1));

      final notifier =
          container.read(attachedFilesProvider.notifier)
              as _SeededAttachedFilesNotifier;
      notifier.replaceAttachments(const []);
      await controller.cancelUploadsForFile(image.path);
      await image.writeAsBytes([2]);
      notifier.replaceAttachments([_pendingImage(image, reportedBytes: 1)]);

      final replacementUpload = controller.upload(
        filePath: image.path,
        fileName: 'paste.png',
        fileSize: 1,
      );
      releaseFirstEncoding.complete(staleDataUrl);
      await oldUploadCancelled;
      await secondEncodingStarted.future.timeout(const Duration(seconds: 1));

      final beforeReplacementCompletes = container
          .read(attachedFilesProvider)
          .single;
      expect(beforeReplacementCompletes.status, FileUploadStatus.pending);
      expect(beforeReplacementCompletes.fileId, isNull);
      expect(await image.readAsBytes(), [2]);

      releaseSecondEncoding.complete(replacementDataUrl);
      await replacementUpload.timeout(const Duration(seconds: 1));

      final completed = container.read(attachedFilesProvider).single;
      expect(encodeCalls, 2);
      expect(completed.status, FileUploadStatus.completed);
      expect(completed.fileId, replacementDataUrl);
      expect(completed.base64DataUrl, replacementDataUrl);
      expect(await image.readAsBytes(), [2]);
    },
  );

  test(
    'cleanup rechecks generation immediately before same-path unlink',
    () async {
      final stagingDirectory = Directory(
        '${Directory.systemTemp.path}/conduit-native-paste',
      );
      await stagingDirectory.create();
      final image = File(
        '${stagingDirectory.path}/'
        '123e4567-e89b-12d3-a456-426614174105-paste.png',
      );
      await image.writeAsBytes([1]);
      addTearDown(() async {
        if (await image.exists()) await image.delete();
      });

      const staleDataUrl = 'data:image/png;base64,AQ==';
      const replacementDataUrl = 'data:image/png;base64,Ag==';
      final firstEncodingStarted = Completer<void>();
      final releaseFirstEncoding = Completer<String?>();
      final cleanupEntered = Completer<void>();
      final releaseCleanup = Completer<void>();
      final secondEncodingStarted = Completer<void>();
      var encodeCalls = 0;
      var cleanupBarrierCalls = 0;
      final container = _directContainer(
        attachments: [_pendingImage(image, reportedBytes: 1)],
        encoder: (_) {
          encodeCalls++;
          if (encodeCalls == 1) {
            firstEncodingStarted.complete();
            return releaseFirstEncoding.future;
          }
          secondEncodingStarted.complete();
          return Future<String?>.value(replacementDataUrl);
        },
        extraOverrides: [
          mediaUploadCleanupBarrierProvider.overrideWithValue((filePath) async {
            cleanupBarrierCalls++;
            if (!cleanupEntered.isCompleted) cleanupEntered.complete();
            await releaseCleanup.future;
          }),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(() {
        if (!releaseFirstEncoding.isCompleted) {
          releaseFirstEncoding.complete(staleDataUrl);
        }
        if (!releaseCleanup.isCompleted) releaseCleanup.complete();
      });

      final controller = container.read(mediaUploadControllerProvider);
      final oldUpload = controller.upload(
        filePath: image.path,
        fileName: 'paste.png',
        fileSize: 1,
      );
      final oldUploadCancelled = expectLater(
        oldUpload,
        throwsA(isA<MediaUploadCancelledException>()),
      );
      await firstEncodingStarted.future.timeout(const Duration(seconds: 1));

      final notifier =
          container.read(attachedFilesProvider.notifier)
              as _SeededAttachedFilesNotifier;
      final cancellation = controller.removeAttachment(image.path);
      expect(container.read(attachedFilesProvider), isEmpty);
      await cleanupEntered.future.timeout(const Duration(seconds: 1));

      // Re-stage different bytes and register the replacement generation while
      // the old cleanup is paused after ownership/type resolution.
      await image.writeAsBytes([2]);
      notifier.replaceAttachments([_pendingImage(image, reportedBytes: 1)]);
      final replacementUpload = controller.upload(
        filePath: image.path,
        fileName: 'paste.png',
        fileSize: 1,
      );

      releaseCleanup.complete();
      await cancellation.timeout(const Duration(seconds: 1));
      expect(await image.readAsBytes(), [2]);

      releaseFirstEncoding.complete(staleDataUrl);
      await oldUploadCancelled;
      await secondEncodingStarted.future.timeout(const Duration(seconds: 1));
      await replacementUpload.timeout(const Duration(seconds: 1));

      expect(cleanupBarrierCalls, 1);
      expect(await image.readAsBytes(), [2]);
      expect(
        container.read(attachedFilesProvider).single.fileId,
        replacementDataUrl,
      );
    },
  );

  test('pending large images retain no controller-side byte buffers', () async {
    final directory = await Directory.systemTemp.createTemp(
      'conduit_pending_large_media_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final first = File('${directory.path}/first.png');
    final second = File('${directory.path}/second.png');
    await _truncate(first, 20 * 1024 * 1024);
    await _truncate(second, 20 * 1024 * 1024);
    final uploadStarted = Completer<void>();
    final finishUpload = Completer<String>();
    final queue = AttachmentUploadQueue();
    await queue.initialize(
      onUpload: (filePath, fileName, {cancelToken}) {
        if (!uploadStarted.isCompleted) uploadStarted.complete();
        return finishUpload.future;
      },
      database: _resolveTestUploadDatabase,
    );
    addTearDown(() {
      queue.dispose();
      if (!finishUpload.isCompleted) finishUpload.complete('teardown');
    });
    var precacheReadCalls = 0;
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(null),
        selectedModelProvider.overrideWith(() => _SeededSelectedModel(null)),
        attachmentUploadQueueProvider.overrideWithValue(queue),
        imageUploadConverterProvider.overrideWithValue((_) async => null),
        uploadImagePrecacheReaderProvider.overrideWithValue((
          path,
          maxBytes,
        ) async {
          precacheReadCalls++;
          return null;
        }),
        attachedFilesProvider.overrideWith(
          () => _SeededAttachedFilesNotifier([
            _pendingImage(first, reportedBytes: 20 * 1024 * 1024),
            _pendingImage(second, reportedBytes: 20 * 1024 * 1024),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);

    await Future.wait([
      container
          .read(mediaUploadControllerProvider)
          .enqueueUpload(
            filePath: first.path,
            fileName: 'first.png',
            fileSize: 20 * 1024 * 1024,
          ),
      container
          .read(mediaUploadControllerProvider)
          .enqueueUpload(
            filePath: second.path,
            fileName: 'second.png',
            fileSize: 20 * 1024 * 1024,
          ),
    ]);
    await uploadStarted.future.timeout(const Duration(seconds: 1));

    expect(precacheReadCalls, 0);
    expect(queue.queue, hasLength(2));
  });

  test(
    'replays a terminal row completed before listener registration',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'conduit_fast_media_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final document = File('${directory.path}/fast.txt');
      await document.writeAsString('fast');
      final queue = AttachmentUploadQueue();
      await queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async => 'server-fast',
        database: _resolveTestUploadDatabase,
      );
      addTearDown(queue.dispose);
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          selectedModelProvider.overrideWith(() => _SeededSelectedModel(null)),
          attachmentUploadQueueProvider.overrideWithValue(queue),
          attachedFilesProvider.overrideWith(
            () => _SeededAttachedFilesNotifier([
              _pendingDocument(document, reportedBytes: 4),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(mediaUploadControllerProvider)
          .upload(filePath: document.path, fileName: 'fast.txt', fileSize: 4)
          .timeout(const Duration(seconds: 1));

      final state = container.read(attachedFilesProvider).single;
      expect(state.status, FileUploadStatus.completed);
      expect(state.fileId, 'server-fast');
    },
  );

  test(
    'terminal upload retains its queue row when owned cleanup fails',
    () async {
      final stagingDirectory = Directory(
        '${Directory.systemTemp.path}/conduit-app-intents',
      );
      await stagingDirectory.create();
      final document = File(
        '${stagingDirectory.path}/'
        '123e4567-e89b-12d3-a456-426614174098-notes.txt',
      );
      await document.writeAsString('queued');
      addTearDown(() async {
        if (await document.exists()) await document.delete();
      });
      final cleanupAttempted = Completer<void>();
      final queue = AttachmentUploadQueue();
      await queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async => 'server-file',
        database: _resolveTestUploadDatabase,
      );
      addTearDown(queue.dispose);
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          selectedModelProvider.overrideWith(() => _SeededSelectedModel(null)),
          attachmentUploadQueueProvider.overrideWithValue(queue),
          terminalAttachmentCleanupProvider.overrideWithValue((
            filePath, {
            required beforeDeleteAdmission,
            required canDelete,
          }) async {
            await beforeDeleteAdmission();
            if (!canDelete()) return true;
            if (!cleanupAttempted.isCompleted) cleanupAttempted.complete();
            return false;
          }),
          attachedFilesProvider.overrideWith(
            () => _SeededAttachedFilesNotifier([
              _pendingDocument(document, reportedBytes: 6),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(mediaUploadControllerProvider)
          .upload(filePath: document.path, fileName: 'notes.txt', fileSize: 6)
          .timeout(const Duration(seconds: 1));
      await cleanupAttempted.future.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);

      expect(queue.queue, hasLength(1));
      expect(queue.queue.single.status, QueuedAttachmentStatus.completed);
      expect(await document.exists(), isTrue);
    },
  );

  test('owned staging conversion preserves the durable cleanup path', () async {
    final stagingDirectory = Directory(
      '${Directory.systemTemp.path}/conduit-app-intents',
    );
    await stagingDirectory.create();
    final original = File(
      '${stagingDirectory.path}/123e4567-e89b-12d3-a456-426614174099-intent.png',
    );
    final conversionDirectory = await Directory.systemTemp.createTemp(
      'conduit_img_test_',
    );
    final converted = File('${conversionDirectory.path}/converted.jpg');
    await original.writeAsBytes([1]);
    await converted.writeAsBytes([9, 8, 7]);
    addTearDown(() async {
      if (await original.exists()) await original.delete();
      if (await conversionDirectory.exists()) {
        await conversionDirectory.delete(recursive: true);
      }
    });

    final replaced = await replaceOwnedStagingFileWithConvertedUpload(
      originalPath: original.path,
      convertedPath: converted.path,
    );

    expect(replaced, OwnedStagingConversionReplacementResult.replaced);
    expect(await original.readAsBytes(), [9, 8, 7]);
    expect(await converted.exists(), isFalse);
    expect(await conversionDirectory.exists(), isFalse);
  });

  test('owned replacement and final admission share one turn', () async {
    final stagingDirectory = Directory(
      '${Directory.systemTemp.path}/conduit-app-intents',
    );
    await stagingDirectory.create();
    final original = File(
      '${stagingDirectory.path}/'
      '123e4567-e89b-12d3-a456-426614174107-intent.png',
    );
    final conversionDirectory = await Directory.systemTemp.createTemp(
      'conduit_img_',
    );
    final converted = File('${conversionDirectory.path}/converted.jpg');
    await original.writeAsBytes([1]);
    await converted.writeAsBytes([9]);
    addTearDown(() async {
      if (await original.exists()) await original.delete();
      if (await conversionDirectory.exists()) {
        await conversionDirectory.delete(recursive: true);
      }
    });
    final replacementWritten = Completer<void>();
    var admissionCalls = 0;

    final result = await replaceOwnedStagingFileWithConvertedUpload(
      originalPath: original.path,
      convertedPath: converted.path,
      canReplace: () {
        admissionCalls++;
        if (admissionCalls == 3) {
          scheduleMicrotask(() {
            original.writeAsBytesSync([2]);
            replacementWritten.complete();
          });
        }
        return true;
      },
    );
    expect(admissionCalls, 3);
    await replacementWritten.future;

    expect(result, OwnedStagingConversionReplacementResult.replaced);
    expect(await original.readAsBytes(), [2]);
  });

  test('owned staging replacement reports an injected copy failure', () async {
    final stagingDirectory = Directory(
      '${Directory.systemTemp.path}/conduit-app-intents',
    );
    await stagingDirectory.create();
    final original = File(
      '${stagingDirectory.path}/'
      '123e4567-e89b-12d3-a456-426614174100-intent.png',
    );
    final conversionDirectory = await Directory.systemTemp.createTemp(
      'conduit_img_',
    );
    final converted = File('${conversionDirectory.path}/converted.jpg');
    await original.writeAsBytes([1]);
    await converted.writeAsBytes([9, 8, 7]);
    addTearDown(() async {
      if (await original.exists()) await original.delete();
      if (await conversionDirectory.exists()) {
        await conversionDirectory.delete(recursive: true);
      }
    });

    final result = await replaceOwnedStagingFileWithConvertedUpload(
      originalPath: original.path,
      convertedPath: converted.path,
      copyFile: (_, _) async {
        throw const FileSystemException('injected replacement failure');
      },
    );

    expect(result, OwnedStagingConversionReplacementResult.failed);
    expect(await original.readAsBytes(), [1]);
    expect(await converted.readAsBytes(), [9, 8, 7]);
  });

  test(
    'owned conversion cleanup never recursively deletes its parent',
    () async {
      final stagingDirectory = Directory(
        '${Directory.systemTemp.path}/conduit-app-intents',
      );
      await stagingDirectory.create();
      final original = File(
        '${stagingDirectory.path}/'
        '123e4567-e89b-12d3-a456-426614174101-intent.png',
      );
      final conversionDirectory = await Directory.systemTemp.createTemp(
        'conduit_img_',
      );
      final converted = File('${conversionDirectory.path}/converted.jpg');
      final sentinel = File('${conversionDirectory.path}/keep.txt');
      await original.writeAsBytes([1]);
      await converted.writeAsBytes([9, 8, 7]);
      await sentinel.writeAsString('keep');
      addTearDown(() async {
        if (await original.exists()) await original.delete();
        if (await conversionDirectory.exists()) {
          await conversionDirectory.delete(recursive: true);
        }
      });

      final result = await replaceOwnedStagingFileWithConvertedUpload(
        originalPath: original.path,
        convertedPath: converted.path,
      );

      expect(result, OwnedStagingConversionReplacementResult.replaced);
      expect(await original.readAsBytes(), [9, 8, 7]);
      expect(await converted.exists(), isFalse);
      expect(await sentinel.readAsString(), 'keep');
      expect(await conversionDirectory.exists(), isTrue);
    },
  );

  test('owned replacement rejects a nested conversion lookalike', () async {
    final stagingDirectory = Directory(
      '${Directory.systemTemp.path}/conduit-app-intents',
    );
    await stagingDirectory.create();
    final original = File(
      '${stagingDirectory.path}/'
      '123e4567-e89b-12d3-a456-426614174103-intent.png',
    );
    final outside = await Directory.systemTemp.createTemp(
      'conduit_conversion_outside_',
    );
    final lookalikeDirectory = Directory('${outside.path}/conduit_img_nested');
    await lookalikeDirectory.create();
    final converted = File('${lookalikeDirectory.path}/converted.jpg');
    await original.writeAsBytes([1]);
    await converted.writeAsBytes([9, 8, 7]);
    addTearDown(() async {
      if (await original.exists()) await original.delete();
      if (await outside.exists()) await outside.delete(recursive: true);
    });

    final result = await replaceOwnedStagingFileWithConvertedUpload(
      originalPath: original.path,
      convertedPath: converted.path,
    );

    expect(result, OwnedStagingConversionReplacementResult.failed);
    expect(await original.readAsBytes(), [1]);
    expect(await converted.readAsBytes(), [9, 8, 7]);
    expect(await lookalikeDirectory.exists(), isTrue);
  });

  test(
    'replacement and terminal cleanup failures recover the durable source on restore',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final stagingDirectory = Directory(
        '${Directory.systemTemp.path}/conduit-app-intents',
      );
      await stagingDirectory.create();
      final original = File(
        '${stagingDirectory.path}/'
        '123e4567-e89b-12d3-a456-426614174102-intent.bmp',
      );
      final conversionDirectory = await Directory.systemTemp.createTemp(
        'conduit_img_',
      );
      final converted = File('${conversionDirectory.path}/converted.jpg');
      await original.writeAsBytes([1, 2, 3]);
      await converted.writeAsBytes([9, 8, 7]);
      addTearDown(() async {
        if (await original.exists()) await original.delete();
        if (await conversionDirectory.exists()) {
          await conversionDirectory.delete(recursive: true);
        }
      });

      final uploadStarted = Completer<void>();
      final releaseUpload = Completer<void>();
      addTearDown(() {
        if (!releaseUpload.isCompleted) releaseUpload.complete();
      });
      String? uploadedPath;
      final queue = AttachmentUploadQueue();
      await queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async {
          uploadedPath = filePath;
          if (!uploadStarted.isCompleted) uploadStarted.complete();
          await releaseUpload.future;
          return 'server-file';
        },
        database: () => database,
      );
      addTearDown(queue.dispose);

      Future<OwnedStagingConversionReplacementResult> failReplacement({
        required String originalPath,
        required String convertedPath,
        bool Function()? canReplace,
      }) {
        return replaceOwnedStagingFileWithConvertedUpload(
          originalPath: originalPath,
          convertedPath: convertedPath,
          canReplace: canReplace,
          copyFile: (_, _) async {
            throw const FileSystemException('injected replacement failure');
          },
        );
      }

      final cleanupAttempted = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          selectedModelProvider.overrideWith(() => _SeededSelectedModel(null)),
          attachmentUploadQueueProvider.overrideWithValue(queue),
          imageUploadConverterProvider.overrideWithValue((_) async {
            return converted.path;
          }),
          ownedStagingConversionReplacerProvider.overrideWithValue(
            failReplacement,
          ),
          terminalAttachmentCleanupProvider.overrideWithValue((
            filePath, {
            required beforeDeleteAdmission,
            required canDelete,
          }) async {
            await beforeDeleteAdmission();
            if (!canDelete()) return true;
            if (!cleanupAttempted.isCompleted) cleanupAttempted.complete();
            return false;
          }),
          attachedFilesProvider.overrideWith(
            () => _SeededAttachedFilesNotifier([
              _pendingImage(original, reportedBytes: 3),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);

      final upload = container
          .read(mediaUploadControllerProvider)
          .upload(
            filePath: original.path,
            fileName: 'intent.bmp',
            fileSize: 3,
            mimeType: 'image/bmp',
          );
      await uploadStarted.future.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);
      releaseUpload.complete();
      await upload.timeout(const Duration(seconds: 1));
      await cleanupAttempted.future.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);

      expect(uploadedPath, original.path);
      expect(await original.exists(), isTrue);
      expect(await converted.exists(), isFalse);
      expect(await conversionDirectory.exists(), isFalse);
      final retainedRows = await database.attachmentQueueDao.getAll();
      expect(retainedRows, hasLength(1));
      expect(retainedRows.single.filePath, original.path);
      expect(retainedRows.single.status, QueuedAttachmentStatus.completed.name);
      final retainedId = retainedRows.single.id;

      queue.dispose();
      final restoredQueue = AttachmentUploadQueue();
      addTearDown(restoredQueue.dispose);
      await restoredQueue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async => 'unused',
        database: () => database,
      );

      expect(restoredQueue.queue, hasLength(1));
      expect(restoredQueue.queue.single.id, retainedId);
      expect(
        restoredQueue.queue.single.status,
        QueuedAttachmentStatus.completed,
      );
      expect(await database.attachmentQueueDao.getAll(), hasLength(1));
      expect(await original.exists(), isFalse);

      await restoredQueue.acknowledgeTerminal(retainedId);

      expect(restoredQueue.queue, isEmpty);
      expect(await database.attachmentQueueDao.getAll(), isEmpty);
    },
  );

  test(
    'conversion removes its temp directory after post-create failure',
    () async {
      final sourceDirectory = await Directory.systemTemp.createTemp(
        'conduit_conversion_cleanup_source_',
      );
      final source = File('${sourceDirectory.path}/source.bmp');
      await source.writeAsBytes([1, 2, 3]);
      final originalCompressor = FlutterImageCompressPlatform.instance;
      FlutterImageCompressPlatform.instance = _DeletingSourceImageCompressor(
        source,
      );
      addTearDown(() async {
        FlutterImageCompressPlatform.instance = originalCompressor;
        if (await sourceDirectory.exists()) {
          await sourceDirectory.delete(recursive: true);
        }
      });
      final before = Directory.systemTemp
          .listSync()
          .whereType<Directory>()
          .where((entry) => p.basename(entry.path).startsWith('conduit_img_'))
          .map((entry) => entry.path)
          .toSet();

      expect(await convertImageForUpload(source.path), isNull);
      final after = Directory.systemTemp
          .listSync()
          .whereType<Directory>()
          .where((entry) => p.basename(entry.path).startsWith('conduit_img_'))
          .map((entry) => entry.path)
          .toSet();

      expect(after.difference(before), isEmpty);
    },
  );

  test('successful conversion persists final byte metadata', () async {
    final directory = await Directory.systemTemp.createTemp(
      'conduit_converted_metadata_',
    );
    final conversionDirectory = await Directory.systemTemp.createTemp(
      'conduit_img_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
      if (await conversionDirectory.exists()) {
        await conversionDirectory.delete(recursive: true);
      }
    });
    final original = File('${directory.path}/photo.bmp');
    final converted = File('${conversionDirectory.path}/converted.jpg');
    await original.writeAsBytes([1, 2, 3]);
    const convertedBytes = <int>[9, 8, 7, 6];
    await converted.writeAsBytes(convertedBytes);

    final uploadStarted = Completer<void>();
    final releaseUpload = Completer<void>();
    addTearDown(() {
      if (!releaseUpload.isCompleted) releaseUpload.complete();
    });
    final queue = AttachmentUploadQueue();
    await queue.initialize(
      onUpload: (filePath, fileName, {cancelToken}) async {
        if (!uploadStarted.isCompleted) uploadStarted.complete();
        await releaseUpload.future;
        return 'server-file';
      },
      database: _resolveTestUploadDatabase,
    );
    addTearDown(queue.dispose);
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(null),
        selectedModelProvider.overrideWith(() => _SeededSelectedModel(null)),
        attachmentUploadQueueProvider.overrideWithValue(queue),
        imageUploadConverterProvider.overrideWithValue(
          (_) async => converted.path,
        ),
        attachedFilesProvider.overrideWith(
          () => _SeededAttachedFilesNotifier([
            _pendingImage(original, reportedBytes: 999),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);

    final upload = container
        .read(mediaUploadControllerProvider)
        .upload(
          filePath: original.path,
          fileName: 'photo.bmp',
          fileSize: 999,
          mimeType: 'image/bmp',
          checksum: 'original-checksum',
        );
    await uploadStarted.future.timeout(const Duration(seconds: 1));

    final queued = queue.queue.single;
    expect(queued.fileSize, convertedBytes.length);
    expect(queued.checksum, sha256.convert(convertedBytes).toString());
    expect(queued.fileName, 'photo.jpg');

    releaseUpload.complete();
    await upload.timeout(const Duration(seconds: 1));
  });

  test('non-converted upload persists its streamed content identity', () async {
    final directory = await Directory.systemTemp.createTemp(
      'conduit_upload_identity_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final document = File('${directory.path}/notes.txt');
    const bytes = <int>[8, 6, 7, 5, 3, 0, 9];
    await document.writeAsBytes(bytes);

    final uploadStarted = Completer<void>();
    final releaseUpload = Completer<void>();
    addTearDown(() {
      if (!releaseUpload.isCompleted) releaseUpload.complete();
    });
    final queue = AttachmentUploadQueue();
    await queue.initialize(
      onUpload: (filePath, fileName, {cancelToken}) async {
        if (!uploadStarted.isCompleted) uploadStarted.complete();
        await releaseUpload.future;
        return 'server-file';
      },
      database: _resolveTestUploadDatabase,
    );
    addTearDown(queue.dispose);
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(null),
        selectedModelProvider.overrideWith(() => _SeededSelectedModel(null)),
        attachmentUploadQueueProvider.overrideWithValue(queue),
        attachedFilesProvider.overrideWith(
          () => _SeededAttachedFilesNotifier([
            _pendingDocument(document, reportedBytes: 999),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);

    final upload = container
        .read(mediaUploadControllerProvider)
        .upload(
          filePath: document.path,
          fileName: 'notes.txt',
          fileSize: 999,
          checksum: 'stale-caller-checksum',
        );
    await uploadStarted.future.timeout(const Duration(seconds: 1));

    final queued = queue.queue.single;
    expect(queued.fileSize, bytes.length);
    expect(queued.checksum, sha256.convert(bytes).toString());

    releaseUpload.complete();
    await upload.timeout(const Duration(seconds: 1));
  });

  test(
    'superseded source cleanup still removes its unique conversion temp',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'conduit_superseded_conversion_',
      );
      final conversionDirectory = await Directory.systemTemp.createTemp(
        'conduit_img_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
        if (await conversionDirectory.exists()) {
          await conversionDirectory.delete(recursive: true);
        }
      });
      final original = File('${directory.path}/photo.bmp');
      final converted = File('${conversionDirectory.path}/converted.jpg');
      await original.writeAsBytes([1, 2, 3]);
      await converted.writeAsBytes([9, 8, 7]);

      final sourceCleanupEntered = Completer<void>();
      final releaseSourceCleanup = Completer<void>();
      final secondConversionStarted = Completer<void>();
      final releaseSecondConversion = Completer<String?>();
      var conversionCalls = 0;
      var sourceBarrierCalls = 0;
      final queue = AttachmentUploadQueue();
      await queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async =>
            'server-${File(filePath).uri.pathSegments.last}',
        database: _resolveTestUploadDatabase,
      );
      addTearDown(queue.dispose);
      addTearDown(() {
        if (!releaseSourceCleanup.isCompleted) releaseSourceCleanup.complete();
        if (!releaseSecondConversion.isCompleted) {
          releaseSecondConversion.complete(null);
        }
      });

      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          selectedModelProvider.overrideWith(() => _SeededSelectedModel(null)),
          attachmentUploadQueueProvider.overrideWithValue(queue),
          imageUploadConverterProvider.overrideWithValue((_) {
            conversionCalls++;
            if (conversionCalls == 1) {
              return Future<String?>.value(converted.path);
            }
            secondConversionStarted.complete();
            return releaseSecondConversion.future;
          }),
          mediaUploadCleanupBarrierProvider.overrideWithValue((filePath) async {
            if (filePath == original.path && sourceBarrierCalls++ == 0) {
              sourceCleanupEntered.complete();
              await releaseSourceCleanup.future;
            }
          }),
          terminalAttachmentCleanupProvider.overrideWithValue((
            filePath, {
            required beforeDeleteAdmission,
            required canDelete,
          }) async {
            if (filePath == original.path) {
              await beforeDeleteAdmission();
              canDelete();
              return true;
            }
            return cleanupTerminalAttachmentFile(
              filePath,
              beforeDeleteAdmission: (_) => beforeDeleteAdmission(),
              canDelete: (_) => canDelete(),
            );
          }),
          attachedFilesProvider.overrideWith(
            () => _SeededAttachedFilesNotifier([
              _pendingImage(original, reportedBytes: 3),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(mediaUploadControllerProvider);
      final oldUpload = controller.upload(
        filePath: original.path,
        fileName: 'photo.bmp',
        fileSize: 3,
        mimeType: 'image/bmp',
      );
      await sourceCleanupEntered.future.timeout(const Duration(seconds: 1));

      final cancellation = controller.cancelUploadsForFile(original.path);
      final replacementUpload = controller.upload(
        filePath: original.path,
        fileName: 'photo.bmp',
        fileSize: 3,
        mimeType: 'image/bmp',
      );
      await secondConversionStarted.future.timeout(const Duration(seconds: 1));

      releaseSourceCleanup.complete();
      await cancellation.timeout(const Duration(seconds: 1));
      try {
        await oldUpload.timeout(const Duration(seconds: 1));
      } on MediaUploadCancelledException {
        // Both terminal completion and explicit cancellation are valid once
        // the old durable row has been finalized.
      }

      expect(await converted.exists(), isFalse);
      expect(await conversionDirectory.exists(), isFalse);

      releaseSecondConversion.complete(null);
      await replacementUpload.timeout(const Duration(seconds: 1));
      expect(controller.debugTrackedPathGenerationCount, 0);
    },
  );

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

  test('direct local document gets an opaque token without encoding', () async {
    final directory = await Directory.systemTemp.createTemp(
      'conduit_direct_document_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final document = File('${directory.path}/notes.txt');
    await document.writeAsString('local direct context');
    var encodeCalls = 0;
    final container = _directContainer(
      attachments: [_pendingDocument(document, reportedBytes: 1)],
      encoder: (file) async {
        encodeCalls++;
        return null;
      },
    );
    addTearDown(container.dispose);

    await container
        .read(mediaUploadControllerProvider)
        .upload(filePath: document.path, fileName: 'notes.txt', fileSize: 1);

    final stored = container.read(attachedFilesProvider).single;
    expect(stored.status, FileUploadStatus.completed);
    expect(stored.fileId, matches(RegExp(r'^direct-local:[a-f0-9]{64}$')));
    expect(stored.fileId, isNot(contains(document.path)));
    expect(stored.fileSize, await document.length());
    expect(stored.isImage, isFalse);
    expect(stored.base64DataUrl, isNull);
    expect(encodeCalls, 0);
  });

  test('direct local document rejects unsupported PDF before send', () async {
    final directory = await Directory.systemTemp.createTemp(
      'conduit_direct_document_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final document = File('${directory.path}/notes.pdf');
    await document.writeAsString('%PDF-fake');
    final container = _directContainer(
      attachments: [_pendingDocument(document, reportedBytes: 1)],
      encoder: (file) async => throw StateError('not an image'),
    );
    addTearDown(container.dispose);

    await expectLater(
      container
          .read(mediaUploadControllerProvider)
          .upload(filePath: document.path, fileName: 'notes.pdf', fileSize: 1),
      throwsA(
        isA<DirectChatInputException>().having(
          (error) => error.message,
          'message',
          contains('UTF-8 text'),
        ),
      ),
    );
    expect(
      container.read(attachedFilesProvider).single.status,
      FileUploadStatus.failed,
    );
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
        database: _resolveTestUploadDatabase,
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
      database: _resolveTestUploadDatabase,
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

  test(
    'late file-info sync cannot upsert into a replacement auth owner',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'conduit_owned_file_sync_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final document = File('${directory.path}/notes.txt');
      await document.writeAsString('owner-a');

      final fileInfoStarted = Completer<void>();
      final fileInfoResponse = Completer<Map<String, dynamic>>();
      final oldApi = _OwnedFileSyncApiService(
        initialFiles: [_ownedFileInfo('owner-a-seed')],
        fileInfoStarted: fileInfoStarted,
        fileInfoResponse: fileInfoResponse,
      );
      final newApi = _OwnedFileSyncApiService(
        initialFiles: [_ownedFileInfo('owner-b-seed')],
      );
      addTearDown(oldApi.dispose);
      addTearDown(newApi.dispose);

      final ownerProvider =
          NotifierProvider<_UploadOwnerNotifier, _UploadOwnerState>(
            () => _UploadOwnerNotifier((
              api: oldApi,
              epoch: Object(),
              token: 'owner-a-token',
            )),
          );
      final queue = AttachmentUploadQueue();
      await queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async =>
            'uploaded-by-owner-a',
        database: _resolveTestUploadDatabase,
      );
      addTearDown(queue.dispose);

      final container = ProviderContainer(
        overrides: [
          isAuthenticatedProvider2.overrideWithValue(true),
          authTokenProvider3.overrideWith(
            (ref) => ref.watch(ownerProvider).token,
          ),
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => ref.watch(ownerProvider).epoch,
          ),
          activeServerProvider.overrideWith((ref) async => _ownedFileServer),
          apiServiceProvider.overrideWith(
            (ref) => ref.watch(ownerProvider).api,
          ),
          selectedModelProvider.overrideWith(() => _SeededSelectedModel(null)),
          attachmentUploadQueueProvider.overrideWithValue(queue),
          terminalAttachmentCleanupProvider.overrideWithValue((
            filePath, {
            required beforeDeleteAdmission,
            required canDelete,
          }) async {
            await beforeDeleteAdmission();
            canDelete();
            return true;
          }),
          attachedFilesProvider.overrideWith(
            () => _SeededAttachedFilesNotifier([
              _pendingDocument(document, reportedBytes: 7),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);

      // Resolve every owner component before the upload captures its snapshot.
      await container.read(activeServerProvider.future);
      expect(
        (await container.read(userFilesProvider.future)).map((file) => file.id),
        ['owner-a-seed'],
      );

      final upload = container
          .read(mediaUploadControllerProvider)
          .upload(filePath: document.path, fileName: 'notes.txt', fileSize: 7);
      await fileInfoStarted.future.timeout(const Duration(seconds: 1));
      expect(oldApi.fileInfoCalls, 1);

      container
          .read(ownerProvider.notifier)
          .setOwner(api: newApi, epoch: Object(), token: 'owner-b-token');
      expect(
        (await container.read(userFilesProvider.future)).map((file) => file.id),
        ['owner-b-seed'],
      );

      fileInfoResponse.complete(_ownedFileInfo('uploaded-by-owner-a').toJson());
      await upload.timeout(const Duration(seconds: 1));
      // The file-info continuation and any attempted synchronous upsert run in
      // microtasks before these event-loop turns, making the negative assertion
      // deterministic without a wall-clock delay.
      for (var iteration = 0; iteration < 3; iteration++) {
        await Future<void>.delayed(Duration.zero);
      }

      final currentIds = container
          .read(userFilesProvider)
          .requireValue
          .map((file) => file.id)
          .toList(growable: false);
      expect(currentIds, ['owner-b-seed']);
      expect(currentIds, isNot(contains('uploaded-by-owner-a')));
      expect(newApi.fileInfoCalls, 0);
    },
  );

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
      database: _resolveTestUploadDatabase,
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

    test('PDF is rejected before local attachment preparation', () async {
      final directory = await Directory.systemTemp.createTemp(
        'conduit_hermes_media_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final document = File('${directory.path}/private-notes.pdf');
      await document.writeAsBytes(utf8.encode('%PDF-fake'));
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
              fileName: 'private-notes.pdf',
              fileSize: 1,
            ),
        throwsA(
          isA<HermesChatInputException>().having(
            (error) => error.message,
            'message',
            allOf(contains('UTF-8 text'), isNot(contains('PDF'))),
          ),
        ),
      );

      expect(uploadCalls, 0);
      expect(queue.queue, isEmpty);
      expect(
        container.read(attachedFilesProvider).single.status,
        FileUploadStatus.failed,
      );
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
  List<Override> extraOverrides = const [],
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
      ...extraOverrides,
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
    database: _resolveTestUploadDatabase,
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

  void replaceAttachments(List<FileUploadState> replacements) {
    state = List.of(replacements);
  }
}

final class _DeletingSourceImageCompressor
    extends UnsupportedFlutterImageCompress {
  _DeletingSourceImageCompressor(this.source);

  final File source;

  @override
  Future<Uint8List?> compressWithFile(
    String path, {
    int minWidth = 1920,
    int minHeight = 1080,
    int inSampleSize = 1,
    int quality = 95,
    int rotate = 0,
    bool autoCorrectionAngle = true,
    CompressFormat format = CompressFormat.jpeg,
    bool keepExif = false,
    int numberOfRetries = 5,
  }) async {
    await source.delete();
    return Uint8List.fromList([9, 8, 7]);
  }
}

final class _ThrowingAttachedFilesNotifier extends AttachedFilesNotifier {
  @override
  List<FileUploadState> build() => const [];

  @override
  void addFiles(List<LocalAttachment> attachments) {
    throw StateError('attachment publication unavailable');
  }
}

final class _SeededSelectedModel extends SelectedModel {
  _SeededSelectedModel(this.model);

  final Model? model;

  @override
  Model? build() => model;
}

const _ownedFileServer = ServerConfig(
  id: 'owned-file-server',
  name: 'Owned File Server',
  url: 'https://owned-file.example',
);

typedef _UploadOwnerState = ({ApiService api, Object epoch, String token});

final class _UploadOwnerNotifier extends Notifier<_UploadOwnerState> {
  _UploadOwnerNotifier(this.initialState);

  final _UploadOwnerState initialState;

  @override
  _UploadOwnerState build() => initialState;

  void setOwner({
    required ApiService api,
    required Object epoch,
    required String token,
  }) {
    state = (api: api, epoch: epoch, token: token);
  }
}

final class _OwnedFileSyncApiService extends ApiService {
  _OwnedFileSyncApiService({
    required List<FileInfo> initialFiles,
    Completer<void>? fileInfoStarted,
    Completer<Map<String, dynamic>>? fileInfoResponse,
  }) : this._(
         WorkerManager(debugIsWebOverride: true),
         initialFiles: initialFiles,
         fileInfoStarted: fileInfoStarted,
         fileInfoResponse: fileInfoResponse,
       );

  _OwnedFileSyncApiService._(
    WorkerManager workerManager, {
    required this.initialFiles,
    required this.fileInfoStarted,
    required this.fileInfoResponse,
  }) : _workerManager = workerManager,
       super(serverConfig: _ownedFileServer, workerManager: workerManager);

  final WorkerManager _workerManager;
  final List<FileInfo> initialFiles;
  final Completer<void>? fileInfoStarted;
  final Completer<Map<String, dynamic>>? fileInfoResponse;
  int fileInfoCalls = 0;

  @override
  Future<({List<FileInfo> items, int? total, bool isPaginated})>
  getUserFilesPage({int page = 1}) async => (
    items: page == 1 ? initialFiles : const <FileInfo>[],
    total: initialFiles.length,
    isPaginated: true,
  );

  @override
  Future<Map<String, dynamic>> getFileInfo(
    String fileId, {
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) {
    fileInfoCalls++;
    final response = fileInfoResponse;
    if (response == null) {
      return Future<Map<String, dynamic>>.error(
        StateError('Unexpected getFileInfo call for $fileId'),
      );
    }
    final started = fileInfoStarted;
    if (started != null && !started.isCompleted) started.complete();
    return response.future;
  }

  @override
  void dispose() {
    super.dispose();
    _workerManager.dispose();
  }
}

FileInfo _ownedFileInfo(String id) => FileInfo(
  id: id,
  filename: '$id.txt',
  originalFilename: '$id.txt',
  size: 7,
  mimeType: 'text/plain',
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 1),
);
