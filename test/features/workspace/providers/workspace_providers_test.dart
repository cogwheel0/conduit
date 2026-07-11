import 'dart:async';

import 'package:checks/checks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/models/user.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
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

  @override
  Future<WorkspacePagedResponse<WorkspaceKnowledgeSummary>>
  getWorkspaceKnowledge({
    String? query,
    String? viewOption,
    int page = 1,
  }) async {
    requests.add((query: query, view: viewOption, page: page));
    if (query == null || query.isEmpty) {
      return const WorkspacePagedResponse(items: [], total: 0);
    }
    return WorkspacePagedResponse(
      items: [
        WorkspaceKnowledgeSummary(
          id: 'knowledge-$page',
          name: 'Knowledge $page',
          userId: 'user-1',
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
