part of 'app_providers.dart';

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
