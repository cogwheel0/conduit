import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import 'rpc_providers.dart';
import 'session_providers.dart';

/// Every call the workspace makes to the daemon (M6), in one place so a
/// test replaces the daemon by overriding this.
final workspaceActionsProvider = Provider<WorkspaceActions>(
  WorkspaceActions.new,
);

class WorkspaceActions {
  WorkspaceActions(this._ref);

  final Ref _ref;

  Future<T> _call<T>(
    String method,
    Map<String, dynamic>? params,
    T Function(Map<String, dynamic>) decode,
  ) =>
      _ref.read(rpcClientProvider).call(method, params: params, decode: decode);

  Future<WorkspaceAccess> capabilities() => _call(
    ConduitMethods.workspaceCapabilities,
    null,
    WorkspaceAccess.fromJson,
  );

  Future<WorkspacePage> list(WorkspaceQuery query) => _call(
    ConduitMethods.workspaceList,
    query.toJson(),
    WorkspacePage.fromJson,
  );

  Future<WorkspaceDetail> get(WorkspaceKind kind, String id) => _call(
    ConduitMethods.workspaceGet,
    WorkspaceRef(kind: kind, id: id).toJson(),
    WorkspaceDetail.fromJson,
  );

  Future<WorkspaceDetail> save(
    WorkspaceDetail detail, {
    bool create = false,
    bool metadataOnly = false,
  }) => _call(
    ConduitMethods.workspaceSave,
    WorkspaceSave(
      detail: detail,
      create: create,
      metadataOnly: metadataOnly,
    ).toJson(),
    WorkspaceDetail.fromJson,
  );

  Future<void> delete(WorkspaceKind kind, String id) => _call(
    ConduitMethods.workspaceDelete,
    WorkspaceRef(kind: kind, id: id).toJson(),
    (json) => json,
  );

  Future<WorkspaceItem> toggle(WorkspaceKind kind, String id) => _call(
    ConduitMethods.workspaceToggle,
    WorkspaceRef(kind: kind, id: id).toJson(),
    WorkspaceItem.fromJson,
  );

  Future<WorkspaceDetail> setAccess(
    WorkspaceKind kind,
    String id,
    List<WorkspaceGrant> grants,
  ) => _call(
    ConduitMethods.workspaceSetAccess,
    WorkspaceAccessEdit(kind: kind, id: id, grants: grants).toJson(),
    WorkspaceDetail.fromJson,
  );

  Future<List<WorkspacePrincipal>> principals({
    String query = '',
    List<String> ids = const <String>[],
  }) async => (await _call(
    ConduitMethods.workspacePrincipals,
    WorkspacePrincipalQuery(query: query, ids: ids).toJson(),
    WorkspacePrincipals.fromJson,
  )).items;

  Future<WorkspaceExportFile> export(WorkspaceKind kind, {String? id}) => _call(
    ConduitMethods.workspaceExport,
    WorkspaceExportQuery(kind: kind, id: id).toJson(),
    WorkspaceExportFile.fromJson,
  );

  Future<WorkspaceImportResult> import(WorkspaceKind kind, String text) =>
      _call(
        ConduitMethods.workspaceImport,
        WorkspaceImport(kind: kind, text: text).toJson(),
        WorkspaceImportResult.fromJson,
      );

  Future<WorkspaceModelOptions> modelOptions() => _call(
    ConduitMethods.workspaceModelOptions,
    null,
    WorkspaceModelOptions.fromJson,
  );

  Future<WorkspacePromptHistory> promptHistory(String promptId) => _call(
    ConduitMethods.workspacePromptHistory,
    WorkspaceRef(kind: WorkspaceKind.prompts, id: promptId).toJson(),
    WorkspacePromptHistory.fromJson,
  );

  Future<WorkspacePromptDiff> promptDiff(
    String promptId, {
    required String fromId,
    required String toId,
  }) => _call(
    ConduitMethods.workspacePromptDiff,
    WorkspacePromptDiffQuery(
      promptId: promptId,
      fromId: fromId,
      toId: toId,
    ).toJson(),
    WorkspacePromptDiff.fromJson,
  );

  Future<WorkspaceDetail> promptSetVersion(String promptId, String versionId) =>
      _call(
        ConduitMethods.workspacePromptSetVersion,
        WorkspacePromptVersionRef(
          promptId: promptId,
          versionId: versionId,
        ).toJson(),
        WorkspaceDetail.fromJson,
      );

  Future<void> promptDeleteVersion(String promptId, String versionId) => _call(
    ConduitMethods.workspacePromptDeleteVersion,
    WorkspacePromptVersionRef(
      promptId: promptId,
      versionId: versionId,
    ).toJson(),
    (json) => json,
  );

  Future<WorkspaceValves> valves(String toolId, {bool user = false}) => _call(
    ConduitMethods.workspaceValves,
    WorkspaceValvesQuery(toolId: toolId, user: user).toJson(),
    WorkspaceValves.fromJson,
  );

  Future<WorkspaceValves> saveValves(WorkspaceValves valves) => _call(
    ConduitMethods.workspaceSaveValves,
    valves.toJson(),
    WorkspaceValves.fromJson,
  );

  Future<WorkspaceToolDto> toolFromUrl(String url) => _call(
    ConduitMethods.workspaceToolFromUrl,
    WorkspaceUrl(url: url).toJson(),
    WorkspaceToolDto.fromJson,
  );

  Future<WorkspaceFiles> files(
    String knowledgeId, {
    String directoryId = '',
    bool more = false,
  }) => _call(
    ConduitMethods.workspaceFiles,
    WorkspaceFilesQuery(
      knowledgeId: knowledgeId,
      directoryId: directoryId,
      more: more,
    ).toJson(),
    WorkspaceFiles.fromJson,
  );

  Future<WorkspaceFiles> attachFiles(
    String knowledgeId,
    String directoryId,
    List<String> fileIds,
  ) => _call(
    ConduitMethods.workspaceAttachFiles,
    WorkspaceFilesAttach(
      knowledgeId: knowledgeId,
      directoryId: directoryId,
      fileIds: fileIds,
    ).toJson(),
    WorkspaceFiles.fromJson,
  );

  Future<WorkspaceFiles> fileAction(WorkspaceFileAction action) => _call(
    ConduitMethods.workspaceFileAction,
    action.toJson(),
    WorkspaceFiles.fromJson,
  );

  Future<WorkspaceFiles> directoryAction(WorkspaceDirectoryAction action) =>
      _call(
        ConduitMethods.workspaceDirectoryAction,
        action.toJson(),
        WorkspaceFiles.fromJson,
      );

  Future<WorkspaceDetail> knowledgeReset(String knowledgeId) => _call(
    ConduitMethods.workspaceKnowledgeReset,
    WorkspaceRef(kind: WorkspaceKind.knowledge, id: knowledgeId).toJson(),
    WorkspaceDetail.fromJson,
  );

  Future<WorkspaceFiles> knowledgeCleanup(String knowledgeId) => _call(
    ConduitMethods.workspaceKnowledgeCleanup,
    WorkspaceRef(kind: WorkspaceKind.knowledge, id: knowledgeId).toJson(),
    WorkspaceFiles.fromJson,
  );
}

/// What the signed-in user may manage; everything off without an account.
final workspaceAccessProvider = FutureProvider<WorkspaceAccess>((ref) async {
  ref.watch(coreConnectionProvider);
  final signedIn =
      ref.watch(authStatusProvider).value?.isAuthenticated ?? false;
  if (!signedIn) return const WorkspaceAccess();
  return ref.read(workspaceActionsProvider).capabilities();
});

/// The sections the user may open, in the order the navigation shows them.
List<WorkspaceKind> manageableSections(WorkspaceAccess access) => [
  for (final kind in WorkspaceKind.values)
    if (sectionAccess(access, kind).manage) kind,
];

WorkspaceSectionAccess sectionAccess(
  WorkspaceAccess access,
  WorkspaceKind kind,
) => switch (kind) {
  WorkspaceKind.models => access.models,
  WorkspaceKind.knowledge => access.knowledge,
  WorkspaceKind.prompts => access.prompts,
  WorkspaceKind.tools => access.tools,
  WorkspaceKind.skills => access.skills,
};

/// Ticks when a section changes, here or in another window.
final _workspaceChangedProvider = StreamProvider.family<int, WorkspaceKind>((
  ref,
  kind,
) {
  var tick = 0;
  return ref
      .watch(rpcClientProvider)
      .events
      .where(
        (envelope) =>
            envelope.event == ConduitEvents.workspaceChanged &&
            envelope.payload['kind'] == kind.name,
      )
      .map((_) => ++tick);
});

/// A section's search and filters.
typedef WorkspaceFilter = ({String query, String view, String source});

final workspaceFilterProvider =
    NotifierProvider.family<
      WorkspaceFilterNotifier,
      WorkspaceFilter,
      WorkspaceKind
    >(WorkspaceFilterNotifier.new);

class WorkspaceFilterNotifier extends Notifier<WorkspaceFilter> {
  WorkspaceFilterNotifier(this.kind);

  final WorkspaceKind kind;

  @override
  WorkspaceFilter build() => (query: '', view: 'all', source: '');

  void setQuery(String query) =>
      state = (query: query, view: state.view, source: state.source);

  void setView(String view) =>
      state = (query: state.query, view: view, source: state.source);

  void setSource(String source) =>
      state = (query: state.query, view: state.view, source: source);
}

/// A section's list: the first page for its filter, and more on request.
/// Refetched when the section changes anywhere.
final workspacePageProvider =
    AsyncNotifierProvider.family<
      WorkspacePageNotifier,
      WorkspacePage,
      WorkspaceKind
    >(WorkspacePageNotifier.new);

class WorkspacePageNotifier extends AsyncNotifier<WorkspacePage> {
  WorkspacePageNotifier(this.kind);

  final WorkspaceKind kind;

  @override
  Future<WorkspacePage> build() {
    ref.watch(coreConnectionProvider);
    ref.watch(_workspaceChangedProvider(kind));
    final filter = ref.watch(workspaceFilterProvider(kind));
    return ref
        .read(workspaceActionsProvider)
        .list(
          WorkspaceQuery(
            kind: kind,
            query: filter.query,
            view: filter.view,
            source: filter.source,
          ),
        );
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || state.isLoading) return;
    final filter = ref.read(workspaceFilterProvider(kind));
    state = AsyncData(
      await ref
          .read(workspaceActionsProvider)
          .list(
            WorkspaceQuery(
              kind: kind,
              query: filter.query,
              view: filter.view,
              source: filter.source,
              more: true,
            ),
          ),
    );
  }

  /// Puts [item] in place of the one with its id: a toggle's answer.
  void replace(WorkspaceItem item) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(
      current.copyWith(
        items: [
          for (final existing in current.items)
            existing.id == item.id ? item : existing,
        ],
      ),
    );
  }
}

/// One item, as its editor opens it. Not refetched on `workspace.changed`:
/// the editor may hold changes, and it reloads itself after a save.
final workspaceDetailProvider =
    FutureProvider.family<WorkspaceDetail, ({WorkspaceKind kind, String id})>((
      ref,
      key,
    ) {
      ref.watch(coreConnectionProvider);
      return ref.read(workspaceActionsProvider).get(key.kind, key.id);
    });

final workspaceModelOptionsProvider = FutureProvider<WorkspaceModelOptions>((
  ref,
) {
  ref.watch(coreConnectionProvider);
  return ref.read(workspaceActionsProvider).modelOptions();
});

final workspacePromptHistoryProvider =
    FutureProvider.family<WorkspacePromptHistory, String>((ref, promptId) {
      ref.watch(coreConnectionProvider);
      ref.watch(_workspaceChangedProvider(WorkspaceKind.prompts));
      return ref.read(workspaceActionsProvider).promptHistory(promptId);
    });

final workspaceValvesProvider =
    FutureProvider.family<WorkspaceValves, ({String toolId, bool user})>((
      ref,
      key,
    ) {
      return ref
          .read(workspaceActionsProvider)
          .valves(key.toolId, user: key.user);
    });

/// A knowledge base's open folder. Each action answers with the folder as
/// it is afterwards, which becomes the state.
final workspaceFilesProvider =
    AsyncNotifierProvider.family<
      WorkspaceFilesNotifier,
      WorkspaceFiles,
      String
    >(WorkspaceFilesNotifier.new);

class WorkspaceFilesNotifier extends AsyncNotifier<WorkspaceFiles> {
  WorkspaceFilesNotifier(this.knowledgeId);

  final String knowledgeId;

  WorkspaceActions get _actions => ref.read(workspaceActionsProvider);

  String get directoryId => state.value?.directoryId ?? '';

  @override
  Future<WorkspaceFiles> build() {
    ref.watch(coreConnectionProvider);
    return _actions.files(knowledgeId);
  }

  Future<void> _run(Future<WorkspaceFiles> Function() action) async {
    state = AsyncData(await action());
  }

  Future<void> open(String directoryId) =>
      _run(() => _actions.files(knowledgeId, directoryId: directoryId));

  Future<void> refresh() =>
      _run(() => _actions.files(knowledgeId, directoryId: directoryId));

  Future<void> loadMore() => _run(
    () => _actions.files(knowledgeId, directoryId: directoryId, more: true),
  );

  Future<void> attach(List<String> fileIds) =>
      _run(() => _actions.attachFiles(knowledgeId, directoryId, fileIds));

  Future<void> file(
    String fileId,
    WorkspaceFileOp op, {
    String? filename,
    String? targetDirectoryId,
  }) => _run(
    () => _actions.fileAction(
      WorkspaceFileAction(
        knowledgeId: knowledgeId,
        fileId: fileId,
        op: op,
        filename: filename,
        directoryId: targetDirectoryId,
      ),
    ),
  );

  Future<void> directory(
    WorkspaceDirectoryOp op, {
    String? targetId,
    String name = '',
  }) => _run(
    () => _actions.directoryAction(
      WorkspaceDirectoryAction(
        knowledgeId: knowledgeId,
        op: op,
        directoryId: targetId,
        parentId: directoryId,
        name: name,
      ),
    ),
  );

  Future<void> cleanup() => _run(() => _actions.knowledgeCleanup(knowledgeId));
}
