import 'dart:async';

import 'package:checks/checks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/models/tool.dart';
import 'package:conduit/core/models/user.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/tools/providers/tools_providers.dart';
import 'package:conduit/features/workspace/models/workspace_common.dart';
import 'package:conduit/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/features/workspace/providers/workspace_providers.dart';

void main() {
  test(
    'models collection refreshes and loads more without duplicates',
    () async {
      final api = _WorkspaceModelsApi();
      final container = _container(api);
      addTearDown(container.dispose);

      final initial = await container.read(workspaceModelsProvider.future);
      check(initial.items.map((item) => item.id)).deepEquals(['model-1']);
      check(initial.total).equals(2);

      await container.read(workspaceModelsProvider.notifier).loadMore();

      final loaded = container.read(workspaceModelsProvider).requireValue;
      check(
        loaded.items.map((item) => item.id),
      ).deepEquals(['model-1', 'model-2']);
      check(loaded.page).equals(2);
      check(loaded.hasMore).isFalse();
    },
  );

  test('loadMore is a no-op while a refresh is in flight', () async {
    final api = _BlockingRefreshModelsApi();
    final container = _container(api);
    addTearDown(container.dispose);

    await container.read(workspaceModelsProvider.future);
    final notifier = container.read(workspaceModelsProvider.notifier);

    // Start a refresh that blocks on a gate the test controls. `refresh` sets
    // `isLoading: true` synchronously before awaiting the request.
    final refreshFuture = notifier.refresh();
    check(container.read(workspaceModelsProvider).requireValue.isLoading)
        .isTrue();

    // A load-more during the in-flight refresh must be rejected: it must not
    // issue a page-2 request nor bump the request generation (which would
    // strand the outstanding refresh with `isLoading` stuck true).
    await notifier.loadMore();
    // Only the build (page 1) and the in-flight refresh (page 1) were requested.
    check(api.requestedPages).deepEquals([1, 1]);

    // Completing the refresh resolves cleanly — proof the load-more did not
    // discard it. `isLoading` clears and the page is not corrupted.
    api.openGate();
    await refreshFuture;
    final state = container.read(workspaceModelsProvider).requireValue;
    check(state.isLoading).isFalse();
    check(state.page).equals(1);
    check(state.items.map((item) => item.id)).deepEquals(['model-1']);
  });

  test('management errors remain visible and preserve prior items', () async {
    final api = _WorkspaceModelsApi();
    final container = _container(api);
    addTearDown(container.dispose);

    await container.read(workspaceModelsProvider.future);
    api.refreshError = StateError('server rejected management request');

    await check(
      container.read(workspaceModelsProvider.notifier).refresh(),
    ).throws<StateError>();

    final state = container.read(workspaceModelsProvider).requireValue;
    check(state.items.map((item) => item.id)).deepEquals(['model-1']);
    check(state.error).isA<StateError>();
    check(state.isLoading).isFalse();
  });

  test('mutation succeeds even when the post-write refresh fails', () async {
    final api = _WorkspaceModelsApi();
    final container = _container(api);
    addTearDown(container.dispose);

    await container.read(workspaceModelsProvider.future);
    // The write endpoint succeeds, but reloading the collection afterwards
    // throws. The mutation must not surface as a failure.
    api.refreshError = StateError('refresh failed');

    final result = await container
        .read(workspaceModelsProvider.notifier)
        .toggle('model-1');
    check(result.id).equals('model-1');

    final state = container.read(workspaceModelsProvider).requireValue;
    // The busy flag is released and the prior items are preserved.
    check(state.isBusy).isFalse();
    check(state.items.map((item) => item.id)).deepEquals(['model-1']);
  });

  test('bool mutation (delete) succeeds when the post-write refresh fails', () async {
    final api = _WorkspaceModelsApi();
    final container = _container(api);
    addTearDown(container.dispose);

    await container.read(workspaceModelsProvider.future);
    // The delete endpoint confirms, but reloading the collection afterwards
    // throws. The deletion must not surface as a failure (the record is gone).
    api.refreshError = StateError('refresh failed');

    await container.read(workspaceModelsProvider.notifier).delete('model-1');
    check(api.deleted).deepEquals(['model-1']);

    final state = container.read(workspaceModelsProvider).requireValue;
    // The busy flag is released and the prior items are preserved.
    check(state.isBusy).isFalse();
    check(state.items.map((item) => item.id)).deepEquals(['model-1']);
  });

  test('exporting prompts pages the full list beyond the first page', () async {
    final api = _WorkspacePromptsApi();
    final container = _container(api);
    addTearDown(container.dispose);

    // The in-UI list only loads page 1, but the export must include every page.
    await container.read(workspacePromptsProvider.future);
    api.pagesRequested.clear();
    final all = await container
        .read(workspacePromptsProvider.notifier)
        .loadAllForExport();

    check(all.map((item) => item.id)).deepEquals([
      'prompt-1',
      'prompt-2',
      'prompt-3',
    ]);
    // The export paged past the first page rather than stopping at it.
    check(api.pagesRequested).deepEquals([1, 2]);
  });

  test('changing the tool query keeps direct_server selections', () async {
    final api = _WorkspaceToolsApi();
    // The chat cache reflects only the regular tool 'beta_tool'; 'alpha' was
    // removed and 'direct_server:mcp-1' never appears in the regular list.
    final container = _toolsContainer(
      api,
      cacheTools: [const Tool(id: 'beta_tool', name: 'Beta')],
    );
    addTearDown(container.dispose);

    await container.read(workspaceToolsProvider.future);
    container.read(selectedToolIdsProvider.notifier).set([
      'alpha',
      'beta_tool',
      'direct_server:mcp-1',
    ]);

    // A plain refresh (e.g. a search-query change) reconciles chat consumers.
    await container.read(workspaceToolsProvider.notifier).refresh();

    // The removed regular tool is pruned; the surviving regular tool and the
    // direct-server selection are both preserved.
    check(container.read(selectedToolIdsProvider)).deepEquals([
      'beta_tool',
      'direct_server:mcp-1',
    ]);
  });

  test('newer model query wins when responses complete out of order', () async {
    final api = _OutOfOrderModelsApi();
    final container = _container(api);
    addTearDown(container.dispose);
    await container.read(workspaceModelsProvider.future);

    final first = container
        .read(workspaceModelsProvider.notifier)
        .setQuery('first');
    await Future<void>.delayed(Duration.zero);
    final second = container
        .read(workspaceModelsProvider.notifier)
        .setQuery('second');
    await Future<void>.delayed(Duration.zero);

    api.complete('second', id: 'second-result');
    await second;
    api.complete('first', id: 'stale-result');
    await first;

    final state = container.read(workspaceModelsProvider).requireValue;
    check(state.query).equals('second');
    check(state.items.map((item) => item.id)).deepEquals(['second-result']);
  });

  test(
    'knowledge search preserves server pagination and filtered total',
    () async {
      final api = _WorkspaceKnowledgeApi();
      final container = _container(api);
      addTearDown(container.dispose);
      await container.read(workspaceKnowledgeProvider.future);

      await container
          .read(workspaceKnowledgeProvider.notifier)
          .setQuery('road map');
      var state = container.read(workspaceKnowledgeProvider).requireValue;
      check(state.items.map((item) => item.id)).deepEquals(['knowledge-1']);
      check(state.total).equals(2);
      check(state.hasMore).isTrue();

      await container.read(workspaceKnowledgeProvider.notifier).loadMore();
      state = container.read(workspaceKnowledgeProvider).requireValue;
      check(
        state.items.map((item) => item.id),
      ).deepEquals(['knowledge-1', 'knowledge-2']);
      check(state.total).equals(2);
      check(state.hasMore).isFalse();
      check(api.requests).deepEquals([
        (query: null, view: null, page: 1),
        (query: 'road map', view: 'all', page: 1),
        (query: 'road map', view: 'all', page: 2),
      ]);
    },
  );

  test('knowledge source filter threads to the search endpoint', () async {
    final api = _WorkspaceKnowledgeApi();
    final container = _container(api);
    addTearDown(container.dispose);
    await container.read(workspaceKnowledgeProvider.future);

    await container
        .read(workspaceKnowledgeProvider.notifier)
        .setSource('external');
    final state = container.read(workspaceKnowledgeProvider).requireValue;

    check(state.source).equals('external');
    check(api.sources).contains('external');
    check(state.items.single.isExternal).isTrue();
  });

  test('tools list filters by name or id on search', () async {
    final api = _WorkspaceToolsApi();
    final container = _toolsContainer(api, cacheTools: const []);
    addTearDown(container.dispose);

    final initial = await container.read(workspaceToolsProvider.future);
    check(initial.items.map((t) => t.id)).deepEquals(['alpha', 'beta_tool']);

    await container.read(workspaceToolsProvider.notifier).setQuery('beta');
    final byName = container.read(workspaceToolsProvider).requireValue;
    check(byName.items.map((t) => t.id)).deepEquals(['beta_tool']);

    // Search also matches the id token, not just the display name.
    await container.read(workspaceToolsProvider.notifier).setQuery('alph');
    final byId = container.read(workspaceToolsProvider).requireValue;
    check(byId.items.map((t) => t.id)).deepEquals(['alpha']);
  });

  test('deleting a tool prunes it from the selected tool ids', () async {
    final api = _WorkspaceToolsApi();
    // After delete the server list no longer contains 'alpha'; the chat cache
    // reflects only the surviving tool.
    final container = _toolsContainer(
      api,
      cacheTools: [
        const Tool(id: 'beta_tool', name: 'Beta'),
      ],
    );
    addTearDown(container.dispose);

    await container.read(workspaceToolsProvider.future);
    container
        .read(selectedToolIdsProvider.notifier)
        .set(['alpha', 'beta_tool']);

    api.remaining = [
      const WorkspaceToolSummary(id: 'beta_tool', name: 'Beta', userId: 'u'),
    ];
    await container.read(workspaceToolsProvider.notifier).delete('alpha');

    check(api.deleted).deepEquals(['alpha']);
    // The deleted tool is pruned; the surviving selection is kept.
    check(container.read(selectedToolIdsProvider)).deepEquals(['beta_tool']);
  });
}

ProviderContainer _toolsContainer(
  _WorkspaceToolsApi api, {
  required List<Tool> cacheTools,
}) {
  return ProviderContainer(
    overrides: [
      reviewerModeProvider.overrideWithValue(false),
      apiServiceProvider.overrideWithValue(api),
      isAuthenticatedProvider2.overrideWithValue(true),
      toolsListProvider.overrideWith(() => _FakeToolsList(cacheTools)),
      activeServerProvider.overrideWith(
        (ref) => const ServerConfig(
          id: 'workspace-server',
          name: 'Workspace Server',
          url: 'https://example.com',
        ),
      ),
      currentUserProvider2.overrideWithValue(
        const User(
          id: 'user-1',
          username: 'user',
          email: 'user@example.com',
          role: 'user',
        ),
      ),
      authTokenProvider3.overrideWithValue('token-1'),
    ],
  );
}

ProviderContainer _container(ApiService api) {
  return ProviderContainer(
    overrides: [
      reviewerModeProvider.overrideWithValue(false),
      apiServiceProvider.overrideWithValue(api),
      activeServerProvider.overrideWith(
        (ref) => const ServerConfig(
          id: 'workspace-server',
          name: 'Workspace Server',
          url: 'https://example.com',
        ),
      ),
      currentUserProvider2.overrideWithValue(
        const User(
          id: 'user-1',
          username: 'user',
          email: 'user@example.com',
          role: 'user',
        ),
      ),
      authTokenProvider3.overrideWithValue('token-1'),
    ],
  );
}

class _OutOfOrderModelsApi extends ApiService {
  _OutOfOrderModelsApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'workspace-server',
          name: 'Workspace Server',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  final _pending =
      <String, Completer<WorkspacePagedResponse<WorkspaceModelSummary>>>{};

  @override
  Future<WorkspacePagedResponse<WorkspaceModelSummary>> getWorkspaceModels({
    String? query,
    String? viewOption,
    String? tag,
    String? orderBy,
    String? direction,
    int page = 1,
  }) {
    if (query == null || query.isEmpty) {
      return Future.value(const WorkspacePagedResponse(items: [], total: 0));
    }
    return (_pending[query] ??= Completer()).future;
  }

  void complete(String query, {required String id}) {
    _pending[query]!.complete(
      WorkspacePagedResponse(
        items: [WorkspaceModelSummary(id: id, name: id, userId: 'user-1')],
        total: 1,
      ),
    );
  }
}

class _WorkspaceKnowledgeApi extends ApiService {
  _WorkspaceKnowledgeApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'workspace-server',
          name: 'Workspace Server',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  final requests = <({String? query, String? view, int page})>[];
  final sources = <String?>[];

  @override
  Future<WorkspacePagedResponse<WorkspaceKnowledgeSummary>>
  getWorkspaceKnowledge({
    String? query,
    String? viewOption,
    String? source,
    int page = 1,
  }) async {
    requests.add((query: query, view: viewOption, page: page));
    sources.add(source);
    final filtered = (query != null && query.isNotEmpty) ||
        (source != null && source.isNotEmpty);
    if (!filtered) {
      return const WorkspacePagedResponse(items: [], total: 0);
    }
    return WorkspacePagedResponse(
      items: [
        WorkspaceKnowledgeSummary(
          id: 'knowledge-$page',
          name: 'Knowledge $page',
          userId: 'user-1',
          meta: source == 'external' ? const {'source': 'external'} : const {},
        ),
      ],
      total: 2,
    );
  }
}

class _WorkspaceModelsApi extends ApiService {
  _WorkspaceModelsApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'workspace-server',
          name: 'Workspace Server',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  Object? refreshError;
  final deleted = <String>[];

  @override
  Future<WorkspaceModelDetail?> toggleWorkspaceModel(String id) async {
    return WorkspaceModelSummary(id: id, name: 'Model 1', userId: 'user-1');
  }

  @override
  Future<bool> deleteWorkspaceModel(String id) async {
    deleted.add(id);
    return true;
  }

  @override
  Future<WorkspacePagedResponse<WorkspaceModelSummary>> getWorkspaceModels({
    String? query,
    String? viewOption,
    String? tag,
    String? orderBy,
    String? direction,
    int page = 1,
  }) async {
    final error = refreshError;
    if (error != null) throw error;
    if (page == 2) {
      return const WorkspacePagedResponse(
        items: [
          WorkspaceModelSummary(
            id: 'model-2',
            name: 'Model 2',
            userId: 'user-1',
          ),
        ],
        total: 2,
      );
    }
    return const WorkspacePagedResponse(
      items: [
        WorkspaceModelSummary(id: 'model-1', name: 'Model 1', userId: 'user-1'),
      ],
      total: 2,
    );
  }
}

class _BlockingRefreshModelsApi extends ApiService {
  _BlockingRefreshModelsApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'workspace-server',
          name: 'Workspace Server',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  final requestedPages = <int>[];
  Completer<WorkspacePagedResponse<WorkspaceModelSummary>>? _gate;
  var _built = false;

  static const _page1 = WorkspacePagedResponse<WorkspaceModelSummary>(
    items: [
      WorkspaceModelSummary(id: 'model-1', name: 'Model 1', userId: 'user-1'),
    ],
    total: 2,
  );

  void openGate() => _gate?.complete(_page1);

  @override
  Future<WorkspacePagedResponse<WorkspaceModelSummary>> getWorkspaceModels({
    String? query,
    String? viewOption,
    String? tag,
    String? orderBy,
    String? direction,
    int page = 1,
  }) {
    requestedPages.add(page);
    // The initial build resolves immediately; the subsequent page-1 refresh
    // blocks on a gate so the test can act while it is in flight.
    if (!_built) {
      _built = true;
      return Future.value(_page1);
    }
    if (page == 1) {
      return (_gate = Completer()).future;
    }
    return Future.value(
      const WorkspacePagedResponse(
        items: [
          WorkspaceModelSummary(
            id: 'model-2',
            name: 'Model 2',
            userId: 'user-1',
          ),
        ],
        total: 2,
      ),
    );
  }
}

class _WorkspacePromptsApi extends ApiService {
  _WorkspacePromptsApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'workspace-server',
          name: 'Workspace Server',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  final pagesRequested = <int>[];

  @override
  Future<WorkspacePagedResponse<WorkspacePromptSummary>> getWorkspacePrompts({
    String? query,
    String? viewOption,
    String? tag,
    String? orderBy,
    String? direction,
    int page = 1,
  }) async {
    pagesRequested.add(page);
    // Three prompts spread across two pages; the second page completes the set.
    if (page == 1) {
      return const WorkspacePagedResponse(
        items: [
          WorkspacePromptSummary(
            id: 'prompt-1',
            command: '/one',
            name: 'One',
            content: '',
            userId: 'user-1',
          ),
          WorkspacePromptSummary(
            id: 'prompt-2',
            command: '/two',
            name: 'Two',
            content: '',
            userId: 'user-1',
          ),
        ],
        total: 3,
      );
    }
    return const WorkspacePagedResponse(
      items: [
        WorkspacePromptSummary(
          id: 'prompt-3',
          command: '/three',
          name: 'Three',
          content: '',
          userId: 'user-1',
        ),
      ],
      total: 3,
    );
  }
}

class _WorkspaceToolsApi extends ApiService {
  _WorkspaceToolsApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'workspace-server',
          name: 'Workspace Server',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  final deleted = <String>[];
  List<WorkspaceToolSummary> remaining = const [
    WorkspaceToolSummary(id: 'alpha', name: 'Alpha', userId: 'u'),
    WorkspaceToolSummary(id: 'beta_tool', name: 'Beta', userId: 'u'),
  ];

  @override
  Future<List<WorkspaceToolSummary>> getWorkspaceTools() async => remaining;

  @override
  Future<void> deleteTool(String toolId) async {
    deleted.add(toolId);
  }
}

class _FakeToolsList extends ToolsList {
  _FakeToolsList(this._tools);

  final List<Tool> _tools;

  @override
  Future<List<Tool>> build() async => _tools;

  @override
  Future<void> refresh() async {
    state = AsyncData(_tools);
  }
}
