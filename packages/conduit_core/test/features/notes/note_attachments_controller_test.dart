import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/note_mapper.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/notes/services/deleted_note_draft_recovery.dart';
import 'package:conduit_core/features/notes/services/note_attachments_controller.dart';
import 'package:conduit_core/features/notes/services/note_audio_upload_service.dart';
import 'package:conduit_core/models/file_info.dart';
import 'package:conduit_core/models/note.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _user = User(
  id: 'user-1',
  username: 'user',
  email: 'user@example.com',
  role: 'user',
);

class _NoDrainSyncEngine extends SyncEngine {
  @override
  Future<void> drainNow() async {}

  @override
  Future<void> drainOutbox() async {}
}

class _OnlineConnectivity extends ConnectivityStatusNotifier {
  @override
  ConnectivityStatus build() => ConnectivityStatus.online;
}

class _UploadApi extends ApiService {
  _UploadApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'server-1',
          name: 'Test',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  final uploads = <({String path, String name, String? contentType})>[];
  final markers = <Object?>[];
  Object? uploadError;
  var nextId = 1;
  List<FileInfo> existingFiles = const <FileInfo>[];

  @override
  Future<String> uploadFile(
    String filePath,
    String fileName, {
    String? contentType,
    Map<String, dynamic>? metadata,
    CancelToken? cancelToken,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    final error = uploadError;
    if (error != null) throw error;
    uploads.add((path: filePath, name: fileName, contentType: contentType));
    markers.add(metadata?['conduit_upload_id']);
    return 'server-file-${nextId++}';
  }

  @override
  Future<List<FileInfo>?> searchFilesForSession({
    String? query,
    String? contentType,
    int? limit,
    int? offset,
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) async => existingFiles;
}

void main() {
  late Directory root;
  late AppDatabase db;
  late _UploadApi api;
  late ProviderContainer container;
  late NoteAudioUploadStore store;
  late Note openNote;
  late List<Note> updates;
  late List<NoteAudioNotice> notices;
  late int changes;
  late NoteAttachmentsController controller;

  Future<Note> readNote(String id) async {
    final row = await db.notesDao.getNote(id);
    return Note.fromJson(noteRowToServer(row!));
  }

  Future<File> recording(String name, {int bytes = 4096}) async {
    final file = File('${root.path}/cache/$name');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(bytes, 7));
    return file;
  }

  Future<void> waitFor(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('waitFor timed out');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('conduit_note_attach_test_');
    db = AppDatabase(NativeDatabase.memory());
    await db
        .into(db.notes)
        .insertOnConflictUpdate(
          serverToNoteRow({
            'id': 'note-1',
            'user_id': 'user-1',
            'title': 'Meeting',
            'data': {
              'content': {'md': 'hello', 'html': ''},
              'files': [
                {'type': 'file', 'id': 'old-file', 'name': 'old.pdf'},
              ],
            },
            'meta': {},
            'is_pinned': false,
            'created_at': 1713786305000000000,
            'updated_at': 1713786305000000000,
          }),
        );
    api = _UploadApi();
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => db),
        apiServiceProvider.overrideWithValue(api),
        isAuthenticatedProvider2.overrideWithValue(true),
        currentUserProvider2.overrideWithValue(_user),
        connectivityStatusProvider.overrideWith(_OnlineConnectivity.new),
        syncEngineProvider.overrideWith(_NoDrainSyncEngine.new),
      ],
    );
    store = NoteAudioUploadStore(
      applicationSupportDirectory: () async {
        final dir = Directory('${root.path}/support');
        await dir.create(recursive: true);
        return dir;
      },
      temporaryDirectory: () async => Directory('${root.path}/cache'),
    );
    openNote = await readNote('note-1');
    updates = <Note>[];
    notices = <NoteAudioNotice>[];
    changes = 0;
    controller = NoteAttachmentsController(
      container: container,
      store: store,
      noteId: 'note-1',
      currentNote: () => openNote,
      resolvedTitle: () => openNote.title,
      onNoteUpdated: (updated) {
        openNote = updated;
        updates.add(updated);
      },
      onChanged: () => changes++,
      onNotice: notices.add,
    )..start();
  });

  tearDown(() async {
    controller.dispose();
    container.dispose();
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  group('NoteAttachmentsController', () {
    test('stages, uploads and attaches a WAV recording', () async {
      final file = await recording('note_recording_1.wav');
      check(await controller.stage(file)).isTrue();
      check(controller.pending).length.equals(1);

      await waitFor(() => notices.isNotEmpty && controller.pending.isEmpty);

      check(notices)
          .deepEquals(<NoteAudioNotice>[NoteAudioNotice.recordingSaved]);
      check(api.uploads).length.equals(1);
      final uploadedName = api.uploads.single.name;
      check(uploadedName).startsWith('recording_');
      check(uploadedName).endsWith('.wav');
      check(api.uploads.single.contentType).equals('audio/wav');
      check(await file.exists()).isFalse();

      final stored = await readNote('note-1');
      final files = stored.data.files!;
      check(files.map((f) => f['id']))
          .deepEquals(<Object?>['old-file', 'server-file-1']);
      check(files.last['name']).equals(api.uploads.single.name);
      check(files.last['itemId']).equals(api.markers.single);
      check(updates).isNotEmpty();
      check(openNote.data.files!.length).equals(2);
      check(controller.isUploading).isFalse();
    });

    test('a failed upload keeps the recording for a retry', () async {
      api.uploadError = DioException(
        requestOptions: RequestOptions(path: '/api/v1/files/'),
        type: DioExceptionType.connectionError,
      );
      check(await controller.stage(await recording('a.m4a'))).isTrue();
      await waitFor(() => notices.isNotEmpty && !controller.isUploading);

      check(notices)
          .deepEquals(<NoteAudioNotice>[NoteAudioNotice.uploadFailed]);
      check(controller.pending).length.equals(1);
      check(controller.pending.single.status)
          .equals(NoteAudioUploadStatus.failed);
      check(controller.isInFlight(controller.pending.single.id)).isFalse();
      check(api.uploads).isEmpty();

      api.uploadError = null;
      await controller.retry(showFeedback: true);

      check(controller.pending).isEmpty();
      check(notices.last).equals(NoteAudioNotice.recordingSaved);
      check(api.uploads.single.contentType).equals('audio/mp4');
      check((await readNote('note-1')).data.files!.length).equals(2);
    });

    test('a retry adopts the file a lost response already created', () async {
      api.uploadError = DioException(
        requestOptions: RequestOptions(path: '/api/v1/files/'),
        type: DioExceptionType.connectionError,
      );
      await controller.stage(await recording('a.m4a', bytes: 2048));
      await waitFor(() => notices.isNotEmpty && !controller.isUploading);
      final pending = controller.pending.single;

      api.uploadError = null;
      api.existingFiles = <FileInfo>[
        FileInfo(
          id: 'server-owned',
          filename: pending.fileName,
          originalFilename: pending.fileName,
          size: pending.fileSize,
          mimeType: 'audio/mp4',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          metadata: <String, dynamic>{
            'data': <String, dynamic>{'conduit_upload_id': pending.id},
          },
        ),
      ];
      await controller.retry();

      check(api.uploads).isEmpty();
      check((await readNote('note-1')).data.files!.map((f) => f['id']))
          .contains('server-owned');
      check(controller.pending).isEmpty();
    });

    test('a pending recording can be removed before it uploads', () async {
      api.uploadError = StateError('offline');
      await controller.stage(await recording('a.m4a'));
      await waitFor(() => notices.isNotEmpty && !controller.isUploading);
      final id = controller.pending.single.id;

      await controller.removePending(id);

      check(controller.pending).isEmpty();
      check(notices.last).equals(NoteAudioNotice.removed);
      final leftover = await store.loadForNote(
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
      );
      check(leftover).isEmpty();
    });

    test('loadPending finds recordings staged by an earlier run', () async {
      final staged = await store.stage(
        source: await recording('old.m4a'),
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
        fileName: 'recording_9.m4a',
      );
      api.uploadError = StateError('offline');

      await controller.loadPending();
      check(controller.pending.map((p) => p.id)).contains(staged.id);
      await waitFor(() => !controller.isUploading && notices.isEmpty);
      check(controller.pending.single.status)
          .equals(NoteAudioUploadStatus.failed);
    });

    test('removeAttachedFile drops the entry from the note', () async {
      final updated = await controller.removeAttachedFile('old-file');
      check(updated).isNotNull();
      check(updated!.data.files).isNotNull().isEmpty();
      check((await readNote('note-1')).data.files).isNotNull().isEmpty();
    });

    test('a recording staged for another note is not attached here', () async {
      final loaded = await store.stage(
        source: await recording('other.m4a'),
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-2',
        fileName: 'recording_1.m4a',
      );
      await controller.loadPending();
      check(controller.pending.map((p) => p.id))
          .not((it) => it.contains(loaded.id));
    });
  });

  group('DeletedNoteDraftRecovery', () {
    test('saves the draft as a new note and moves the recordings', () async {
      api.uploadError = StateError('offline');
      await controller.stage(await recording('a.m4a'));
      await waitFor(() => notices.isNotEmpty && !controller.isUploading);
      final pendingId = controller.pending.single.id;

      // The server deleted the note: sync purged the local row.
      await db.notesDao.purgeReconciledNote('note-1');
      check(await db.notesDao.getNote('note-1')).isNull();

      const title = 'Meeting notes';
      const markdown = 'hello\n\nunsaved edit';
      final recovered = <Note>[];
      var failures = 0;
      final recovery = DeletedNoteDraftRecovery(
        container: container,
        noteId: 'note-1',
        attachments: controller,
        currentNote: () => openNote,
        readDraft: () => (title: title, markdown: markdown),
        untitledTitle: () => 'Untitled',
        isOpen: () => true,
        hasUnsavedChanges: () => true,
        cancelPendingSave: () {},
        scheduleSaveAfter: (delay, action) {},
        saveSoon: () {},
        onRecovered:
            ({
              required Note note,
              required String savedMarkdown,
              required bool changedDuringRecovery,
            }) {
              recovered.add(note);
              openNote = note;
              check(changedDuringRecovery).isFalse();
              check(savedMarkdown).equals('hello\n\nunsaved edit');
            },
        onFailure: () => failures++,
      )..start();
      addTearDown(recovery.dispose);
      api.uploadError = null;

      await recovery.recover(NoteRecoverySession.capture(container));

      check(failures).equals(0);
      check(recovered).length.equals(1);
      final created = recovered.single;
      check(created.id).startsWith('local:');
      check(created.title).equals('Meeting notes');
      check(created.markdownContent).equals('hello\n\nunsaved edit');
      // The deleted note's other data (its files) travels with the draft.
      check(created.data.files!.map((f) => f['id'])).contains('old-file');
      check(recovery.pendingRetry).isNull();

      // The recording followed the note and was attached to it.
      await waitFor(() => controller.pending.isEmpty);
      final recoveredRow = await db.notesDao.getNote(created.id);
      check(recoveredRow).isNotNull();
      final files = (await readNote(created.id)).data.files!;
      check(files.map((f) => f['itemId'])).contains(pendingId);
      final stale = await store.loadForNote(
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
      );
      check(stale).isEmpty();
    });

    test('an empty title falls back to the untitled name', () async {
      await db.notesDao.purgeReconciledNote('note-1');
      final recovered = <Note>[];
      final recovery = DeletedNoteDraftRecovery(
        container: container,
        noteId: 'note-1',
        attachments: controller,
        currentNote: () => openNote,
        readDraft: () => (title: '  ', markdown: 'body'),
        untitledTitle: () => 'Untitled',
        isOpen: () => true,
        hasUnsavedChanges: () => true,
        cancelPendingSave: () {},
        scheduleSaveAfter: (delay, action) {},
        saveSoon: () {},
        onRecovered: ({
          required Note note,
          required String savedMarkdown,
          required bool changedDuringRecovery,
        }) => recovered.add(note),
        onFailure: () {},
      )..start();
      addTearDown(recovery.dispose);

      await recovery.recover(NoteRecoverySession.capture(container));

      check(recovered.single.title).equals('Untitled');
    });

    test('a draft edited during the recovery is saved again', () async {
      await db.notesDao.purgeReconciledNote('note-1');
      var markdown = 'first';
      var savedAgain = 0;
      bool? changed;
      final recovery = DeletedNoteDraftRecovery(
        container: container,
        noteId: 'note-1',
        attachments: controller,
        currentNote: () => openNote,
        readDraft: () {
          // The user keeps typing while the recovered note is created.
          final snapshot = (title: 'T', markdown: markdown);
          markdown = '$markdown!';
          return snapshot;
        },
        untitledTitle: () => 'Untitled',
        isOpen: () => true,
        hasUnsavedChanges: () => true,
        cancelPendingSave: () {},
        scheduleSaveAfter: (delay, action) {},
        saveSoon: () => savedAgain++,
        onRecovered: ({
          required Note note,
          required String savedMarkdown,
          required bool changedDuringRecovery,
        }) => changed = changedDuringRecovery,
        onFailure: () {},
      )..start();
      addTearDown(recovery.dispose);

      await recovery.recover(NoteRecoverySession.capture(container));

      check(changed).equals(true);
      check(savedAgain).equals(1);
    });
  });

  group('noteContentData', () {
    test('leaves html empty so Open WebUI derives it from the markdown', () {
      check(noteContentData('# Hi')).deepEquals(<String, dynamic>{
        'content': <String, dynamic>{'json': null, 'html': '', 'md': '# Hi'},
      });
    });
  });

  group('uploadedNoteAudioFileId', () {
    PendingNoteAudioUpload item() => PendingNoteAudioUpload(
      id: 'u1',
      serverScope: 's',
      accountScope: 'a',
      noteId: 'n',
      localPath: '/x/recording.m4a',
      fileName: 'rec.m4a',
      fileSize: 10,
      status: NoteAudioUploadStatus.failed,
      createdAt: DateTime(2026),
    );

    FileInfo file(
      String id, {
      String marker = 'u1',
      DateTime? at,
      int size = 10,
    }) => FileInfo(
      id: id,
      filename: 'rec.m4a',
      originalFilename: 'rec.m4a',
      size: size,
      mimeType: 'audio/mp4',
      createdAt: at ?? DateTime(2026),
      updatedAt: DateTime(2026),
      metadata: <String, dynamic>{'conduit_upload_id': marker},
    );

    test('matches the marker, name and size, newest first', () {
      final result = uploadedNoteAudioFileId(<FileInfo>[
        file('older', at: DateTime(2025)),
        file('newer', at: DateTime(2026, 6)),
        file('other-marker', marker: 'zzz'),
        file('wrong-size', size: 11),
      ], item());
      check(result).equals('newer');
    });

    test('is null with no match', () {
      check(uploadedNoteAudioFileId(<FileInfo>[file('x', marker: 'q')], item()))
          .isNull();
    });
  });
}
