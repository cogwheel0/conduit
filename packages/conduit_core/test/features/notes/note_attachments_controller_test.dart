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
import 'package:conduit_core/features/notes/utils/note_page_data.dart';
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

/// A stand-in for the auth session epoch that a test can rotate, as
/// signing out and in as another user does.
final _testEpochProvider = NotifierProvider<_TestEpoch, Object>(_TestEpoch.new);

class _TestEpoch extends Notifier<Object> {
  @override
  Object build() => Object();

  void rotate() => state = Object();
}

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

  /// While set, an upload is answered only once this completes.
  Completer<void>? holdUpload;
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
    await holdUpload?.future;
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

/// A store whose account-wide scan waits until the test lets it finish.
class _HeldScanStore extends NoteAudioUploadStore {
  _HeldScanStore({
    required super.applicationSupportDirectory,
    required super.temporaryDirectory,
  });

  final entered = Completer<void>();
  final release = Completer<void>();

  /// While set, a scan of one note's recordings waits for it too.
  Completer<void>? holdNoteScan;
  final noteScanEntered = Completer<void>();

  /// While set, moving a recording to another note waits for it.
  Completer<void>? holdRebind;
  final rebindEntered = Completer<void>();

  /// While set, reading a recording's current copy waits for it; with
  /// [holdLoadCurrentOfNote], only a copy on that note waits.
  Completer<void>? holdLoadCurrent;
  String? holdLoadCurrentOfNote;
  final loadCurrentEntered = Completer<void>();

  /// A note whose recordings cannot be read: reading one throws.
  String? failLoadCurrentOfNote;

  /// While set, a read that finds a recording gone waits for it to answer.
  Completer<void>? holdGoneAnswer;
  final goneAnswerHeld = Completer<void>();

  /// While set, a read that would find a recording gone throws instead.
  bool failGoneAnswer = false;

  @override
  Future<PendingNoteAudioUpload?> loadCurrent(
    PendingNoteAudioUpload item,
  ) async {
    if (item.noteId == failLoadCurrentOfNote) {
      throw StateError('unreadable recording manifest');
    }
    final hold = holdLoadCurrent;
    final of = holdLoadCurrentOfNote;
    if (hold != null && (of == null || item.noteId == of)) {
      if (!loadCurrentEntered.isCompleted) loadCurrentEntered.complete();
      await hold.future;
    }
    final PendingNoteAudioUpload? current = await super.loadCurrent(item);
    if (current == null && failGoneAnswer) {
      throw StateError('unreadable recording manifest');
    }
    final goneHold = holdGoneAnswer;
    if (current == null && goneHold != null) {
      if (!goneAnswerHeld.isCompleted) goneAnswerHeld.complete();
      await goneHold.future;
    }
    return current;
  }

  @override
  Future<PendingNoteAudioUpload?> rebindToNote(
    PendingNoteAudioUpload item, {
    required String noteId,
  }) async {
    final hold = holdRebind;
    if (hold != null) {
      if (!rebindEntered.isCompleted) rebindEntered.complete();
      await hold.future;
    }
    return super.rebindToNote(item, noteId: noteId);
  }

  @override
  Future<List<PendingNoteAudioUpload>> loadForAccount({
    required String serverId,
    String accountId = '',
  }) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return super.loadForAccount(serverId: serverId, accountId: accountId);
  }

  @override
  Future<List<PendingNoteAudioUpload>> loadForNote({
    required String serverId,
    String accountId = '',
    required String noteId,
  }) async {
    final hold = holdNoteScan;
    if (hold != null) {
      if (!noteScanEntered.isCompleted) noteScanEntered.complete();
      await hold.future;
    }
    return super.loadForNote(
      serverId: serverId,
      accountId: accountId,
      noteId: noteId,
    );
  }
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
        openWebUiAuthSessionEpochProvider.overrideWith(
          (ref) => ref.watch(_testEpochProvider),
        ),
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

    test('on a 0.12.5 note a recording is linked from the page content, '
        'not added to a file list', () async {
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'note-1',
              'user_id': 'user-1',
              'title': 'Meeting',
              'data': {
                // Last saved from the web editor, which keeps JSON and HTML.
                'content': {
                  'json': {'type': 'doc'},
                  'md': 'hello',
                  'html': '<p>hello</p>',
                },
                'pages': [
                  {
                    'id': 'main',
                    'title': 'Meeting',
                    'content': {
                      'json': {'type': 'doc'},
                      'md': 'hello',
                      'html': '<p>hello</p>',
                    },
                  },
                ],
                'pages_revision': 0,
                'search_text': 'Meeting\nhello',
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );
      openNote = await readNote('note-1');
      check(openNote.data.hasPages).isTrue();

      final file = await recording('note_recording_1.wav');
      final fileSize = await file.length();
      check(await controller.stage(file)).isTrue();
      await waitFor(() => notices.isNotEmpty && controller.pending.isEmpty);

      check(notices)
          .deepEquals(<NoteAudioNotice>[NoteAudioNotice.recordingSaved]);
      final name = api.uploads.single.name;
      final row = (await db.notesDao.getNote('note-1'))!;
      final data = decodeNoteData(row.data);
      check(data.keys).not((it) => it.contains('files'));
      const href = '/api/v1/files/server-file-1/content';
      final content = notePageContent(data, kNoteMainPageId)!;
      check(content['md']).equals('hello\n\n[$name]($href)');
      // The server and the web editor read JSON, then HTML, before markdown:
      // the file is linked in each, and the rich text the web editor saved
      // stays as it was.
      check(content['html']).equals(
        '<p>hello</p><div data-file-id="server-file-1">'
        '<a href="$href">$name</a></div>',
      );
      check(content['json']).isA<Map<String, dynamic>>().deepEquals({
        'type': 'doc',
        'content': [
          {
            'type': 'fileAttachment',
            'attrs': {'id': 'server-file-1', 'name': name, 'size': fileSize},
          },
        ],
      });
      check(noteDirtyPageIds(data)).deepEquals([kNoteMainPageId]);
      check(row.dirtyData).isTrue();
      check(openNote.markdownContent).endsWith(
        '[$name](/api/v1/files/server-file-1/content)',
      );
    });

    test('a note that gained pages takes the recording on its main page',
        () async {
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'note-1',
              'user_id': 'user-1',
              'title': 'Meeting',
              'data': {
                'content': {'json': null, 'md': '## Meeting', 'html': ''},
                'pages': [
                  {
                    'id': 'main',
                    'title': 'Meeting',
                    'content': {'json': null, 'md': 'one', 'html': ''},
                  },
                  {
                    'id': 'p2',
                    'title': 'Two',
                    'content': {'json': null, 'md': 'two', 'html': ''},
                  },
                ],
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );
      openNote = await readNote('note-1');

      final file = await recording('note_recording_1.wav');
      check(await controller.stage(file)).isTrue();
      await waitFor(() => notices.isNotEmpty && controller.pending.isEmpty);

      check(notices)
          .deepEquals(<NoteAudioNotice>[NoteAudioNotice.recordingSaved]);
      final data = decodeNoteData((await db.notesDao.getNote('note-1'))!.data);
      check(notePageMarkdown(data, 'main')).startsWith('one\n\n[');
      check(notePageMarkdown(data, 'p2')).equals('two');
      check(noteDirtyPageIds(data)).deepEquals(['main']);
    });

    test('a recording is attached to the page it was made on', () async {
      var shownPage = 'p2';
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'note-1',
              'user_id': 'user-1',
              'title': 'Meeting',
              'data': {
                'content': {'json': null, 'md': '## Meeting', 'html': ''},
                'pages': [
                  {
                    'id': 'main',
                    'title': 'Meeting',
                    'content': {'json': null, 'md': 'one', 'html': ''},
                  },
                  {
                    'id': 'p2',
                    'title': 'Two',
                    'content': {'json': null, 'md': 'two', 'html': ''},
                  },
                ],
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );
      openNote = await readNote('note-1');
      controller.dispose();
      controller = NoteAttachmentsController(
        container: container,
        store: store,
        noteId: 'note-1',
        currentNote: () => openNote,
        resolvedTitle: () => openNote.title,
        onNoteUpdated: (updated) => openNote = updated,
        onChanged: () => changes++,
        onNotice: notices.add,
        currentPageId: () => shownPage,
      )..start();

      final file = await recording('note_recording_1.wav');
      check(await controller.stage(file)).isTrue();
      // The user moves to the main page while the recording uploads; it was
      // made on the second page, and goes there.
      shownPage = 'main';
      await waitFor(() => notices.isNotEmpty && controller.pending.isEmpty);

      final data = decodeNoteData((await db.notesDao.getNote('note-1'))!.data);
      check(notePageMarkdown(data, 'main')).equals('one');
      check(notePageMarkdown(data, 'p2')).startsWith('two\n\n[');
      check(noteDirtyPageIds(data)).deepEquals(['p2']);
    });

    Future<void> storeTwoPages({required String main, required String two}) {
      return db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'note-1',
              'user_id': 'user-1',
              'title': 'Meeting',
              'data': {
                'content': {'json': null, 'md': '## Meeting', 'html': ''},
                'pages': [
                  {
                    'id': 'main',
                    'title': 'Meeting',
                    'content': {'json': null, 'md': main, 'html': ''},
                  },
                  {
                    'id': 'p2',
                    'title': 'Two',
                    'content': {'json': null, 'md': two, 'html': ''},
                  },
                ],
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );
    }

    NoteAttachmentsController showingPages(String? Function() page) {
      controller.dispose();
      return controller = NoteAttachmentsController(
        container: container,
        store: store,
        noteId: 'note-1',
        currentNote: () => openNote,
        resolvedTitle: () => openNote.title,
        onNoteUpdated: (updated) => openNote = updated,
        onChanged: () => changes++,
        onNotice: notices.add,
        currentPageId: page,
      )..start();
    }

    test('a recording goes to the page it was started on, even when the page '
        'shown changed before it was kept', () async {
      await storeTwoPages(main: 'one', two: 'two');
      openNote = await readNote('note-1');
      // Recording began on the second page; a page switch finished while the
      // recorder was open.
      showingPages(() => 'main');

      final file = await recording('note_recording_1.wav');
      check(await controller.stage(file, pageId: 'p2')).isTrue();
      await waitFor(() => notices.isNotEmpty && controller.pending.isEmpty);

      final data = decodeNoteData((await db.notesDao.getNote('note-1'))!.data);
      check(notePageMarkdown(data, 'main')).equals('one');
      check(notePageMarkdown(data, 'p2')).startsWith('two\n\n[');
    });

    test('a recording staged before pages were known goes to the main page, '
        'not the page shown', () async {
      await storeTwoPages(main: 'one', two: 'two');
      openNote = await readNote('note-1');
      showingPages(() => 'p2');
      await store.stage(
        source: await recording('old.m4a'),
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
        fileName: 'recording_9.m4a',
      );

      await controller.loadPending();
      check(controller.pending).isNotEmpty();
      // A recording from an earlier run attaches without a notice.
      await waitFor(
        () => controller.pending.isEmpty && !controller.isUploading,
      );

      final data = decodeNoteData((await db.notesDao.getNote('note-1'))!.data);
      check(notePageMarkdown(data, 'main')).startsWith('one\n\n[');
      check(notePageMarkdown(data, 'p2')).equals('two');
    });

    test('a file removed from a page a sync has removed leaves the other '
        'pages alone', () async {
      const link = '[f.pdf](/api/v1/files/f/content)';
      await storeTwoPages(main: 'one\n\n$link', two: 'two\n\n$link');
      // The editor shows the second page as it was read.
      openNote = await readNote('note-1');
      showingPages(() => 'p2');
      // A sync then stores the note without that page.
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'note-1',
              'user_id': 'user-1',
              'title': 'Meeting',
              'data': {
                'content': {'json': null, 'md': 'one\n\n$link', 'html': ''},
                'pages': [
                  {
                    'id': 'main',
                    'title': 'Meeting',
                    'content': {
                      'json': null,
                      'md': 'one\n\n$link',
                      'html': '',
                    },
                  },
                ],
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );

      check(await controller.removeAttachedFile('f')).isNotNull();

      final data = decodeNoteData((await db.notesDao.getNote('note-1'))!.data);
      check(notePageMarkdown(data, 'main')).equals('one\n\n$link');
    });

    test('a file is removed from the page shown when the removal started',
        () async {
      const link = '[f.pdf](/api/v1/files/f/content)';
      await storeTwoPages(main: 'one\n\n$link', two: 'two\n\n$link');
      openNote = await readNote('note-1');
      // The editor moves to the main page while the removal runs.
      var reads = 0;
      showingPages(() => reads++ == 0 ? 'p2' : 'main');

      check(await controller.removeAttachedFile('f')).isNotNull();

      final data = decodeNoteData((await db.notesDao.getNote('note-1'))!.data);
      check(notePageMarkdown(data, 'p2')).equals('two');
      check(notePageMarkdown(data, 'main')).equals('one\n\n$link');
    });

    test('a note stored in the older shape is linked when the server is '
        'known to be 0.12.5', () async {
      container.dispose();
      container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          apiServiceProvider.overrideWithValue(api),
          isAuthenticatedProvider2.overrideWithValue(true),
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => ref.watch(_testEpochProvider),
          ),
          currentUserProvider2.overrideWithValue(_user),
          connectivityStatusProvider.overrideWith(_OnlineConnectivity.new),
          syncEngineProvider.overrideWith(_NoDrainSyncEngine.new),
          notePagesServerProvider.overrideWithValue(true),
        ],
      );
      controller.dispose();
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

      final file = await recording('note_recording_1.wav');
      check(await controller.stage(file)).isTrue();
      await waitFor(() => notices.isNotEmpty && controller.pending.isEmpty);

      final data = decodeNoteData((await db.notesDao.getNote('note-1'))!.data);
      // The old list is left for the next save to move; the new recording
      // is a link already.
      check(data['files'] as List).length.equals(1);
      check((data['content'] as Map)['md'] as String)
          .endsWith('(/api/v1/files/server-file-1/content)');
    });

    test('removing a file the page still lists from its old copy takes the '
        'link out of the stored note', () async {
      // The page opened the note in its older shape, with old-file listed; a
      // save since moved the file into the content as a link and the stored
      // note took the server's pages.
      check(openNote.data.files!.single['id']).equals('old-file');
      const link = '[old.pdf](/api/v1/files/old-file/content)';
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'note-1',
              'user_id': 'user-1',
              'title': 'Meeting',
              'data': {
                'content': {'json': null, 'md': 'hello\n\n$link', 'html': ''},
                'pages': [
                  {
                    'id': 'main',
                    'title': 'Meeting',
                    'content': {
                      'json': null,
                      'md': 'hello\n\n$link',
                      'html': '',
                    },
                  },
                ],
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );

      final updated = await controller.removeAttachedFile('old-file');

      check(updated).isNotNull();
      final data = decodeNoteData((await db.notesDao.getNote('note-1'))!.data);
      check(notePageMarkdown(data, kNoteMainPageId)).equals('hello');
      check(data.keys).not((it) => it.contains('files'));
      check(noteDirtyPageIds(data)).deepEquals([kNoteMainPageId]);
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

    test(
      'removeAttachedFile keeps a file attached after the note was read',
      () async {
        // The editor's snapshot (openNote) lists only old-file; a recording
        // finished since and is already in the stored row.
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
                    {'type': 'file', 'id': 'new-file', 'name': 'new.m4a'},
                  ],
                },
                'meta': {},
                'is_pinned': false,
                'created_at': 1713786305000000000,
                'updated_at': 1713786305000000000,
              }),
            );
        check(openNote.data.files!.map((f) => f['id']))
            .deepEquals(['old-file']);

        final updated = await controller.removeAttachedFile('old-file');

        check(updated).isNotNull();
        check(updated!.data.files!.map((f) => f['id']))
            .deepEquals(['new-file']);
        check((await readNote('note-1')).data.files!.map((f) => f['id']))
            .deepEquals(['new-file']);
      },
    );

    test(
      'removeAttachedFile returns nothing when the session changed meanwhile',
      () async {
        final removal = controller.removeAttachedFile('old-file');
        // The account changes while the removal is in flight.
        container.read(_testEpochProvider.notifier).rotate();

        check(await removal).isNull();
      },
    );

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

    test('saving a removed page as its own note moves only that page\'s '
        'recordings', () async {
      api.uploadError = StateError('offline');
      final onRemoved = await store.stage(
        source: await recording('two.m4a'),
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
        fileName: 'recording_2.m4a',
        pageId: 'p2',
      );
      final onMain = await store.stage(
        source: await recording('main.m4a'),
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
        fileName: 'recording_1.m4a',
      );
      await controller.loadPending();
      await waitFor(
        () => controller.pending.length == 2 && !controller.isUploading,
      );

      final recovered = <Note>[];
      final recovery = DeletedNoteDraftRecovery(
        container: container,
        noteId: 'note-1',
        attachments: controller,
        currentNote: () => openNote,
        readDraft: () => (title: 'Two', markdown: 'two, kept'),
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
            },
        onFailure: () {},
      )..start();
      addTearDown(recovery.dispose);

      await recovery.recover(
        NoteRecoverySession.capture(container),
        pageId: 'p2',
      );

      check(recovered).length.equals(1);
      final left = await store.loadForNote(
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
      );
      check(left.map((item) => item.id)).deepEquals([onMain.id]);
      final moved = await store.loadForNote(
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: recovered.single.id,
      );
      check(moved.map((item) => item.id)).deepEquals([onRemoved.id]);
      // The main page's recording waits for its note, not for this editor,
      // which shows the new note now: looking again does not bring it back.
      check(controller.pending.map((item) => item.id)).deepEquals([
        onRemoved.id,
      ]);
      await controller.loadPending();
      check(controller.pending.map((item) => item.id)).deepEquals([
        onRemoved.id,
      ]);
      await waitFor(() => !controller.isUploading);
    });

    test('a scan begun before a page was recovered does not bring the other '
        'pages\' recordings back', () async {
      api.uploadError = StateError('offline');
      await store.stage(
        source: await recording('two.m4a'),
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
        fileName: 'recording_2.m4a',
        pageId: 'p2',
      );
      final onMain = await store.stage(
        source: await recording('main.m4a'),
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
        fileName: 'recording_1.m4a',
      );

      // A scan is under way when the page is saved as a note of its own, and
      // ends after it.
      final held = _HeldScanStore(
        applicationSupportDirectory: () async {
          final dir = Directory('${root.path}/support');
          await dir.create(recursive: true);
          return dir;
        },
        temporaryDirectory: () async => Directory('${root.path}/cache'),
      );
      controller.dispose();
      controller = NoteAttachmentsController(
        container: container,
        store: held,
        noteId: 'note-1',
        currentNote: () => openNote,
        resolvedTitle: () => openNote.title,
        onNoteUpdated: (updated) => openNote = updated,
        onChanged: () => changes++,
        onNotice: notices.add,
      )..start();
      final scanning = controller.loadPending();
      await held.entered.future;
      final previous = openNote;
      final recovered = openNote.copyWith(id: 'local:recovered');
      openNote = recovered;
      await controller.rebindTo(previous, recovered, pageId: 'p2');
      held.release.complete();
      await scanning;
      await waitFor(() => !controller.isUploading);

      check(
        controller.pending.map((item) => item.id),
      ).not((it) => it.contains(onMain.id));
      final left = await store.loadForNote(
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
      );
      check(left.map((item) => item.id)).deepEquals([onMain.id]);
    });

    test('a later recovery of the new note leaves the recordings the first '
        'one kept with the original note', () async {
      api.uploadError = StateError('offline');
      await store.stage(
        source: await recording('two.m4a'),
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
        fileName: 'recording_2.m4a',
        pageId: 'p2',
      );
      final onMain = await store.stage(
        source: await recording('main.m4a'),
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
        fileName: 'recording_1.m4a',
      );
      await controller.loadPending();
      await waitFor(
        () => controller.pending.length == 2 && !controller.isUploading,
      );

      final original = openNote;
      final pageNote = openNote.copyWith(id: 'local:page');
      openNote = pageNote;
      await controller.rebindTo(original, pageNote, pageId: 'p2');
      // The server then deletes the new note, whose draft is recovered too.
      final again = openNote.copyWith(id: 'local:again');
      openNote = again;
      await controller.rebindTo(pageNote, again);
      await waitFor(() => !controller.isUploading);

      final left = await store.loadForNote(
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
      );
      check(left.map((item) => item.id)).deepEquals([onMain.id]);
    });

    test('an upload still running for a recording the original note keeps '
        'does not come back to the editor', () async {
      final onMain = await store.stage(
        source: await recording('main.m4a'),
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
        fileName: 'recording_1.m4a',
      );
      await store.stage(
        source: await recording('two.m4a'),
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
        fileName: 'recording_2.m4a',
        pageId: 'p2',
      );
      api.holdUpload = Completer<void>();
      await controller.loadPending();
      await waitFor(() => api.holdUpload != null && controller.isUploading);

      final original = openNote;
      final pageNote = openNote.copyWith(id: 'local:page');
      openNote = pageNote;
      await controller.rebindTo(original, pageNote, pageId: 'p2');
      api.holdUpload!.complete();
      api.uploadError = StateError('offline');
      await waitFor(() => !controller.isUploading);

      check(
        controller.pending.map((item) => item.id),
      ).not((it) => it.contains(onMain.id));
    });

    test('an upload that reaches its attach while a page recovery runs does '
        'not attach to the new note', () async {
      final held = _HeldScanStore(
        applicationSupportDirectory: () async {
          final dir = Directory('${root.path}/support');
          await dir.create(recursive: true);
          return dir;
        },
        temporaryDirectory: () async => Directory('${root.path}/cache'),
      )..release.complete();
      controller.dispose();
      controller = NoteAttachmentsController(
        container: container,
        store: held,
        noteId: 'note-1',
        currentNote: () => openNote,
        resolvedTitle: () => openNote.title,
        onNoteUpdated: (updated) => openNote = updated,
        onChanged: () => changes++,
        onNotice: notices.add,
      )..start();
      await held.stage(
        source: await recording('main.m4a'),
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
        fileName: 'recording_1.m4a',
      );
      // The new note, as the recovery stores it.
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'local:page',
              'user_id': 'user-1',
              'title': 'Two',
              'data': {
                'content': {'md': 'two', 'html': ''},
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );
      api.holdUpload = Completer<void>();
      await controller.loadPending();
      await waitFor(() => controller.isUploading);

      // The recovery stops partway, as the upload finishes.
      held.holdNoteScan = Completer<void>();
      final original = openNote;
      final pageNote = await readNote('local:page');
      openNote = pageNote;
      final rebinding = controller.rebindTo(original, pageNote, pageId: 'p2');
      await held.noteScanEntered.future;
      api.holdUpload!.complete();
      // The upload, and its attach, are over before the recovery goes on.
      await waitFor(() => !controller.isUploading);
      held.holdNoteScan!.complete();
      await rebinding;
      await waitFor(() => !controller.isUploading);

      final stored = await readNote('local:page');
      check(stored.data.files ?? const <Map<String, dynamic>>[]).isEmpty();
      check(stored.markdownContent).equals('two');
    });

    test('a recording moved off a removed page can still attach when a retry '
        'runs during the move', () async {
      final held = _HeldScanStore(
        applicationSupportDirectory: () async {
          final dir = Directory('${root.path}/support');
          await dir.create(recursive: true);
          return dir;
        },
        temporaryDirectory: () async => Directory('${root.path}/cache'),
      )..release.complete();
      controller.dispose();
      controller = NoteAttachmentsController(
        container: container,
        store: held,
        noteId: 'note-1',
        currentNote: () => openNote,
        resolvedTitle: () => openNote.title,
        onNoteUpdated: (updated) => openNote = updated,
        onChanged: () => changes++,
        onNotice: notices.add,
      )..start();
      // A recording made on the page a sync removes, whose upload failed.
      api.uploadError = StateError('offline');
      final onRemoved = await held.stage(
        source: await recording('two.m4a'),
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
        fileName: 'recording_2.m4a',
        pageId: 'p2',
      );
      await controller.loadPending();
      await waitFor(
        () => controller.pending.length == 1 && !controller.isUploading,
      );
      // The new note, as the recovery stores it.
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'local:page',
              'user_id': 'user-1',
              'title': 'Two',
              'data': {
                'content': {'md': 'two', 'html': ''},
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );

      // The connection returns while the recording is being moved, and it is
      // retried: the retry waits for the move and publishes the moved copy,
      // which is on the new note's main page, before the move ends.
      api.uploadError = null;
      held.holdRebind = Completer<void>();
      final original = openNote;
      final pageNote = await readNote('local:page');
      openNote = pageNote;
      final rebinding = controller.rebindTo(original, pageNote, pageId: 'p2');
      await held.rebindEntered.future;
      final retrying = controller.retry();
      held.holdRebind!.complete();
      await rebinding;
      await retrying;
      check(controller.pending.map((item) => item.id)).deepEquals([
        onRemoved.id,
      ]);

      // It is the new note's recording: retried, it attaches there.
      await controller.retry();
      await waitFor(() => !controller.isUploading);
      final stored = await readNote('local:page');
      check(stored.data.files ?? const <Map<String, dynamic>>[]).length
          .equals(1);
      check(controller.pending).isEmpty();
    });

    test('a recording retried after its move, while the move goes on, '
        'stays to be attached', () async {
      final held = _HeldScanStore(
        applicationSupportDirectory: () async {
          final dir = Directory('${root.path}/support');
          await dir.create(recursive: true);
          return dir;
        },
        temporaryDirectory: () async => Directory('${root.path}/cache'),
      )..release.complete();
      controller.dispose();
      controller = NoteAttachmentsController(
        container: container,
        store: held,
        noteId: 'note-1',
        currentNote: () => openNote,
        resolvedTitle: () => openNote.title,
        onNoteUpdated: (updated) => openNote = updated,
        onChanged: () => changes++,
        onNotice: notices.add,
      )..start();
      api.uploadError = StateError('offline');
      final onRemoved = await held.stage(
        source: await recording('two.m4a'),
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
        fileName: 'recording_2.m4a',
        pageId: 'p2',
      );
      await controller.loadPending();
      await waitFor(
        () => controller.pending.length == 1 && !controller.isUploading,
      );
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'local:page',
              'user_id': 'user-1',
              'title': 'Two',
              'data': {
                'content': {'md': 'two', 'html': ''},
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );

      // The recording has moved; the rest of the move waits on a scan when
      // the user retries it. The retry finds nothing left where it was.
      api.uploadError = null;
      held.holdNoteScan = Completer<void>();
      final original = openNote;
      final pageNote = await readNote('local:page');
      openNote = pageNote;
      final rebinding = controller.rebindTo(original, pageNote, pageId: 'p2');
      await held.noteScanEntered.future;
      await controller.retry();
      held.holdNoteScan!.complete();
      await rebinding;
      check(controller.pending.map((item) => item.id)).deepEquals([
        onRemoved.id,
      ]);

      await controller.retry();
      await waitFor(() => !controller.isUploading);
      final stored = await readNote('local:page');
      check(stored.data.files ?? const <Map<String, dynamic>>[]).length
          .equals(1);
      check(controller.pending).isEmpty();
    });

    test('a recording that was finished while it was being moved does not '
        'stay pending', () async {
      final held = _HeldScanStore(
        applicationSupportDirectory: () async {
          final dir = Directory('${root.path}/support');
          await dir.create(recursive: true);
          return dir;
        },
        temporaryDirectory: () async => Directory('${root.path}/cache'),
      )..release.complete();
      controller.dispose();
      controller = NoteAttachmentsController(
        container: container,
        store: held,
        noteId: 'note-1',
        currentNote: () => openNote,
        resolvedTitle: () => openNote.title,
        onNoteUpdated: (updated) => openNote = updated,
        onChanged: () => changes++,
        onNotice: notices.add,
      )..start();
      api.uploadError = StateError('offline');
      final onRemoved = await held.stage(
        source: await recording('two.m4a'),
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
        fileName: 'recording_2.m4a',
        pageId: 'p2',
      );
      await controller.loadPending();
      await waitFor(
        () => controller.pending.length == 1 && !controller.isUploading,
      );
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'local:page',
              'user_id': 'user-1',
              'title': 'Two',
              'data': {
                'content': {'md': 'two', 'html': ''},
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );
      api.uploadError = null;
      final original = openNote;
      final pageNote = await readNote('local:page');
      openNote = pageNote;

      // The move waits; meanwhile the recording's record goes, as a finished
      // upload's does, and a retry reports it gone.
      held.holdRebind = Completer<void>();
      final rebinding = controller.rebindTo(original, pageNote, pageId: 'p2');
      await held.rebindEntered.future;
      await held.remove(onRemoved);
      final retrying = controller.retry();
      held.holdRebind!.complete();
      await rebinding;
      await retrying;
      await waitFor(() => controller.pending.isEmpty);
      check(controller.pending).isEmpty();
    });

    test('a recording reported gone by a retry that looked before its move '
        'stays when its moved copy is there', () async {
      final held = _HeldScanStore(
        applicationSupportDirectory: () async {
          final dir = Directory('${root.path}/support');
          await dir.create(recursive: true);
          return dir;
        },
        temporaryDirectory: () async => Directory('${root.path}/cache'),
      )..release.complete();
      controller.dispose();
      controller = NoteAttachmentsController(
        container: container,
        store: held,
        noteId: 'note-1',
        currentNote: () => openNote,
        resolvedTitle: () => openNote.title,
        onNoteUpdated: (updated) => openNote = updated,
        onChanged: () => changes++,
        onNotice: notices.add,
      )..start();
      api.uploadError = StateError('offline');
      final onRemoved = await held.stage(
        source: await recording('two.m4a'),
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
        fileName: 'recording_2.m4a',
        pageId: 'p2',
      );
      await controller.loadPending();
      await waitFor(
        () => controller.pending.length == 1 && !controller.isUploading,
      );
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'local:page',
              'user_id': 'user-1',
              'title': 'Two',
              'data': {
                'content': {'md': 'two', 'html': ''},
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );
      api.uploadError = null;
      final original = openNote;
      final pageNote = await readNote('local:page');
      openNote = pageNote;

      // The recording has moved; the rest of the move waits on a scan. A
      // retry looks for it where it was, and answers after the move ends.
      held.holdNoteScan = Completer<void>();
      final rebinding = controller.rebindTo(original, pageNote, pageId: 'p2');
      await held.noteScanEntered.future;
      held.holdLoadCurrent = Completer<void>();
      final retrying = controller.retry();
      await held.loadCurrentEntered.future;
      held.holdNoteScan!.complete();
      await rebinding;
      final lateAnswer = held.holdLoadCurrent!;
      held.holdLoadCurrent = null;
      lateAnswer.complete();
      await retrying;
      // Not taken for gone: it is retried on the new note, and attached there.
      await controller.retry();
      await waitFor(() => !controller.isUploading);
      final stored = await readNote('local:page');
      check(stored.data.files ?? const <Map<String, dynamic>>[]).length
          .equals(1);
      check(controller.pending.map((item) => item.id))
          .not((it) => it.contains(onRemoved.id));
    });

    test('a recording reported gone while it moves on again stays',
        () async {
      final held = _HeldScanStore(
        applicationSupportDirectory: () async {
          final dir = Directory('${root.path}/support');
          await dir.create(recursive: true);
          return dir;
        },
        temporaryDirectory: () async => Directory('${root.path}/cache'),
      )..release.complete();
      controller.dispose();
      controller = NoteAttachmentsController(
        container: container,
        store: held,
        noteId: 'note-1',
        currentNote: () => openNote,
        resolvedTitle: () => openNote.title,
        onNoteUpdated: (updated) => openNote = updated,
        onChanged: () => changes++,
        onNotice: notices.add,
      )..start();
      api.uploadError = StateError('offline');
      final recording1 = await held.stage(
        source: await recording('two.m4a'),
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
        fileName: 'recording_2.m4a',
      );
      await controller.loadPending();
      await waitFor(
        () => controller.pending.length == 1 && !controller.isUploading,
      );
      Future<Note> storeNote(String id) async {
        await db
            .into(db.notes)
            .insertOnConflictUpdate(
              serverToNoteRow({
                'id': id,
                'user_id': 'user-1',
                'title': id,
                'data': {
                  'content': {'md': id, 'html': ''},
                },
                'meta': {},
                'is_pinned': false,
                'created_at': 1713786305000000000,
                'updated_at': 1713786305000000000,
              }),
            );
        return readNote(id);
      }

      // The note is recovered once; the recording moves with it.
      final first = await storeNote('local:first');
      final original = openNote;
      openNote = first;
      await controller.rebindTo(original, first);
      // A report of it gone is being checked against that copy when the new
      // note is recovered in its turn, and the recording moves again.
      held
        ..holdLoadCurrentOfNote = 'local:first'
        ..holdLoadCurrent = Completer<void>();
      final Future<void> report = controller.debugReportGone(recording1.id);
      await held.loadCurrentEntered.future;
      final second = await storeNote('local:second');
      openNote = second;
      await controller.rebindTo(first, second);
      // The retry the move starts fails, offline, and is over before the
      // report is answered: nothing but the report touches the recording.
      await waitFor(() => !controller.isUploading);
      held.holdLoadCurrent!.complete();
      held.holdLoadCurrent = null;
      await report;

      check(controller.pending.map((item) => item.id)).deepEquals([
        recording1.id,
      ]);
      check(controller.pending.single.noteId).equals('local:second');
    });

    test('a moved recording whose copy cannot be read stays in view',
        () async {
      final held = _HeldScanStore(
        applicationSupportDirectory: () async {
          final dir = Directory('${root.path}/support');
          await dir.create(recursive: true);
          return dir;
        },
        temporaryDirectory: () async => Directory('${root.path}/cache'),
      )..release.complete();
      controller.dispose();
      controller = NoteAttachmentsController(
        container: container,
        store: held,
        noteId: 'note-1',
        currentNote: () => openNote,
        resolvedTitle: () => openNote.title,
        onNoteUpdated: (updated) => openNote = updated,
        onChanged: () => changes++,
        onNotice: notices.add,
      )..start();
      api.uploadError = StateError('offline');
      final staged = await held.stage(
        source: await recording('two.m4a'),
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
        fileName: 'recording_2.m4a',
      );
      await controller.loadPending();
      await waitFor(
        () => controller.pending.length == 1 && !controller.isUploading,
      );
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'local:moved',
              'user_id': 'user-1',
              'title': 'Moved',
              'data': {
                'content': {'md': 'moved', 'html': ''},
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );
      final original = openNote;
      openNote = await readNote('local:moved');
      await controller.rebindTo(original, openNote);
      await waitFor(() => !controller.isUploading);

      // A report of it gone is checked against its copy, which cannot be
      // read: it is not taken for gone.
      held.failLoadCurrentOfNote = 'local:moved';
      await controller.debugReportGone(staged.id);

      check(controller.pending.map((item) => item.id)).deepEquals([staged.id]);
    });

    test('a moved recording\'s upload is over only once its copy is checked',
        () async {
      void Function()? onChange;
      final held = _HeldScanStore(
        applicationSupportDirectory: () async {
          final dir = Directory('${root.path}/support');
          await dir.create(recursive: true);
          return dir;
        },
        temporaryDirectory: () async => Directory('${root.path}/cache'),
      )..release.complete();
      controller.dispose();
      controller = NoteAttachmentsController(
        container: container,
        store: held,
        noteId: 'note-1',
        currentNote: () => openNote,
        resolvedTitle: () => openNote.title,
        onNoteUpdated: (updated) => openNote = updated,
        onChanged: () {
          changes++;
          onChange?.call();
        },
        onNotice: notices.add,
      )..start();
      api.uploadError = StateError('offline');
      final staged = await held.stage(
        source: await recording('two.m4a'),
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
        fileName: 'recording_2.m4a',
      );
      await controller.loadPending();
      await waitFor(
        () => controller.pending.length == 1 && !controller.isUploading,
      );
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'local:moved',
              'user_id': 'user-1',
              'title': 'Moved',
              'data': {
                'content': {'md': 'moved', 'html': ''},
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );
      final original = openNote;
      openNote = await readNote('local:moved');
      await controller.rebindTo(original, openNote);
      // The retry the move starts fails, offline.
      await waitFor(() => !controller.isUploading);
      check(controller.pending.map((item) => item.id)).deepEquals([staged.id]);

      // Back online, it is retried and attaches. The check of its copy, which
      // finds it gone, is held: until it answers, the upload is not over, and
      // the recording is not reported saved while it still shows.
      api.uploadError = null;
      var overWhileShown = false;
      onChange = () {
        if (!controller.isUploading && controller.pending.isNotEmpty) {
          overWhileShown = true;
        }
      };
      final noticesBefore = notices.length;
      held.holdGoneAnswer = Completer<void>();
      final retrying = controller.retry(showFeedback: true);
      await held.goneAnswerHeld.future;
      // What is left of the upload once the copy is gone takes a few turns.
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      check(controller.isUploading).isTrue();
      check(notices.skip(noticesBefore)).isEmpty();
      held.holdGoneAnswer!.complete();
      await retrying;
      check(controller.pending).isEmpty();
      check(overWhileShown).isFalse();
      check(
        notices.skip(noticesBefore),
      ).deepEquals([NoteAudioNotice.recordingSaved]);
    });

    test('a moved recording\'s upload reports nothing once another session '
        'began while its copy was checked', () async {
      final held = _HeldScanStore(
        applicationSupportDirectory: () async {
          final dir = Directory('${root.path}/support');
          await dir.create(recursive: true);
          return dir;
        },
        temporaryDirectory: () async => Directory('${root.path}/cache'),
      )..release.complete();
      controller.dispose();
      controller = NoteAttachmentsController(
        container: container,
        store: held,
        noteId: 'note-1',
        currentNote: () => openNote,
        resolvedTitle: () => openNote.title,
        onNoteUpdated: (updated) => openNote = updated,
        onChanged: () => changes++,
        onNotice: notices.add,
      )..start();
      api.uploadError = StateError('offline');
      final staged = await held.stage(
        source: await recording('two.m4a'),
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
        fileName: 'recording_2.m4a',
      );
      await controller.loadPending();
      await waitFor(
        () => controller.pending.length == 1 && !controller.isUploading,
      );
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'local:moved',
              'user_id': 'user-1',
              'title': 'Moved',
              'data': {
                'content': {'md': 'moved', 'html': ''},
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );
      final original = openNote;
      openNote = await readNote('local:moved');
      await controller.rebindTo(original, openNote);
      // The retry the move starts fails, offline.
      await waitFor(() => !controller.isUploading);
      check(controller.pending.map((item) => item.id)).deepEquals([staged.id]);

      // Back online, it is retried and attaches. Another session begins while
      // the check of its copy is held: the old upload's success is not
      // reported to it.
      api.uploadError = null;
      final noticesBefore = notices.length;
      held.holdGoneAnswer = Completer<void>();
      final retrying = controller.retry(showFeedback: true);
      await held.goneAnswerHeld.future;
      container.read(_testEpochProvider.notifier).rotate();
      held.holdGoneAnswer!.complete();
      await retrying;
      check(notices.skip(noticesBefore)).isEmpty();
    });

    test('a moved recording whose copy cannot be read after its upload is '
        'not reported saved, and is once a retry finds it gone', () async {
      final held = _HeldScanStore(
        applicationSupportDirectory: () async {
          final dir = Directory('${root.path}/support');
          await dir.create(recursive: true);
          return dir;
        },
        temporaryDirectory: () async => Directory('${root.path}/cache'),
      )..release.complete();
      controller.dispose();
      controller = NoteAttachmentsController(
        container: container,
        store: held,
        noteId: 'note-1',
        currentNote: () => openNote,
        resolvedTitle: () => openNote.title,
        onNoteUpdated: (updated) => openNote = updated,
        onChanged: () => changes++,
        onNotice: notices.add,
      )..start();
      api.uploadError = StateError('offline');
      final staged = await held.stage(
        source: await recording('two.m4a'),
        serverId: 'server-1',
        accountId: 'user:user-1',
        noteId: 'note-1',
        fileName: 'recording_2.m4a',
      );
      await controller.loadPending();
      await waitFor(
        () => controller.pending.length == 1 && !controller.isUploading,
      );
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'local:moved',
              'user_id': 'user-1',
              'title': 'Moved',
              'data': {
                'content': {'md': 'moved', 'html': ''},
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );
      final original = openNote;
      openNote = await readNote('local:moved');
      await controller.rebindTo(original, openNote);
      // The retry the move starts fails, offline.
      await waitFor(() => !controller.isUploading);
      check(controller.pending.map((item) => item.id)).deepEquals([staged.id]);

      // Back online, it is retried and attaches, but the check of its copy
      // cannot be read: it stays in view, and is not reported saved.
      api.uploadError = null;
      final noticesBefore = notices.length;
      held.failGoneAnswer = true;
      await controller.retry(showFeedback: true);
      check(controller.pending.map((item) => item.id)).deepEquals([staged.id]);
      check(notices.skip(noticesBefore)).isEmpty();

      // A later retry finds it gone, and the check reads: it is saved.
      held.failGoneAnswer = false;
      await controller.retry(showFeedback: true);
      check(controller.pending).isEmpty();
      check(
        notices.skip(noticesBefore),
      ).deepEquals([NoteAudioNotice.recordingSaved]);
      final stored = await readNote('local:moved');
      check(stored.data.files ?? const <Map<String, dynamic>>[]).length
          .equals(1);
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
