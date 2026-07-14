import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/features/notes/services/note_audio_upload_service.dart';

void main() {
  group('NoteAudioUploadCoordinator', () {
    test(
      'keeps a durable recording and retry state when upload fails',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'conduit_note_audio_upload_test_',
        );
        addTearDown(() => _deleteDirectory(root));

        final source = await _recordingFile(root, 'source.m4a');
        final store = NoteAudioUploadStore(
          applicationSupportDirectory: () async => root,
          idGenerator: () => 'upload-1',
        );
        final staged = await store.stage(
          source: source,
          serverId: 'server-1',
          accountId: 'user-1',
          noteId: 'note-1',
          fileName: 'recording.m4a',
        );

        var attachCalls = 0;
        final coordinator = NoteAudioUploadCoordinator(
          store: store,
          upload: (_, _) async => throw DioException(
            requestOptions: RequestOptions(path: '/api/v1/files/'),
            type: DioExceptionType.connectionError,
            message: 'offline',
          ),
          attach: (_, _) async => attachCalls++,
        );

        final failed = await coordinator.process(staged);

        check(failed).isNotNull();
        check(failed!.status).equals(NoteAudioUploadStatus.failed);
        check(failed.serverFileId).isNull();
        check(await source.exists()).isFalse();
        check(await File(failed.localPath).exists()).isTrue();
        check(attachCalls).equals(0);

        final reloaded = await store.loadForNote(
          serverId: 'server-1',
          accountId: 'user-1',
          noteId: 'note-1',
        );
        check(reloaded).length.equals(1);
        check(reloaded.single.id).equals('upload-1');
        check(reloaded.single.status).equals(NoteAudioUploadStatus.failed);

        final accountItems = await store.loadForAccount(
          serverId: 'server-1',
          accountId: 'user-1',
        );
        check(accountItems.single.noteId).equals('note-1');
        check(
          await store.loadForAccount(
            serverId: 'server-1',
            accountId: 'another-user',
          ),
        ).isEmpty();
      },
    );

    test(
      'retries after reconstruction and deletes only after attach',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'conduit_note_audio_upload_test_',
        );
        addTearDown(() => _deleteDirectory(root));

        final source = await _recordingFile(root, 'source.m4a');
        final store = NoteAudioUploadStore(
          applicationSupportDirectory: () async => root,
          idGenerator: () => 'upload-2',
        );
        final staged = await store.stage(
          source: source,
          serverId: 'server-1',
          noteId: 'note-1',
          fileName: 'recording.m4a',
        );

        final failed = await NoteAudioUploadCoordinator(
          store: store,
          upload: (_, _) async => throw StateError('offline'),
          attach: (_, _) async => fail('attach must not run'),
        ).process(staged);
        check(failed).isNotNull();

        final durablePath = failed!.localPath;
        final reconstructedStore = NoteAudioUploadStore(
          applicationSupportDirectory: () async => root,
        );
        final reloaded = await reconstructedStore.loadForNote(
          serverId: 'server-1',
          noteId: 'note-1',
        );
        check(reloaded).length.equals(1);

        var uploadCalls = 0;
        String? attachedFileId;
        final completed = await NoteAudioUploadCoordinator(
          store: reconstructedStore,
          upload: (_, file) async {
            uploadCalls++;
            check(await file.exists()).isTrue();
            return 'file-1';
          },
          attach: (_, fileId) async => attachedFileId = fileId,
        ).process(reloaded.single);

        check(completed).isNull();
        check(uploadCalls).equals(1);
        check(attachedFileId).equals('file-1');
        check(await File(durablePath).exists()).isFalse();
        check(
          await reconstructedStore.loadForNote(
            serverId: 'server-1',
            noteId: 'note-1',
          ),
        ).isEmpty();
      },
    );

    test(
      'persists file id before attach and does not re-upload on retry',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'conduit_note_audio_upload_test_',
        );
        addTearDown(() => _deleteDirectory(root));

        final source = await _recordingFile(root, 'source.m4a');
        final store = NoteAudioUploadStore(
          applicationSupportDirectory: () async => root,
          idGenerator: () => 'upload-3',
        );
        final staged = await store.stage(
          source: source,
          serverId: 'server-1',
          noteId: 'note-1',
          fileName: 'recording.m4a',
        );

        var uploadCalls = 0;
        var attachCalls = 0;
        final interrupted = await NoteAudioUploadCoordinator(
          store: store,
          upload: (_, _) async {
            uploadCalls++;
            return 'file-2';
          },
          attach: (_, _) async {
            attachCalls++;
            throw StateError('interrupted before note update');
          },
        ).process(staged);

        check(interrupted).isNotNull();
        check(interrupted!.status).equals(NoteAudioUploadStatus.failed);
        check(interrupted.serverFileId).equals('file-2');
        check(uploadCalls).equals(1);
        check(attachCalls).equals(1);
        check(await File(interrupted.localPath).exists()).isTrue();

        final reconstructedStore = NoteAudioUploadStore(
          applicationSupportDirectory: () async => root,
        );
        final reloaded = await reconstructedStore.loadForNote(
          serverId: 'server-1',
          noteId: 'note-1',
        );
        check(reloaded.single.serverFileId).equals('file-2');

        final completed = await NoteAudioUploadCoordinator(
          store: reconstructedStore,
          upload: (_, _) async {
            uploadCalls++;
            return 'unexpected-file-id';
          },
          attach: (_, fileId) async {
            attachCalls++;
            check(fileId).equals('file-2');
          },
        ).process(reloaded.single);

        check(completed).isNull();
        check(uploadCalls).equals(1);
        check(attachCalls).equals(2);
      },
    );

    test(
      'recovers a journaled copy interrupted before its final rename',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'conduit_note_audio_upload_test_',
        );
        addTearDown(() => _deleteDirectory(root));

        final store = NoteAudioUploadStore(
          applicationSupportDirectory: () async => root,
          idGenerator: () => 'upload-4',
        );
        final staged = await store.stage(
          source: await _recordingFile(root, 'source.m4a'),
          serverId: 'server-1',
          accountId: 'user-1',
          noteId: 'note-1',
          fileName: 'recording.m4a',
        );
        final recording = File(staged.localPath);
        final interruptedCopy = File('${recording.parent.path}/.staging.m4a');
        await recording.rename(interruptedCopy.path);

        final recovered = await NoteAudioUploadStore(
          applicationSupportDirectory: () async => root,
        ).loadForAccount(serverId: 'server-1', accountId: 'user-1');

        check(recovered).length.equals(1);
        check(recovered.single.status).equals(NoteAudioUploadStatus.failed);
        check(await File(recovered.single.localPath).exists()).isTrue();
        check(await interruptedCopy.exists()).isFalse();
      },
    );

    test(
      'recovers an interrupted copy from its journaled cache name',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'conduit_note_audio_upload_test_',
        );
        addTearDown(() => _deleteDirectory(root));
        final cache = await Directory('${root.path}/cache').create();

        final store = NoteAudioUploadStore(
          applicationSupportDirectory: () async => root,
          temporaryDirectory: () async => cache,
          idGenerator: () => 'upload-8',
        );
        final source = await _recordingFile(cache, 'source.m4a');
        final staged = await store.stage(
          source: source,
          serverId: 'server-1',
          accountId: 'user-1',
          noteId: 'note-1',
          fileName: 'recording.m4a',
        );

        final durable = File(staged.localPath);
        final completeBytes = await durable.readAsBytes();
        await durable.delete();
        final interrupted = File('${durable.parent.path}/.staging.m4a');
        await interrupted.writeAsBytes(completeBytes.take(512).toList());
        await File(
          '${cache.path}/source.m4a',
        ).writeAsBytes(completeBytes, flush: true);

        final recovered = await NoteAudioUploadStore(
          applicationSupportDirectory: () async => root,
          temporaryDirectory: () async => cache,
        ).loadForAccount(serverId: 'server-1', accountId: 'user-1');

        check(recovered).length.equals(1);
        check(recovered.single.status).equals(NoteAudioUploadStatus.failed);
        check(await File(recovered.single.localPath).length()).equals(2048);
        check(await interrupted.exists()).isFalse();
        check(await File('${cache.path}/source.m4a').exists()).isFalse();
      },
    );

    test(
      'shares upload work and lets a current editor take over attach',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'conduit_note_audio_upload_test_',
        );
        addTearDown(() => _deleteDirectory(root));

        final store = NoteAudioUploadStore(
          applicationSupportDirectory: () async => root,
          idGenerator: () => 'upload-5',
        );
        final staged = await store.stage(
          source: await _recordingFile(root, 'source.m4a'),
          serverId: 'server-1',
          noteId: 'note-1',
          fileName: 'recording.m4a',
        );

        final uploadStarted = Completer<void>();
        final finishUpload = Completer<String>();
        var uploadCalls = 0;
        var firstAttachCalls = 0;
        var replacementAttachCalls = 0;
        final first = NoteAudioUploadCoordinator(
          store: store,
          upload: (_, _) {
            uploadCalls++;
            uploadStarted.complete();
            return finishUpload.future;
          },
          attach: (_, _) async {
            firstAttachCalls++;
            throw StateError('original editor was disposed');
          },
        ).process(staged);
        await uploadStarted.future;
        check(NoteAudioUploadCoordinator.tryReserveRemoval(staged)).isFalse();

        final replacement = NoteAudioUploadCoordinator(
          store: store,
          upload: (_, _) async {
            uploadCalls++;
            return 'duplicate-file';
          },
          attach: (_, fileId) async {
            replacementAttachCalls++;
            check(fileId).equals('file-3');
          },
        ).process(staged);
        finishUpload.complete('file-3');

        check(await first).isNotNull();
        check(await replacement).isNull();
        check(uploadCalls).equals(1);
        check(firstAttachCalls).equals(1);
        check(replacementAttachCalls).equals(1);
        check(
          await store.loadForNote(serverId: 'server-1', noteId: 'note-1'),
        ).isEmpty();
      },
    );

    test(
      'reloads newer durable state before processing a stale editor item',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'conduit_note_audio_upload_test_',
        );
        addTearDown(() => _deleteDirectory(root));

        final store = NoteAudioUploadStore(
          applicationSupportDirectory: () async => root,
          idGenerator: () => 'upload-6',
        );
        final staged = await store.stage(
          source: await _recordingFile(root, 'source.m4a'),
          serverId: 'server-1',
          noteId: 'note-1',
          fileName: 'recording.m4a',
        );

        var uploadCalls = 0;
        final failedAttach = await NoteAudioUploadCoordinator(
          store: store,
          upload: (_, _) async {
            uploadCalls++;
            return 'file-6';
          },
          attach: (_, _) async => throw StateError('attach interrupted'),
        ).process(staged);
        check(failedAttach?.serverFileId).equals('file-6');

        var attachCalls = 0;
        final completed = await NoteAudioUploadCoordinator(
          store: store,
          upload: (_, _) async {
            uploadCalls++;
            return 'duplicate-file';
          },
          attach: (_, fileId) async {
            attachCalls++;
            check(fileId).equals('file-6');
          },
        ).process(staged);

        check(completed).isNull();
        check(uploadCalls).equals(1);
        check(attachCalls).equals(1);

        // A still-mounted stale editor may retry after another owner removed
        // the completed job. Missing durable state is terminal and must not be
        // recreated from its old in-memory snapshot.
        final repeated = await NoteAudioUploadCoordinator(
          store: store,
          upload: (_, _) async => fail('must not upload a completed job'),
          attach: (_, _) async => fail('must not attach a completed job'),
        ).process(staged);
        check(repeated).isNull();
        check(
          await store.loadForNote(serverId: 'server-1', noteId: 'note-1'),
        ).isEmpty();
      },
    );

    test('a removal reservation excludes processing across editors', () async {
      final root = await Directory.systemTemp.createTemp(
        'conduit_note_audio_upload_test_',
      );
      addTearDown(() => _deleteDirectory(root));

      final store = NoteAudioUploadStore(
        applicationSupportDirectory: () async => root,
        idGenerator: () => 'upload-7',
      );
      final staged = await store.stage(
        source: await _recordingFile(root, 'source.m4a'),
        serverId: 'server-1',
        noteId: 'note-1',
        fileName: 'recording.m4a',
      );

      check(NoteAudioUploadCoordinator.tryReserveRemoval(staged)).isTrue();
      late final Future<PendingNoteAudioUpload?> processing;
      try {
        processing = NoteAudioUploadCoordinator(
          store: store,
          upload: (_, _) async => fail('reserved item must not upload'),
          attach: (_, _) async => fail('reserved item must not attach'),
        ).process(staged);
        await store.remove(staged);
      } finally {
        NoteAudioUploadCoordinator.releaseRemoval(staged);
      }
      check(await processing).isNull();

      check(
        await store.loadForNote(serverId: 'server-1', noteId: 'note-1'),
      ).isEmpty();
    });

    test(
      'an account scan cannot resurrect an item removed while reading',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'conduit_note_audio_upload_test_',
        );
        addTearDown(() => _deleteDirectory(root));

        final stagingStore = NoteAudioUploadStore(
          applicationSupportDirectory: () async => root,
          idGenerator: () => 'upload-9',
        );
        final staged = await stagingStore.stage(
          source: await _recordingFile(root, 'source.m4a'),
          serverId: 'server-1',
          accountId: 'user-1',
          noteId: 'note-1',
          fileName: 'recording.m4a',
        );
        await File(staged.localPath).delete();

        final recoveryStarted = Completer<void>();
        final allowRecovery = Completer<Directory>();
        final scanningStore = NoteAudioUploadStore(
          applicationSupportDirectory: () async => root,
          temporaryDirectory: () {
            recoveryStarted.complete();
            return allowRecovery.future;
          },
        );

        final scan = scanningStore.loadForAccount(
          serverId: 'server-1',
          accountId: 'user-1',
        );
        await recoveryStarted.future;

        var removalCompleted = false;
        final removal = stagingStore
            .remove(staged)
            .then((_) => removalCompleted = true);
        await Future<void>.delayed(Duration.zero);
        check(removalCompleted).isFalse();

        allowRecovery.complete(
          await Directory.systemTemp.createTemp(
            'conduit_note_audio_empty_cache_',
          ),
        );
        final cache = await allowRecovery.future;
        addTearDown(() => _deleteDirectory(cache));
        await scan;
        await removal;

        check(await File(staged.localPath).parent.exists()).isFalse();
        check(
          await scanningStore.loadForAccount(
            serverId: 'server-1',
            accountId: 'user-1',
          ),
        ).isEmpty();
      },
    );
  });
}

Future<File> _recordingFile(Directory root, String name) async {
  final file = File('${root.path}/$name');
  await file.writeAsBytes(List<int>.filled(2048, 7), flush: true);
  return file;
}

Future<void> _deleteDirectory(Directory directory) async {
  if (await directory.exists()) {
    await directory.delete(recursive: true);
  }
}
