import 'dart:io';

import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/attachment_upload_queue.dart';
import 'package:conduit/core/services/media_upload_controller.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_sharing_intent/model/sharing_file.dart';
import 'package:path/path.dart' as p;
import 'package:drift/native.dart';

import 'package:conduit/core/services/share_receiver_service.dart';
import 'package:conduit/core/services/share_staging_cleanup.dart';
import 'package:conduit/features/chat/services/file_attachment_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SharedPayload', () {
    test('parses native payload maps and filters invalid file paths', () {
      final payload = SharedPayload.fromMap({
        'id': 'share-1',
        'text': 'hello',
        'filePaths': ['/tmp/a.txt', '', 42, '/tmp/b.txt'],
      });

      expect(payload.id, 'share-1');
      expect(payload.text, 'hello');
      expect(payload.filePaths, ['/tmp/a.txt', '/tmp/b.txt']);
      expect(payload.toMap(), {
        'id': 'share-1',
        'text': 'hello',
        'filePaths': ['/tmp/a.txt', '/tmp/b.txt'],
      });
    });

    test('ignores malformed native payloads', () {
      const payload = SharedPayload();

      expect(SharedPayload.fromMap(null).hasAnything, isFalse);
      expect(SharedPayload.fromMap('bad').hasAnything, isFalse);
      expect(payload.toMap(), {'filePaths': <String>[]});
    });

    test('maps shared text and URLs into composer text', () {
      final payload = SharedPayload.fromSharedFiles([
        SharedFile(
          value: '  hello from another app  ',
          type: SharedMediaType.TEXT,
          mimeType: 'text/plain',
        ),
        SharedFile(
          value: 'https://example.com/article',
          type: SharedMediaType.URL,
        ),
      ]);

      expect(
        payload.text,
        'hello from another app\nhttps://example.com/article',
      );
      expect(payload.filePaths, isEmpty);
    });

    test('maps shared files, photos, and videos into file paths', () {
      final payload = SharedPayload.fromSharedFiles([
        SharedFile(
          value: 'file:///tmp/shared%20photo.jpg',
          type: SharedMediaType.IMAGE,
          mimeType: 'image/jpeg',
        ),
        SharedFile(
          value: '/tmp/movie.mp4',
          type: SharedMediaType.VIDEO,
          mimeType: 'video/mp4',
        ),
        SharedFile(
          value: '/tmp/doc.pdf',
          type: SharedMediaType.FILE,
          mimeType: 'application/pdf',
        ),
      ]);

      expect(payload.text, isNull);
      expect(payload.filePaths, [
        '/tmp/shared photo.jpg',
        '/tmp/movie.mp4',
        '/tmp/doc.pdf',
      ]);
    });

    test('merges Android multi-file share text into composer text', () {
      final payload = SharedPayload.fromSharedFiles([
        SharedFile(
          value: '/tmp/photo.jpg',
          type: SharedMediaType.IMAGE,
          mimeType: 'image/jpeg',
        ),
        SharedFile(
          value: '/tmp/document.pdf',
          type: SharedMediaType.FILE,
          mimeType: 'application/pdf',
        ),
      ], extraText: '  shared caption  ');

      expect(payload.text, 'shared caption');
      expect(payload.filePaths, ['/tmp/photo.jpg', '/tmp/document.pdf']);
    });

    test('deduplicates iOS messages and malformed media values', () {
      final payload = SharedPayload.fromSharedFiles([
        SharedFile(
          value: '/tmp/one.jpg',
          type: SharedMediaType.IMAGE,
          message: 'caption',
        ),
        SharedFile(
          value: '/tmp/two.jpg',
          type: SharedMediaType.IMAGE,
          message: 'caption',
        ),
        SharedFile(value: '', type: SharedMediaType.FILE),
        SharedFile(value: ' ', type: SharedMediaType.TEXT),
        SharedFile(value: '/tmp/two.jpg', type: SharedMediaType.IMAGE),
      ]);

      expect(payload.text, 'caption');
      expect(payload.filePaths, ['/tmp/one.jpg', '/tmp/two.jpg']);
    });

    test('retains ignored Android thumbnails without proven ownership', () async {
      final thumbnail = File(
        p.join(
          Directory.systemTemp.path,
          'conduit-share-thumbnail-${DateTime.now().microsecondsSinceEpoch}.png',
        ),
      );
      await thumbnail.writeAsBytes([1, 2, 3]);
      addTearDown(() async {
        if (await thumbnail.exists()) {
          await thumbnail.delete();
        }
      });

      final payload = SharedPayload.fromSharedFiles([
        SharedFile(
          value: '/tmp/movie.mp4',
          thumbnail: thumbnail.path,
          type: SharedMediaType.VIDEO,
          mimeType: 'video/mp4',
        ),
      ]);

      expect(payload.filePaths, ['/tmp/movie.mp4']);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await thumbnail.exists(), isTrue);
    });
  });

  group('SharedAttachmentImportStatusNotifier', () {
    test('preserves prepared composer marker for the same native import', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(
        sharedAttachmentImportStatusProvider.notifier,
      );
      notifier.set(
        const SharedAttachmentImportStatus(
          id: 'share-1',
          expectedFileCount: 2,
          isInProgress: true,
        ),
      );
      notifier.markComposerPrepared('share-1');

      notifier.set(
        const SharedAttachmentImportStatus(
          id: 'share-1',
          expectedFileCount: 2,
          isInProgress: false,
        ),
      );

      expect(
        container.read(sharedAttachmentImportStatusProvider).preparedComposer,
        isTrue,
      );

      notifier.set(
        const SharedAttachmentImportStatus(
          id: 'share-2',
          expectedFileCount: 1,
          isInProgress: true,
        ),
      );

      expect(
        container.read(sharedAttachmentImportStatusProvider).preparedComposer,
        isFalse,
      );
    });
  });

  group('native share payload acknowledgement', () {
    const channel = MethodChannel('conduit/share_receiver_ack_test');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('peek survives restart-style rereads until matching ack', () async {
      Object? durablePayload = <String, Object?>{
        'id': 'share-current',
        'text': 'durable text',
        'filePaths': <String>[],
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'takePendingShareImportPayload':
                return durablePayload;
              case 'ackPendingShareImportPayload':
                final arguments = call.arguments as Map<Object?, Object?>;
                final current = SharedPayload.fromMap(durablePayload);
                if (arguments['id'] != current.id) return false;
                durablePayload = null;
                return true;
            }
            return null;
          });

      expect(
        (await peekPendingNativeSharePayloadForTest(channel))?.id,
        'share-current',
      );
      expect(
        (await peekPendingNativeSharePayloadForTest(channel))?.id,
        'share-current',
      );
      expect(
        await ackPendingNativeSharePayloadForTest(channel, 'share-stale'),
        isFalse,
      );
      expect(
        (await peekPendingNativeSharePayloadForTest(channel))?.id,
        'share-current',
      );
      expect(
        await ackPendingNativeSharePayloadForTest(channel, 'share-current'),
        isTrue,
      );
      expect(await peekPendingNativeSharePayloadForTest(channel), isNull);
    });

    test('retry never acknowledges while both terminal outcomes do', () async {
      final acknowledgedIds = <String>[];
      Future<bool> acknowledge(String id) async {
        acknowledgedIds.add(id);
        return true;
      }

      const payload = SharedPayload(id: 'share-1', text: 'hello');

      expect(
        await acknowledgeNativeSharePayloadAfterProcessingForTest(
          result: SharedPayloadProcessResult.retry,
          payload: payload,
          acknowledge: acknowledge,
        ),
        isFalse,
      );
      expect(acknowledgedIds, isEmpty);

      expect(
        await acknowledgeNativeSharePayloadAfterProcessingForTest(
          result: SharedPayloadProcessResult.processed,
          payload: payload,
          acknowledge: acknowledge,
        ),
        isTrue,
      );
      expect(acknowledgedIds, ['share-1']);

      expect(
        await acknowledgeNativeSharePayloadAfterProcessingForTest(
          result: SharedPayloadProcessResult.consumed,
          payload: payload,
          acknowledge: acknowledge,
        ),
        isTrue,
      );
      expect(acknowledgedIds, ['share-1', 'share-1']);
    });

    test('content without an acknowledgement ID is rejected', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'takePendingShareImportPayload') {
              return <String, Object?>{
                'text': 'cannot be acknowledged',
                'filePaths': <String>[],
              };
            }
            return null;
          });

      expect(await peekPendingNativeSharePayloadForTest(channel), isNull);
    });

    test(
      'terminal fence prevents reprocessing while ack is deferred',
      () async {
        final fence = NativeShareProcessingFence();
        const payload = SharedPayload(id: 'share-terminal', text: 'hello');
        final acknowledgedIds = <String>[];

        expect(fence.shouldProcess(payload), isTrue);
        expect(
          await fenceTerminalNativeSharePayloadUntilAcknowledgedForTest(
            fence: fence,
            result: SharedPayloadProcessResult.processed,
            payload: payload,
            acknowledge: (id) async {
              acknowledgedIds.add(id);
              return false;
            },
          ),
          isFalse,
        );
        expect(acknowledgedIds, ['share-terminal']);
        expect(fence.shouldProcess(payload), isFalse);

        expect(
          await fenceTerminalNativeSharePayloadUntilAcknowledgedForTest(
            fence: fence,
            result: SharedPayloadProcessResult.processed,
            payload: payload,
            acknowledge: (id) async {
              acknowledgedIds.add(id);
              return true;
            },
          ),
          isTrue,
        );
        expect(acknowledgedIds, ['share-terminal', 'share-terminal']);
        expect(fence.shouldProcess(payload), isTrue);
      },
    );
  });

  group('shared attachment validation', () {
    test('copies valid unowned share files into owned staging', () async {
      final root = await Directory.systemTemp.createTemp(
        'conduit_share_receiver_valid_',
      );
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });

      final file = File(
        p.join(
          root.path,
          'shared-intents',
          '123e4567-e89b-12d3-a456-426614174000-small.txt',
        ),
      );
      await file.create(recursive: true);
      await file.writeAsString('hello');

      final attachments = await validSharedAttachmentsForTest([file.path]);
      addTearDown(
        () => Future.wait(
          attachments.map(
            (attachment) => deleteShareStagingFile(attachment.file.path),
          ),
        ),
      );

      expect(attachments, hasLength(1));
      expect(attachments.single.file.path, isNot(file.path));
      expect(await isShareStagingPath(attachments.single.file.path), isTrue);
      expect(attachments.single.displayName, p.basename(file.path));
      expect(await attachments.single.file.readAsString(), 'hello');
      expect(await file.exists(), isTrue);
    });

    test('rejects oversized images without deleting unowned files', () async {
      final root = await Directory.systemTemp.createTemp(
        'conduit_share_receiver_oversized_',
      );
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });

      final file = File(
        p.join(
          root.path,
          'shared-intents',
          '123e4567-e89b-12d3-a456-426614174000-big.jpg',
        ),
      );
      await file.create(recursive: true);
      final handle = await file.open(mode: FileMode.write);
      await handle.truncate(20 * 1024 * 1024 + 1);
      await handle.close();

      final attachments = await validSharedAttachmentsForTest([file.path]);

      expect(attachments, isEmpty);
      expect(await file.exists(), isTrue);
    });

    test('allows non-image staged files over the image size cap', () async {
      final root = await Directory.systemTemp.createTemp(
        'conduit_share_receiver_large_file_',
      );
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });

      final file = File(
        p.join(
          root.path,
          'shared-intents',
          '123e4567-e89b-12d3-a456-426614174000-meeting.mp3',
        ),
      );
      await file.create(recursive: true);
      final handle = await file.open(mode: FileMode.write);
      await handle.truncate(20 * 1024 * 1024 + 1);
      await handle.close();

      final attachments = await validSharedAttachmentsForTest([file.path]);
      addTearDown(
        () => Future.wait(
          attachments.map(
            (attachment) => deleteShareStagingFile(attachment.file.path),
          ),
        ),
      );

      expect(attachments, hasLength(1));
      expect(attachments.single.file.path, isNot(file.path));
      expect(await isShareStagingPath(attachments.single.file.path), isTrue);
      expect(await file.exists(), isTrue);
    });

    test('rejects excess files without deleting unowned files', () async {
      final root = await Directory.systemTemp.createTemp(
        'conduit_share_receiver_count_',
      );
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });

      final files = <File>[];
      for (var i = 0; i < 7; i++) {
        final file = File(
          p.join(
            root.path,
            'shared-intents',
            '123e4567-e89b-12d3-a456-426614174000-$i.txt',
          ),
        );
        await file.create(recursive: true);
        await file.writeAsString('hello $i');
        files.add(file);
      }

      final attachments = await validSharedAttachmentsForTest(
        files.map((file) => file.path).toList(),
      );
      addTearDown(
        () => Future.wait(
          attachments.map(
            (attachment) => deleteShareStagingFile(attachment.file.path),
          ),
        ),
      );

      expect(attachments, hasLength(6));
      expect(await files[5].exists(), isTrue);
      expect(await files[6].exists(), isTrue);
    });

    test('applies the count cap after rejecting invalid entries', () async {
      final root = await Directory.systemTemp.createTemp(
        'conduit_share_receiver_validated_count_',
      );
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });

      final validFiles = <File>[];
      for (var index = 0; index < 6; index++) {
        final file = File(p.join(root.path, 'valid-$index.txt'));
        await file.writeAsString('valid $index');
        validFiles.add(file);
      }
      final missingPath = p.join(root.path, 'missing-first.txt');

      final attachments = await validSharedAttachmentsForTest([
        missingPath,
        ...validFiles.map((file) => file.path),
      ]);
      addTearDown(
        () => Future.wait(
          attachments.map(
            (attachment) => deleteShareStagingFile(attachment.file.path),
          ),
        ),
      );

      expect(attachments, hasLength(6));
      expect(
        attachments.map((attachment) => attachment.displayName),
        validFiles.map((file) => p.basename(file.path)),
      );
    });

    test(
      'copies temp-root files without deleting the uncertain source',
      () async {
        final file = File(
          p.join(
            Directory.systemTemp.path,
            'conduit-share-plugin-cache-root-${DateTime.now().microsecondsSinceEpoch}.txt',
          ),
        );
        await file.writeAsString('hello from cache root');
        addTearDown(() async {
          if (await file.exists()) {
            await file.delete();
          }
        });

        final attachments = await validSharedAttachmentsForTest([file.path]);
        addTearDown(
          () => Future.wait(
            attachments.map(
              (attachment) => deleteShareStagingFile(attachment.file.path),
            ),
          ),
        );

        expect(attachments, hasLength(1));
        final stagedPath = attachments.single.file.path;
        expect(await isShareStagingPath(stagedPath), isTrue);
        expect(p.basename(p.dirname(stagedPath)), shareStagingDirectoryName);
        expect(await File(stagedPath).readAsString(), 'hello from cache root');
        expect(await file.exists(), isTrue);
      },
    );

    test(
      'deletes an exact legacy-plugin source through a one-use lease',
      () async {
        final pluginRoot = await Directory.systemTemp.createTemp(
          'conduit_legacy_plugin_root_',
        );
        final source = File(p.join(pluginRoot.path, 'plugin-source.txt'));
        await source.writeAsString('plugin-owned');
        addTearDown(() async {
          if (await pluginRoot.exists()) {
            await pluginRoot.delete(recursive: true);
          }
        });

        final attachments = await validSharedAttachmentsForTest(
          [source.path],
          isLegacyPluginPayload: true,
          legacyPluginSourceRootResolver: () async => pluginRoot,
        );
        addTearDown(
          () => Future.wait(
            attachments.map(
              (attachment) => deleteShareStagingFile(attachment.file.path),
            ),
          ),
        );

        expect(attachments, hasLength(1));
        expect(await source.exists(), isFalse);
      },
    );

    test(
      'retains nested document paths outside the plugin root contract',
      () async {
        final pluginRoot = await Directory.systemTemp.createTemp(
          'conduit_legacy_plugin_nested_',
        );
        final documents = Directory(p.join(pluginRoot.path, 'Documents'));
        await documents.create();
        final source = File(p.join(documents.path, 'caller-owned.txt'));
        await source.writeAsString('caller-owned');
        addTearDown(() async {
          if (await pluginRoot.exists()) {
            await pluginRoot.delete(recursive: true);
          }
        });

        final attachments = await validSharedAttachmentsForTest(
          [source.path],
          isLegacyPluginPayload: true,
          legacyPluginSourceRootResolver: () async => pluginRoot,
        );
        addTearDown(
          () => Future.wait(
            attachments.map(
              (attachment) => deleteShareStagingFile(attachment.file.path),
            ),
          ),
        );

        expect(attachments, hasLength(1));
        expect(await source.readAsString(), 'caller-owned');
      },
    );
  });

  group('share staging cleanup', () {
    test('does not treat arbitrary temp files as share staging', () async {
      final file = File(
        p.join(
          Directory.systemTemp.path,
          'conduit-not-share-${DateTime.now().microsecondsSinceEpoch}.txt',
        ),
      );
      await file.writeAsString('keep me');
      addTearDown(() async {
        if (await file.exists()) {
          await file.delete();
        }
      });

      expect(await isShareStagingPath(file.path), isFalse);

      await deleteShareStagingFile(file.path);

      expect(await file.exists(), isTrue);
    });
  });

  group('shared payload processing', () {
    test(
      'joins the first durable item after second-item failure and restart',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'conduit_share_receiver_durable_batch_',
        );
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(() async {
          await database.close();
          if (await root.exists()) await root.delete(recursive: true);
        });
        final first = File(p.join(root.path, 'first.txt'));
        final second = File(p.join(root.path, 'second.txt'));
        await first.writeAsString('first durable bytes');
        await second.writeAsString('second durable bytes');
        var uploadCalls = 0;
        Future<String> upload(
          String filePath,
          String fileName, {
          CancelToken? cancelToken,
        }) async => 'server-${++uploadCalls}';

        final firstQueue = _FailSecondDurableQueue();
        await firstQueue.initialize(onUpload: upload, database: () => database);
        final firstContainer = _durableShareContainer(firstQueue);
        _markComposerPrepared(firstContainer, 'native-batch-restart');
        final firstStaged = <File>[];
        Future<IncomingSharedFileStageResult> firstStager(
          String filePath,
        ) async {
          final result = await stageIncomingSharedFileWithResult(
            filePath,
            deletePluginSourceAfterCopy: false,
          );
          firstStaged.add(result.file);
          return result;
        }

        final firstResult = await processSharedPayloadForTest(
          firstContainer,
          SharedPayload(
            id: 'native-batch-restart',
            filePaths: [first.path, second.path],
          ),
          incomingFileStager: firstStager,
        );

        expect(firstResult, SharedPayloadProcessResult.retry);
        expect(await first.exists(), isTrue);
        expect(await second.exists(), isTrue);
        expect(firstQueue.queue, hasLength(1));
        expect(firstQueue.queue.single.receiptHeld, isTrue);
        expect(firstQueue.queue.single.durableKey, isNotNull);
        expect(firstContainer.read(attachedFilesProvider), hasLength(1));
        expect(await firstStaged[1].exists(), isFalse);
        final firstReceipt = firstQueue.queue.single.durableKey;

        firstContainer.dispose();
        firstQueue.dispose();

        final restoredQueue = AttachmentUploadQueue();
        await restoredQueue.initialize(
          onUpload: upload,
          database: () => database,
        );
        final restoredContainer = _durableShareContainer(restoredQueue);
        _markComposerPrepared(restoredContainer, 'native-batch-restart');
        addTearDown(() {
          restoredContainer.dispose();
          restoredQueue.dispose();
        });

        final restoredResult = await processSharedPayloadForTest(
          restoredContainer,
          SharedPayload(
            id: 'native-batch-restart',
            filePaths: [first.path, second.path],
          ),
        );

        expect(restoredResult, SharedPayloadProcessResult.processed);
        expect(restoredQueue.queue, hasLength(2));
        expect(
          restoredQueue.queue.map((item) => item.durableKey).toSet(),
          hasLength(2),
        );
        expect(restoredQueue.queue.first.durableKey, firstReceipt);
        expect(restoredQueue.queue.every((item) => item.receiptHeld), isTrue);
        for (var attempt = 0; attempt < 100 && uploadCalls < 2; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(uploadCalls, 2);
        expect(restoredContainer.read(attachedFilesProvider), hasLength(2));
        expect(await first.exists(), isTrue);
        expect(await second.exists(), isTrue);

        await restoredContainer
            .read(mediaUploadControllerProvider)
            .releaseNativeShareReceipts(
              restoredQueue.queue.map((item) => item.durableKey!),
            );
        for (
          var attempt = 0;
          attempt < 100 && restoredQueue.queue.isNotEmpty;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(restoredQueue.queue, isEmpty);
        expect(await database.attachmentQueueDao.getAll(), isEmpty);
      },
    );

    test('consumes invalid file-only payloads instead of retrying', () async {
      final root = await Directory.systemTemp.createTemp(
        'conduit_share_receiver_missing_',
      );
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });

      final container = ProviderContainer(
        overrides: [fileAttachmentServiceProvider.overrideWithValue(Object())],
      );
      addTearDown(container.dispose);

      final missingPath = p.join(
        root.path,
        'shared-intents',
        '123e4567-e89b-12d3-a456-426614174000-missing.txt',
      );

      final result = await processSharedPayloadForTest(
        container,
        SharedPayload(id: 'stale', filePaths: [missingPath]),
      );

      expect(result, SharedPayloadProcessResult.consumed);
      expect(container.read(attachedFilesProvider), isEmpty);
    });

    test(
      'retries without consuming files when native ownership is indeterminate',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'conduit_share_receiver_indeterminate_',
        );
        addTearDown(() async {
          if (await root.exists()) {
            await root.delete(recursive: true);
          }
        });
        final source = File(
          p.join(
            root.path,
            'native-share',
            '123e4567-e89b-12d3-a456-426614174000-retry.txt',
          ),
        );
        await source.create(recursive: true);
        await source.writeAsString('retry me');

        final container = ProviderContainer(
          overrides: [
            fileAttachmentServiceProvider.overrideWithValue(Object()),
          ],
        );
        addTearDown(container.dispose);

        final result = await processSharedPayloadForTest(
          container,
          SharedPayload(id: 'transient', filePaths: [source.path]),
          nativeStagingRootResolver: () async =>
              throw PlatformException(code: 'app-group-unavailable'),
        );

        expect(result, SharedPayloadProcessResult.retry);
        expect(await source.exists(), isTrue);
        expect(container.read(attachedFilesProvider), isEmpty);
      },
    );

    test(
      'rolls back earlier copies when a later attachment fails to stage',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'conduit_share_receiver_transaction_',
        );
        addTearDown(() async {
          if (await root.exists()) {
            await root.delete(recursive: true);
          }
        });
        final first = File(
          p.join(
            root.path,
            'external',
            '123e4567-e89b-12d3-a456-426614174000-first.txt',
          ),
        );
        final second = File(
          p.join(
            root.path,
            'external',
            '123e4567-e89b-12d3-a456-426614174001-second.txt',
          ),
        );
        await first.create(recursive: true);
        await first.writeAsString('first');
        await second.writeAsString('second');

        File? stagedFirst;
        final stagedArtifacts = <File>[];
        addTearDown(() async {
          for (final artifact in stagedArtifacts) {
            if (await artifact.exists()) await artifact.delete();
          }
        });
        var stageCalls = 0;
        Future<IncomingSharedFileStageResult> stager(String filePath) async {
          stageCalls += 1;
          if (stageCalls == 2) {
            throw const FileSystemException('simulated staging failure');
          }
          final result = await stageIncomingSharedFileWithResult(
            filePath,
            deletePluginSourceAfterCopy: false,
          );
          stagedFirst = result.file;
          stagedArtifacts.add(result.file);
          return result;
        }

        final container = ProviderContainer(
          overrides: [
            fileAttachmentServiceProvider.overrideWithValue(Object()),
          ],
        );
        addTearDown(container.dispose);

        final result = await processSharedPayloadForTest(
          container,
          SharedPayload(
            id: 'transaction',
            filePaths: [first.path, second.path],
          ),
          incomingFileStager: stager,
        );

        expect(result, SharedPayloadProcessResult.retry);
        expect(stageCalls, 2);
        expect(await first.exists(), isTrue);
        expect(await second.exists(), isTrue);
        expect(stagedFirst, isNotNull);
        expect(await stagedFirst!.exists(), isFalse);
        expect(container.read(attachedFilesProvider), isEmpty);
      },
    );

    test(
      'retries only rollback artifacts whose first unlink was deferred',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'conduit_share_receiver_rollback_retry_',
        );
        addTearDown(() async {
          if (await root.exists()) {
            await root.delete(recursive: true);
          }
        });
        final sources = <File>[];
        for (var index = 0; index < 3; index++) {
          final source = File(p.join(root.path, 'source-$index.txt'));
          await source.writeAsString('source $index');
          sources.add(source);
        }

        final staged = <File>[];
        Future<IncomingSharedFileStageResult> stager(String filePath) async {
          if (staged.length == 2) {
            throw const FileSystemException('simulated staging failure');
          }
          final result = await stageIncomingSharedFileWithResult(
            filePath,
            deletePluginSourceAfterCopy: false,
          );
          staged.add(result.file);
          return result;
        }

        final rollbackCalls = <String, int>{};
        Future<ShareStagingFileCleanupResult> rollback(String filePath) async {
          final call = (rollbackCalls[filePath] ?? 0) + 1;
          rollbackCalls[filePath] = call;
          if (filePath == staged[1].path && call == 1) {
            return ShareStagingFileCleanupResult.failed;
          }
          return deleteShareStagingFileWithResult(filePath);
        }

        final container = ProviderContainer(
          overrides: [
            fileAttachmentServiceProvider.overrideWithValue(Object()),
          ],
        );
        addTearDown(container.dispose);

        final result = await processSharedPayloadForTest(
          container,
          SharedPayload(
            id: 'rollback-retry',
            filePaths: sources.map((source) => source.path).toList(),
          ),
          incomingFileStager: stager,
          stagedFileRollback: rollback,
        );

        expect(result, SharedPayloadProcessResult.retry);
        expect(rollbackCalls[staged[0].path], 1);
        expect(rollbackCalls[staged[1].path], 2);
        expect(await staged[0].exists(), isFalse);
        expect(await staged[1].exists(), isFalse);
        expect(container.read(attachedFilesProvider), isEmpty);
      },
    );

    test(
      'drains an incomplete rollback before restaging the same payload',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'conduit_share_receiver_retained_rollback_',
        );
        addTearDown(() async {
          if (await root.exists()) {
            await root.delete(recursive: true);
          }
        });
        final first = File(p.join(root.path, 'first.txt'));
        final second = File(p.join(root.path, 'second.txt'));
        await first.writeAsString('first');
        await second.writeAsString('second');

        final staged = <File>[];
        var stageCalls = 0;
        var oldArtifactAbsentBeforeRestaging = false;
        Future<IncomingSharedFileStageResult> stager(String filePath) async {
          stageCalls += 1;
          if (stageCalls.isEven) {
            throw const FileSystemException('simulated staging failure');
          }
          if (stageCalls == 3) {
            oldArtifactAbsentBeforeRestaging = !await staged.first.exists();
          }
          final result = await stageIncomingSharedFileWithResult(
            filePath,
            deletePluginSourceAfterCopy: false,
          );
          staged.add(result.file);
          return result;
        }

        var rollbackCalls = 0;
        Future<ShareStagingFileCleanupResult> rollback(String filePath) async {
          rollbackCalls += 1;
          if (rollbackCalls <= 4) {
            return ShareStagingFileCleanupResult.failed;
          }
          return deleteShareStagingFileWithResult(filePath);
        }

        final container = ProviderContainer(
          overrides: [
            fileAttachmentServiceProvider.overrideWithValue(Object()),
          ],
        );
        addTearDown(container.dispose);

        SharedPayload payload() => SharedPayload(
          id: 'retained-rollback',
          filePaths: [first.path, second.path],
        );

        expect(
          await processSharedPayloadForTest(
            container,
            payload(),
            incomingFileStager: stager,
            stagedFileRollback: rollback,
          ),
          SharedPayloadProcessResult.retry,
        );
        expect(stageCalls, 2);
        expect(await staged.first.exists(), isTrue);

        // The second attempt is cleanup-only because the old copy is still
        // owned after both retry admissions fail.
        expect(
          await processSharedPayloadForTest(
            container,
            payload(),
            incomingFileStager: stager,
            stagedFileRollback: rollback,
          ),
          SharedPayloadProcessResult.retry,
        );
        expect(stageCalls, 2);
        expect(await staged.first.exists(), isTrue);

        expect(
          await processSharedPayloadForTest(
            container,
            payload(),
            incomingFileStager: stager,
            stagedFileRollback: rollback,
          ),
          SharedPayloadProcessResult.retry,
        );
        expect(oldArtifactAbsentBeforeRestaging, isTrue);
        expect(stageCalls, 4);
        expect(await staged.first.exists(), isFalse);
        expect(await staged.last.exists(), isFalse);
        expect(container.read(attachedFilesProvider), isEmpty);
      },
    );
  });
}

ProviderContainer _durableShareContainer(AttachmentUploadQueue queue) {
  return ProviderContainer(
    overrides: [
      fileAttachmentServiceProvider.overrideWithValue(Object()),
      apiServiceProvider.overrideWithValue(null),
      attachmentUploadQueueProvider.overrideWithValue(queue),
      selectedModelProvider.overrideWith(() => _ShareSelectedModel(null)),
    ],
  );
}

void _markComposerPrepared(ProviderContainer container, String payloadId) {
  container
      .read(sharedAttachmentImportStatusProvider.notifier)
      .set(
        SharedAttachmentImportStatus(
          id: payloadId,
          expectedFileCount: 2,
          isInProgress: false,
          preparedComposer: true,
        ),
      );
}

final class _ShareSelectedModel extends SelectedModel {
  _ShareSelectedModel(this.initialModel);

  final Model? initialModel;

  @override
  Model? build() => initialModel;
}

final class _FailSecondDurableQueue extends AttachmentUploadQueue {
  var _durableCalls = 0;

  @override
  Future<DurableAttachmentEnqueueResult> enqueueOrJoin({
    required String filePath,
    required String fileName,
    required int fileSize,
    String? mimeType,
    String? checksum,
    bool holdForOwner = false,
    String? durableKey,
    bool receiptHeld = false,
  }) {
    if (durableKey != null && ++_durableCalls == 2) {
      throw StateError('injected second durable enqueue failure');
    }
    return super.enqueueOrJoin(
      filePath: filePath,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      checksum: checksum,
      holdForOwner: holdForOwner,
      durableKey: durableKey,
      receiptHeld: receiptHeld,
    );
  }
}
