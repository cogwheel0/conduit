import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/utils/debug_logger.dart';
import 'package:conduit/features/chat/providers/knowledge_cache_provider.dart';
import 'package:conduit/features/prompts/providers/prompts_providers.dart';
import 'package:conduit/features/tools/providers/tools_providers.dart';
import 'package:conduit/features/workspace/models/workspace_common.dart';
import 'package:conduit/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/features/workspace/providers/workspace_session.dart';

part 'workspace_providers.g.dart';

/// The active server's reported Open WebUI version, or null when unknown.
///
/// Surfaced as a standalone provider so the tools editor can gate saves on the
/// `required_open_webui_version` a tool declares without reaching into the
/// backend config plumbing, and so tests can pin a version cheaply. Fails open
/// (null) while the config is loading or belongs to another server.
final workspaceServerVersionProvider = Provider<String?>((ref) {
  return ref.watch(backendConfigProvider).asData?.value?.version;
});

class WorkspaceCollectionState<T> {
  const WorkspaceCollectionState({
    this.query = '',
    this.view = 'all',
    this.source = '',
    this.page = 1,
    this.items = const [],
    this.total = 0,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.isBusy = false,
    this.error,
  });

  final String query;
  final String view;

  /// Secondary filter dimension used by the Knowledge section to separate local
  /// vs external (connected) sources. Empty means "all sources". Other sections
  /// leave this unset.
  final String source;
  final int page;
  final List<T> items;
  final int total;
  final bool isLoading;
  final bool isLoadingMore;
  final bool isBusy;
  final Object? error;

  bool get hasMore => items.length < total;
  bool get isEmpty => !isLoading && error == null && items.isEmpty;

  WorkspaceCollectionState<T> copyWith({
    String? query,
    String? view,
    String? source,
    int? page,
    List<T>? items,
    int? total,
    bool? isLoading,
    bool? isLoadingMore,
    bool? isBusy,
    Object? error,
    bool clearError = false,
  }) {
    return WorkspaceCollectionState<T>(
      query: query ?? this.query,
      view: view ?? this.view,
      source: source ?? this.source,
      page: page ?? this.page,
      items: items ?? this.items,
      total: total ?? this.total,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      isBusy: isBusy ?? this.isBusy,
      error: clearError ? null : error ?? this.error,
    );
  }
}

List<T> _mergeById<T>(
  List<T> existing,
  List<T> incoming,
  String Function(T item) idOf,
) {
  final merged = <String, T>{for (final item in existing) idOf(item): item};
  for (final item in incoming) {
    merged[idOf(item)] = item;
  }
  return merged.values.toList(growable: false);
}

void _syncModels(Ref ref) {
  ref.invalidate(modelsProvider);
}

void _syncKnowledge(Ref ref) {
  ref.invalidate(knowledgeBasesProvider);
  ref.read(knowledgeCacheProvider.notifier).clearCache();
  ref.invalidate(userFilesProvider);
}

void _syncPrompts(Ref ref) {
  ref.invalidate(promptsListProvider);
}

void _syncSkills(Ref ref) {
  // Model metadata can contain skill relationships, so refresh resolved models.
  ref.invalidate(modelsProvider);
}

@Riverpod(keepAlive: true)
class WorkspaceModels extends _$WorkspaceModels {
  int _requestGeneration = 0;
  @override
  Future<WorkspaceCollectionState<WorkspaceModelSummary>> build() async {
    final session = WorkspaceSessionIdentity.watch(ref);
    final response = await session.api.getWorkspaceModels();
    session.ensureCurrent(ref);
    return WorkspaceCollectionState(
      items: response.items,
      total: response.total,
    );
  }

  Future<void> setQuery(String query) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    state = AsyncData(current.copyWith(query: query, clearError: true));
    await refresh();
  }

  Future<void> setView(String view) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    state = AsyncData(current.copyWith(view: view, clearError: true));
    await refresh();
  }

  Future<void> refresh() async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    final generation = ++_requestGeneration;
    final query = current.query;
    final view = current.view;
    state = AsyncData(current.copyWith(isLoading: true, clearError: true));
    final session = WorkspaceSessionIdentity.read(ref);
    try {
      final response = await session.api.getWorkspaceModels(
        query: query,
        viewOption: view,
      );
      if (generation != _requestGeneration || !session.isCurrent(ref)) return;
      state = AsyncData(
        current.copyWith(
          page: 1,
          items: response.items,
          total: response.total,
          isLoading: false,
          isBusy: false,
          clearError: true,
        ),
      );
      _syncModels(ref);
    } catch (error, stackTrace) {
      if (generation != _requestGeneration || !session.isCurrent(ref)) return;
      state = AsyncData(current.copyWith(isLoading: false, error: error));
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> loadMore() async {
    final current = state.asData?.value;
    if (current == null || current.isLoadingMore || !current.hasMore) return;
    final generation = ++_requestGeneration;
    final query = current.query;
    final view = current.view;
    final nextPage = current.page + 1;
    state = AsyncData(current.copyWith(isLoadingMore: true, clearError: true));
    final session = WorkspaceSessionIdentity.read(ref);
    try {
      final response = await session.api.getWorkspaceModels(
        query: query,
        viewOption: view,
        page: nextPage,
      );
      if (generation != _requestGeneration || !session.isCurrent(ref)) return;
      state = AsyncData(
        current.copyWith(
          page: current.page + 1,
          items: _mergeById(current.items, response.items, (item) => item.id),
          total: response.total,
          isLoadingMore: false,
          isBusy: false,
          clearError: true,
        ),
      );
    } catch (error, stackTrace) {
      if (generation != _requestGeneration || !session.isCurrent(ref)) return;
      state = AsyncData(current.copyWith(isLoadingMore: false, error: error));
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<WorkspaceModelDetail> create(WorkspaceModelForm form) =>
      _mutate((api) => api.createWorkspaceModel(form), detailId: form.id);

  Future<WorkspaceModelDetail> updateItem(WorkspaceModelForm form) =>
      _mutate((api) => api.updateWorkspaceModel(form), detailId: form.id);

  Future<WorkspaceModelDetail> updateAccess(
    String id,
    String name,
    List<WorkspaceAccessGrantInput> grants,
  ) => _mutate(
    (api) => api.updateWorkspaceModelAccess(id, name, grants),
    detailId: id,
  );

  Future<WorkspaceModelDetail> toggle(String id) =>
      _mutate((api) => api.toggleWorkspaceModel(id), detailId: id);

  Future<void> delete(String id) async {
    await _mutateBool((api) => api.deleteWorkspaceModel(id));
    ref.invalidate(workspaceModelDetailProvider(id));
  }

  Future<bool> importItems(List<Map<String, dynamic>> items) async {
    await _mutateBool((api) => api.importWorkspaceModels(items));
    return true;
  }

  /// Returns every readable model for export. Read-only: does not mutate state
  /// and respects the stale-session guard.
  Future<List<WorkspaceModelDetail>> exportAll() async {
    final session = WorkspaceSessionIdentity.read(ref);
    final result = await session.api.exportWorkspaceModels();
    session.ensureCurrent(ref);
    return result;
  }

  Future<List<WorkspaceModelDetail>> sync() async {
    final session = WorkspaceSessionIdentity.read(ref);
    final result = await session.api.syncWorkspaceModels();
    session.ensureCurrent(ref);
    await refresh();
    return result;
  }

  Future<WorkspaceModelDetail> _mutate(
    Future<WorkspaceModelDetail?> Function(ApiService api) action, {
    required String detailId,
  }) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    state = AsyncData(current.copyWith(isBusy: true, clearError: true));
    final session = WorkspaceSessionIdentity.read(ref);
    try {
      final result = await action(session.api);
      session.ensureCurrent(ref);
      if (result == null) {
        throw StateError('Model mutation returned no record.');
      }
      ref.invalidate(workspaceModelDetailProvider(detailId));
      // The write already succeeded; a failure while reloading the collection
      // must not surface as a failed mutation. Isolate the refresh so the write
      // outcome is preserved.
      try {
        await refresh();
      } catch (refreshError) {
        DebugLogger.warning(
          'post-write refresh failed',
          scope: 'workspace/models',
          data: {'error': refreshError.toString()},
        );
        if (session.isCurrent(ref)) {
          state = AsyncData(
            (state.asData?.value ?? current).copyWith(isBusy: false),
          );
        }
      }
      return result;
    } catch (error, stackTrace) {
      if (session.isCurrent(ref)) {
        state = AsyncData(current.copyWith(isBusy: false, error: error));
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _mutateBool(Future<bool> Function(ApiService api) action) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    state = AsyncData(current.copyWith(isBusy: true, clearError: true));
    final session = WorkspaceSessionIdentity.read(ref);
    try {
      final confirmed = await action(session.api);
      session.ensureCurrent(ref);
      if (!confirmed) throw StateError('Model mutation was not confirmed.');
      await refresh();
    } catch (error, stackTrace) {
      if (session.isCurrent(ref)) {
        state = AsyncData(current.copyWith(isBusy: false, error: error));
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
}

@riverpod
Future<WorkspaceModelDetail?> workspaceModelDetail(Ref ref, String id) async {
  final session = WorkspaceSessionIdentity.watch(ref);
  final result = await session.api.getWorkspaceModel(id);
  session.ensureCurrent(ref);
  return result;
}

@Riverpod(keepAlive: true)
class WorkspaceKnowledge extends _$WorkspaceKnowledge {
  int _requestGeneration = 0;
  @override
  Future<WorkspaceCollectionState<WorkspaceKnowledgeSummary>> build() async {
    final session = WorkspaceSessionIdentity.watch(ref);
    final response = await session.api.getWorkspaceKnowledge();
    session.ensureCurrent(ref);
    return WorkspaceCollectionState(
      items: response.items,
      total: response.total,
    );
  }

  Future<void> setQuery(String query) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    state = AsyncData(current.copyWith(query: query, clearError: true));
    await refresh();
  }

  Future<void> setView(String view) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    state = AsyncData(current.copyWith(view: view, clearError: true));
    await refresh();
  }

  /// Sets the local/external source filter (`''`, `'local'`, or `'external'`).
  Future<void> setSource(String source) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    state = AsyncData(current.copyWith(source: source, clearError: true));
    await refresh();
  }

  Future<void> refresh() => _fetch(append: false);
  Future<void> loadMore() => _fetch(append: true);

  Future<void> _fetch({required bool append}) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    if (append && (current.isLoadingMore || !current.hasMore)) return;
    final generation = ++_requestGeneration;
    final query = current.query;
    final view = current.view;
    final source = current.source;
    final nextPage = append ? current.page + 1 : 1;
    state = AsyncData(
      current.copyWith(
        isLoading: !append,
        isLoadingMore: append,
        clearError: true,
      ),
    );
    final session = WorkspaceSessionIdentity.read(ref);
    try {
      final response = await session.api.getWorkspaceKnowledge(
        query: query,
        viewOption: view,
        source: source,
        page: nextPage,
      );
      if (generation != _requestGeneration || !session.isCurrent(ref)) return;
      state = AsyncData(
        current.copyWith(
          page: nextPage,
          items: append
              ? _mergeById(current.items, response.items, (item) => item.id)
              : response.items,
          total: response.total,
          isLoading: false,
          isLoadingMore: false,
          isBusy: false,
          clearError: true,
        ),
      );
      if (!append) _syncKnowledge(ref);
    } catch (error, stackTrace) {
      if (generation != _requestGeneration || !session.isCurrent(ref)) return;
      state = AsyncData(
        current.copyWith(isLoading: false, isLoadingMore: false, error: error),
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<WorkspaceKnowledgeDetail> create(WorkspaceKnowledgeForm form) =>
      _mutate((api) => api.createWorkspaceKnowledge(form));

  Future<WorkspaceKnowledgeDetail> updateItem(
    String id,
    WorkspaceKnowledgeForm form,
  ) => _mutate((api) => api.updateWorkspaceKnowledge(id, form), id: id);

  Future<WorkspaceKnowledgeDetail> updateAccess(
    String id,
    List<WorkspaceAccessGrantInput> grants,
  ) => _mutate((api) => api.updateWorkspaceKnowledgeAccess(id, grants), id: id);

  Future<void> delete(String id) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    state = AsyncData(current.copyWith(isBusy: true, clearError: true));
    final session = WorkspaceSessionIdentity.read(ref);
    try {
      await session.api.deleteKnowledgeBase(id);
      session.ensureCurrent(ref);
      ref.invalidate(workspaceKnowledgeDetailProvider(id));
      await refresh();
    } catch (error, stackTrace) {
      if (session.isCurrent(ref)) {
        state = AsyncData(current.copyWith(isBusy: false, error: error));
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Removes every file from the knowledge base (optionally directories too)
  /// while keeping the base itself. Reconciles chat knowledge consumers.
  Future<WorkspaceKnowledgeDetail> reset(
    String id, {
    bool includeDirectories = true,
  }) => _mutate(
    (api) =>
        api.resetWorkspaceKnowledge(id, includeDirectories: includeDirectories),
    id: id,
  );

  /// Read-only export of a knowledge base as a downloadable archive. Does not
  /// mutate provider state; still honours the stale-session guard.
  Future<List<int>> export(String id) async {
    final session = WorkspaceSessionIdentity.read(ref);
    final bytes = await session.api.exportWorkspaceKnowledge(id);
    session.ensureCurrent(ref);
    return bytes;
  }

  Future<WorkspaceKnowledgeDetail> _mutate(
    Future<WorkspaceKnowledgeDetail?> Function(ApiService api) action, {
    String? id,
  }) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    state = AsyncData(current.copyWith(isBusy: true, clearError: true));
    final session = WorkspaceSessionIdentity.read(ref);
    try {
      final result = await action(session.api);
      session.ensureCurrent(ref);
      if (result == null) {
        throw StateError('Knowledge mutation returned no record.');
      }
      ref.invalidate(workspaceKnowledgeDetailProvider(id ?? result.summary.id));
      // The write already succeeded; isolate the refresh so a reload failure
      // does not surface as a failed mutation.
      try {
        await refresh();
      } catch (refreshError) {
        DebugLogger.warning(
          'post-write refresh failed',
          scope: 'workspace/knowledge',
          data: {'error': refreshError.toString()},
        );
        if (session.isCurrent(ref)) {
          state = AsyncData(
            (state.asData?.value ?? current).copyWith(isBusy: false),
          );
        }
      }
      return result;
    } catch (error, stackTrace) {
      if (session.isCurrent(ref)) {
        state = AsyncData(current.copyWith(isBusy: false, error: error));
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
}

@riverpod
Future<WorkspaceKnowledgeDetail?> workspaceKnowledgeDetail(
  Ref ref,
  String id,
) async {
  final session = WorkspaceSessionIdentity.watch(ref);
  final result = await session.api.getWorkspaceKnowledgeDetail(id);
  session.ensureCurrent(ref);
  return result;
}

@Riverpod(keepAlive: true)
class WorkspacePrompts extends _$WorkspacePrompts {
  int _requestGeneration = 0;
  @override
  Future<WorkspaceCollectionState<WorkspacePromptSummary>> build() async {
    final session = WorkspaceSessionIdentity.watch(ref);
    final response = await session.api.getWorkspacePrompts();
    session.ensureCurrent(ref);
    return WorkspaceCollectionState(
      items: response.items,
      total: response.total,
    );
  }

  Future<void> setQuery(String query) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    state = AsyncData(current.copyWith(query: query, clearError: true));
    await refresh();
  }

  Future<void> setView(String view) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    state = AsyncData(current.copyWith(view: view, clearError: true));
    await refresh();
  }

  Future<void> refresh() => _fetch(append: false);
  Future<void> loadMore() => _fetch(append: true);

  Future<void> _fetch({required bool append}) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    if (append && (current.isLoadingMore || !current.hasMore)) return;
    final generation = ++_requestGeneration;
    final query = current.query;
    final view = current.view;
    final nextPage = append ? current.page + 1 : 1;
    state = AsyncData(
      current.copyWith(
        isLoading: !append,
        isLoadingMore: append,
        clearError: true,
      ),
    );
    final session = WorkspaceSessionIdentity.read(ref);
    try {
      final response = await session.api.getWorkspacePrompts(
        query: query,
        viewOption: view,
        page: nextPage,
      );
      if (generation != _requestGeneration || !session.isCurrent(ref)) return;
      state = AsyncData(
        current.copyWith(
          page: nextPage,
          items: append
              ? _mergeById(current.items, response.items, (item) => item.id)
              : response.items,
          total: response.total,
          isLoading: false,
          isLoadingMore: false,
          isBusy: false,
          clearError: true,
        ),
      );
      if (!append) _syncPrompts(ref);
    } catch (error, stackTrace) {
      if (generation != _requestGeneration || !session.isCurrent(ref)) return;
      state = AsyncData(
        current.copyWith(isLoading: false, isLoadingMore: false, error: error),
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<WorkspacePromptDetail> create(WorkspacePromptForm form) =>
      _mutate((api) => api.createWorkspacePrompt(form));

  Future<WorkspacePromptDetail> updateItem(
    String id,
    WorkspacePromptForm form,
  ) => _mutate((api) => api.updateWorkspacePrompt(id, form), id: id);

  Future<WorkspacePromptDetail> updateAccess(
    String id,
    List<WorkspaceAccessGrantInput> grants,
  ) => _mutate((api) => api.updateWorkspacePromptAccess(id, grants), id: id);

  Future<WorkspacePromptDetail> toggle(String id) =>
      _mutate((api) => api.toggleWorkspacePrompt(id), id: id);

  /// Metadata-only update (name/command/tags). Does not create a history entry
  /// on the server, unlike [updateItem].
  Future<WorkspacePromptDetail> updateMetadata(
    String id, {
    required String name,
    required String command,
    List<String> tags = const [],
  }) => _mutate(
    (api) => api.updateWorkspacePromptMetadata(
      id,
      name: name,
      command: command,
      tags: tags,
    ),
    id: id,
  );

  /// Pins [versionId] as the active production version for the prompt.
  Future<WorkspacePromptDetail> setProductionVersion(
    String id,
    String versionId,
  ) => _mutate((api) => api.setWorkspacePromptVersion(id, versionId), id: id);

  Future<void> delete(String id) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    state = AsyncData(current.copyWith(isBusy: true, clearError: true));
    final session = WorkspaceSessionIdentity.read(ref);
    try {
      await session.api.deletePrompt(id);
      session.ensureCurrent(ref);
      ref.invalidate(workspacePromptDetailProvider(id));
      await refresh();
    } catch (error, stackTrace) {
      if (session.isCurrent(ref)) {
        state = AsyncData(current.copyWith(isBusy: false, error: error));
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Reads one page of version history. Read-only: does not mutate provider
  /// state but still honours the stale-session guard.
  Future<List<WorkspacePromptHistoryEntry>> history(
    String id, {
    int page = 0,
  }) async {
    final session = WorkspaceSessionIdentity.read(ref);
    final result = await session.api.getWorkspacePromptHistory(id, page: page);
    session.ensureCurrent(ref);
    return result;
  }

  /// Reads a single history snapshot. Read-only.
  Future<WorkspacePromptHistoryEntry> historyEntry(
    String id,
    String historyId,
  ) async {
    final session = WorkspaceSessionIdentity.read(ref);
    final result = await session.api.getWorkspacePromptHistoryEntry(
      id,
      historyId,
    );
    session.ensureCurrent(ref);
    return result;
  }

  /// Computes the diff between two history entries. Read-only.
  Future<Map<String, dynamic>> historyDiff(
    String id, {
    required String fromId,
    required String toId,
  }) async {
    final session = WorkspaceSessionIdentity.read(ref);
    final result = await session.api.getWorkspacePromptHistoryDiff(
      id,
      fromId: fromId,
      toId: toId,
    );
    session.ensureCurrent(ref);
    return result;
  }

  /// Deletes a history entry. The server refuses to delete the active
  /// production version. Refreshes the detail so the production marker stays
  /// accurate.
  Future<void> deleteHistoryEntry(String id, String historyId) async {
    final session = WorkspaceSessionIdentity.read(ref);
    final confirmed = await session.api.deleteWorkspacePromptHistoryEntry(
      id,
      historyId,
    );
    session.ensureCurrent(ref);
    if (!confirmed) {
      throw StateError('Prompt history deletion was not confirmed.');
    }
    ref.invalidate(workspacePromptDetailProvider(id));
  }

  /// Imports a single prompt definition by creating it. Fail-closed: throws
  /// when the server does not confirm the create. Does not refresh the
  /// collection — the caller batches a single [refresh] after the import run so
  /// slash suggestions update once.
  Future<void> importPrompt(WorkspacePromptForm form) async {
    final session = WorkspaceSessionIdentity.read(ref);
    final result = await session.api.createWorkspacePrompt(form);
    session.ensureCurrent(ref);
    if (result == null) {
      throw StateError('Prompt import returned no record.');
    }
  }

  Future<WorkspacePromptDetail> _mutate(
    Future<WorkspacePromptDetail?> Function(ApiService api) action, {
    String? id,
  }) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    state = AsyncData(current.copyWith(isBusy: true, clearError: true));
    final session = WorkspaceSessionIdentity.read(ref);
    try {
      final result = await action(session.api);
      session.ensureCurrent(ref);
      if (result == null) {
        throw StateError('Prompt mutation returned no record.');
      }
      ref.invalidate(workspacePromptDetailProvider(id ?? result.id));
      // The write already succeeded; isolate the refresh so a reload failure
      // does not surface as a failed mutation.
      try {
        await refresh();
      } catch (refreshError) {
        DebugLogger.warning(
          'post-write refresh failed',
          scope: 'workspace/prompts',
          data: {'error': refreshError.toString()},
        );
        if (session.isCurrent(ref)) {
          state = AsyncData(
            (state.asData?.value ?? current).copyWith(isBusy: false),
          );
        }
      }
      return result;
    } catch (error, stackTrace) {
      if (session.isCurrent(ref)) {
        state = AsyncData(current.copyWith(isBusy: false, error: error));
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
}

@riverpod
Future<WorkspacePromptDetail?> workspacePromptDetail(Ref ref, String id) async {
  final session = WorkspaceSessionIdentity.watch(ref);
  final result = await session.api.getWorkspacePrompt(id);
  session.ensureCurrent(ref);
  return result;
}

@Riverpod(keepAlive: true)
class WorkspaceTools extends _$WorkspaceTools {
  int _requestGeneration = 0;
  @override
  Future<WorkspaceCollectionState<WorkspaceToolSummary>> build() async {
    final session = WorkspaceSessionIdentity.watch(ref);
    final items = await session.api.getWorkspaceTools();
    session.ensureCurrent(ref);
    return WorkspaceCollectionState(items: items, total: items.length);
  }

  Future<void> setQuery(String query) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    state = AsyncData(current.copyWith(query: query, clearError: true));
    await refresh();
  }

  Future<void> setView(String view) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    state = AsyncData(current.copyWith(view: view, clearError: true));
    await refresh();
  }

  Future<void> refresh() async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    final generation = ++_requestGeneration;
    final query = current.query.trim().toLowerCase();
    state = AsyncData(current.copyWith(isLoading: true, clearError: true));
    final session = WorkspaceSessionIdentity.read(ref);
    try {
      var items = await session.api.getWorkspaceTools();
      if (generation != _requestGeneration || !session.isCurrent(ref)) return;
      if (query.isNotEmpty) {
        items = items
            .where(
              (item) =>
                  item.name.toLowerCase().contains(query) ||
                  item.id.toLowerCase().contains(query),
            )
            .toList(growable: false);
      }
      state = AsyncData(
        current.copyWith(
          page: 1,
          items: items,
          total: items.length,
          isLoading: false,
          isBusy: false,
          clearError: true,
        ),
      );
      await _reconcileChatConsumers();
    } catch (error, stackTrace) {
      if (generation != _requestGeneration || !session.isCurrent(ref)) return;
      state = AsyncData(current.copyWith(isLoading: false, error: error));
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> loadMore() async {}

  Future<WorkspaceToolDetail> create(WorkspaceToolForm form) =>
      _mutate((api) => api.createWorkspaceTool(form), id: form.id);

  Future<WorkspaceToolDetail> updateItem(String id, WorkspaceToolForm form) =>
      _mutate((api) => api.updateWorkspaceTool(id, form), id: id);

  Future<WorkspaceToolDetail> updateAccess(
    String id,
    List<WorkspaceAccessGrantInput> grants,
  ) => _mutate((api) => api.updateWorkspaceToolAccess(id, grants), id: id);

  Future<void> delete(String id) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    state = AsyncData(current.copyWith(isBusy: true, clearError: true));
    final session = WorkspaceSessionIdentity.read(ref);
    try {
      await session.api.deleteTool(id);
      session.ensureCurrent(ref);
      ref.invalidate(workspaceToolDetailProvider(id));
      // refresh() reconciles chat consumers (cache + selected/auto-selected
      // tool ids), which prunes the just-deleted id.
      await refresh();
    } catch (error, stackTrace) {
      if (session.isCurrent(ref)) {
        state = AsyncData(current.copyWith(isBusy: false, error: error));
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Imports a single tool definition by creating it. Fail-closed: throws when
  /// the server does not confirm the create. Does not refresh the collection —
  /// the caller batches a single [refresh] after the import run so chat tool
  /// consumers reconcile once.
  Future<void> importTool(WorkspaceToolForm form) async {
    final session = WorkspaceSessionIdentity.read(ref);
    final result = await session.api.createWorkspaceTool(form);
    session.ensureCurrent(ref);
    if (result == null) {
      throw StateError('Tool import returned no record.');
    }
  }

  /// Returns every readable tool via the dedicated `/tools/export` endpoint as
  /// raw maps (full detail, including content/specs). Read-only: does not mutate
  /// state and respects the stale-session guard.
  Future<List<Map<String, dynamic>>> exportAll() async {
    final session = WorkspaceSessionIdentity.read(ref);
    final result = await session.api.exportTools();
    session.ensureCurrent(ref);
    return result;
  }

  /// Fetches one tool's full detail (content, specs, manifest) for a per-item
  /// export. Read-only.
  Future<Map<String, dynamic>> exportOne(String id) async {
    final session = WorkspaceSessionIdentity.read(ref);
    final result = await session.api.getTool(id);
    session.ensureCurrent(ref);
    return result;
  }

  /// Admin-only: fetches a tool definition from a URL, normalizing GitHub
  /// `tree`/`blob` URLs to their raw form first. The result prefills an unsaved
  /// create editor. Read-only: does not mutate provider state.
  Future<Map<String, dynamic>> loadFromUrl(String url) async {
    final session = WorkspaceSessionIdentity.read(ref);
    final result = await session.api.loadToolFromUrl(url);
    session.ensureCurrent(ref);
    return result;
  }

  // --- Valves ---------------------------------------------------------------
  // Valve reads/writes are per-tool configuration and never touch the
  // collection state, but still honour the stale-session guard.

  Future<Map<String, dynamic>> toolValves(String id) async {
    final session = WorkspaceSessionIdentity.read(ref);
    final result = await session.api.getToolValves(id);
    session.ensureCurrent(ref);
    return result;
  }

  Future<WorkspaceValveSpec?> toolValvesSpec(String id) async {
    final session = WorkspaceSessionIdentity.read(ref);
    final result = await session.api.getToolValvesSpec(id);
    session.ensureCurrent(ref);
    return result;
  }

  Future<void> updateToolValves(String id, Map<String, dynamic> valves) async {
    final session = WorkspaceSessionIdentity.read(ref);
    await session.api.updateToolValves(id, valves);
    session.ensureCurrent(ref);
  }

  Future<Map<String, dynamic>> userToolValves(String id) async {
    final session = WorkspaceSessionIdentity.read(ref);
    final result = await session.api.getUserToolValves(id);
    session.ensureCurrent(ref);
    return result;
  }

  Future<WorkspaceValveSpec?> userToolValvesSpec(String id) async {
    final session = WorkspaceSessionIdentity.read(ref);
    final result = await session.api.getUserToolValvesSpec(id);
    session.ensureCurrent(ref);
    return result;
  }

  Future<void> updateUserToolValves(
    String id,
    Map<String, dynamic> valves,
  ) async {
    final session = WorkspaceSessionIdentity.read(ref);
    await session.api.updateUserToolValves(id, valves);
    session.ensureCurrent(ref);
  }

  Future<WorkspaceToolDetail> _mutate(
    Future<WorkspaceToolDetail?> Function(ApiService api) action, {
    required String id,
  }) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    state = AsyncData(current.copyWith(isBusy: true, clearError: true));
    final session = WorkspaceSessionIdentity.read(ref);
    try {
      final result = await action(session.api);
      session.ensureCurrent(ref);
      if (result == null) throw StateError('Tool mutation returned no record.');
      ref.invalidate(workspaceToolDetailProvider(id));
      // The write already succeeded; isolate the refresh so a reload failure
      // does not surface as a failed mutation.
      try {
        await refresh();
      } catch (refreshError) {
        DebugLogger.warning(
          'post-write refresh failed',
          scope: 'workspace/tools',
          data: {'error': refreshError.toString()},
        );
        if (session.isCurrent(ref)) {
          state = AsyncData(
            (state.asData?.value ?? current).copyWith(isBusy: false),
          );
        }
      }
      return result;
    } catch (error, stackTrace) {
      if (session.isCurrent(ref)) {
        state = AsyncData(current.copyWith(isBusy: false, error: error));
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Reconciles the chat-side tool consumers after the workspace list changes:
  /// re-fetches and re-persists the [toolsListProvider] cache (replacing the
  /// stale [OptimizedStorageService] snapshot) and prunes any selected /
  /// auto-selected tool ids that no longer resolve to a live tool. Never throws
  /// — a chat-cache hiccup must not fail a workspace mutation.
  Future<void> _reconcileChatConsumers() async {
    final session = WorkspaceSessionIdentity.read(ref);
    try {
      await ref.read(toolsListProvider.notifier).refresh();
      if (!session.isCurrent(ref)) return;
      final available = (ref.read(toolsListProvider).asData?.value ?? const [])
          .map((tool) => tool.id)
          .toSet();
      final selected = ref.read(selectedToolIdsProvider);
      final pruned = selected
          .where(available.contains)
          .toList(growable: false);
      if (pruned.length != selected.length) {
        ref.read(selectedToolIdsProvider.notifier).set(pruned);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'tool chat-consumer reconcile failed',
        scope: 'workspace/tools',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

@riverpod
Future<WorkspaceToolDetail?> workspaceToolDetail(Ref ref, String id) async {
  final session = WorkspaceSessionIdentity.watch(ref);
  final json = await session.api.getTool(id);
  session.ensureCurrent(ref);
  return WorkspaceToolSummary.fromJson(json);
}

@Riverpod(keepAlive: true)
class WorkspaceSkills extends _$WorkspaceSkills {
  int _requestGeneration = 0;
  @override
  Future<WorkspaceCollectionState<WorkspaceSkillSummary>> build() async {
    final session = WorkspaceSessionIdentity.watch(ref);
    final response = await session.api.getWorkspaceSkills();
    session.ensureCurrent(ref);
    return WorkspaceCollectionState(
      items: response.items,
      total: response.total,
    );
  }

  Future<void> setQuery(String query) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    state = AsyncData(current.copyWith(query: query, clearError: true));
    await refresh();
  }

  Future<void> setView(String view) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    state = AsyncData(current.copyWith(view: view, clearError: true));
    await refresh();
  }

  Future<void> refresh() => _fetch(append: false);
  Future<void> loadMore() => _fetch(append: true);

  Future<void> _fetch({required bool append}) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    if (append && (current.isLoadingMore || !current.hasMore)) return;
    final generation = ++_requestGeneration;
    final query = current.query;
    final view = current.view;
    final nextPage = append ? current.page + 1 : 1;
    state = AsyncData(
      current.copyWith(
        isLoading: !append,
        isLoadingMore: append,
        clearError: true,
      ),
    );
    final session = WorkspaceSessionIdentity.read(ref);
    try {
      final response = await session.api.getWorkspaceSkills(
        query: query,
        viewOption: view,
        page: nextPage,
      );
      if (generation != _requestGeneration || !session.isCurrent(ref)) return;
      state = AsyncData(
        current.copyWith(
          page: nextPage,
          items: append
              ? _mergeById(current.items, response.items, (item) => item.id)
              : response.items,
          total: response.total,
          isLoading: false,
          isLoadingMore: false,
          isBusy: false,
          clearError: true,
        ),
      );
      if (!append) _syncSkills(ref);
    } catch (error, stackTrace) {
      if (generation != _requestGeneration || !session.isCurrent(ref)) return;
      state = AsyncData(
        current.copyWith(isLoading: false, isLoadingMore: false, error: error),
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<WorkspaceSkillDetail> create(WorkspaceSkillForm form) =>
      _mutate((api) => api.createWorkspaceSkill(form), id: form.id);

  Future<WorkspaceSkillDetail> updateItem(String id, WorkspaceSkillForm form) =>
      _mutate((api) => api.updateWorkspaceSkill(id, form), id: id);

  Future<WorkspaceSkillDetail> updateAccess(
    String id,
    List<WorkspaceAccessGrantInput> grants,
  ) => _mutate((api) => api.updateWorkspaceSkillAccess(id, grants), id: id);

  Future<WorkspaceSkillDetail> toggle(String id) =>
      _mutate((api) => api.toggleWorkspaceSkill(id), id: id);

  Future<void> delete(String id) async {
    await _mutateBool((api) => api.deleteWorkspaceSkill(id));
    ref.invalidate(workspaceSkillDetailProvider(id));
  }

  /// Imports a single skill definition by creating it. Fail-closed: throws when
  /// the server does not confirm the create. Does not refresh the collection —
  /// the caller batches a single [refresh] after the import run so model skill
  /// selectors/runtime metadata reconcile once.
  Future<void> importSkill(WorkspaceSkillForm form) async {
    final session = WorkspaceSessionIdentity.read(ref);
    final result = await session.api.createWorkspaceSkill(form);
    session.ensureCurrent(ref);
    if (result == null) {
      throw StateError('Skill import returned no record.');
    }
  }

  /// Returns every readable skill (with content) for export via the dedicated
  /// `/skills/export` endpoint. Read-only: does not mutate state and respects
  /// the stale-session guard.
  Future<List<WorkspaceSkillDetail>> exportAll() async {
    final session = WorkspaceSessionIdentity.read(ref);
    final result = await session.api.exportWorkspaceSkills();
    session.ensureCurrent(ref);
    return result;
  }

  Future<WorkspaceSkillDetail> _mutate(
    Future<WorkspaceSkillDetail?> Function(ApiService api) action, {
    required String id,
  }) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    state = AsyncData(current.copyWith(isBusy: true, clearError: true));
    final session = WorkspaceSessionIdentity.read(ref);
    try {
      final result = await action(session.api);
      session.ensureCurrent(ref);
      if (result == null) {
        throw StateError('Skill mutation returned no record.');
      }
      ref.invalidate(workspaceSkillDetailProvider(id));
      // The write already succeeded; isolate the refresh so a reload failure
      // does not surface as a failed mutation.
      try {
        await refresh();
      } catch (refreshError) {
        DebugLogger.warning(
          'post-write refresh failed',
          scope: 'workspace/skills',
          data: {'error': refreshError.toString()},
        );
        if (session.isCurrent(ref)) {
          state = AsyncData(
            (state.asData?.value ?? current).copyWith(isBusy: false),
          );
        }
      }
      return result;
    } catch (error, stackTrace) {
      if (session.isCurrent(ref)) {
        state = AsyncData(current.copyWith(isBusy: false, error: error));
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _mutateBool(Future<bool> Function(ApiService api) action) async {
    final current = state.asData?.value ?? const WorkspaceCollectionState();
    state = AsyncData(current.copyWith(isBusy: true, clearError: true));
    final session = WorkspaceSessionIdentity.read(ref);
    try {
      final confirmed = await action(session.api);
      session.ensureCurrent(ref);
      if (!confirmed) throw StateError('Skill mutation was not confirmed.');
      await refresh();
    } catch (error, stackTrace) {
      if (session.isCurrent(ref)) {
        state = AsyncData(current.copyWith(isBusy: false, error: error));
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
}

@riverpod
Future<WorkspaceSkillDetail?> workspaceSkillDetail(Ref ref, String id) async {
  final session = WorkspaceSessionIdentity.watch(ref);
  final result = await session.api.getWorkspaceSkill(id);
  session.ensureCurrent(ref);
  return result;
}
