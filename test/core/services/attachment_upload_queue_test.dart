import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/auth/api_auth_interceptor.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/services/attachment_upload_queue.dart';
import 'package:conduit/core/services/share_staging_cleanup.dart';

/// Lifecycle tests for the per-server [AttachmentUploadQueue]. Each test builds
/// a fresh instance (the queue is no longer a singleton — it is owned and
/// disposed by `attachmentUploadQueueProvider`).
void main() {
  test('provider stays unavailable until the durable database opens', () async {
    final api = _QueueApi();
    final database = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        isAuthenticatedProvider2.overrideWithValue(true),
        apiServiceProvider.overrideWithValue(api),
        appDatabaseProvider.overrideWith(
          (ref) => ref.watch(_mutableDatabaseProvider),
        ),
      ],
    );
    final subscription = container.listen<AttachmentUploadQueue?>(
      attachmentUploadQueueProvider,
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(() async {
      subscription.close();
      container.dispose();
      api.dispose();
      await database.close();
    });

    check(container.read(attachmentUploadQueueProvider)).isNull();

    container.read(_mutableDatabaseProvider.notifier).set(database);
    await Future<void>.delayed(Duration.zero);
    final queue = container.read(attachmentUploadQueueProvider);
    check(queue).isNotNull();
    await queue!.ready;

    container.read(_mutableDatabaseProvider.notifier).set(null);
    await Future<void>.delayed(Duration.zero);
    check(container.read(attachmentUploadQueueProvider)).isNull();
    await expectLater(
      queue.enqueue(filePath: '/tmp/retired', fileName: 'retired', fileSize: 1),
      throwsA(isA<StateError>()),
    );
  });

  group('AttachmentUploadQueue lifecycle', () {
    AppDatabase? liveDatabase;

    AppDatabase resolveLiveDatabase() =>
        liveDatabase ??= AppDatabase(NativeDatabase.memory());

    setUp(() {
      liveDatabase = null;
      addTearDown(() async {
        await liveDatabase?.close();
      });
    });

    test('processing stops after dispose without an idle periodic wake', () {
      fakeAsync((async) {
        var callCount = 0;
        final queue = AttachmentUploadQueue();
        queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async {
            callCount++;
            return 'fake-file-id';
          },
          database: resolveLiveDatabase,
        );
        // Let the initial (async) load settle before enqueueing.
        async.flushMicrotasks();
        queue.enqueue(filePath: '/tmp/a.txt', fileName: 'a.txt', fileSize: 1);

        async.elapse(const Duration(seconds: 25));
        async.flushMicrotasks();
        final before = callCount;
        check(before).isGreaterThan(0);

        queue.dispose();
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();
        check(callCount).equals(before);
      });
    });

    test('retry timer wakes at the scheduled retry and stops when empty', () {
      fakeAsync((async) {
        var callCount = 0;
        var now = DateTime.utc(2026);
        final queue = AttachmentUploadQueue(now: () => now);
        queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async {
            callCount++;
            if (callCount == 1) throw StateError('transient');
            return 'uploaded';
          },
          database: resolveLiveDatabase,
        );
        async.flushMicrotasks();
        queue.enqueue(filePath: '/tmp/retry', fileName: 'retry', fileSize: 1);
        async.flushMicrotasks();
        check(callCount).equals(1);
        check(queue.queue.single.retryCount).equals(1);

        now = now.add(const Duration(seconds: 4));
        async.elapse(const Duration(seconds: 4));
        async.flushMicrotasks();
        check(callCount).equals(1);

        // Base retry is 5 seconds with at most one second of positive jitter.
        now = now.add(const Duration(seconds: 3));
        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();
        check(callCount).equals(2);

        now = now.add(const Duration(minutes: 2));
        async.elapse(const Duration(minutes: 2));
        async.flushMicrotasks();
        check(callCount).equals(2);
        queue.dispose();
      });
    });

    test('manual retry cannot supersede an in-flight upload', () async {
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      addTearDown(() {
        if (!releaseFirst.isCompleted) releaseFirst.complete();
      });
      var uploadCalls = 0;
      final queue = AttachmentUploadQueue();
      addTearDown(queue.dispose);
      await queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async {
          uploadCalls++;
          if (uploadCalls == 1) {
            firstStarted.complete();
            await releaseFirst.future;
          }
          return 'server-$uploadCalls';
        },
        database: resolveLiveDatabase,
      );
      final completed = queue.queueStream.firstWhere(
        (items) => items.any(
          (item) => item.status == QueuedAttachmentStatus.completed,
        ),
      );

      final id = await queue.enqueue(
        filePath: '/tmp/in-flight-retry',
        fileName: 'in-flight-retry',
        fileSize: 1,
      );
      await firstStarted.future.timeout(const Duration(seconds: 1));
      await queue.retry(id);
      releaseFirst.complete();
      final terminal = (await completed.timeout(
        const Duration(seconds: 1),
      )).single;

      check(uploadCalls).equals(1);
      check(terminal.fileId).equals('server-1');
    });

    test(
      'cancellation cannot overwrite a published completion file id',
      () async {
        final cancelSettled = Completer<void>();
        final queue = AttachmentUploadQueue(
          idGenerator: () => 'completion-race',
        );
        addTearDown(queue.dispose);
        await queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async =>
              'server-file-id',
          database: resolveLiveDatabase,
          onQueueChanged: (items) {
            final item = items
                .where((entry) => entry.id == 'completion-race')
                .firstOrNull;
            if (item?.status == QueuedAttachmentStatus.completed &&
                !cancelSettled.isCompleted) {
              unawaited(
                queue.cancel('completion-race').then((_) {
                  if (!cancelSettled.isCompleted) cancelSettled.complete();
                }),
              );
            }
          },
        );

        await queue.enqueue(
          filePath: '/tmp/completion-race',
          fileName: 'completion-race',
          fileSize: 1,
        );
        await cancelSettled.future.timeout(const Duration(seconds: 1));

        check(
          queue.queue.single.status,
        ).equals(QueuedAttachmentStatus.completed);
        check(queue.queue.single.fileId).equals('server-file-id');
        final row =
            (await resolveLiveDatabase().attachmentQueueDao.getAll()).single;
        check(row.status).equals(QueuedAttachmentStatus.completed.name);
        check(row.fileId).equals('server-file-id');
      },
    );

    test('connection timeouts back off consecutively without budget burn', () {
      fakeAsync((async) {
        var callCount = 0;
        var now = DateTime.utc(2026);
        final queue = AttachmentUploadQueue(now: () => now);
        queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async {
            callCount++;
            throw DioException(
              requestOptions: RequestOptions(path: '/upload'),
              type: DioExceptionType.connectionTimeout,
            );
          },
          database: resolveLiveDatabase,
        );
        async.flushMicrotasks();
        queue.enqueue(
          filePath: '/tmp/offline',
          fileName: 'offline',
          fileSize: 1,
        );
        async.flushMicrotasks();

        check(callCount).equals(1);
        check(queue.queue.single.status).equals(QueuedAttachmentStatus.pending);
        check(queue.queue.single.retryCount).equals(0);
        check(queue.queue.single.nextRetryAt).isNotNull();

        async.flushMicrotasks();
        check(callCount).equals(1);

        now = now.add(const Duration(seconds: 7));
        async.elapse(const Duration(seconds: 7));
        async.flushMicrotasks();
        check(callCount).equals(2);
        check(queue.queue.single.retryCount).equals(0);
        final secondDelay = queue.queue.single.nextRetryAt!.difference(now);
        check(secondDelay).isGreaterOrEqual(const Duration(seconds: 10));
        check(secondDelay).isLessThan(const Duration(seconds: 11));
        queue.dispose();
      });
    });

    for (final type in const [
      DioExceptionType.sendTimeout,
      DioExceptionType.receiveTimeout,
    ]) {
      test(
        '$type is terminal because OpenWebUI cannot deduplicate uploads',
        () async {
          var uploadCalls = 0;
          final queue = AttachmentUploadQueue();
          addTearDown(queue.dispose);
          await queue.initialize(
            onUpload: (filePath, fileName, {cancelToken}) async {
              uploadCalls++;
              throw DioException(
                requestOptions: RequestOptions(path: '/api/v1/files/'),
                type: type,
              );
            },
            database: resolveLiveDatabase,
          );
          final failed = queue.queueStream.firstWhere(
            (items) => items.any(
              (item) => item.status == QueuedAttachmentStatus.failed,
            ),
          );

          await queue.enqueue(
            filePath: '/tmp/possibly-uploaded',
            fileName: 'possibly-uploaded',
            fileSize: 1,
          );
          await failed.timeout(const Duration(seconds: 1));

          final item = queue.queue.single;
          check(item.status).equals(QueuedAttachmentStatus.failed);
          check(item.retryCount).equals(0);
          check(item.nextRetryAt).isNull();
          check(item.lastError).isNotNull().contains('indeterminate');
          await queue.processQueue();
          check(uploadCalls).equals(1);
        },
      );
    }

    test(
      'live initialization fails closed when durable storage is unavailable',
      () async {
        final queue = AttachmentUploadQueue();
        addTearDown(queue.dispose);

        await expectLater(
          queue.initialize(
            onUpload: (filePath, fileName, {cancelToken}) async => 'unused',
            database: () => null,
          ),
          throwsA(isA<StateError>()),
        );
        check(queue.queue).isEmpty();
      },
    );

    test('Dio unknown local I/O failures still consume retry budget', () async {
      final queue = AttachmentUploadQueue(maxRetries: 1);
      addTearDown(queue.dispose);
      await queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async {
          throw DioException(
            requestOptions: RequestOptions(path: '/upload'),
            type: DioExceptionType.unknown,
            error: const FileSystemException('staged file missing'),
          );
        },
        database: resolveLiveDatabase,
      );
      final failed = queue.queueStream.firstWhere(
        (items) =>
            items.any((item) => item.status == QueuedAttachmentStatus.failed),
      );

      await queue.enqueue(
        filePath: '/tmp/missing',
        fileName: 'missing',
        fileSize: 1,
      );
      await failed.timeout(const Duration(seconds: 1));

      check(queue.queue.single.status).equals(QueuedAttachmentStatus.failed);
      check(queue.queue.single.retryCount).equals(1);
    });

    test(
      'consumer acknowledgement prunes completed terminal entries',
      () async {
        final queue = AttachmentUploadQueue();
        queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async => 'remote-id',
          database: resolveLiveDatabase,
        );
        await queue.ready;
        final terminal = Completer<QueuedAttachment>();
        final snapshots = <List<QueuedAttachment>>[];
        final sub = queue.queueStream.listen((items) {
          snapshots.add(items);
          final item = items
              .where(
                (entry) => entry.status == QueuedAttachmentStatus.completed,
              )
              .firstOrNull;
          if (item != null && !terminal.isCompleted) terminal.complete(item);
        });
        addTearDown(sub.cancel);

        final id = await queue.enqueue(
          filePath: '/tmp/done',
          fileName: 'done',
          fileSize: 1,
        );
        await terminal.future;
        check(queue.queue.map((item) => item.id)).contains(id);

        await queue.acknowledgeTerminal(id);
        check(queue.queue).isEmpty();
        await Future<void>.delayed(Duration.zero);
        check(snapshots.last).isEmpty();
        queue.dispose();
      },
    );

    test(
      'terminal persistence failure still notifies and never auto-reuploads',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        await database.customStatement('''
          CREATE TRIGGER reject_completed_attachment_update
          BEFORE UPDATE OF status ON attachment_queue
          WHEN NEW.status = 'completed'
          BEGIN
            SELECT RAISE(ABORT, 'injected completed persistence failure');
          END;
        ''');

        var uploadCalls = 0;
        final queue = AttachmentUploadQueue(idGenerator: () => 'terminal-gap');
        addTearDown(queue.dispose);
        await queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async {
            uploadCalls++;
            return 'remote-id';
          },
          database: () => database,
          // A throwing synchronous observer must not starve stream consumers.
          onQueueChanged: (_) => throw StateError('observer failed'),
        );
        final terminal = queue.queueStream.firstWhere(
          (items) => items.any(
            (item) => item.status == QueuedAttachmentStatus.completed,
          ),
        );

        await queue.enqueue(
          filePath: '/tmp/terminal-gap',
          fileName: 'terminal-gap',
          fileSize: 1,
        );
        final completed = (await terminal.timeout(
          const Duration(seconds: 1),
        )).single;

        check(completed.fileId).equals('remote-id');
        check(uploadCalls).equals(1);
        final staleRow = (await database.attachmentQueueDao.getAll()).single;
        check(staleRow.status).equals(QueuedAttachmentStatus.uploading.name);

        queue.dispose();
        var restoredUploadCalls = 0;
        final restored = AttachmentUploadQueue(
          terminalAttachmentCleanup: (_) async => false,
        );
        addTearDown(restored.dispose);
        await restored.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async {
            restoredUploadCalls++;
            return 'duplicate';
          },
          database: () => database,
        );
        await restored.processQueue();

        check(restoredUploadCalls).equals(0);
        check(restored.queue).length.equals(1);
        check(
          restored.queue.single.status,
        ).equals(QueuedAttachmentStatus.failed);
        check(
          restored.queue.single.lastError,
        ).isNotNull().contains('outcome is unknown');
      },
    );

    test(
      'restored interrupted upload retains its source for explicit recovery',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final stagingDirectory = Directory(
          '${Directory.systemTemp.path}/conduit-app-intents',
        );
        await stagingDirectory.create();
        final source = File(
          '${stagingDirectory.path}/'
          '123e4567-e89b-12d3-a456-426614174108-intent.txt',
        );
        await source.writeAsBytes([4, 2]);
        addTearDown(() async {
          if (await source.exists()) await source.delete();
        });
        await _seedAttachment(
          database,
          id: 'interrupted-owner',
          filePath: source.path,
          status: QueuedAttachmentStatus.uploading,
        );
        var uploadCalls = 0;
        final queue = AttachmentUploadQueue();
        addTearDown(queue.dispose);

        await queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async {
            uploadCalls++;
            return 'unexpected';
          },
          database: () => database,
        );
        await queue.processQueue();

        check(uploadCalls).equals(0);
        check(queue.queue).length.equals(1);
        check(queue.queue.single.id).equals('interrupted-owner');
        check(queue.queue.single.status).equals(QueuedAttachmentStatus.failed);
        check(await source.readAsBytes()).deepEquals([4, 2]);
        check(await database.attachmentQueueDao.getAll()).length.equals(1);
      },
    );

    test(
      'held durable receipt joins after restart until explicit release',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        var uploadCalls = 0;
        const durableKey = 'native-share-v1:payload:0:checksum';
        final firstQueue = AttachmentUploadQueue(idGenerator: () => 'receipt');
        await firstQueue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async {
            uploadCalls++;
            return 'server-file';
          },
          database: () => database,
        );
        final completed = firstQueue.queueStream.firstWhere(
          (items) => items.any(
            (item) => item.status == QueuedAttachmentStatus.completed,
          ),
        );
        final inserted = await firstQueue.enqueueOrJoin(
          filePath: '/tmp/native-receipt',
          fileName: 'native-receipt',
          fileSize: 4,
          checksum: 'checksum',
          durableKey: durableKey,
          receiptHeld: true,
        );
        await completed.timeout(const Duration(seconds: 1));
        await firstQueue.acknowledgeTerminal(inserted.item.id);

        check(firstQueue.queue).length.equals(1);
        check(firstQueue.queue.single.receiptHeld).isTrue();
        check(await database.attachmentQueueDao.getAll()).length.equals(1);
        firstQueue.dispose();

        final restoredQueue = AttachmentUploadQueue();
        addTearDown(restoredQueue.dispose);
        await restoredQueue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async {
            uploadCalls++;
            return 'duplicate';
          },
          database: () => database,
        );
        final joined = await restoredQueue.enqueueOrJoin(
          filePath: '/tmp/new-copy',
          fileName: 'native-receipt',
          fileSize: 4,
          checksum: 'checksum',
          durableKey: durableKey,
          receiptHeld: true,
        );

        check(joined.inserted).isFalse();
        check(joined.item.id).equals('receipt');
        check(restoredQueue.queue).length.equals(1);
        check(uploadCalls).equals(1);

        await restoredQueue.releaseDurableReceipts([durableKey]);
        check(restoredQueue.queue).isEmpty();
        check(await database.attachmentQueueDao.getAll()).isEmpty();
      },
    );

    test('restored failed row retains staging for manual retry', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final stagingDirectory = Directory(
        '${Directory.systemTemp.path}/conduit-app-intents',
      );
      await stagingDirectory.create();
      final source = File(
        '${stagingDirectory.path}/'
        '123e4567-e89b-12d3-a456-426614174118-retry.txt',
      );
      await source.writeAsBytes([7, 8, 9]);
      addTearDown(() async {
        if (await source.exists()) await source.delete();
      });
      await _seedAttachment(
        database,
        id: 'retryable-failed-owner',
        filePath: source.path,
        status: QueuedAttachmentStatus.failed,
        fileSize: 3,
        checksum: sha256.convert([7, 8, 9]).toString(),
      );
      var cleanupCalls = 0;
      final queue = AttachmentUploadQueue(
        terminalAttachmentCleanup: (_) async {
          cleanupCalls++;
          return true;
        },
      );
      addTearDown(queue.dispose);

      await queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async => 'unused',
        database: () => database,
      );

      check(cleanupCalls).equals(0);
      check(queue.queue.single.status).equals(QueuedAttachmentStatus.failed);
      check(await source.readAsBytes()).deepEquals([7, 8, 9]);
      check(await database.attachmentQueueDao.getAll()).length.equals(1);
    });

    test(
      'failed-state persistence rejection still settles queue listeners',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        await database.customStatement('''
          CREATE TRIGGER reject_failed_attachment_update
          BEFORE UPDATE OF status ON attachment_queue
          WHEN NEW.status = 'failed'
          BEGIN
            SELECT RAISE(ABORT, 'injected failed persistence failure');
          END;
        ''');

        var uploadCalls = 0;
        final queue = AttachmentUploadQueue(
          idGenerator: () => 'failed-gap',
          maxRetries: 1,
        );
        addTearDown(queue.dispose);
        await queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async {
            uploadCalls++;
            throw StateError('known upload failure');
          },
          database: () => database,
        );
        final terminal = queue.queueStream.firstWhere(
          (items) =>
              items.any((item) => item.status == QueuedAttachmentStatus.failed),
        );

        await queue.enqueue(
          filePath: '/tmp/failed-gap',
          fileName: 'failed-gap',
          fileSize: 1,
        );
        final failed = (await terminal.timeout(
          const Duration(seconds: 1),
        )).single;
        await Future<void>.delayed(Duration.zero);

        check(uploadCalls).equals(1);
        check(failed.status).equals(QueuedAttachmentStatus.failed);
        check(
          (await database.attachmentQueueDao.getAll()).single.status,
        ).equals(QueuedAttachmentStatus.uploading.name);
      },
    );

    test(
      'consumer acknowledgement prunes unretryable failed entries',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final queue = AttachmentUploadQueue(maxRetries: 1);
        queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async {
            throw StateError('terminal failure');
          },
          database: () => database,
        );
        await queue.ready;
        final terminal = Completer<QueuedAttachment>();
        final sub = queue.queueStream.listen((items) {
          final failed = items
              .where((item) => item.status == QueuedAttachmentStatus.failed)
              .firstOrNull;
          if (failed != null && !terminal.isCompleted) {
            terminal.complete(failed);
          }
        });
        addTearDown(sub.cancel);

        final id = await queue.enqueue(
          filePath: '/tmp/failed',
          fileName: 'failed',
          fileSize: 1,
        );
        await terminal.future.timeout(const Duration(seconds: 1));
        await queue.acknowledgeTerminal(id);

        check(queue.queue).isEmpty();
        check(await database.attachmentQueueDao.getAll()).isEmpty();
        queue.dispose();
      },
    );

    test(
      'restored terminal row survives an injected cleanup failure',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        await _seedAttachment(
          database,
          id: 'cleanup-failed',
          filePath: '/tmp/cleanup-failed',
          status: QueuedAttachmentStatus.completed,
          checksum: sha256.convert(const <int>[]).toString(),
        );
        var cleanupCalls = 0;
        final queue = AttachmentUploadQueue(
          terminalAttachmentCleanup: (filePath) async {
            cleanupCalls++;
            return false;
          },
        );
        addTearDown(queue.dispose);

        await queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async => 'unused',
          database: () => database,
        );

        check(cleanupCalls).equals(1);
        check(queue.queue).length.equals(1);
        check(queue.queue.single.id).equals('cleanup-failed');
        check(
          queue.queue.single.status,
        ).equals(QueuedAttachmentStatus.completed);
        check(await database.attachmentQueueDao.getAll()).length.equals(1);
      },
    );

    test(
      'restored terminal row survives native staging-root resolution failure',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final outside = await Directory.systemTemp.createTemp(
          'conduit_native_root_restore_',
        );
        final staged = File(
          '${outside.path}/'
          '123e4567-e89b-12d3-a456-426614174013-shared.jpg',
        );
        await staged.writeAsBytes([1, 2, 3]);
        addTearDown(() async {
          if (await outside.exists()) await outside.delete(recursive: true);
        });
        await _seedAttachment(
          database,
          id: 'native-root-failed',
          filePath: staged.path,
          status: QueuedAttachmentStatus.completed,
          fileSize: 3,
          checksum: sha256.convert(const <int>[1, 2, 3]).toString(),
        );
        final queue = AttachmentUploadQueue(
          terminalAttachmentCleanup: (filePath) {
            return cleanupTerminalAttachmentFile(
              filePath,
              nativeStagingRootResolver: () {
                throw PlatformException(code: 'app-group-unavailable');
              },
            );
          },
        );
        addTearDown(queue.dispose);

        await queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async => 'unused',
          database: () => database,
        );

        check(queue.queue).length.equals(1);
        check(queue.queue.single.id).equals('native-root-failed');
        check(await database.attachmentQueueDao.getAll()).length.equals(1);
        check(await staged.exists()).isTrue();
      },
    );

    test(
      'restored terminal row removes its image-conversion temp directory',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final conversionDirectory = await Directory.systemTemp.createTemp(
          'conduit_img_',
        );
        final converted = File('${conversionDirectory.path}/converted.jpg');
        await converted.writeAsBytes([1, 2, 3]);
        addTearDown(() async {
          if (await conversionDirectory.exists()) {
            await conversionDirectory.delete(recursive: true);
          }
        });
        await _seedAttachment(
          database,
          id: 'restored-conversion',
          filePath: converted.path,
          status: QueuedAttachmentStatus.completed,
          fileSize: 3,
          checksum: sha256.convert([1, 2, 3]).toString(),
        );
        final queue = AttachmentUploadQueue();
        addTearDown(queue.dispose);
        final replayed = <List<QueuedAttachment>>[];

        await queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async => 'unused',
          database: () => database,
          onQueueChanged: replayed.add,
        );

        check(replayed).isNotEmpty();
        check(replayed.first.single.id).equals('restored-conversion');
        check(queue.queue.single.id).equals('restored-conversion');
        check(await database.attachmentQueueDao.getAll()).length.equals(1);
        check(await converted.exists()).isFalse();
        check(await conversionDirectory.exists()).isFalse();

        await queue.acknowledgeTerminal('restored-conversion');
        check(queue.queue).isEmpty();
        check(await database.attachmentQueueDao.getAll()).isEmpty();
      },
    );

    test(
      'restored terminal row never unlinks same-path replacement bytes',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final stagingDirectory = Directory(
          '${Directory.systemTemp.path}/conduit-app-intents',
        );
        await stagingDirectory.create();
        final source = File(
          '${stagingDirectory.path}/'
          '123e4567-e89b-12d3-a456-426614174109-'
          '${DateTime.now().microsecondsSinceEpoch}.txt',
        );
        const originalBytes = <int>[1, 2, 3];
        const replacementBytes = <int>[3, 2, 1];
        await source.writeAsBytes(originalBytes);
        await _seedAttachment(
          database,
          id: 'replaced-terminal-owner',
          filePath: source.path,
          status: QueuedAttachmentStatus.completed,
          fileSize: originalBytes.length,
          checksum: sha256.convert(originalBytes).toString(),
        );
        // Simulate pathname reuse while Conduit is not running. Equal length
        // proves the guard is content identity, not just a byte-count check.
        await source.writeAsBytes(replacementBytes, flush: true);
        addTearDown(() async {
          if (await source.exists()) await source.delete();
        });

        final queue = AttachmentUploadQueue();
        addTearDown(queue.dispose);
        await queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async => 'unused',
          database: () => database,
        );

        check(queue.queue.single.id).equals('replaced-terminal-owner');
        check(await database.attachmentQueueDao.getAll()).length.equals(1);
        check(await source.readAsBytes()).deepEquals(replacementBytes);

        await queue.acknowledgeTerminal('replaced-terminal-owner');
        check(queue.queue).isEmpty();
        check(await database.attachmentQueueDao.getAll()).isEmpty();
      },
    );

    test('legacy cleanup adapter honors restored identity admission', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final stagingDirectory = Directory(
        '${Directory.systemTemp.path}/conduit-app-intents',
      );
      await stagingDirectory.create();
      final source = File(
        '${stagingDirectory.path}/'
        '123e4567-e89b-12d3-a456-426614174119-adapter.txt',
      );
      const originalBytes = <int>[1, 2, 3];
      const replacementBytes = <int>[3, 2, 1];
      await source.writeAsBytes(replacementBytes);
      addTearDown(() async {
        if (await source.exists()) await source.delete();
      });
      await _seedAttachment(
        database,
        id: 'adapter-replaced-owner',
        filePath: source.path,
        status: QueuedAttachmentStatus.completed,
        fileSize: originalBytes.length,
        checksum: sha256.convert(originalBytes).toString(),
      );
      var cleanupCalls = 0;
      final queue = AttachmentUploadQueue(
        terminalAttachmentCleanup: (_) async {
          cleanupCalls += 1;
          await source.delete();
          return true;
        },
      );
      addTearDown(queue.dispose);

      await queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async => 'unused',
        database: () => database,
      );

      check(cleanupCalls).equals(0);
      check(queue.queue.single.id).equals('adapter-replaced-owner');
      check(await database.attachmentQueueDao.getAll()).length.equals(1);
      check(await source.readAsBytes()).deepEquals(replacementBytes);

      await queue.acknowledgeTerminal('adapter-replaced-owner');
      check(queue.queue).isEmpty();
      check(await database.attachmentQueueDao.getAll()).isEmpty();
    });

    test(
      'legacy terminal row without content identity preserves its pathname',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final stagingDirectory = Directory(
          '${Directory.systemTemp.path}/conduit-app-intents',
        );
        await stagingDirectory.create();
        final source = File(
          '${stagingDirectory.path}/'
          '123e4567-e89b-12d3-a456-426614174110-'
          '${DateTime.now().microsecondsSinceEpoch}.txt',
        );
        const bytes = <int>[4, 5, 6];
        await source.writeAsBytes(bytes);
        addTearDown(() async {
          if (await source.exists()) await source.delete();
        });
        await _seedAttachment(
          database,
          id: 'legacy-terminal-owner',
          filePath: source.path,
          status: QueuedAttachmentStatus.cancelled,
          fileSize: bytes.length,
        );

        final queue = AttachmentUploadQueue();
        addTearDown(queue.dispose);
        await queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async => 'unused',
          database: () => database,
        );

        check(queue.queue.single.id).equals('legacy-terminal-owner');
        check(await database.attachmentQueueDao.getAll()).length.equals(1);
        check(await source.readAsBytes()).deepEquals(bytes);

        await queue.acknowledgeTerminal('legacy-terminal-owner');
        check(queue.queue).isEmpty();
        check(await database.attachmentQueueDao.getAll()).isEmpty();
      },
    );

    test('same-tick enqueues receive distinct durable identities', () async {
      final uploadResult = Completer<String>();
      addTearDown(() {
        if (!uploadResult.isCompleted) uploadResult.complete('teardown');
      });
      final queue = AttachmentUploadQueue(now: () => DateTime.utc(2026));
      queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) => uploadResult.future,
        database: resolveLiveDatabase,
      );
      await queue.ready;

      final first = await queue.enqueue(
        filePath: '/tmp/first',
        fileName: 'first',
        fileSize: 1,
      );
      final second = await queue.enqueue(
        filePath: '/tmp/second',
        fileName: 'second',
        fileSize: 1,
      );

      check(first).not((it) => it.equals(second));
      check(queue.queue.map((item) => item.id).toSet()).length.equals(2);
      queue.dispose();
    });

    test('owner-held enqueue cannot start until explicitly released', () async {
      final uploadStarted = Completer<void>();
      final queue = AttachmentUploadQueue();
      addTearDown(queue.dispose);
      await queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async {
          uploadStarted.complete();
          return 'server-file';
        },
        database: resolveLiveDatabase,
      );

      final id = await queue.enqueue(
        filePath: '/tmp/held',
        fileName: 'held',
        fileSize: 1,
        holdForOwner: true,
      );
      await Future<void>.delayed(Duration.zero);

      check(uploadStarted.isCompleted).isFalse();
      check(queue.queue.single.status).equals(QueuedAttachmentStatus.pending);

      queue.releaseOwnerHold(id);
      await uploadStarted.future.timeout(const Duration(seconds: 1));
    });

    test(
      'clearAll cancels an active upload and prevents a late row reinsert',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final uploadStarted = Completer<void>();
        final uploadResult = Completer<String>();
        CancelToken? token;
        addTearDown(() {
          if (!uploadResult.isCompleted) uploadResult.complete('teardown');
        });
        final queue = AttachmentUploadQueue();
        queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) {
            token = cancelToken;
            if (!uploadStarted.isCompleted) uploadStarted.complete();
            return uploadResult.future;
          },
          database: () => database,
        );
        await queue.ready;
        await queue.enqueue(
          filePath: '/tmp/active',
          fileName: 'active',
          fileSize: 1,
        );
        await uploadStarted.future;

        await queue.clearAll();
        check(token?.isCancelled ?? false).isTrue();
        check(queue.queue).isEmpty();
        check(await database.attachmentQueueDao.getAll()).isEmpty();

        uploadResult.complete('late-remote-id');
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        check(queue.queue).isEmpty();
        check(await database.attachmentQueueDao.getAll()).isEmpty();
        queue.dispose();
      },
    );

    test(
      'clearAll delete failure preserves and tombstones live rows',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        await database.customStatement('''
          CREATE TRIGGER reject_clear_attachment_delete
          BEFORE DELETE ON attachment_queue
          BEGIN
            SELECT RAISE(ABORT, 'injected clear delete failure');
          END;
        ''');
        var uploadCalls = 0;
        final queue = AttachmentUploadQueue(idGenerator: () => 'held-clear');
        addTearDown(queue.dispose);
        await queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async {
            uploadCalls++;
            return 'unexpected';
          },
          database: () => database,
        );
        final id = await queue.enqueue(
          filePath: '/tmp/held-clear',
          fileName: 'held-clear',
          fileSize: 1,
          holdForOwner: true,
        );

        await check(queue.clearAll()).throws<Exception>();
        check(queue.queue.map((item) => item.id)).deepEquals([id]);
        check(
          (await database.attachmentQueueDao.getAll()).map((row) => row.id),
        ).deepEquals([id]);

        queue.releaseOwnerHold(id);
        await queue.processQueue();
        check(uploadCalls).equals(0);

        await database.customStatement(
          'DROP TRIGGER reject_clear_attachment_delete',
        );
        await queue.clearAll();
        check(queue.queue).isEmpty();
        check(await database.attachmentQueueDao.getAll()).isEmpty();
      },
    );

    test('clearAll clears durable rows with an empty live snapshot', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final queue = AttachmentUploadQueue();
      addTearDown(queue.dispose);
      await queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async => 'unused',
        database: () => database,
      );
      await _seedPendingAttachment(database, id: 'durable-only', order: 0);
      check(queue.queue).isEmpty();

      await queue.clearAll();

      check(queue.queue).isEmpty();
      check(await database.attachmentQueueDao.getAll()).isEmpty();
    });

    test('removing a later snapshotted row prevents its upload', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await _seedPendingAttachment(database, id: 'first', order: 0);
      await _seedPendingAttachment(database, id: 'second', order: 1);

      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final uploaded = <String>[];
      addTearDown(() {
        if (!releaseFirst.isCompleted) releaseFirst.complete();
      });
      final queue = AttachmentUploadQueue();
      addTearDown(queue.dispose);
      await queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async {
          uploaded.add(fileName);
          if (fileName == 'first') {
            firstStarted.complete();
            await releaseFirst.future;
          }
          return 'remote-$fileName';
        },
        database: () => database,
      );

      final processing = queue.processQueue();
      await firstStarted.future;
      await queue.remove('second');
      releaseFirst.complete();
      await processing;

      check(uploaded).deepEquals(['first']);
      check(
        (await database.attachmentQueueDao.getAll()).map((row) => row.id),
      ).deepEquals(['first']);
    });

    test(
      'clearAll prevents later snapshotted rows from uploading or returning',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        await _seedPendingAttachment(database, id: 'first', order: 0);
        await _seedPendingAttachment(database, id: 'second', order: 1);

        final firstStarted = Completer<void>();
        final releaseFirst = Completer<void>();
        final uploaded = <String>[];
        addTearDown(() {
          if (!releaseFirst.isCompleted) releaseFirst.complete();
        });
        final queue = AttachmentUploadQueue();
        addTearDown(queue.dispose);
        await queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async {
            uploaded.add(fileName);
            if (fileName == 'first') {
              firstStarted.complete();
              await releaseFirst.future;
            }
            return 'remote-$fileName';
          },
          database: () => database,
        );

        final processing = queue.processQueue();
        await firstStarted.future;
        await queue.clearAll();
        releaseFirst.complete();
        await processing;

        check(uploaded).deepEquals(['first']);
        check(queue.queue).isEmpty();
        check(await database.attachmentQueueDao.getAll()).isEmpty();
      },
    );

    test(
      'a blocked failing initial insert cannot race a processing wakeup',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        await database.customStatement('''
          CREATE TRIGGER reject_attachment_queue_insert
          BEFORE INSERT ON attachment_queue
          BEGIN
            SELECT RAISE(ABORT, 'injected attachment insert failure');
          END;
        ''');

        var uploadCalls = 0;
        final queue = AttachmentUploadQueue(idGenerator: () => 'rejected');
        addTearDown(queue.dispose);
        await queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async {
            uploadCalls++;
            return 'must-not-upload';
          },
          database: () => database,
        );

        final transactionStarted = Completer<void>();
        final releaseTransaction = Completer<void>();
        addTearDown(() {
          if (!releaseTransaction.isCompleted) releaseTransaction.complete();
        });
        final blocker = database.transaction(() async {
          transactionStarted.complete();
          await releaseTransaction.future;
        });
        await transactionStarted.future;

        Object? enqueueError;
        final enqueueSettled = queue
            .enqueue(
              filePath: '/tmp/rejected',
              fileName: 'rejected',
              fileSize: 1,
            )
            .then<void>(
              (_) {},
              onError: (Object error, StackTrace _) {
                enqueueError = error;
              },
            );
        await Future<void>.delayed(Duration.zero);

        await queue.processQueue().timeout(const Duration(seconds: 1));
        check(uploadCalls).equals(0);

        releaseTransaction.complete();
        await blocker;
        await enqueueSettled;
        await queue.processQueue();

        check(enqueueError).isNotNull();
        check(uploadCalls).equals(0);
        check(queue.queue).isEmpty();
        check(await database.attachmentQueueDao.getAll()).isEmpty();
      },
    );

    test(
      'submitted persistence keeps its database owner across dispose',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final queue = AttachmentUploadQueue();
        queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async => 'unused',
          database: () => database,
        );
        await queue.ready;

        final transactionStarted = Completer<void>();
        final releaseTransaction = Completer<void>();
        final blocker = database.transaction(() async {
          transactionStarted.complete();
          await releaseTransaction.future;
        });
        await transactionStarted.future;

        final first = queue.enqueue(
          filePath: '/tmp/first-owned',
          fileName: 'first-owned',
          fileSize: 1,
        );
        await Future<void>.delayed(Duration.zero);
        final second = queue.enqueue(
          filePath: '/tmp/second-owned',
          fileName: 'second-owned',
          fileSize: 1,
        );
        await Future<void>.delayed(Duration.zero);

        queue.dispose();
        releaseTransaction.complete();
        await blocker;
        await Future.wait([first, second]);

        final rows = await database.attachmentQueueDao.getAll();
        check(
          rows.map((row) => row.fileName).toSet(),
        ).deepEquals({'first-owned', 'second-owned'});
      },
    );

    test(
      'submitted deletes keep their database owner across dispose',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final uploadResult = Completer<String>();
        addTearDown(() {
          if (!uploadResult.isCompleted) uploadResult.complete('teardown');
        });
        final queue = AttachmentUploadQueue();
        queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) => uploadResult.future,
          database: () => database,
        );
        await queue.ready;
        final firstId = await queue.enqueue(
          filePath: '/tmp/delete-first',
          fileName: 'delete-first',
          fileSize: 1,
        );
        final secondId = await queue.enqueue(
          filePath: '/tmp/delete-second',
          fileName: 'delete-second',
          fileSize: 1,
        );

        final transactionStarted = Completer<void>();
        final releaseTransaction = Completer<void>();
        final blocker = database.transaction(() async {
          transactionStarted.complete();
          await releaseTransaction.future;
        });
        await transactionStarted.future;

        final firstDelete = queue.remove(firstId);
        await Future<void>.delayed(Duration.zero);
        final secondDelete = queue.remove(secondId);
        await Future<void>.delayed(Duration.zero);

        queue.dispose();
        releaseTransaction.complete();
        await blocker;
        await Future.wait([firstDelete, secondDelete]);

        check(await database.attachmentQueueDao.getAll()).isEmpty();
      },
    );

    test('copyWith can clear nullable retry and error state', () {
      final item = QueuedAttachment(
        id: 'one',
        filePath: '/tmp/one',
        fileName: 'one',
        fileSize: 1,
        nextRetryAt: DateTime(2026),
        lastError: 'failed',
        fileId: 'remote',
      );

      final cleared = item.copyWith(
        nextRetryAt: null,
        lastError: null,
        fileId: null,
      );
      check(cleared.nextRetryAt).isNull();
      check(cleared.lastError).isNull();
      check(cleared.fileId).isNull();
    });

    test('dispose closes queueStream so listeners receive onDone', () async {
      final queue = AttachmentUploadQueue();
      queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async => 'id',
        database: resolveLiveDatabase,
      );
      var done = false;
      final sub = queue.queueStream.listen((_) {}, onDone: () => done = true);
      addTearDown(sub.cancel);

      queue.dispose();
      await Future<void>.delayed(Duration.zero);

      check(done).isTrue();
    });

    test('dispose is idempotent (does not double-close the controller)', () {
      final queue = AttachmentUploadQueue();
      queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async => 'id',
        database: resolveLiveDatabase,
      );
      queue.dispose();
      queue.dispose();
    });

    test('an upload awaiting a terminal event resolves via onDone, and its '
        'token is cancelled, when the queue is disposed mid-upload', () async {
      final queue = AttachmentUploadQueue();
      final uploadStarted = Completer<void>();
      final hang = Completer<String>();
      CancelToken? capturedToken;
      // Release the hanging upload during cleanup so its future does not leak.
      addTearDown(() {
        if (!hang.isCompleted) hang.complete('teardown');
      });
      queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) {
          capturedToken = cancelToken;
          if (!uploadStarted.isCompleted) uploadStarted.complete();
          return hang.future;
        },
        database: resolveLiveDatabase,
      );
      await queue
          .ready; // load settled before enqueue (no enqueue-vs-load race)

      final id = await queue.enqueue(
        filePath: '/tmp/b.txt',
        fileName: 'b.txt',
        fileSize: 1,
      );
      // Wait until the upload actually starts (item is now `uploading`).
      await uploadStarted.future;

      // Model a MediaUploadController completer that resolves on a terminal
      // status OR when the stream closes (onDone).
      final resolved = Completer<void>();
      void tryResolve() {
        if (!resolved.isCompleted) resolved.complete();
      }

      final sub = queue.queueStream.listen((items) {
        for (final e in items) {
          if (e.id == id &&
              e.status != QueuedAttachmentStatus.pending &&
              e.status != QueuedAttachmentStatus.uploading) {
            tryResolve();
          }
        }
      }, onDone: tryResolve);
      addTearDown(sub.cancel);

      queue.dispose();

      // Would hang forever before the provider-ownership refactor; now the
      // stream closes on dispose and the awaiting completer resolves.
      await resolved.future.timeout(const Duration(seconds: 1));
      check(resolved.isCompleted).isTrue();
      // Dispose aborts the in-flight upload so it cannot land on the old server.
      check(capturedToken?.isCancelled ?? false).isTrue();
    });

    test(
      'ready resolves even when the queue is disposed mid-initialization',
      () async {
        final queue = AttachmentUploadQueue();
        queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async => 'id',
          database: resolveLiveDatabase,
        );
        // Dispose before the initial load settles. `ready` is owned by the
        // instance (not a provider future), so awaiting it must still resolve
        // rather than hang — the guarantee the provider read relies on.
        queue.dispose();
        await queue.ready.timeout(const Duration(seconds: 1));
      },
    );

    test('enqueue after dispose throws instead of silently dropping', () async {
      final queue = AttachmentUploadQueue();
      queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async => 'id',
        database: resolveLiveDatabase,
      );
      await queue.ready;
      queue.dispose();

      var threw = false;
      try {
        await queue.enqueue(
          filePath: '/tmp/c.txt',
          fileName: 'c.txt',
          fileSize: 1,
        );
      } on StateError {
        threw = true;
      }
      check(threw).isTrue();
    });

    test(
      'ready rejects on load failure and preserves the existing snapshot',
      () async {
        final queue = AttachmentUploadQueue();
        queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async => 'id',
          database: resolveLiveDatabase,
        );
        await queue.ready;
        await queue.enqueue(
          filePath: '/tmp/kept.txt',
          fileName: 'kept.txt',
          fileSize: 1,
        );
        final before = queue.queue.map((e) => e.id).toList();

        // Re-initialize with a resolver that fails before the DAO read. The
        // failure must remain visible through `ready`, and staging the load means
        // the previous in-memory snapshot is not cleared on the failed attempt.
        queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async => 'id',
          database: () => throw StateError('load failed'),
        );
        var threw = false;
        try {
          await queue.ready;
        } on StateError {
          threw = true;
        }
        check(threw).isTrue();
        check(queue.queue.map((e) => e.id).toList()).deepEquals(before);
        queue.dispose();
      },
    );
  });
}

Future<void> _seedPendingAttachment(
  AppDatabase database, {
  required String id,
  required int order,
}) {
  return _seedAttachment(
    database,
    id: id,
    filePath: '/tmp/$id',
    status: QueuedAttachmentStatus.pending,
    order: order,
  );
}

Future<void> _seedAttachment(
  AppDatabase database, {
  required String id,
  required String filePath,
  required QueuedAttachmentStatus status,
  int order = 0,
  int fileSize = 1,
  String? checksum,
}) {
  return database.attachmentQueueDao.upsert(
    AttachmentUploadQueue.companionFromLegacyJson({
      'id': id,
      'filePath': filePath,
      'fileName': id,
      'fileSize': fileSize,
      'checksum': ?checksum,
      'enqueuedAt': DateTime.utc(2026, 1, 1, 0, 0, order).toIso8601String(),
      'retryCount': 0,
      'status': status.name,
    }),
  );
}

final _mutableDatabaseProvider =
    NotifierProvider<_MutableDatabase, AppDatabase?>(_MutableDatabase.new);

final class _MutableDatabase extends Notifier<AppDatabase?> {
  @override
  AppDatabase? build() => null;

  void set(AppDatabase? database) => state = database;
}

final class _QueueApi extends ApiService {
  _QueueApi() : this._withWorker(WorkerManager());

  _QueueApi._withWorker(this._ownedWorkerManager)
    : super(
        serverConfig: const ServerConfig(
          id: 'queue-test',
          name: 'Queue test',
          url: 'https://queue.example',
        ),
        workerManager: _ownedWorkerManager,
      );

  final WorkerManager _ownedWorkerManager;

  @override
  void dispose() {
    super.dispose();
    _ownedWorkerManager.dispose();
  }

  @override
  Future<String> uploadFile(
    String filePath,
    String fileName, {
    String? contentType,
    Map<String, dynamic>? metadata,
    CancelToken? cancelToken,
    ApiAuthSnapshot? authSnapshot,
  }) {
    throw StateError('provider readiness test must not upload');
  }
}
