part of 'app_providers.dart';

/// The account, server and database a project editor opened under.
///
/// The [Folders] notifier outlives an account switch and rebuilds for the next
/// account, so reaching it says nothing about whose folder a later Save would
/// change. The editor captures this before its first await and hands it back
/// for every read and write; once the API, sign-in session or database no
/// longer match, both refuse before sending or writing anything.
@immutable
final class FolderProjectOwner {
  const FolderProjectOwner._(
    this._api,
    this._auth,
    this._ownership,
    this._database,
  );

  final ApiService _api;
  final ApiAuthSnapshot _auth;
  final OpenWebUiCacheOwnershipSnapshot _ownership;
  final AppDatabase _database;
}

// Folders provider — Drift-backed read path (CDT-RFC-001 Phase 1). Renders
// from `FoldersDao.watchFolders()`; server-confirmed mutations land in memory
// and in the database in the same call so the next emission agrees.
// `foldersFeatureEnabledProvider` is now set by the SyncEngine from
// PullResult.
@Riverpod(keepAlive: true)
class Folders extends _$Folders {
  @override
  Future<List<Folder>> build() async {
    if (!ref.watch(isAuthenticatedProvider2)) {
      DebugLogger.log('skip-unauthed', scope: 'folders');
      return const [];
    }

    final db = ref.watch(appDatabaseProvider);
    if (db == null) {
      return const [];
    }

    final completer = Completer<List<Folder>>();
    final subscription = db.foldersDao.watchFolders().listen(
      (rows) {
        final folders = _sort([for (final row in rows) folderFromRow(row)]);
        if (!completer.isCompleted) {
          completer.complete(folders);
          return;
        }
        // Every sync cycle rewrites the folders table inside a transaction
        // (replaceServerFolders), which invalidates this watcher even when
        // nothing changed. Folder is freezed (structural ==) — drop
        // value-identical emissions so the drawer's folder sections don't
        // rebuild once per background pull.
        if (const ListEquality<Object?>().equals(
          state.asData?.value,
          folders,
        )) {
          return;
        }
        if (ref.mounted) {
          state = AsyncData<List<Folder>>(folders);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'watch-failed',
          scope: 'folders',
          error: error,
          stackTrace: stackTrace,
        );
        if (!completer.isCompleted) {
          completer.complete(const <Folder>[]);
        }
      },
    );
    ref.onDispose(subscription.cancel);
    return completer.future;
  }

  Future<void> refresh({bool forceFresh = false}) async {
    await ref
        .read(syncEngineProvider.notifier)
        .requestPull(reason: 'folders-refresh');
  }

  Future<void> warmIfNeeded() async {
    await ref
        .read(syncEngineProvider.notifier)
        .requestPull(reason: 'folders-warm');
  }

  void upsertFolder(Folder folder) {
    _replaceState(
      _upsertItemById(
        state.asData?.value ?? const <Folder>[],
        folder,
        idOf: (item) => item.id,
      ),
    );
    _persistFolder(folder);
  }

  /// Applies a server-confirmed folder upsert.
  void upsertFolderFromRemote(Folder folder) => upsertFolder(folder);

  void updateFolder(String id, Folder Function(Folder folder) transform) {
    final current = state.asData?.value;
    final update = current == null
        ? null
        : _transformItemById(current, id, transform, idOf: (f) => f.id);
    if (update == null) {
      _persistFolderTransform(id, transform);
      _requestReconcilePull(
        action: current == null ? 'update-cold' : 'update-missing',
      );
      return;
    }
    _replaceState(update.items);
    _persistFolder(update.item);
  }

  /// Applies a server-confirmed folder update.
  void updateFolderFromRemote(
    String id,
    Folder Function(Folder folder) transform,
  ) {
    updateFolder(id, transform);
  }

  /// The signed-in account for a project editor to hold until it saves. Null
  /// when no account with a local database is signed in.
  FolderProjectOwner? captureProjectOwner() {
    final api = ref.read(apiServiceProvider);
    final database = ref.read(appDatabaseProvider);
    if (api == null || database == null) return null;
    final ownership = captureOpenWebUiCacheOwnership(ref, api: api);
    if (ownership == null) return null;
    return FolderProjectOwner._(
      api,
      api.captureAuthSnapshot(),
      ownership,
      database,
    );
  }

  /// Whether [owner] is still the signed-in account on the same database.
  bool isCurrentProjectOwner(FolderProjectOwner owner) =>
      openWebUiCacheOwnershipIsCurrent(ref, owner._ownership) &&
      identical(ref.read(appDatabaseProvider), owner._database);

  void _requireProjectOwner(FolderProjectOwner owner) {
    if (!isCurrentProjectOwner(owner)) {
      throw const FolderProjectWriteException(
        FolderProjectWriteFailure.ownerChanged,
      );
    }
  }

  /// The server's current copy of a folder, read as the account that opened
  /// the editor, for the form to refresh from. Null when the server no longer
  /// has the folder, or when this device has edits to it that are not sent yet:
  /// those win until they are pushed, as in a pull, and an older server copy
  /// must not replace them in the form. Throws [FolderProjectWriteException]
  /// when that account is not signed in any more, before the request or when
  /// the answer arrives.
  ///
  /// The server's verdict on this account's write access rides on the same
  /// answer. It is recorded on the local row either way, without touching its
  /// data, so a save that follows is judged by it and not by an older cached
  /// grant. An answer without a verdict leaves what the row says.
  ///
  /// The answer's project `data` is also kept on the row, as [refreshProjectData]
  /// does, so the cache agrees with what the form shows.
  Future<Folder?> loadProjectDetail(
    FolderProjectOwner owner,
    String folderId,
  ) => _readServerDetail(owner, folderId);

  /// A folder as this device holds it after reading the project `data` the
  /// server has for it now, for a new draft in that folder to start from.
  ///
  /// The folder list the server sends is lean and carries no `data`, so the
  /// cached copy can predate a change made in another client, or be missing
  /// altogether for a folder only just listed. The folder itself is asked, as
  /// [owner], and its `data` kept on the row (see
  /// [FoldersDao.recordServerFolderData]). A failed read, offline included,
  /// proves nothing about the defaults and leaves the cache as it is; so does a
  /// row with unsent edits, which are not overridden and need no request.
  ///
  /// Null when the folder is gone. Throws [FolderProjectWriteException] when
  /// [owner] is not the signed-in account any more, so a draft of the next
  /// account never learns this one's defaults.
  Future<Folder?> refreshProjectData(
    FolderProjectOwner owner,
    String folderId,
  ) async {
    final dao = owner._database.foldersDao;
    _requireProjectOwner(owner);
    final row = await dao.getFolder(folderId);
    if (row == null || row.deleted) return null;
    if (!row.dirty) {
      try {
        await _readServerDetail(owner, folderId);
      } on FolderProjectWriteException {
        rethrow;
      } catch (_) {
        // Offline or refused: the cached defaults stay the answer.
      }
    }
    _requireProjectOwner(owner);
    final current = await dao.getFolder(folderId);
    return current == null || current.deleted ? null : folderFromRow(current);
  }

  Future<Folder?> _readServerDetail(
    FolderProjectOwner owner,
    String folderId,
  ) async {
    _requireProjectOwner(owner);
    final database = owner._database;
    final row = await database.foldersDao.getFolder(folderId);
    if (row == null || row.deleted) return null;
    _requireProjectOwner(owner);
    final raw = await owner._api.getFolderById(
      folderId,
      authSnapshot: owner._auth,
    );
    _requireProjectOwner(owner);
    if (raw == null) return null;
    final detail = Folder.fromJson(raw);
    final writeAccess = detail.writeAccess;
    final updatedAt = raw['updated_at'];
    return ref.read(folderLocksProvider).runExclusive(folderId, () async {
      _requireProjectOwner(owner);
      final current = await database.foldersDao.getFolder(folderId);
      if (current == null || current.deleted) return null;
      if (writeAccess != null) {
        await database.foldersDao.recordWriteAccess(
          id: folderId,
          writeAccess: writeAccess,
        );
      }
      await database.foldersDao.recordServerFolderData(
        requestedFor: row,
        data: raw.containsKey('data')
            ? Value(detail.data)
            : const Value.absent(),
        serverUpdatedAt: updatedAt is int ? updatedAt : null,
      );
      return current.dirty ? null : detail;
    });
  }

  /// Whether a file the folder's project lists still exists, asked of the
  /// server as the account that opened the editor. True and false are the
  /// server's own answers (a file it reports as not found is gone, or not
  /// readable by this account). Null when nothing can be said: offline, a
  /// timeout or any other failure is not proof of deletion, and neither is an
  /// answer that arrives after that account has been replaced.
  Future<bool?> projectFileExists(
    FolderProjectOwner owner,
    String fileId,
  ) async {
    if (!isCurrentProjectOwner(owner)) return null;
    bool? exists;
    try {
      await owner._api.getFileInfo(fileId, authSnapshot: owner._auth);
      exists = true;
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) exists = false;
    } catch (_) {}
    return isCurrentProjectOwner(owner) ? exists : null;
  }

  /// Saves edited project defaults. Each argument that is not null replaces
  /// that one key of the folder's `data`; every other key is left as stored
  /// and the queued request carries only the edited keys. An empty [modelIds]
  /// clears the saved models (`null`, which the web client also treats as
  /// "no default" where an empty list would select no model).
  ///
  /// The write is local and durable first, so it also works offline; the
  /// outbox sends it. Under the folder lock the owner is checked again and the
  /// folder's access is judged on its current row, so a grant downgraded or a
  /// folder removed since the editor opened is refused rather than written.
  Future<void> saveProjectDefaults(
    FolderProjectOwner owner,
    String folderId, {
    List<Object?>? files,
    List<Object?>? modelIds,
    String? systemPrompt,
  }) async {
    final patch = <String, dynamic>{
      'files': ?files,
      if (modelIds != null) 'model_ids': modelIds.isEmpty ? null : modelIds,
      'system_prompt': ?systemPrompt,
    };
    if (patch.isEmpty) return;
    _requireProjectOwner(owner);
    final database = owner._database;
    await ref.read(folderLocksProvider).runExclusive(folderId, () async {
      _requireProjectOwner(owner);
      await database.foldersDao.patchFolderDataWithOutbox(
        id: folderId,
        dataPatch: patch,
      );
    });
    if (!isCurrentProjectOwner(owner)) return;
    unawaited(
      ref
          .read(syncEngineProvider.notifier)
          .drainNowForDatabase(database)
          .catchError((Object _) {}),
    );
  }

  void removeFolder(String id) {
    final current = state.asData?.value;
    if (current != null) {
      final removal = _removeItemById(current, id, idOf: (f) => f.id);
      if (removal.didRemove) {
        _replaceState(removal.items);
      }
    }
    final db = ref.read(appDatabaseProvider);
    if (db == null) return;
    unawaited(
      db.foldersDao.hardDelete(id).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        DebugLogger.error(
          'row-delete-failed',
          scope: 'folders',
          error: error,
          stackTrace: stackTrace,
          data: {'id': id},
        );
      }),
    );
  }

  /// Applies a server-confirmed folder deletion.
  void removeFolderFromRemote(String id) => removeFolder(id);

  void _persistFolder(Folder folder) {
    final db = ref.read(appDatabaseProvider);
    if (db == null) return;
    unawaited(
      db.foldersDao.upsertServerFolder(_rawFolder(folder)).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        DebugLogger.error(
          'row-upsert-failed',
          scope: 'folders',
          error: error,
          stackTrace: stackTrace,
          data: {'id': folder.id},
        );
      }),
    );
  }

  void _persistFolderTransform(
    String id,
    Folder Function(Folder folder) transform,
  ) {
    final db = ref.read(appDatabaseProvider);
    if (db == null) return;
    unawaited(
      (() async {
        final row = await db.foldersDao.getFolder(id);
        if (row == null) return;
        await db.foldersDao.upsertServerFolder(
          _rawFolder(transform(folderFromRow(row))),
        );
      })().catchError((Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'row-transform-failed',
          scope: 'folders',
          error: error,
          stackTrace: stackTrace,
          data: {'id': id},
        );
      }),
    );
  }

  void _requestReconcilePull({required String action}) {
    _submitReconcilePull(
      ref,
      reason: 'folders-reconcile',
      scope: 'folders',
      action: action,
    );
  }

  /// `FoldersDao.upsertServerFolder`-shaped raw map (timestamps as server
  /// epoch seconds; everything else rides in rawExtra verbatim).
  static Map<String, dynamic> _rawFolder(Folder folder) {
    final raw = folder.toJson();
    final createdAt = folder.createdAt;
    final updatedAt = folder.updatedAt;
    raw['created_at'] = createdAt == null ? 0 : _epochSecondsOf(createdAt);
    raw['updated_at'] = updatedAt == null ? 0 : _epochSecondsOf(updatedAt);
    return raw;
  }

  List<Folder> _sort(List<Folder> input) {
    final sorted = [...input];
    sorted.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return List<Folder>.unmodifiable(sorted);
  }

  void _replaceState(List<Folder> folders) {
    state = AsyncData<List<Folder>>(_sort(folders));
  }
}

// Files provider
@Riverpod(keepAlive: true)
class UserFiles extends _$UserFiles {
  int _loadGeneration = 0;

  @override
  Future<List<FileInfo>> build() async {
    if (!ref.watch(isAuthenticatedProvider2)) {
      DebugLogger.log('skip-unauthed', scope: 'files');
      return const [];
    }
    final api = ref.watch(apiServiceProvider);
    if (api == null) return const [];
    return _load(api);
  }

  Future<void> refresh() async {
    if (!ref.read(isAuthenticatedProvider2)) {
      state = const AsyncData<List<FileInfo>>([]);
      return;
    }
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      state = const AsyncData<List<FileInfo>>([]);
      return;
    }
    final result = await AsyncValue.guard(() => _load(api));
    if (!ref.mounted) return;
    state = result;
  }

  void upsert(FileInfo file) {
    if (!state.hasValue) {
      return;
    }

    final current = state.requireValue;
    final updated = _upsertItemById(current, file, idOf: (item) => item.id);
    _replaceState(updated);
  }

  void remove(String id) {
    final current = state.asData?.value;
    if (current == null) return;
    final removal = _removeItemById(current, id, idOf: (file) => file.id);
    _replaceState(removal.items);
  }

  Future<List<FileInfo>> _load(ApiService api) async {
    try {
      final loadGeneration = ++_loadGeneration;
      final firstPage = await api.getUserFilesPage(page: 1);
      final initialFiles = _sort(firstPage.items);

      final shouldLoadMore =
          firstPage.isPaginated &&
          firstPage.items.isNotEmpty &&
          (firstPage.total == null ||
              firstPage.items.length < firstPage.total!);

      if (shouldLoadMore) {
        unawaited(
          Future<void>.delayed(Duration.zero, () {
            return _loadRemainingPages(
              api,
              loadGeneration: loadGeneration,
              initialFiles: initialFiles,
              total: firstPage.total,
            );
          }),
        );
      }

      return initialFiles;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'files-failed',
        scope: 'files',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  List<FileInfo> _sort(List<FileInfo> input) {
    final sorted = [...input];
    sorted.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List<FileInfo>.unmodifiable(sorted);
  }

  void _replaceState(List<FileInfo> files) {
    state = AsyncData<List<FileInfo>>(_sort(files));
  }

  Future<void> _loadRemainingPages(
    ApiService api, {
    required int loadGeneration,
    required List<FileInfo> initialFiles,
    required int? total,
  }) async {
    if (!_isCurrentLoad(loadGeneration)) {
      return;
    }

    var page = 2;
    var totalCount = total;
    var loadedFiles = initialFiles;

    try {
      while (true) {
        final pageResult = await api.getUserFilesPage(page: page);
        if (!_isCurrentLoad(loadGeneration)) {
          return;
        }
        if (pageResult.items.isEmpty) {
          return;
        }

        loadedFiles = _mergeFiles(loadedFiles, pageResult.items);
        totalCount ??= pageResult.total;

        final currentFiles = state.asData?.value ?? initialFiles;
        _replaceState(_mergeFiles(currentFiles, pageResult.items));

        if (!pageResult.isPaginated) {
          return;
        }
        if (totalCount != null && loadedFiles.length >= totalCount) {
          return;
        }

        page += 1;
      }
    } catch (error, stackTrace) {
      if (!_isCurrentLoad(loadGeneration)) {
        return;
      }
      DebugLogger.error(
        'files-page-load-failed',
        scope: 'files',
        error: error,
        stackTrace: stackTrace,
        data: {'generation': loadGeneration, 'page': page},
      );
    }
  }

  bool _isCurrentLoad(int loadGeneration) =>
      ref.mounted && _loadGeneration == loadGeneration;

  List<FileInfo> _mergeFiles(
    List<FileInfo> current,
    Iterable<FileInfo> incoming,
  ) {
    final merged = <String, FileInfo>{
      for (final file in current) file.id: file,
    };
    for (final file in incoming) {
      merged[file.id] = file;
    }
    return merged.values.toList(growable: false);
  }
}

@riverpod
Future<List<FileInfo>> searchUserFiles(Ref ref, String query) async {
  if (!ref.watch(isAuthenticatedProvider2)) {
    return const [];
  }

  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    return const [];
  }

  final trimmedQuery = query.trim();
  if (trimmedQuery.isEmpty) {
    return const [];
  }

  try {
    const pageSize = 100;
    final files = <FileInfo>[];
    var offset = 0;

    while (true) {
      final page = await api.searchFiles(
        query: trimmedQuery,
        limit: pageSize,
        offset: offset,
      );
      if (page.isEmpty) {
        break;
      }

      files.addAll(page);
      if (page.length < pageSize) {
        break;
      }

      offset += page.length;
    }

    final deduped = <String, FileInfo>{for (final file in files) file.id: file};
    final sorted = deduped.values.toList(growable: false)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List<FileInfo>.unmodifiable(sorted);
  } catch (error, stackTrace) {
    DebugLogger.error(
      'files-search-failed',
      scope: 'files/search',
      error: error,
      stackTrace: stackTrace,
      data: {'query': trimmedQuery},
    );
    rethrow;
  }
}

// File content provider
@riverpod
Future<String> fileContent(Ref ref, String fileId) async {
  // Protected: require authentication
  if (!ref.read(isAuthenticatedProvider2)) {
    DebugLogger.log('skip-unauthed', scope: 'files/content');
    throw Exception('Not authenticated');
  }
  final api = ref.watch(apiServiceProvider);
  if (api == null) throw Exception('No API service available');

  try {
    return await api.getFileContent(fileId);
  } catch (e) {
    DebugLogger.error(
      'file-content-failed',
      scope: 'files',
      error: e,
      data: {'fileId': fileId},
    );
    throw Exception('Failed to load file content: $e');
  }
}

// Knowledge Base providers
@Riverpod(keepAlive: true)
class KnowledgeBases extends _$KnowledgeBases {
  @override
  Future<List<KnowledgeBase>> build() async {
    if (!ref.watch(isAuthenticatedProvider2)) {
      DebugLogger.log('skip-unauthed', scope: 'knowledge');
      return const [];
    }
    final api = ref.watch(apiServiceProvider);
    if (api == null) return const [];
    return _load(api);
  }

  Future<void> refresh() async {
    if (!ref.read(isAuthenticatedProvider2)) {
      state = const AsyncData<List<KnowledgeBase>>([]);
      return;
    }
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      state = const AsyncData<List<KnowledgeBase>>([]);
      return;
    }
    final result = await AsyncValue.guard(() => _load(api));
    if (!ref.mounted) return;
    state = result;
  }

  void upsert(KnowledgeBase knowledgeBase) {
    final current = state.asData?.value ?? const <KnowledgeBase>[];
    final updated = _upsertItemById(
      current,
      knowledgeBase,
      idOf: (item) => item.id,
    );
    _replaceState(updated);
  }

  void remove(String id) {
    final current = state.asData?.value;
    if (current == null) return;
    final removal = _removeItemById(
      current,
      id,
      idOf: (knowledgeBase) => knowledgeBase.id,
    );
    _replaceState(removal.items);
  }

  Future<List<KnowledgeBase>> _load(ApiService api) async {
    try {
      final knowledgeBases = await api.getKnowledgeBases();
      return _sort(knowledgeBases);
    } catch (e, stackTrace) {
      DebugLogger.error(
        'knowledge-bases-failed',
        scope: 'knowledge',
        error: e,
        stackTrace: stackTrace,
      );
      return const [];
    }
  }

  List<KnowledgeBase> _sort(List<KnowledgeBase> input) {
    final sorted = [...input];
    sorted.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List<KnowledgeBase>.unmodifiable(sorted);
  }

  void _replaceState(List<KnowledgeBase> knowledgeBases) {
    state = AsyncData<List<KnowledgeBase>>(_sort(knowledgeBases));
  }
}

@riverpod
Future<List<KnowledgeBaseItem>> knowledgeBaseItems(Ref ref, String kbId) async {
  // Protected: require authentication
  if (!ref.read(isAuthenticatedProvider2)) {
    DebugLogger.log('skip-unauthed', scope: 'knowledge/items');
    return [];
  }
  final api = ref.watch(apiServiceProvider);
  if (api == null) return [];

  try {
    return await api.getKnowledgeBaseItems(kbId);
  } catch (e) {
    DebugLogger.error('knowledge-items-failed', scope: 'knowledge', error: e);
    return [];
  }
}

// Audio providers
@Riverpod(keepAlive: true)
Future<List<String>> availableVoices(Ref ref) async {
  // Protected: require authentication
  if (!ref.read(isAuthenticatedProvider2)) {
    DebugLogger.log('skip-unauthed', scope: 'voices');
    return [];
  }
  final config = await ref.watch(backendConfigProvider.future);
  if (config == null) return [];

  return config.ttsVoices
      .map((voice) => voice.name.isNotEmpty ? voice.name : voice.id)
      .where((name) => name.isNotEmpty)
      .toList(growable: false);
}

// Image Generation providers
@Riverpod(keepAlive: true)
Future<List<Map<String, dynamic>>> imageModels(Ref ref) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) return [];

  try {
    return await api.getImageModels();
  } catch (e) {
    DebugLogger.error('image-models-failed', scope: 'image-models', error: e);
    return [];
  }
}
