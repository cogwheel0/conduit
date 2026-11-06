import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart' show visibleForTesting;

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/note_mapper.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/notes/providers/notes_providers.dart';
import 'package:conduit_core/features/notes/services/audio_recording_service.dart';
import 'package:conduit_core/features/notes/services/note_audio_upload_service.dart';
import 'package:conduit_core/features/notes/utils/note_page_data.dart';
import 'package:conduit_core/features/notes/utils/note_persistence.dart';
import 'package:conduit_core/models/file_info.dart';
import 'package:conduit_core/models/note.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// What the editor tells the user about a recording, for it to word.
enum NoteAudioNotice {
  /// The upload finished and the recording is attached to the note.
  recordingSaved,

  /// Staging or uploading failed; the recording is kept for a retry.
  uploadFailed,

  /// A pending recording was removed.
  removed,

  /// Something else failed (removing a recording).
  error,
}

/// The recordings of one open note: staged to durable storage, uploaded to
/// the server and attached to the note, surviving a lost connection, a closed
/// page and a process death, and rebound to a recovered note when the server
/// deleted the original.
///
/// This is the editor's logic, moved out of the Flutter page so it is tested
/// without widgets. The page owns the widgets: it mirrors
/// [pending], [isUploading] and [isInFlight] on [onChanged], words the
/// [onNotice]s, and takes the note [onNoteUpdated] hands back.
class NoteAttachmentsController {
  NoteAttachmentsController({
    required ProviderContainer container,
    required NoteAudioUploadStore store,
    required String noteId,
    required Note? Function() currentNote,
    required String Function() resolvedTitle,
    required void Function(Note note) onNoteUpdated,
    required void Function() onChanged,
    required void Function(NoteAudioNotice notice) onNotice,
    String? Function()? currentPageId,
  }) : _container = container,
       _store = store,
       _noteId = noteId,
       _currentNote = currentNote,
       _resolvedTitle = resolvedTitle,
       _onNoteUpdated = onNoteUpdated,
       _onChanged = onChanged,
       _onNotice = onNotice,
       _currentPageId = currentPageId;

  final ProviderContainer _container;
  final NoteAudioUploadStore _store;
  final String _noteId;
  final Note? Function() _currentNote;
  final String Function() _resolvedTitle;
  final void Function(Note note) _onNoteUpdated;
  final void Function() _onChanged;
  final void Function(NoteAudioNotice notice) _onNotice;

  /// The page of a note with several pages (Open WebUI 0.12.5+) the editor
  /// shows, read once when a recording is made or a file removed: the
  /// recording is attached there, and the file detached from it. Null, or a
  /// page the note no longer has, means the main page, as it does for a
  /// recording staged before pages were known.
  final String? Function()? _currentPageId;

  final List<PendingNoteAudioUpload> _pending = <PendingNoteAudioUpload>[];

  /// Notes that keep their recordings although this editor started on one:
  /// once a page of the note was saved as a note of its own ([rebindTo] with
  /// a page), the editor shows that note, and the recordings of the other
  /// pages wait for their note to be opened again.
  final Set<String> _leftBehind = <String>{};

  /// Counts [rebindTo] calls: a scan of the store that one overtook was for
  /// the note the editor showed before, and is not published.
  int _rebinds = 0;

  /// Recordings that stay with the note they were made on after a page of
  /// it was recovered: an upload of one still running neither comes back to
  /// this editor nor attaches to the note it shows now.
  final Set<String> _leftBehindUploads = <String>{};

  /// Recordings [rebindTo] is moving to another note. A retry meanwhile
  /// finds no copy where one was and reports it gone; such a report waits in
  /// [_goneWhileMoving] for the move to say where the recording is.
  final Set<String> _moving = <String>{};
  final Set<String> _goneWhileMoving = <String>{};

  /// The copies [rebindTo] moved recordings to, by id. A recording reported
  /// gone later, by a retry that looked where it was before the move, is
  /// gone only if its copy is too.
  final Map<String, PendingNoteAudioUpload> _movedCopies =
      <String, PendingNoteAudioUpload>{};
  final Set<String> _inFlight = <String>{};
  final Set<String> _queued = <String>{};
  final Set<String> _feedbackIds = <String>{};
  final Set<String> _hidden = <String>{};
  int _mutationGeneration = 0;
  bool _draining = false;
  bool _isUploading = false;
  bool _disposed = false;
  CancelToken? _activeCancelToken;
  ProviderSubscription<ConnectivityStatus>? _connectivitySubscription;
  ProviderSubscription<Object>? _authEpochSubscription;

  /// Recordings not yet attached, oldest first.
  List<PendingNoteAudioUpload> get pending =>
      List<PendingNoteAudioUpload>.unmodifiable(_pending);

  /// Whether the upload queue is being drained.
  bool get isUploading => _isUploading;

  /// Whether [id] is uploading, attaching or being removed right now.
  bool isInFlight(String id) => _inFlight.contains(id);

  /// Starts retrying on reconnect and dropping state on a sign-in change.
  /// Call once, from the page's `initState`.
  void start() {
    _connectivitySubscription = _container.listen<ConnectivityStatus>(
      connectivityStatusProvider,
      (previous, next) {
        if (previous == ConnectivityStatus.offline &&
            next == ConnectivityStatus.online) {
          unawaited(retry());
        }
      },
    );
    _authEpochSubscription = _container.listen<Object>(
      openWebUiAuthSessionEpochProvider,
      (previous, next) {
        _activeCancelToken?.cancel('Authentication session changed.');
        _activeCancelToken = null;
        _queued.clear();
        _feedbackIds.clear();
        _inFlight.clear();
        _hidden.clear();
        _mutationGeneration++;
        if (_disposed) return;
        _pending.clear();
        _onChanged();
        if (_currentNote() != null) unawaited(loadPending());
      },
    );
  }

  void dispose() {
    _disposed = true;
    _connectivitySubscription?.close();
    _authEpochSubscription?.close();
    _activeCancelToken?.cancel('Note editor disposed.');
    _activeCancelToken = null;
  }

  /// Stops any upload in flight and forgets what was queued, as a note
  /// replaced after a remote deletion must (see [rebindTo]).
  void cancelActiveWork(String reason) {
    _activeCancelToken?.cancel(reason);
    _activeCancelToken = null;
    _queued.clear();
    _feedbackIds.clear();
  }

  ({String serverId, String accountId})? _scope() {
    if (!_container.read(isAuthenticatedProvider2)) return null;
    final ApiService? api = _container.read(apiServiceProvider);
    if (api == null) return null;

    final String? userId = _container.read(currentUserProvider2)?.id.trim();
    if (userId == null || userId.isEmpty) return null;

    return (serverId: api.serverConfig.id, accountId: 'user:$userId');
  }

  bool _isCurrent({
    required Object? api,
    required AppDatabase? db,
    Object? authEpoch,
  }) =>
      !_disposed &&
      isCurrentNoteEditorSession(
        _container,
        api: api,
        db: db,
        authEpoch: authEpoch,
      );

  void _notify() {
    if (!_disposed) _onChanged();
  }

  void _sortPending() =>
      _pending.sort((a, b) => a.createdAt.compareTo(b.createdAt));

  /// Moves a recorder cache file into account-scoped application support
  /// before any network request. Once this returns true, closing the page or
  /// losing connectivity cannot discard the recording.
  /// [pageId] is the page the recording was started on; by default the page
  /// shown now.
  Future<bool> stage(File audioFile, {String? pageId}) async {
    final Note? note = _currentNote();
    final scope = _scope();
    final ApiService? api = _container.read(apiServiceProvider);
    final AppDatabase? db = _container.read(appDatabaseProvider);
    final Object authEpoch = _container.read(openWebUiAuthSessionEpochProvider);
    if (note == null || scope == null) {
      _onNotice(NoteAudioNotice.uploadFailed);
      return false;
    }

    final String fileName = noteRecordingFileName(audioFile.path);
    // The page the recording was made on, read with the note: it is stored
    // with the recording, which is attached there even when the editor
    // shows another page, or is closed, by the time it uploads.
    final String? madeOn = pageId ?? _currentPageId?.call();
    try {
      final PendingNoteAudioUpload item = await _store.stage(
        source: audioFile,
        serverId: scope.serverId,
        accountId: scope.accountId,
        noteId: note.id,
        fileName: fileName,
        pageId: madeOn,
      );
      if (!_isCurrent(api: api, db: db, authEpoch: authEpoch)) return true;
      _mutationGeneration++;
      _hidden.remove(item.id);
      final int index = _pending.indexWhere(
        (PendingNoteAudioUpload candidate) => candidate.id == item.id,
      );
      if (index < 0) {
        _pending.add(item);
      } else {
        _pending[index] = item;
      }
      _sortPending();
      _notify();
      unawaited(retry(ids: <String>[item.id], showFeedback: true));
      return true;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'note-audio-stage-failed',
        scope: 'notes/audio',
        error: error,
        stackTrace: stackTrace,
      );
      if (!_disposed) _onNotice(NoteAudioNotice.uploadFailed);
      return false;
    }
  }

  /// Reads the recordings this note (and the ids it was remapped from) still
  /// has on disk, and retries them when online.
  Future<void> loadPending() async {
    final Note? note = _currentNote();
    final scope = _scope();
    final ApiService? api = _container.read(apiServiceProvider);
    final AppDatabase? db = _container.read(appDatabaseProvider);
    final Object authEpoch = _container.read(openWebUiAuthSessionEpochProvider);
    if (note == null || scope == null) return;
    final int mutationGeneration = _mutationGeneration;
    final int rebinds = _rebinds;
    try {
      final Set<String> currentIds = <String>{_noteId, note.id};
      if (db != null) {
        currentIds.add(await db.notesDao.resolveNoteRemapTarget(_noteId));
        currentIds.add(await db.notesDao.resolveNoteRemapTarget(note.id));
      }
      currentIds.removeAll(_leftBehind);
      if (!_isCurrent(api: api, db: db, authEpoch: authEpoch)) return;

      final List<PendingNoteAudioUpload> accountItems = await _store
          .loadForAccount(serverId: scope.serverId, accountId: scope.accountId);
      final List<List<PendingNoteAudioUpload>> exactItems = await Future.wait(
        currentIds.map(
          (String noteId) => _store.loadForNote(
            serverId: scope.serverId,
            accountId: scope.accountId,
            noteId: noteId,
          ),
        ),
      );
      if (!_isCurrent(api: api, db: db, authEpoch: authEpoch)) return;

      final Map<String, PendingNoteAudioUpload> matchingById =
          <String, PendingNoteAudioUpload>{};
      for (final List<PendingNoteAudioUpload> batch in exactItems) {
        for (final PendingNoteAudioUpload item in batch) {
          matchingById[item.id] = item;
        }
      }
      for (final PendingNoteAudioUpload item in accountItems) {
        if (currentIds.contains(item.noteId)) {
          matchingById[item.id] = item;
          continue;
        }
        if (db != null) {
          final String resolvedId = await db.notesDao.resolveNoteRemapTarget(
            item.noteId,
          );
          if (currentIds.contains(resolvedId)) matchingById[item.id] = item;
        }
      }
      if (!_isCurrent(api: api, db: db, authEpoch: authEpoch)) return;

      // The editor moved to another note meanwhile: this scan is the old
      // note's, whose recordings may now stay with it.
      if (rebinds != _rebinds) return;
      final bool changedWhileLoading =
          mutationGeneration != _mutationGeneration;
      if (changedWhileLoading) {
        // A stage, completion, or removal won the race with this disk scan.
        // Preserve the newer UI state while still merging other recovered
        // recordings, always deduplicated by their durable id.
        for (final PendingNoteAudioUpload existing in _pending) {
          matchingById[existing.id] = existing;
        }
      }
      for (final String hiddenId in _hidden) {
        matchingById.remove(hiddenId);
      }
      _pending
        ..clear()
        ..addAll(matchingById.values);
      _sortPending();
      _notify();
      if (_container.read(connectivityStatusProvider) ==
          ConnectivityStatus.online) {
        unawaited(retry());
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'note-audio-recovery-failed',
        scope: 'notes/audio',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Uploads and attaches [ids] (every pending recording by default), one at
  /// a time. [showFeedback] words the outcome to the user.
  Future<void> retry({Iterable<String>? ids, bool showFeedback = false}) async {
    if (_disposed || _scope() == null) return;
    final Iterable<String> requestedIds =
        ids ?? _pending.map((PendingNoteAudioUpload item) => item.id).toList();
    _queued.addAll(requestedIds);
    if (showFeedback) {
      _feedbackIds.addAll(requestedIds);
    }
    if (_draining) return;

    _draining = true;
    _isUploading = true;
    _notify();
    try {
      while (!_disposed && _queued.isNotEmpty) {
        final String id = _queued.first;
        _queued.remove(id);
        final bool showItemFeedback = _feedbackIds.remove(id);
        await _process(id, showFeedback: showItemFeedback);
      }
    } finally {
      _draining = false;
      _isUploading = false;
      _notify();
    }
  }

  Future<void> _process(String id, {required bool showFeedback}) async {
    final int index = _pending.indexWhere(
      (PendingNoteAudioUpload item) => item.id == id,
    );
    if (index < 0) return;
    final PendingNoteAudioUpload pendingItem = _pending[index];
    final Future<void>? removalCompletion =
        NoteAudioUploadCoordinator.removalCompletion(pendingItem);
    if (removalCompletion != null) {
      await removalCompletion;
      if (!_disposed) await loadPending();
      return;
    }

    final ApiService? api = _container.read(apiServiceProvider);
    final AppDatabase? db = _container.read(appDatabaseProvider);
    if (api == null || _scope() == null) return;
    final Object authEpoch = _container.read(openWebUiAuthSessionEpochProvider);
    final ApiAuthSnapshot authSnapshot = api.captureAuthSnapshot();
    final CancelToken cancelToken = CancelToken();
    _activeCancelToken = cancelToken;

    _inFlight.add(id);
    _notify();
    try {
      final NoteAudioUploadCoordinator coordinator = NoteAudioUploadCoordinator(
        store: _store,
        upload: (PendingNoteAudioUpload item, File file) async {
          if (!_isCurrent(api: api, db: db, authEpoch: authEpoch)) {
            throw StateError('The active note session changed');
          }

          // A prior process may have committed the POST but lost its
          // response. OpenWebUI stores this marker under `meta.data`;
          // reconcile before a retry so that uncertain requests do not
          // create duplicate files.
          if (item.status != NoteAudioUploadStatus.pending &&
              item.serverFileId == null) {
            final List<FileInfo>? targetedFiles = await api
                .searchFilesForSession(
                  query: item.fileName,
                  limit: 100,
                  authSnapshot: authSnapshot,
                  cancelToken: cancelToken,
                );
            final List<FileInfo> files =
                targetedFiles ??
                await api.getUserFilesForSession(
                  authSnapshot: authSnapshot,
                  cancelToken: cancelToken,
                );
            if (!_isCurrent(api: api, db: db, authEpoch: authEpoch)) {
              throw StateError('The active note session changed');
            }
            final String? existing = uploadedNoteAudioFileId(files, item);
            if (existing != null) return existing;
          }

          return api.uploadFile(
            file.path,
            item.fileName,
            contentType: noteAudioContentType(item.fileName),
            metadata: <String, dynamic>{'conduit_upload_id': item.id},
            cancelToken: cancelToken,
            authSnapshot: authSnapshot,
          );
        },
        attach: (PendingNoteAudioUpload item, String fileId) => _attach(
          item,
          fileId,
          api: api,
          db: db,
          authEpoch: authEpoch,
          authSnapshot: authSnapshot,
          cancelToken: cancelToken,
        ),
        onChanged: (PendingNoteAudioUpload? item) {
          if (_isCurrent(api: api, db: db, authEpoch: authEpoch)) {
            _applyChange(id, item);
          }
        },
      );
      final PendingNoteAudioUpload? result = await coordinator.process(
        pendingItem,
      );
      if (!_isCurrent(api: api, db: db, authEpoch: authEpoch)) return;

      // A shared in-flight operation may have been owned by a different
      // editor instance, whose change callback does not target this page.
      // A moved recording is checked against its copy before the upload
      // counts as over, so it is not reported saved while still in view.
      await _reportChange(id, result);
      // Another session may have begun while the copy was checked.
      if (!_isCurrent(api: api, db: db, authEpoch: authEpoch)) return;

      if (result == null) {
        // Saved once it has left the view. It stays when the copy a move made
        // of it could not be read, or is still stored (the upload then found
        // only where it was before), or while a move settles its report.
        final bool left = !_pending.any(
          (PendingNoteAudioUpload item) => item.id == id,
        );
        if (showFeedback && left) _onNotice(NoteAudioNotice.recordingSaved);
      } else if (showFeedback) {
        _onNotice(NoteAudioNotice.uploadFailed);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'note-audio-coordinator-failed',
        scope: 'notes/audio',
        stackTrace: stackTrace,
        data: {'id': id, 'errorType': error.runtimeType.toString()},
      );
      if (showFeedback && _isCurrent(api: api, db: db, authEpoch: authEpoch)) {
        _onNotice(NoteAudioNotice.uploadFailed);
      }
    } finally {
      if (identical(_activeCancelToken, cancelToken)) {
        _activeCancelToken = null;
      }
      _inFlight.remove(id);
      _notify();
    }
  }

  /// Removes a pending recording the user chose to delete (after asking).
  /// Nothing happens while it uploads, or once the server owns its bytes.
  Future<void> removePending(String id) async {
    if (_inFlight.contains(id)) return;
    final int index = _pending.indexWhere(
      (PendingNoteAudioUpload item) => item.id == id,
    );
    if (index < 0) return;
    final PendingNoteAudioUpload item = _pending[index];
    // Once the server owns the bytes, deleting only this local retry record
    // would misleadingly leave a private orphan on the server. Keep it
    // available for the idempotent attach retry instead.
    if (item.serverFileId != null) return;
    if (!NoteAudioUploadCoordinator.tryReserveRemoval(item)) return;
    _queued.remove(id);
    _feedbackIds.remove(id);
    _inFlight.add(id);
    _hidden.add(id);
    _mutationGeneration++;
    _notify();
    try {
      await _store.remove(item);
      _applyChange(id, null);
      if (!_disposed) _onNotice(NoteAudioNotice.removed);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'note-audio-remove-failed',
        scope: 'notes/audio',
        error: error,
        stackTrace: stackTrace,
        data: {'id': id},
      );
      _hidden.remove(id);
      if (!_disposed) _onNotice(NoteAudioNotice.error);
    } finally {
      NoteAudioUploadCoordinator.releaseRemoval(item);
      _inFlight.remove(id);
      _notify();
    }
  }

  /// Removes an attachment the server already holds from the note's files.
  /// Returns the stored note, or null when it could not be persisted or the
  /// session changed.
  Future<Note?> removeAttachedFile(String? fileId) async {
    final Note? note = _currentNote();
    if (note == null) return null;
    final ApiService? api = _container.read(apiServiceProvider);
    final AppDatabase? db = _container.read(appDatabaseProvider);
    if (api == null && db == null) return null;
    // The session is more than the API and database objects, which can stay
    // the same while the account changes underneath them.
    final Object authEpoch = _container.read(openWebUiAuthSessionEpochProvider);

    if (fileId == null) return null;
    // The page the file is removed from, read once: the editor may show
    // another page by the time the stored row is read.
    final String? page = _currentPageId?.call();
    // The note as this page has it, for the API path; with a database the
    // patch is built from the stored row inside the note lock, so an
    // attachment added since [note] was read (a recording finishing, a pull),
    // or files a sync moved into the content, are seen as they are now.
    final Map<String, dynamic> shown = <String, dynamic>{
      'content': note.data.content.toJson(),
      'files': ?note.data.files,
      if (note.data.hasPages)
        'pages': <Object>[
          for (final NotePage page in note.data.pages) page.toJson(),
        ],
    };
    final String target = notePageIdIn(shown, page);
    final Note? updated = await persistNoteUpdate(
      _container,
      noteId: _noteId,
      writeId: note.id,
      api: api,
      db: db,
      title: _resolvedTitle(),
      authEpoch: authEpoch,
      // Only the stored row decides on the durable path: a list read from a
      // stale copy must not be merged into a note that is paged by now.
      data: db == null
          ? noteDataWithoutFile(shown, fileId, pageId: target)
          : const <String, dynamic>{},
      // The same page as the save targets: one a sync removed meanwhile has
      // no link left to take out, and another page's must stay.
      dataFrom: (Map<String, dynamic> existing) =>
          noteDataWithoutFile(existing, fileId, pageId: target),
      pageId: target,
      isStillOpen: () => !_disposed,
    );
    if (updated == null ||
        !_isCurrent(api: api, db: db, authEpoch: authEpoch)) {
      return null;
    }
    return updated;
  }

  /// Idempotently appends one attachment using the newest local note row.
  ///
  /// The read, duplicate check, and write share the same note lock as sync,
  /// so an upload finishing from an older editor cannot replace files added
  /// by a concurrent pull or recording.
  Future<Note?> _durableAttach(
    AppDatabase db, {
    required String id,
    required Map<String, dynamic> attachment,
    required bool Function() canCommit,
    String? page,
  }) async {
    // The account the recording was attached under, taken before the first
    // await; `canCommit` below fences the epoch it belongs to.
    final String? accountId = _container.read(currentUserProvider2)?.id;
    final String resolvedId = await db.notesDao.resolveNoteRemapTarget(id);
    if (!canCommit()) return null;

    final noteLocks = _container.read(noteLocksProvider);
    var noteAvailable = false;
    await noteLocks.runExclusive(resolvedId, () async {
      if (!canCommit()) return;
      final NoteRow? existingRow = await db.notesDao.getNote(resolvedId);
      if (existingRow == null || existingRow.deleted || !canCommit()) return;
      // Attaching changes the note's data like any edit, so a read-only note
      // refuses it here rather than queueing an update the server rejects.
      requireNoteWriteAccess(
        existingRow,
        noteId: resolvedId,
        accountId: accountId,
      );
      noteAvailable = true;

      final Map<String, dynamic> existingData = decodeNoteData(
        existingRow.data,
      );
      if (_attachesByLink(existingData)) {
        // A 0.12.5 server keeps attachments as links in the page content.
        final Map<String, dynamic>? linked = noteDataWithFileLink(
          existingData,
          attachment,
          pageId: notePageIdIn(existingData, page),
        );
        if (linked == null || !canCommit()) return;
        await db.notesDao.updateNoteWithOutbox(
          resolvedId,
          data: Value(jsonEncode(linked)),
          localUpdatedAtNs: DateTime.now().microsecondsSinceEpoch * 1000,
          enqueue: true,
        );
        return;
      }
      final Object? rawFiles = existingData['files'];
      final List<Map<String, dynamic>> files = rawFiles is List
          ? rawFiles
                .whereType<Map>()
                .map((Map file) => Map<String, dynamic>.from(file))
                .toList(growable: true)
          : <Map<String, dynamic>>[];
      if (noteHasAttachment(files, attachment) || !canCommit()) return;

      await db.notesDao.updateNoteWithOutbox(
        resolvedId,
        data: Value(
          jsonEncode(<String, dynamic>{
            ...existingData,
            'files': <Map<String, dynamic>>[
              ...files,
              Map<String, dynamic>.from(attachment),
            ],
          }),
        ),
        localUpdatedAtNs: DateTime.now().microsecondsSinceEpoch * 1000,
        enqueue: true,
      );
    });
    if (!noteAvailable || !canCommit()) return null;

    final NoteRow? row = await db.notesDao.getNote(resolvedId);
    if (row == null || row.deleted || !canCommit()) return null;
    unawaited(_drainAttachment());
    return Note.fromJson(noteRowToServer(row));
  }

  Future<void> _drainAttachment() async {
    try {
      await _container.read(syncEngineProvider.notifier).drainNow();
    } catch (error) {
      DebugLogger.warning(
        'note-audio-attachment-drain-failed',
        scope: 'notes/audio',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
  }

  Future<void> _attach(
    PendingNoteAudioUpload item,
    String fileId, {
    required Object? api,
    required AppDatabase? db,
    required Object authEpoch,
    required ApiAuthSnapshot authSnapshot,
    required CancelToken cancelToken,
  }) async {
    if (!_isCurrent(api: api, db: db, authEpoch: authEpoch)) {
      throw StateError('The active note session changed');
    }
    if (_leftBehindUploads.contains(item.id)) {
      throw StateError('The recording stays with the note it was made on');
    }
    final Note? note = _currentNote();
    if (note == null) throw StateError('The note is no longer available');

    final Map<String, dynamic> attachment = noteAudioAttachment(item, fileId);
    final String? page = item.pageId;

    Note? updatedNote;
    if (db != null) {
      updatedNote = await _durableAttach(
        db,
        id: note.id,
        page: page,
        attachment: attachment,
        // Checked again inside the note's lock, after the wait for it: a
        // page recovery meanwhile can leave this recording with its note.
        canCommit: () =>
            _isCurrent(api: api, db: db, authEpoch: authEpoch) &&
            !_leftBehindUploads.contains(item.id),
      );
    } else if (note.data.hasPages ||
        _container.read(notePagesServerProvider) == true) {
      final Map<String, dynamic> existing = <String, dynamic>{
        'content': note.data.content.toJson(),
        if (note.data.hasPages)
          'pages': <Object>[
            for (final NotePage page in note.data.pages) page.toJson(),
          ],
      };
      final String pageId = notePageIdIn(existing, page);
      final Map<String, dynamic>? linked = noteDataWithFileLink(
        existing,
        attachment,
        pageId: pageId,
      );
      if (linked == null) return;
      updatedNote = await persistNoteUpdate(
        _container,
        noteId: _noteId,
        writeId: note.id,
        api: api,
        db: db,
        title: _resolvedTitle(),
        data: <String, dynamic>{'content': notePageContent(linked, pageId)},
        pageId: pageId,
        authEpoch: authEpoch,
        authSnapshot: authSnapshot,
        cancelToken: cancelToken,
        isStillOpen: () => !_disposed,
      );
    } else {
      final List<Map<String, dynamic>> currentFiles =
          note.data.files ?? <Map<String, dynamic>>[];
      if (noteHasAttachment(currentFiles, attachment)) return;
      updatedNote = await persistNoteUpdate(
        _container,
        noteId: _noteId,
        writeId: note.id,
        api: api,
        db: db,
        title: _resolvedTitle(),
        data: <String, dynamic>{
          'files': <Map<String, dynamic>>[...currentFiles, attachment],
        },
        authEpoch: authEpoch,
        authSnapshot: authSnapshot,
        cancelToken: cancelToken,
        isStillOpen: () => !_disposed,
      );
    }
    if (updatedNote == null) {
      throw StateError('The recording could not be attached to the note');
    }
    if (!_isCurrent(api: api, db: db, authEpoch: authEpoch)) {
      throw StateError('The active note session changed');
    }
    _container.invalidate(noteByIdProvider(_noteId));
    if (updatedNote.id != _noteId) {
      _container.invalidate(noteByIdProvider(updatedNote.id));
    }
    _onNoteUpdated(updatedNote);
  }

  /// Whether a recording is attached by a link in the page content: the note
  /// is in the paged shape of a 0.12.5 server, or the server is known to be
  /// one (a note stored before the upgrade, or created here since, can still
  /// be in the older shape).
  bool _attachesByLink(Map<String, dynamic> data) =>
      noteDataHasPages(data) ||
      _container.read(notePagesServerProvider) == true;

  void _applyChange(String id, PendingNoteAudioUpload? updated) {
    final Future<void>? check = _reportChange(id, updated);
    if (check != null) unawaited(check);
  }

  /// Applies a change of recording [id]; a report of it gone that is checked
  /// against the copy a move made returns that check.
  Future<void>? _reportChange(String id, PendingNoteAudioUpload? updated) {
    if (_disposed || _leftBehindUploads.contains(id)) return null;
    if (updated == null) {
      if (_moving.contains(id)) {
        _goneWhileMoving.add(id);
        return null;
      }
      if (_movedCopies.containsKey(id)) return _confirmGone(id);
    }
    _setChange(id, updated);
    return null;
  }

  /// Hides recording [id], reported gone, unless the copy a move made of it
  /// is still stored: the report then only missed where it was before. A
  /// move that starts while the copy is read settles the report itself, and
  /// one that has moved the recording again meanwhile is checked by its own
  /// copy.
  Future<void> _confirmGone(String id) async {
    while (true) {
      final PendingNoteAudioUpload? copy = _movedCopies[id];
      final PendingNoteAudioUpload? current;
      try {
        current = copy == null ? null : await _store.loadCurrent(copy);
      } catch (error, stackTrace) {
        // Unknown: the recording stays in view, to be retried.
        DebugLogger.error(
          'note-audio-moved-copy-check-failed',
          scope: 'notes/audio',
          error: error,
          stackTrace: stackTrace,
          data: {'uploadId': id},
        );
        return;
      }
      if (_disposed || current != null) return;
      if (_moving.contains(id)) {
        _goneWhileMoving.add(id);
        return;
      }
      if (!identical(_movedCopies[id], copy)) continue;
      _movedCopies.remove(id);
      _setChange(id, null);
      return;
    }
  }

  /// Reports recording [id] gone, as a retry that found no copy does; the
  /// future completes once the report is settled or left to a running move.
  @visibleForTesting
  Future<void> debugReportGone(String id) async {
    await _reportChange(id, null);
  }

  /// Settles the reports of recordings gone that came in while [ids] moved:
  /// one the move made a copy of is checked against that copy; one it made
  /// none of was finished or removed meanwhile, and goes.
  void _settleMove(
    Iterable<String> ids,
    Map<String, PendingNoteAudioUpload> reboundUploads,
  ) {
    for (final String id in ids) {
      final PendingNoteAudioUpload? copy = reboundUploads[id];
      if (copy != null) _movedCopies[id] = copy;
    }
    _moving.removeAll(ids);
    for (final String id in ids.toList()) {
      if (!_goneWhileMoving.remove(id)) continue;
      if (_movedCopies.containsKey(id)) {
        unawaited(_confirmGone(id));
      } else {
        _setChange(id, null);
      }
    }
  }

  void _setChange(String id, PendingNoteAudioUpload? updated) {
    if (_disposed) return;
    _mutationGeneration++;
    final int index = _pending.indexWhere(
      (PendingNoteAudioUpload item) => item.id == id,
    );
    if (updated == null) {
      _hidden.add(id);
      if (index >= 0) _pending.removeAt(index);
    } else if (index >= 0) {
      _hidden.remove(id);
      _pending[index] = updated;
    } else {
      _hidden.remove(id);
      _pending.add(updated);
    }
    _sortPending();
    _onChanged();
  }

  /// Moves this note's recordings to [recovered], the note created from the
  /// draft of one the server deleted, and retries them there. Anything the
  /// move cannot finish stays visible and retryable, and a later store scan
  /// completes it.
  ///
  /// With [pageId], [recovered] holds the text of that page of [previous],
  /// which is still there: only the recordings made on that page move. The
  /// others stay with [previous], stored for when it is opened again, and
  /// leave this editor, which shows [recovered] from now on.
  Future<void> rebindTo(
    Note previous,
    Note recovered, {
    String? pageId,
  }) async {
    bool moves(PendingNoteAudioUpload item) =>
        pageId == null || (item.pageId ?? kNoteMainPageId) == pageId;
    _rebinds++;
    // Notes that kept their recordings in an earlier page recovery keep them
    // now too.
    final Set<String> keptBefore = Set<String>.of(_leftBehind);
    if (pageId != null) {
      _leftBehind.addAll(<String>{_noteId, previous.id});
      // Reserved before anything is awaited: an upload of one of these that
      // reaches its attach meanwhile must not attach to the new note.
      for (final PendingNoteAudioUpload item in _pending) {
        if (!moves(item)) _leftBehindUploads.add(item.id);
      }
    }
    final ApiService? api = _container.read(apiServiceProvider);
    final AppDatabase? db = _container.read(appDatabaseProvider);
    final Object authEpoch = _container.read(openWebUiAuthSessionEpochProvider);
    final String recoveredId = recovered.id;
    final Map<String, PendingNoteAudioUpload> reboundUploads =
        <String, PendingNoteAudioUpload>{};
    final Set<String> attemptedUploadIds = <String>{};
    Future<PendingNoteAudioUpload?> rebindItem(
      PendingNoteAudioUpload item,
    ) async {
      try {
        return await NoteAudioUploadCoordinator.rebind(
          item,
          () => _store.rebindToNote(item, noteId: recoveredId),
        );
      } catch (error, stackTrace) {
        DebugLogger.error(
          'deleted-note-audio-item-rebind-failed',
          scope: 'notes/recovery',
          error: error,
          stackTrace: stackTrace,
          data: {'noteId': previous.id, 'uploadId': item.id},
        );
        // Keep the durable old-scope item visible and retryable in this
        // editor. rebindToNote leaves its intent journal behind after
        // rollback, so a later store scan will finish moving it to the
        // recovered note.
        return item;
      }
    }

    final Map<String, PendingNoteAudioUpload> initialUploads =
        <String, PendingNoteAudioUpload>{
          for (final PendingNoteAudioUpload item in _pending)
            if (moves(item)) item.id: item,
        };
    attemptedUploadIds.addAll(initialUploads.keys);
    _moving.addAll(initialUploads.keys);
    final List<Future<MapEntry<String, PendingNoteAudioUpload?>>> rebindWaits =
        initialUploads.entries
            .map(
              (MapEntry<String, PendingNoteAudioUpload> entry) async =>
                  MapEntry(entry.key, await rebindItem(entry.value)),
            )
            .toList(growable: false);

    // rebind() installs its reservation synchronously before awaiting
    // existing work. Cancellation then lets that work settle against the old
    // path before the operation callback can move the durable directory.
    cancelActiveWork('The note was replaced after remote deletion.');

    try {
      final List<MapEntry<String, PendingNoteAudioUpload?>> initialResults =
          await Future.wait(rebindWaits);
      for (final MapEntry<String, PendingNoteAudioUpload?> entry
          in initialResults) {
        final PendingNoteAudioUpload? rebound = entry.value;
        if (rebound != null) reboundUploads[entry.key] = rebound;
      }
      final Map<String, PendingNoteAudioUpload> audioItemsById =
          <String, PendingNoteAudioUpload>{
            for (final PendingNoteAudioUpload item in _pending) item.id: item,
          };
      final scope = _scope();
      if (scope != null) {
        for (final String noteId in <String>{_noteId, previous.id}) {
          if (keptBefore.contains(noteId)) continue;
          final List<PendingNoteAudioUpload> durableItems = await _store
              .loadForNote(
                serverId: scope.serverId,
                accountId: scope.accountId,
                noteId: noteId,
              );
          for (final PendingNoteAudioUpload item in durableItems) {
            audioItemsById[item.id] = item;
          }
        }
      }

      for (final PendingNoteAudioUpload item in audioItemsById.values) {
        if (!moves(item) || !attemptedUploadIds.add(item.id)) continue;
        _moving.add(item.id);
        final PendingNoteAudioUpload? rebound = await rebindItem(item);
        if (rebound != null) reboundUploads[item.id] = rebound;
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'deleted-note-audio-rebind-failed',
        scope: 'notes/recovery',
        error: error,
        stackTrace: stackTrace,
        data: {'noteId': previous.id},
      );
    }
    if (!_isCurrent(api: api, db: db, authEpoch: authEpoch)) {
      _moving.removeAll(attemptedUploadIds);
      _goneWhileMoving.removeAll(attemptedUploadIds);
      return;
    }

    // A recording this move took is the new note's, whatever page its copy
    // names: one a retry published while it moved belongs to that note now.
    bool stays(PendingNoteAudioUpload item) =>
        !moves(item) && !attemptedUploadIds.contains(item.id);
    final int pendingBefore = _pending.length;
    for (final PendingNoteAudioUpload item in _pending) {
      if (stays(item)) _leftBehindUploads.add(item.id);
    }
    _pending.removeWhere(stays);
    if (_pending.length != pendingBefore && reboundUploads.isEmpty) {
      _mutationGeneration++;
      _notify();
    }

    if (reboundUploads.isNotEmpty) {
      _mutationGeneration++;
      final Map<String, PendingNoteAudioUpload> visibleById =
          <String, PendingNoteAudioUpload>{
            for (final PendingNoteAudioUpload item in _pending) item.id: item,
            ...reboundUploads,
          };
      for (final String hiddenId in _hidden) {
        visibleById.remove(hiddenId);
      }
      _pending
        ..clear()
        ..addAll(visibleById.values);
      _sortPending();
      _notify();
      if (_container.read(connectivityStatusProvider) ==
          ConnectivityStatus.online) {
        unawaited(retry(ids: reboundUploads.keys));
      }
    }
    _settleMove(attemptedUploadIds, reboundUploads);
  }
}

/// The server file a retried upload already created, when a prior process
/// committed the POST but lost the response: the one carrying the item's
/// `conduit_upload_id` marker (under `meta.data`, or at the top of `meta`)
/// with its name and size, newest first.
String? uploadedNoteAudioFileId(
  Iterable<FileInfo> files,
  PendingNoteAudioUpload item,
) {
  final List<FileInfo> matches =
      files
          .where((FileInfo candidate) {
            final Map<String, dynamic>? metadata = candidate.metadata;
            final Object? nested = metadata?['data'];
            final Object? marker = nested is Map
                ? nested['conduit_upload_id']
                : metadata?['conduit_upload_id'];
            return marker?.toString() == item.id &&
                candidate.displayName == item.fileName &&
                candidate.size == item.fileSize;
          })
          .toList(growable: false)
        ..sort((FileInfo a, FileInfo b) => b.createdAt.compareTo(a.createdAt));
  return matches.isEmpty ? null : matches.first.id;
}

/// The note `files` entry for an uploaded recording. Device-local paths never
/// enter NoteData: only the server attachment descriptor is synced, keyed by
/// the durable upload id for replay dedupe.
Map<String, dynamic> noteAudioAttachment(
  PendingNoteAudioUpload item,
  String fileId,
) => <String, dynamic>{
  'type': 'file',
  'file': '',
  'id': fileId,
  'url': fileId,
  'name': item.fileName,
  'collection_name': '',
  'status': 'uploaded',
  'size': item.fileSize,
  'error': '',
  'itemId': item.id,
};

/// [data] with [attachment] linked at the end of the content of page
/// [pageId] (by default the main page), as an Open WebUI 0.12.5 server
/// attaches files; null when the page links it already. The link goes into
/// every form the content holds (see [noteContentWithLinkedFiles]), so the
/// rich text the web editor saved is kept, and the server and the web editor,
/// which read its JSON or HTML first, find the file there too.
Map<String, dynamic>? noteDataWithFileLink(
  Map<String, dynamic> data,
  Map<String, dynamic> attachment, {
  String pageId = kNoteMainPageId,
}) {
  final String md = notePageMarkdown(data, pageId);
  final String? fileId = attachment['id']?.toString();
  if (fileId == null ||
      noteFileLinksInMarkdown(
        md,
      ).any((NoteFileLink link) => link.id == fileId)) {
    return null;
  }
  final Map<String, dynamic> content =
      notePageContent(data, pageId) ?? <String, dynamic>{'md': md};
  final Map<String, dynamic> linked = noteContentWithLinkedFiles(
    content,
    <Object?>[attachment],
  );
  if (identical(linked, content)) return null;
  return applyNoteContentEdit(data, <String, dynamic>{
    'content': linked,
  }, pageId: pageId);
}

/// Whether [files] already holds [attachment], by server file id or by the
/// upload id it was attached under.
bool noteHasAttachment(
  Iterable<Map<String, dynamic>> files,
  Map<String, dynamic> attachment,
) {
  final String? fileId = attachment['id']?.toString();
  final String? itemId = attachment['itemId']?.toString();
  return files.any(
    (Map<String, dynamic> file) =>
        (fileId != null && file['id']?.toString() == fileId) ||
        (itemId != null && file['itemId']?.toString() == itemId),
  );
}
