import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../../core/utils/debug_logger.dart';

const _manifestVersion = 1;
const _storeDirectoryName = 'note_audio_uploads';
const _manifestFileName = 'manifest.json';
const _defaultAudioFileName = 'recording.m4a';

enum NoteAudioUploadStatus { pending, uploading, attaching, failed }

@immutable
class PendingNoteAudioUpload {
  const PendingNoteAudioUpload({
    required this.id,
    required this.serverScope,
    required this.accountScope,
    required this.noteId,
    required this.localPath,
    required this.fileName,
    required this.fileSize,
    required this.status,
    required this.createdAt,
    this.lastError,
    this.serverFileId,
    this.sourceCacheFileName,
  });

  final String id;
  final String serverScope;
  final String accountScope;
  final String noteId;
  final String localPath;
  final String fileName;
  final int fileSize;
  final NoteAudioUploadStatus status;
  final DateTime createdAt;
  final String? lastError;
  final String? serverFileId;
  final String? sourceCacheFileName;

  PendingNoteAudioUpload transition(
    NoteAudioUploadStatus nextStatus, {
    String? lastError,
    String? serverFileId,
  }) {
    return PendingNoteAudioUpload(
      id: id,
      serverScope: serverScope,
      accountScope: accountScope,
      noteId: noteId,
      localPath: localPath,
      fileName: fileName,
      fileSize: fileSize,
      status: nextStatus,
      createdAt: createdAt,
      // A retrying/uploading transition intentionally clears a stale failure.
      lastError: lastError,
      serverFileId: serverFileId ?? this.serverFileId,
      sourceCacheFileName: sourceCacheFileName,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': _manifestVersion,
    'id': id,
    'serverScope': serverScope,
    'accountScope': accountScope,
    'noteId': noteId,
    'localFileName': path.basename(localPath),
    'fileName': fileName,
    'fileSize': fileSize,
    'status': status.name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'lastError': lastError,
    'serverFileId': serverFileId,
    // Only a basename is persisted. Recovery resolves it against the app's
    // cache directory, so an absolute device path never enters the manifest.
    'sourceCacheFileName': sourceCacheFileName,
  };

  static PendingNoteAudioUpload fromJson(
    Map<String, dynamic> json, {
    required Directory itemDirectory,
  }) {
    if (json['version'] != _manifestVersion) {
      throw const FormatException('Unsupported note audio manifest version');
    }

    final id = json['id'] as String?;
    final serverScope = json['serverScope'] as String?;
    final accountScope = json['accountScope'] as String?;
    final noteId = json['noteId'] as String?;
    final localFileName = json['localFileName'] as String?;
    final fileName = json['fileName'] as String?;
    final fileSize = (json['fileSize'] as num?)?.toInt();
    final statusName = json['status'] as String?;
    final sourceCacheFileName = json['sourceCacheFileName'] as String?;
    final createdAt = DateTime.tryParse(json['createdAt'] as String? ?? '');
    if (id == null ||
        serverScope == null ||
        accountScope == null ||
        noteId == null ||
        localFileName == null ||
        fileName == null ||
        fileSize == null ||
        statusName == null ||
        createdAt == null ||
        path.basename(localFileName) != localFileName ||
        !RegExp(r'^recording\.[a-z0-9]{1,8}$').hasMatch(localFileName) ||
        (sourceCacheFileName != null &&
            (path.basename(sourceCacheFileName) != sourceCacheFileName ||
                !RegExp(
                  r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$',
                ).hasMatch(sourceCacheFileName)))) {
      throw const FormatException('Invalid note audio manifest');
    }

    final status = NoteAudioUploadStatus.values.firstWhere(
      (candidate) => candidate.name == statusName,
      orElse: () => NoteAudioUploadStatus.failed,
    );
    return PendingNoteAudioUpload(
      id: id,
      serverScope: serverScope,
      accountScope: accountScope,
      noteId: noteId,
      localPath: path.join(itemDirectory.path, localFileName),
      fileName: fileName,
      fileSize: fileSize,
      status: status,
      createdAt: createdAt.toLocal(),
      lastError: json['lastError'] as String?,
      serverFileId: json['serverFileId'] as String?,
      sourceCacheFileName: sourceCacheFileName,
    );
  }
}

typedef NoteAudioUploadCallback =
    Future<String> Function(PendingNoteAudioUpload item, File file);
typedef NoteAudioAttachCallback =
    Future<void> Function(PendingNoteAudioUpload item, String fileId);
typedef NoteAudioUploadChanged = void Function(PendingNoteAudioUpload? item);

/// Durable, account-scoped storage for note recordings awaiting upload.
///
/// Each recording owns a small sidecar manifest in application-support storage.
/// The manifest is written before the recorder's cache file is removed, and the
/// returned server file id is written before note attachment begins. These two
/// ordering guarantees make both network failure and process death recoverable.
class NoteAudioUploadStore {
  NoteAudioUploadStore({
    Future<Directory> Function()? applicationSupportDirectory,
    Future<Directory> Function()? temporaryDirectory,
    String Function()? idGenerator,
  }) : _applicationSupportDirectory =
           applicationSupportDirectory ?? getApplicationSupportDirectory,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _idGenerator = idGenerator ?? const Uuid().v4;

  final Future<Directory> Function() _applicationSupportDirectory;
  final Future<Directory> Function() _temporaryDirectory;
  final String Function() _idGenerator;
  static final Set<String> _activeStageDirectories = <String>{};
  static final Map<String, Future<void>> _itemOperationTails =
      <String, Future<void>>{};

  Future<PendingNoteAudioUpload> stage({
    required File source,
    required String serverId,
    String accountId = '',
    required String noteId,
    required String fileName,
  }) async {
    if (!await source.exists()) {
      throw StateError('Recorded audio file is missing');
    }

    final id = _safeId(_idGenerator());
    final serverScope = _scope(serverId);
    final accountScope = _scope(accountId);
    final noteDirectory = await _noteDirectory(
      serverScope: serverScope,
      accountScope: accountScope,
      noteId: noteId,
    );
    final itemDirectory = Directory(path.join(noteDirectory.path, id));
    await itemDirectory.create(recursive: true);
    final activeStageKey = path.normalize(itemDirectory.path);

    final extension = _safeExtension(fileName);
    final durableFile = File(
      path.join(itemDirectory.path, 'recording$extension'),
    );
    final stagingFile = File(
      path.join(itemDirectory.path, '.staging$extension'),
    );
    final sourceSize = await source.length();
    final item = PendingNoteAudioUpload(
      id: id,
      serverScope: serverScope,
      accountScope: accountScope,
      noteId: noteId,
      localPath: durableFile.path,
      fileName: fileName,
      fileSize: sourceSize,
      status: NoteAudioUploadStatus.pending,
      createdAt: DateTime.now(),
      sourceCacheFileName: path.basename(source.path),
    );
    _activeStageDirectories.add(activeStageKey);
    var stageCompleted = false;
    var sourceMoved = false;
    try {
      // Journal the owning note before copying. An account-wide recovery scan
      // can therefore attribute and surface a process-interrupted stage.
      if (!await save(item)) {
        throw const FileSystemException(
          'Recorded audio staging directory disappeared',
        );
      }
      try {
        // Cache and application-support directories normally share a volume on
        // iOS/Android, making this an atomic relocation with no partial-copy
        // window. Cross-volume/test environments fall back to a recoverable
        // copy while the journal still points at the cache basename.
        await source.rename(stagingFile.path);
        sourceMoved = true;
      } on FileSystemException {
        await source.copy(stagingFile.path);
      }
      final durableSize = await stagingFile.length();
      if (sourceSize != durableSize) {
        throw const FileSystemException('Recorded audio copy was incomplete');
      }
      // Rename is atomic within this directory. Recovery only recognizes the
      // final `recording.*` name, so it can never surface a partial copy.
      await stagingFile.rename(durableFile.path);
      stageCompleted = true;

      // The application-support copy and its manifest are durable now. Losing
      // the cache source after this point cannot lose the recording.
      if (!sourceMoved) {
        try {
          await source.delete();
        } catch (error, stackTrace) {
          DebugLogger.error(
            'note-audio-source-cleanup-failed',
            scope: 'notes/audio',
            error: error,
            stackTrace: stackTrace,
            data: {'id': id},
          );
        }
      }
      return item;
    } catch (_) {
      if (!stageCompleted) {
        var sourceAvailable = !sourceMoved;
        if (sourceMoved && await stagingFile.exists()) {
          try {
            await stagingFile.rename(source.path);
            sourceAvailable = true;
          } catch (restoreError, restoreStackTrace) {
            // Keep the journaled staging directory when restoration fails;
            // recovery can still finish it on the next app start.
            DebugLogger.error(
              'note-audio-source-restore-failed',
              scope: 'notes/audio',
              error: restoreError,
              stackTrace: restoreStackTrace,
              data: {'id': id},
            );
          }
        }
        try {
          if (sourceAvailable) await itemDirectory.delete(recursive: true);
        } catch (cleanupError, cleanupStackTrace) {
          DebugLogger.error(
            'note-audio-stage-cleanup-failed',
            scope: 'notes/audio',
            error: cleanupError,
            stackTrace: cleanupStackTrace,
            data: {'id': id},
          );
        }
      }
      rethrow;
    } finally {
      _activeStageDirectories.remove(activeStageKey);
    }
  }

  Future<List<PendingNoteAudioUpload>> loadForNote({
    required String serverId,
    String accountId = '',
    required String noteId,
  }) async {
    final serverScope = _scope(serverId);
    final accountScope = _scope(accountId);
    final noteDirectory = await _noteDirectory(
      serverScope: serverScope,
      accountScope: accountScope,
      noteId: noteId,
    );
    if (!await noteDirectory.exists()) return <PendingNoteAudioUpload>[];

    final items = <PendingNoteAudioUpload>[];
    await for (final entity in noteDirectory.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final item = await _withItemLock(
        entity,
        () async => await entity.exists()
            ? _readOrRecover(
                entity,
                serverScope: serverScope,
                accountScope: accountScope,
                noteId: noteId,
              )
            : null,
      );
      if (item != null) items.add(item);
    }
    items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return items;
  }

  /// Reloads one caller-owned item from its durable manifest.
  ///
  /// Editors may retain an older in-memory snapshot after another editor has
  /// uploaded or removed the same recording. Processing must therefore begin
  /// from disk, and a missing item directory means that the operation already
  /// completed rather than that the stale snapshot should be saved again.
  Future<PendingNoteAudioUpload?> loadCurrent(
    PendingNoteAudioUpload item,
  ) async {
    final itemDirectory = File(item.localPath).parent;
    await _validateItemDirectory(item, itemDirectory);
    return _withItemLock(
      itemDirectory,
      () async => await itemDirectory.exists()
          ? _readOrRecover(
              itemDirectory,
              serverScope: item.serverScope,
              accountScope: item.accountScope,
              noteId: item.noteId,
            )
          : null,
    );
  }

  /// Loads every recording owned by an account on a server.
  ///
  /// This account-level scan is needed when a note was recorded under a
  /// temporary `local:` id which was remapped to its server id while the app
  /// was closed. Callers still resolve and filter [PendingNoteAudioUpload.noteId]
  /// before displaying or retrying an item.
  Future<List<PendingNoteAudioUpload>> loadForAccount({
    required String serverId,
    String accountId = '',
  }) async {
    final serverScope = _scope(serverId);
    final accountScope = _scope(accountId);
    final accountDirectory = await _accountDirectory(
      serverScope: serverScope,
      accountScope: accountScope,
    );
    if (!await accountDirectory.exists()) {
      return <PendingNoteAudioUpload>[];
    }

    final items = <PendingNoteAudioUpload>[];
    await for (final noteEntity in accountDirectory.list(followLinks: false)) {
      if (noteEntity is! Directory) continue;
      final expectedNoteScope = path.basename(noteEntity.path);
      await for (final itemEntity in noteEntity.list(followLinks: false)) {
        if (itemEntity is! Directory) continue;
        final item = await _withItemLock(
          itemEntity,
          () async => await itemEntity.exists()
              ? _readAccountItem(
                  itemEntity,
                  serverScope: serverScope,
                  accountScope: accountScope,
                  expectedNoteScope: expectedNoteScope,
                )
              : null,
        );
        if (item != null) items.add(item);
      }
    }
    items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return items;
  }

  /// Saves [item] only while its durable directory still exists.
  ///
  /// Returning false is a completion signal: another editor already attached
  /// and removed this upload, so a stale writer must not recreate a ghost job.
  Future<bool> save(PendingNoteAudioUpload item) async {
    final itemDirectory = File(item.localPath).parent;
    await _validateItemDirectory(item, itemDirectory);
    return _withItemLock(
      itemDirectory,
      () => _saveUnlocked(item, itemDirectory),
    );
  }

  Future<bool> _saveUnlocked(
    PendingNoteAudioUpload item,
    Directory itemDirectory,
  ) async {
    if (!await itemDirectory.exists()) return false;

    final manifest = File(path.join(itemDirectory.path, _manifestFileName));
    final temporary = File('${manifest.path}.tmp');
    await temporary.writeAsString(jsonEncode(item.toJson()), flush: true);
    await temporary.rename(manifest.path);
    return true;
  }

  Future<void> remove(PendingNoteAudioUpload item) async {
    final itemDirectory = File(item.localPath).parent;
    await _validateItemDirectory(item, itemDirectory);
    await _withItemLock(itemDirectory, () async {
      if (await itemDirectory.exists()) {
        await itemDirectory.delete(recursive: true);
      }
    });
  }

  Future<PendingNoteAudioUpload?> _readOrRecover(
    Directory itemDirectory, {
    required String serverScope,
    required String accountScope,
    required String noteId,
  }) async {
    if (_activeStageDirectories.contains(path.normalize(itemDirectory.path))) {
      return null;
    }
    final manifest = File(path.join(itemDirectory.path, _manifestFileName));
    try {
      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid note audio manifest root');
      }
      var item = PendingNoteAudioUpload.fromJson(
        decoded,
        itemDirectory: itemDirectory,
      );
      if (item.id != path.basename(itemDirectory.path) ||
          item.serverScope != serverScope ||
          item.accountScope != accountScope ||
          item.noteId != noteId) {
        throw const FormatException('Note audio manifest scope mismatch');
      }
      item = await _recoverInterruptedStage(item);
      if (!await File(item.localPath).exists()) {
        item = item.transition(
          NoteAudioUploadStatus.failed,
          lastError: 'The saved recording file is missing.',
        );
        if (!await _saveUnlocked(item, itemDirectory)) return null;
      }
      return item;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'note-audio-manifest-read-failed',
        scope: 'notes/audio',
        error: error,
        stackTrace: stackTrace,
        data: {'id': path.basename(itemDirectory.path)},
      );
      return _recoverItemDirectory(
        itemDirectory,
        serverScope: serverScope,
        accountScope: accountScope,
        noteId: noteId,
      );
    }
  }

  Future<PendingNoteAudioUpload?> _readAccountItem(
    Directory itemDirectory, {
    required String serverScope,
    required String accountScope,
    required String expectedNoteScope,
  }) async {
    if (_activeStageDirectories.contains(path.normalize(itemDirectory.path))) {
      return null;
    }
    final manifest = File(path.join(itemDirectory.path, _manifestFileName));
    try {
      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid note audio manifest root');
      }
      var item = PendingNoteAudioUpload.fromJson(
        decoded,
        itemDirectory: itemDirectory,
      );
      if (item.id != path.basename(itemDirectory.path) ||
          item.serverScope != serverScope ||
          item.accountScope != accountScope ||
          _scope(item.noteId) != expectedNoteScope) {
        throw const FormatException('Note audio manifest scope mismatch');
      }
      item = await _recoverInterruptedStage(item);
      if (!await File(item.localPath).exists()) {
        item = item.transition(
          NoteAudioUploadStatus.failed,
          lastError: 'The saved recording file is missing.',
        );
        if (!await _saveUnlocked(item, itemDirectory)) return null;
      }
      return item;
    } catch (error, stackTrace) {
      // The note id itself lives inside the manifest, so a corrupt manifest
      // cannot be safely attributed during an account-wide scan. An exact
      // [loadForNote] can still recover its recording directory.
      DebugLogger.error(
        'note-audio-account-manifest-read-failed',
        scope: 'notes/audio',
        error: error,
        stackTrace: stackTrace,
        data: {'id': path.basename(itemDirectory.path)},
      );
      return null;
    }
  }

  Future<PendingNoteAudioUpload> _recoverInterruptedStage(
    PendingNoteAudioUpload item,
  ) async {
    final recording = File(item.localPath);
    if (await recording.exists()) return item;

    final extension = path.extension(item.localPath);
    final staging = File(
      path.join(recording.parent.path, '.staging$extension'),
    );
    var stagingComplete =
        await staging.exists() && await staging.length() == item.fileSize;
    File? copiedSource;
    if (!stagingComplete) {
      final sourceCacheFileName = item.sourceCacheFileName;
      if (sourceCacheFileName == null) return item;

      final temporaryDirectory = await _temporaryDirectory();
      final source = File(
        path.join(temporaryDirectory.path, sourceCacheFileName),
      );
      if (!await source.exists() || await source.length() != item.fileSize) {
        return item;
      }
      if (await staging.exists()) await staging.delete();
      try {
        await source.rename(staging.path);
      } on FileSystemException {
        await source.copy(staging.path);
        copiedSource = source;
      }
      stagingComplete =
          await staging.exists() && await staging.length() == item.fileSize;
      if (!stagingComplete) return item;
    }

    await staging.rename(recording.path);
    if (copiedSource != null) {
      try {
        await copiedSource.delete();
      } catch (error, stackTrace) {
        DebugLogger.error(
          'note-audio-recovered-source-cleanup-failed',
          scope: 'notes/audio',
          error: error,
          stackTrace: stackTrace,
          data: {'id': item.id},
        );
      }
    }
    final recovered = item.transition(
      NoteAudioUploadStatus.failed,
      lastError: 'The recording copy was interrupted and needs to be retried.',
    );
    await _saveUnlocked(recovered, recording.parent);
    return recovered;
  }

  Future<PendingNoteAudioUpload?> _recoverItemDirectory(
    Directory itemDirectory, {
    required String serverScope,
    required String accountScope,
    required String noteId,
  }) async {
    File? recording;
    await for (final entity in itemDirectory.list(followLinks: false)) {
      if (entity is File &&
          path.basename(entity.path).startsWith('recording.')) {
        recording = entity;
        break;
      }
    }
    if (recording == null || !await recording.exists()) return null;

    final item = PendingNoteAudioUpload(
      id: path.basename(itemDirectory.path),
      serverScope: serverScope,
      accountScope: accountScope,
      noteId: noteId,
      localPath: recording.path,
      fileName: _defaultAudioFileName,
      fileSize: await recording.length(),
      status: NoteAudioUploadStatus.failed,
      createdAt: await recording.lastModified(),
      lastError: 'The upload state was interrupted and needs to be retried.',
    );
    return await _saveUnlocked(item, itemDirectory) ? item : null;
  }

  Future<Directory> _noteDirectory({
    required String serverScope,
    required String accountScope,
    required String noteId,
  }) async {
    final accountDirectory = await _accountDirectory(
      serverScope: serverScope,
      accountScope: accountScope,
    );
    return Directory(path.join(accountDirectory.path, _scope(noteId)));
  }

  Future<Directory> _accountDirectory({
    required String serverScope,
    required String accountScope,
  }) async {
    final support = await _applicationSupportDirectory();
    return Directory(
      path.join(support.path, _storeDirectoryName, serverScope, accountScope),
    );
  }

  Future<void> _validateItemDirectory(
    PendingNoteAudioUpload item,
    Directory itemDirectory,
  ) async {
    final expectedNoteDirectory = await _noteDirectory(
      serverScope: item.serverScope,
      accountScope: item.accountScope,
      noteId: item.noteId,
    );
    final expected = path.normalize(
      path.join(expectedNoteDirectory.path, _safeId(item.id)),
    );
    if (path.normalize(itemDirectory.path) != expected ||
        path.normalize(File(item.localPath).parent.path) != expected) {
      throw StateError('Refusing to access note audio outside its scope');
    }
  }

  Future<T> _withItemLock<T>(
    Directory itemDirectory,
    Future<T> Function() operation,
  ) async {
    final key = path.normalize(path.absolute(itemDirectory.path));
    final previous = _itemOperationTails[key] ?? Future<void>.value();
    final release = Completer<void>();
    final tail = release.future;
    _itemOperationTails[key] = tail;

    await previous;
    try {
      return await operation();
    } finally {
      if (identical(_itemOperationTails[key], tail)) {
        _itemOperationTails.remove(key);
      }
      release.complete();
    }
  }

  static String _scope(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static String _safeId(String value) {
    final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    if (safe.isEmpty) {
      throw ArgumentError.value(value, 'id', 'Invalid note audio upload id');
    }
    return safe;
  }

  static String _safeExtension(String fileName) {
    final extension = path.extension(fileName).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)
        ? extension
        : '.m4a';
  }
}

/// Runs the two-phase upload/attach operation against durable store state.
class NoteAudioUploadCoordinator {
  NoteAudioUploadCoordinator({
    required NoteAudioUploadStore store,
    required NoteAudioUploadCallback upload,
    required NoteAudioAttachCallback attach,
    NoteAudioUploadChanged? onChanged,
  }) : _store = store,
       _upload = upload,
       _attach = attach,
       _onChanged = onChanged;

  final NoteAudioUploadStore _store;
  final NoteAudioUploadCallback _upload;
  final NoteAudioAttachCallback _attach;
  final NoteAudioUploadChanged? _onChanged;

  static final Map<String, Future<PendingNoteAudioUpload?>> _inFlight =
      <String, Future<PendingNoteAudioUpload?>>{};
  static final Map<String, Completer<void>> _removalReservations =
      <String, Completer<void>>{};

  /// Atomically reserves an item for deletion across every editor instance.
  /// Returns false while upload/attach work already owns the item.
  static bool tryReserveRemoval(PendingNoteAudioUpload item) {
    final key = _keyFor(item);
    if (_inFlight.containsKey(key) || _removalReservations.containsKey(key)) {
      return false;
    }
    _removalReservations[key] = Completer<void>();
    return true;
  }

  static void releaseRemoval(PendingNoteAudioUpload item) {
    final reservation = _removalReservations.remove(_keyFor(item));
    if (reservation != null && !reservation.isCompleted) {
      reservation.complete();
    }
  }

  /// Lets another editor wait for a reserved deletion instead of interpreting
  /// the coordinator's `null` completion sentinel as a successful attachment.
  static Future<void>? removalCompletion(PendingNoteAudioUpload item) =>
      _removalReservations[_keyFor(item)]?.future;

  static String _keyFor(PendingNoteAudioUpload item) => jsonEncode(<String>[
    item.serverScope,
    item.accountScope,
    item.noteId,
    item.id,
    path.normalize(item.localPath),
  ]);

  Future<PendingNoteAudioUpload?> process(PendingNoteAudioUpload item) {
    final key = _keyFor(item);
    final removal = _removalReservations[key]?.future;
    if (removal != null) return _reloadAfterRemoval(item, removal);
    final existing = _inFlight[key];
    if (existing != null) return _continueAfter(existing);

    late final Future<PendingNoteAudioUpload?> tracked;
    tracked = _processCurrent(item).whenComplete(() {
      if (identical(_inFlight[key], tracked)) {
        _inFlight.remove(key);
      }
    });
    _inFlight[key] = tracked;
    return tracked;
  }

  Future<PendingNoteAudioUpload?> _reloadAfterRemoval(
    PendingNoteAudioUpload item,
    Future<void> removal,
  ) async {
    await removal;
    final current = await _store.loadCurrent(item);
    _notify(current);
    return current;
  }

  Future<PendingNoteAudioUpload?> _continueAfter(
    Future<PendingNoteAudioUpload?> existing,
  ) async {
    final result = await existing;
    if (result == null || result.serverFileId == null) return result;

    // A replacement editor may have joined while the original owner was being
    // disposed during a local-id route remap. The upload itself is shared, but
    // let the current owner take over the idempotent attachment phase.
    return process(result);
  }

  Future<PendingNoteAudioUpload?> _processCurrent(
    PendingNoteAudioUpload staleItem,
  ) async {
    final current = await _store.loadCurrent(staleItem);
    if (current == null) {
      _notify(null);
      return null;
    }
    return _process(current);
  }

  Future<PendingNoteAudioUpload?> _process(PendingNoteAudioUpload item) async {
    var current = item;
    try {
      var fileId = current.serverFileId;
      if (fileId == null) {
        final uploadItem = current;
        current = current.transition(NoteAudioUploadStatus.uploading);
        await _persistAndNotify(current);

        final file = File(current.localPath);
        if (!await file.exists()) {
          throw StateError('Saved recording file is missing');
        }
        // Preserve the durable pre-attempt status for reconciliation. A
        // restored `uploading`/`failed` job may already exist on the server,
        // while a freshly staged `pending` job cannot.
        fileId = await _upload(uploadItem, file);

        // This write is the crash boundary: once it commits, subsequent retry
        // attaches the known server file instead of uploading a duplicate.
        current = current.transition(
          NoteAudioUploadStatus.attaching,
          serverFileId: fileId,
        );
        await _persistAndNotify(current);
      } else {
        current = current.transition(NoteAudioUploadStatus.attaching);
        await _persistAndNotify(current);
      }

      await _attach(current, fileId);
      await _store.remove(current);
      _notify(null);
      return null;
    } catch (error, stackTrace) {
      final safeError = current.serverFileId == null
          ? 'The recording could not be uploaded. Retry when the connection is available.'
          : 'The uploaded recording could not be attached to the note. Retry to finish saving it.';
      current = current.transition(
        NoteAudioUploadStatus.failed,
        lastError: safeError,
      );
      if (!await _store.save(current)) {
        _notify(null);
        return null;
      }
      _notify(current);
      DebugLogger.error(
        'note-audio-upload-failed',
        scope: 'notes/audio',
        stackTrace: stackTrace,
        data: {
          'id': current.id,
          'hasFileId': current.serverFileId != null,
          'errorType': error.runtimeType.toString(),
        },
      );
      return current;
    }
  }

  Future<void> _persistAndNotify(PendingNoteAudioUpload item) async {
    if (!await _store.save(item)) {
      throw StateError('The note audio upload already completed');
    }
    _notify(item);
  }

  void _notify(PendingNoteAudioUpload? item) {
    try {
      _onChanged?.call(item);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'note-audio-upload-callback-failed',
        scope: 'notes/audio',
        error: error,
        stackTrace: stackTrace,
        data: {'id': item?.id},
      );
    }
  }
}
