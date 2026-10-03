import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  }) : _container = container,
       _store = store,
       _noteId = noteId,
       _currentNote = currentNote,
       _resolvedTitle = resolvedTitle,
       _onNoteUpdated = onNoteUpdated,
       _onChanged = onChanged,
       _onNotice = onNotice;

  final ProviderContainer _container;
  final NoteAudioUploadStore _store;
  final String _noteId;
  final Note? Function() _currentNote;
  final String Function() _resolvedTitle;
  final void Function(Note note) _onNoteUpdated;
  final void Function() _onChanged;
  final void Function(NoteAudioNotice notice) _onNotice;

  final List<PendingNoteAudioUpload> _pending = <PendingNoteAudioUpload>[];
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
  Future<bool> stage(File audioFile) async {
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
    try {
      final PendingNoteAudioUpload item = await _store.stage(
        source: audioFile,
        serverId: scope.serverId,
        accountId: scope.accountId,
        noteId: note.id,
        fileName: fileName,
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
    try {
      final Set<String> currentIds = <String>{_noteId, note.id};
      if (db != null) {
        currentIds.add(await db.notesDao.resolveNoteRemapTarget(_noteId));
        currentIds.add(await db.notesDao.resolveNoteRemapTarget(note.id));
      }
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
      _applyChange(id, result);

      if (result == null) {
        if (showFeedback) _onNotice(NoteAudioNotice.recordingSaved);
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

    List<Map<String, dynamic>> without(List<Map<String, dynamic>> files) =>
        files
            .where((Map<String, dynamic> f) => f['id']?.toString() != fileId)
            .toList();
    final List<Map<String, dynamic>> currentFiles =
        note.data.files ?? <Map<String, dynamic>>[];
    final Note? updated = await persistNoteUpdate(
      _container,
      noteId: _noteId,
      writeId: note.id,
      api: api,
      db: db,
      title: _resolvedTitle(),
      data: <String, dynamic>{'files': without(currentFiles)},
      // With a database the list is filtered from the stored row inside the
      // note lock, so an attachment added since [note] was read (a recording
      // finishing, a pull) is kept rather than overwritten.
      dataFrom: (Map<String, dynamic> existing) {
        final Object? raw = existing['files'];
        return <String, dynamic>{
          'files': without(
            raw is List
                ? raw
                      .whereType<Map>()
                      .map((Map file) => Map<String, dynamic>.from(file))
                      .toList()
                : <Map<String, dynamic>>[],
          ),
        };
      },
      isStillOpen: () => !_disposed,
    );
    if (updated == null || !_isCurrent(api: api, db: db)) return null;
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
  }) async {
    final String resolvedId = await db.notesDao.resolveNoteRemapTarget(id);
    if (!canCommit()) return null;

    final noteLocks = _container.read(noteLocksProvider);
    var noteAvailable = false;
    await noteLocks.runExclusive(resolvedId, () async {
      if (!canCommit()) return;
      final NoteRow? existingRow = await db.notesDao.getNote(resolvedId);
      if (existingRow == null || existingRow.deleted || !canCommit()) return;
      noteAvailable = true;

      final Map<String, dynamic> existingData = decodeNoteData(
        existingRow.data,
      );
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
    final Note? note = _currentNote();
    if (note == null) throw StateError('The note is no longer available');

    final Map<String, dynamic> attachment = noteAudioAttachment(item, fileId);

    Note? updatedNote;
    if (db != null) {
      updatedNote = await _durableAttach(
        db,
        id: note.id,
        attachment: attachment,
        canCommit: () => _isCurrent(api: api, db: db, authEpoch: authEpoch),
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

  void _applyChange(String id, PendingNoteAudioUpload? updated) {
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
  Future<void> rebindTo(Note previous, Note recovered) async {
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
          for (final PendingNoteAudioUpload item in _pending) item.id: item,
        };
    attemptedUploadIds.addAll(initialUploads.keys);
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
        if (!attemptedUploadIds.add(item.id)) continue;
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
    if (!_isCurrent(api: api, db: db, authEpoch: authEpoch)) return;

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
