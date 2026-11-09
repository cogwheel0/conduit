import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:meta/meta.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/features/chat/providers/knowledge_cache_provider.dart';
import 'package:conduit_core/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit_core/features/workspace/providers/workspace_providers.dart';
import 'package:conduit_core/features/workspace/providers/workspace_session.dart';

part 'workspace_knowledge_files.g.dart';

/// A file picked for upload: its name, size in bytes (-1 when the platform
/// cannot tell before reading it), and a way to read it once it is its
/// turn.
typedef WorkspaceUploadSource = ({
  String name,
  int size,
  Future<List<int>> Function() read,
});

/// Progress of the file currently being uploaded into a knowledge base.
@immutable
class WorkspaceUploadProgress {
  const WorkspaceUploadProgress({required this.filename, this.fraction});

  final String filename;

  /// 0..1 send progress, or null when the total size is unknown.
  final double? fraction;
}

/// State for the knowledge file browser: the current directory scope, its
/// child directories/files, breadcrumbs, in-flight ingestion (pending) files,
/// and transient loading/upload flags. Errors are surfaced (never swallowed to
/// an empty list) so the browser can distinguish empty from failed.
@immutable
class WorkspaceKnowledgeBrowserState {
  const WorkspaceKnowledgeBrowserState({
    this.directoryId = '',
    this.breadcrumbs = const [],
    this.directories = const [],
    this.files = const [],
    this.pending = const [],
    this.total = 0,
    this.page = 1,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.isBusy = false,
    this.error,
    this.upload,
  });

  /// Empty string is the root scope (files with no directory).
  final String directoryId;
  final List<WorkspaceKnowledgeDirectory> breadcrumbs;
  final List<WorkspaceKnowledgeDirectory> directories;
  final List<WorkspaceKnowledgeFile> files;
  final List<WorkspacePendingFile> pending;
  final int total;
  final int page;
  final bool isLoading;
  final bool isLoadingMore;
  final bool isBusy;
  final Object? error;
  final WorkspaceUploadProgress? upload;

  bool get isRoot => directoryId.isEmpty;
  bool get hasMore => files.length < total;
  bool get isEmpty =>
      !isLoading &&
      error == null &&
      files.isEmpty &&
      directories.isEmpty &&
      pending.isEmpty;

  /// Ids still being ingested (linked in the background) or failed.
  Set<String> get pendingIds => pending.map((f) => f.id).toSet();

  /// Pending files whose ingestion reported an error/failed state.
  List<WorkspacePendingFile> get failedPending => pending
      .where(
        (f) => (f.status ?? '').toLowerCase() == 'failed' || f.error != null,
      )
      .toList(growable: false);

  WorkspaceKnowledgeBrowserState copyWith({
    String? directoryId,
    List<WorkspaceKnowledgeDirectory>? breadcrumbs,
    List<WorkspaceKnowledgeDirectory>? directories,
    List<WorkspaceKnowledgeFile>? files,
    List<WorkspacePendingFile>? pending,
    int? total,
    int? page,
    bool? isLoading,
    bool? isLoadingMore,
    bool? isBusy,
    Object? error,
    bool clearError = false,
    WorkspaceUploadProgress? upload,
    bool clearUpload = false,
  }) {
    return WorkspaceKnowledgeBrowserState(
      directoryId: directoryId ?? this.directoryId,
      breadcrumbs: breadcrumbs ?? this.breadcrumbs,
      directories: directories ?? this.directories,
      files: files ?? this.files,
      pending: pending ?? this.pending,
      total: total ?? this.total,
      page: page ?? this.page,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      isBusy: isBusy ?? this.isBusy,
      error: clearError ? null : error ?? this.error,
      upload: clearUpload ? null : upload ?? this.upload,
    );
  }
}

/// Owns the file browser for a single knowledge base. Every mutation runs
/// through the shared stale-session guard and reconciles the chat-facing
/// knowledge consumers (knowledge bases list, knowledge cache, user files) plus
/// the workspace collection + detail providers.
@Riverpod(keepAlive: true)
class WorkspaceKnowledgeFiles extends _$WorkspaceKnowledgeFiles {
  int _requestGeneration = 0;

  @override
  Future<WorkspaceKnowledgeBrowserState> build(String knowledgeId) async {
    final session = WorkspaceSessionIdentity.watch(ref);
    final page = await session.api.getWorkspaceKnowledgeFiles(
      knowledgeId,
      directoryId: '',
    );
    final pending = await _loadPending(session.api);
    session.ensureCurrent(ref);
    return WorkspaceKnowledgeBrowserState(
      directoryId: '',
      breadcrumbs: page.breadcrumbs,
      directories: page.directories,
      files: page.items,
      pending: pending,
      total: page.total,
    );
  }

  Future<List<WorkspacePendingFile>> _loadPending(ApiService api) async {
    try {
      return await api.getWorkspaceKnowledgePendingFiles(knowledgeId);
    } catch (_) {
      // Pending status is advisory; never fail the whole browser on it.
      return const [];
    }
  }

  WorkspaceKnowledgeBrowserState get _current =>
      state.asData?.value ?? const WorkspaceKnowledgeBrowserState();

  /// Navigate into a child directory.
  Future<void> openDirectory(String directoryId) =>
      _fetch(directoryId: directoryId, append: false);

  /// Jump to a breadcrumb ancestor, or to root when [directoryId] is empty.
  Future<void> openBreadcrumb(String directoryId) =>
      _fetch(directoryId: directoryId, append: false);

  Future<void> refresh() =>
      _fetch(directoryId: _current.directoryId, append: false);

  Future<void> loadMore() =>
      _fetch(directoryId: _current.directoryId, append: true);

  Future<void> _fetch({
    required String directoryId,
    required bool append,
  }) async {
    final current = _current;
    if (append && (current.isLoadingMore || !current.hasMore)) return;
    final generation = ++_requestGeneration;
    final nextPage = append ? current.page + 1 : 1;
    state = AsyncData(
      current.copyWith(
        directoryId: directoryId,
        isLoading: !append,
        isLoadingMore: append,
        clearError: true,
      ),
    );
    final session = WorkspaceSessionIdentity.read(ref);
    try {
      final page = await session.api.getWorkspaceKnowledgeFiles(
        knowledgeId,
        directoryId: directoryId,
        page: nextPage,
      );
      final pending = append
          ? current.pending
          : await _loadPending(session.api);
      if (generation != _requestGeneration || !session.isCurrent(ref)) return;
      state = AsyncData(
        current.copyWith(
          directoryId: directoryId,
          page: nextPage,
          breadcrumbs: page.breadcrumbs,
          directories: page.directories,
          files: append ? [...current.files, ...page.items] : page.items,
          pending: pending,
          total: page.total,
          isLoading: false,
          isLoadingMore: false,
          isBusy: false,
          clearError: true,
        ),
      );
    } catch (error, stackTrace) {
      if (generation != _requestGeneration || !session.isCurrent(ref)) return;
      state = AsyncData(
        current.copyWith(
          directoryId: directoryId,
          isLoading: false,
          isLoadingMore: false,
          error: error,
        ),
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Reloads only the ingestion (pending) list. When nothing remains pending,
  /// also refreshes the file list so newly-processed files appear.
  Future<void> refreshPending() async {
    final current = _current;
    final session = WorkspaceSessionIdentity.read(ref);
    final pending = await _loadPending(session.api);
    if (!session.isCurrent(ref)) return;
    final hadPending = current.pending.isNotEmpty;
    state = AsyncData(current.copyWith(pending: pending));
    if (hadPending && pending.isEmpty) {
      await refresh();
    }
  }

  // --- File mutations -------------------------------------------------------

  /// Uploads raw bytes to `/files/` then attaches the resulting file into the
  /// current directory. Surfaces send progress via [WorkspaceUploadProgress].
  Future<void> uploadBytes(String filename, List<int> bytes) async {
    await _run(() async {
      final session = WorkspaceSessionIdentity.read(ref);
      await session.api.validateWorkspaceKnowledgeUpload(
        knowledgeId,
        count: 1,
        largestFileSize: bytes.length,
      );
      session.ensureCurrent(ref);
      state = AsyncData(
        _current.copyWith(
          upload: WorkspaceUploadProgress(filename: filename, fraction: 0),
        ),
      );
      final fileId = await session.api.uploadFileBytes(
        filename,
        bytes,
        onProgress: (sent, total) {
          if (!session.isCurrent(ref)) return;
          final fraction = total > 0 ? sent / total : null;
          state = AsyncData(
            _current.copyWith(
              upload: WorkspaceUploadProgress(
                filename: filename,
                fraction: fraction,
              ),
            ),
          );
        },
      );
      session.ensureCurrent(ref);
      await _refuseUnprocessed(
        session,
        await _waitForProcessing(session, [fileId]),
      );
      await _attachUploaded(session.api, [fileId]);
      session.ensureCurrent(ref);
    });
  }

  /// Creates a plain-text file from [content] and attaches it.
  Future<void> addTextFile(String filename, String content) async {
    await _run(() async {
      final session = WorkspaceSessionIdentity.read(ref);
      final name = filename.toLowerCase().endsWith('.txt')
          ? filename
          : '$filename.txt';
      final bytes = utf8.encode(content);
      await session.api.validateWorkspaceKnowledgeUpload(
        knowledgeId,
        count: 1,
        largestFileSize: bytes.length,
      );
      session.ensureCurrent(ref);
      final fileId = await session.api.uploadFileBytes(name, bytes);
      session.ensureCurrent(ref);
      await _refuseUnprocessed(
        session,
        await _waitForProcessing(session, [fileId]),
      );
      await _attachUploaded(session.api, [fileId]);
      session.ensureCurrent(ref);
    });
  }

  /// Attaches a file that already exists on the server into the current dir.
  /// Nothing is uploaded, so the server's own check on linking decides: it
  /// lets a full base take a file it already holds.
  Future<void> attachExisting(String fileId) async {
    await _run(() async {
      final session = WorkspaceSessionIdentity.read(ref);
      try {
        await _attach(session.api, fileId);
      } on DioException catch (error) {
        // The file is the user's own; it stays where it was.
        throw _limitRefusal(error) ?? error;
      }
      session.ensureCurrent(ref);
    });
  }

  /// Uploads [files] and links them into the current directory in one
  /// request.
  ///
  /// Open WebUI 0.13 is asked first whether they fit the knowledge base's
  /// limits, by their count and the largest [WorkspaceUploadSource.size], so
  /// a refused upload sends nothing. When a size is unknown (-1), only the
  /// count is asked about; the server still checks each file's size when it
  /// is linked. Files uploaded before a later failure, or that the server
  /// still refuses to link, are deleted again rather than left among the
  /// user's files.
  Future<void> uploadMany(List<WorkspaceUploadSource> picked) async {
    // An empty file is not uploaded, so it does not count against a limit.
    final files = [
      for (final file in picked)
        if (file.size != 0) file,
    ];
    if (files.isEmpty) return;
    final sizeUnknown = files.any((file) => file.size < 0);
    await _run(() async {
      final session = WorkspaceSessionIdentity.read(ref);
      await session.api.validateWorkspaceKnowledgeUpload(
        knowledgeId,
        count: files.length,
        largestFileSize: sizeUnknown
            ? null
            : files.fold<int>(
                0,
                (largest, file) => file.size > largest ? file.size : largest,
              ),
      );
      session.ensureCurrent(ref);
      final uploaded = <String>[];
      final names = <String, String>{};
      try {
        for (final file in files) {
          final bytes = await file.read();
          if (bytes.isEmpty) continue;
          final id = await session.api.uploadFileBytes(file.name, bytes);
          uploaded.add(id);
          names[id] = file.name;
          session.ensureCurrent(ref);
        }
      } catch (_) {
        await _discardUploads(session.api, uploaded);
        rethrow;
      }
      if (uploaded.isEmpty) return;
      // Files the server could not process are deleted and left out: first,
      // so a link that fails cannot leave them among the user's files. The
      // rest go in, and the user hears why the others did not.
      final failed = await _waitForProcessing(session, uploaded);
      await _discardUploads(session.api, failed.keys.toList());
      final processed = [
        for (final id in uploaded)
          if (!failed.containsKey(id)) id,
      ];
      if (processed.isNotEmpty) {
        await _attachUploaded(session.api, processed);
        session.ensureCurrent(ref);
      }
      if (failed.isNotEmpty) throw _unprocessed(failed, names: names);
    });
  }

  /// Waits until the server has processed [fileIds], which it does in the
  /// background after each upload, so they can be linked; see
  /// [ApiService.waitForFileProcessing]. Returns the uploads it could not
  /// process, with its reason for each. The uploads are deleted again if the
  /// wait fails or the session changes meanwhile.
  Future<Map<String, String>> _waitForProcessing(
    WorkspaceSessionIdentity session,
    List<String> fileIds,
  ) async {
    final failed = <String, String>{};
    try {
      for (final id in fileIds) {
        final error = await session.api.waitForFileProcessing(
          id,
          keepWaiting: () => session.isCurrent(ref),
        );
        session.ensureCurrent(ref);
        if (error != null) failed[id] = error;
      }
    } catch (_) {
      await _discardUploads(session.api, fileIds);
      rethrow;
    }
    return failed;
  }

  /// Deletes the uploads in [failed], which the server could not process,
  /// and throws its reasons.
  Future<void> _refuseUnprocessed(
    WorkspaceSessionIdentity session,
    Map<String, String> failed,
  ) async {
    if (failed.isEmpty) return;
    await _discardUploads(session.api, failed.keys.toList());
    throw _unprocessed(failed);
  }

  /// The server's reasons for not processing the uploads in [failed], each
  /// named from [names] when there is a list of them.
  static KnowledgeUploadRefused _unprocessed(
    Map<String, String> failed, {
    Map<String, String>? names,
  }) => KnowledgeUploadRefused(
    names == null
        ? failed.values.join('\n')
        : [
            for (final entry in failed.entries)
              '${names[entry.key] ?? entry.key}: ${entry.value}',
          ].join('\n'),
  );

  /// Links freshly uploaded [fileIds] into the current directory. When the
  /// server refuses them, as for the knowledge base's limits, they are
  /// deleted so they do not linger among the user's files, and the server's
  /// reason is thrown as [KnowledgeUploadRefused].
  Future<void> _attachUploaded(ApiService api, List<String> fileIds) async {
    try {
      if (fileIds.length == 1) {
        await _attach(api, fileIds.single);
      } else {
        final directoryId = _current.isRoot ? null : _current.directoryId;
        final added = await api.attachWorkspaceKnowledgeFiles(
          knowledgeId,
          fileIds
              .map((id) => (fileId: id, directoryId: directoryId))
              .toList(growable: false),
        );
        // Files the server could not process were not added; the rest were.
        final warning = added?.warning;
        if (warning != null) {
          final linked = {for (final file in added!.files) file.id};
          await _discardUploads(api, [
            for (final id in fileIds)
              if (!linked.contains(id)) id,
          ]);
          throw KnowledgeUploadRefused(warning);
        }
      }
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 400 || status == 413) {
        await _discardUploads(api, fileIds);
      }
      throw _limitRefusal(error) ?? error;
    }
  }

  Future<void> _discardUploads(ApiService api, List<String> fileIds) async {
    for (final id in fileIds) {
      try {
        await api.deleteFile(id);
      } catch (_) {}
    }
  }

  /// The server's reason for refusing files, as [KnowledgeUploadRefused].
  static KnowledgeUploadRefused? _limitRefusal(DioException error) {
    final status = error.response?.statusCode;
    if (status != 400 && status != 413) return null;
    final data = error.response?.data;
    final detail = data is Map ? data['detail'] : null;
    return detail is String && detail.trim().isNotEmpty
        ? KnowledgeUploadRefused(detail.trim())
        : null;
  }

  /// Attaches a single [fileId] into the current directory via the JSON
  /// `/file/add` route (upload-then-link flow, the verified v0.10.2 contract).
  Future<void> _attach(ApiService api, String fileId) async {
    final directoryId = _current.isRoot ? null : _current.directoryId;
    await api.attachWorkspaceKnowledgeFile(
      knowledgeId,
      fileId,
      directoryId: directoryId,
    );
  }

  Future<void> reindex(String fileId) async {
    await _run(() async {
      final session = WorkspaceSessionIdentity.read(ref);
      await session.api.reindexWorkspaceKnowledgeFile(knowledgeId, fileId);
      session.ensureCurrent(ref);
    });
  }

  /// Renames a file by updating the underlying file's filename metadata.
  Future<void> rename(String fileId, String filename) async {
    await _run(() async {
      final session = WorkspaceSessionIdentity.read(ref);
      await session.api.renameFile(fileId, filename);
      session.ensureCurrent(ref);
    });
  }

  /// Moves a file to [directoryId] (empty string / null = root).
  Future<void> move(String fileId, String? directoryId) async {
    await _run(() async {
      final session = WorkspaceSessionIdentity.read(ref);
      final target = (directoryId == null || directoryId.isEmpty)
          ? null
          : directoryId;
      await session.api.moveWorkspaceKnowledgeFile(
        knowledgeId,
        fileId,
        directoryId: target,
      );
      session.ensureCurrent(ref);
    });
  }

  /// Detaches a file from the knowledge base. When [deleteUnderlying] is true
  /// the underlying stored file is deleted too (owner/admin only, gated by the
  /// caller and re-enforced server-side).
  Future<void> detach(String fileId, {required bool deleteUnderlying}) async {
    await _run(() async {
      final session = WorkspaceSessionIdentity.read(ref);
      await session.api.removeWorkspaceKnowledgeFile(
        knowledgeId,
        fileId,
        deleteFile: deleteUnderlying,
      );
      session.ensureCurrent(ref);
    });
  }

  // --- Directory mutations --------------------------------------------------

  Future<void> createDirectory(String name) async {
    await _run(() async {
      final session = WorkspaceSessionIdentity.read(ref);
      await session.api.createWorkspaceKnowledgeDirectory(
        knowledgeId,
        name: name,
        parentId: _current.isRoot ? null : _current.directoryId,
      );
      session.ensureCurrent(ref);
    });
  }

  Future<void> updateDirectory(String directoryId, String name) async {
    await _run(() async {
      final session = WorkspaceSessionIdentity.read(ref);
      await session.api.updateWorkspaceKnowledgeDirectory(
        knowledgeId,
        directoryId,
        name: name,
      );
      session.ensureCurrent(ref);
    });
  }

  Future<void> deleteDirectory(String directoryId) async {
    await _run(() async {
      final session = WorkspaceSessionIdentity.read(ref);
      await session.api.deleteWorkspaceKnowledgeDirectory(
        knowledgeId,
        directoryId,
      );
      session.ensureCurrent(ref);
    });
  }

  // --- Sync -----------------------------------------------------------------

  /// Computes a sync diff for a locally-supplied manifest. Read-only; provided
  /// for parity with the server sync API and covered by unit tests.
  Future<WorkspaceSyncDiff> syncDiff(
    List<Map<String, dynamic>> manifest,
  ) async {
    final session = WorkspaceSessionIdentity.read(ref);
    final diff = await session.api.diffWorkspaceKnowledge(
      knowledgeId,
      manifest,
    );
    session.ensureCurrent(ref);
    return diff;
  }

  /// Removes the given orphaned file/directory ids from the knowledge base.
  Future<void> syncCleanup({
    required List<String> fileIds,
    List<String> directoryIds = const [],
  }) async {
    if (fileIds.isEmpty && directoryIds.isEmpty) return;
    await _run(() async {
      final session = WorkspaceSessionIdentity.read(ref);
      await session.api.cleanupWorkspaceKnowledgeSync(
        knowledgeId,
        fileIds: fileIds,
        directoryIds: directoryIds,
      );
      session.ensureCurrent(ref);
    });
  }

  /// Convenience cleanup that removes files whose ingestion failed.
  Future<void> cleanupFailed() async {
    final failed = _current.failedPending.map((f) => f.id).toList();
    await syncCleanup(fileIds: failed);
  }

  // --- Plumbing -------------------------------------------------------------

  /// Runs [action] with a busy flag, then refreshes the current directory and
  /// reconciles every chat/workspace consumer that shares this knowledge base.
  Future<void> _run(Future<void> Function() action) async {
    final current = _current;
    state = AsyncData(current.copyWith(isBusy: true, clearError: true));
    final session = WorkspaceSessionIdentity.read(ref);
    try {
      await action();
      session.ensureCurrent(ref);
      state = AsyncData(_current.copyWith(clearUpload: true));
      await refresh();
      _reconcile();
    } on KnowledgeUploadRefused {
      // The server said why; the caller shows it, and the browser is not
      // broken. Some files of a batch may have gone in, so the list reloads.
      if (session.isCurrent(ref)) {
        state = AsyncData(_current.copyWith(isBusy: false, clearUpload: true));
        try {
          await refresh();
          _reconcile();
        } catch (_) {}
      }
      rethrow;
    } catch (error, stackTrace) {
      if (session.isCurrent(ref)) {
        state = AsyncData(
          _current.copyWith(isBusy: false, error: error, clearUpload: true),
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Refreshes chat-facing knowledge consumers so uploads/detaches/deletes are
  /// visible everywhere the base is used.
  void _reconcile() {
    ref.invalidate(workspaceKnowledgeDetailProvider(knowledgeId));
    ref.invalidate(knowledgeBasesProvider);
    ref.read(knowledgeCacheProvider.notifier).clearCache();
    ref.invalidate(userFilesProvider);
    // Refresh the owning collection so file counts / updated timestamps track.
    final knowledge = ref.read(workspaceKnowledgeProvider.notifier);
    // Fire and forget, and it re-throws a failed fetch (offline, a 5xx)
    // after recording it in its own state: nothing may be left to escape.
    unawaited(
      knowledge.refresh().catchError((Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'collection-refresh-failed',
          scope: 'workspace/knowledge',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }
}
