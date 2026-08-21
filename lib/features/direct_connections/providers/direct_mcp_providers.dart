import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/tool.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/secure_credential_storage.dart';
import '../models/direct_mcp_server.dart';
import '../services/direct_mcp_client.dart';
import '../services/direct_mcp_oauth.dart';
import '../services/direct_mcp_server_store.dart';
import 'direct_connection_providers.dart';

final directMcpServerStoreProvider = Provider<DirectMcpServerStore>((ref) {
  return DirectMcpServerStore(
    SecureCredentialStorage(instance: ref.watch(secureStorageProvider)),
  );
});

final directMcpOAuthCoordinatorProvider = Provider<DirectMcpOAuthCoordinator>((
  ref,
) {
  ref.watch(incompleteLogoutFenceProvider);
  final coordinator = DirectMcpOAuthCoordinator(
    store: ref.watch(directMcpServerStoreProvider),
  );
  ref.onDispose(() => unawaited(coordinator.close()));
  return coordinator;
});

final class DirectMcpServersController
    extends AsyncNotifier<List<DirectMcpServer>> {
  Future<void> _mutationQueue = Future<void>.value();

  @override
  Future<List<DirectMcpServer>> build() async {
    if (ref.watch(incompleteLogoutFenceProvider)) return Future.value(const []);
    final registry = ref.read(directRunRegistryProvider);
    final servers = await ref.watch(directMcpServerStoreProvider).load();
    registry.synchronizeMcpServers(servers);
    return servers;
  }

  Future<void> reload() async {
    final store = ref.read(directMcpServerStoreProvider);
    final registry = ref.read(directRunRegistryProvider);
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final servers = await store.load();
      registry.synchronizeMcpServers(servers);
      return servers;
    });
  }

  Future<List<DirectMcpServer>> upsert(
    DirectMcpServer server, {
    DirectMcpServer? expectedPrevious,
    bool secretsConfirmedForNewOrigin = false,
    bool oauthFlowCompletedForExactMutation = false,
  }) => _serialize(() async {
    _requireMutationAdmission();
    final registry = ref.read(directRunRegistryProvider);
    final oauth = ref.read(directMcpOAuthCoordinatorProvider);
    final store = ref.read(directMcpServerStoreProvider);
    await oauth.cancel(server.id);
    final servers = await store.upsert(
      server,
      expectedPrevious: expectedPrevious,
      secretsConfirmedForNewOrigin: secretsConfirmedForNewOrigin,
      oauthFlowCompletedForExactMutation: oauthFlowCompletedForExactMutation,
    );
    if (ref.mounted) state = AsyncData(servers);
    registry.synchronizeMcpServers(servers);
    return servers;
  });

  Future<List<DirectMcpServer>> remove(String id) => _serialize(() async {
    _requireMutationAdmission();
    final registry = ref.read(directRunRegistryProvider);
    final oauth = ref.read(directMcpOAuthCoordinatorProvider);
    final store = ref.read(directMcpServerStoreProvider);
    await oauth.cancel(id);
    final servers = await store.remove(id);
    if (ref.mounted) state = AsyncData(servers);
    registry.synchronizeMcpServers(servers);
    return servers;
  });

  Future<void> clear() => _serialize(() async {
    _requireMutationAdmission();
    final registry = ref.read(directRunRegistryProvider);
    final oauth = ref.read(directMcpOAuthCoordinatorProvider);
    final store = ref.read(directMcpServerStoreProvider);
    await oauth.cancelAll();
    await store.clear();
    if (ref.mounted) state = const AsyncData([]);
    registry.synchronizeMcpServers(const []);
  });

  Future<List<DirectMcpServer>> rememberApproval(
    DirectMcpServer expectedServer,
    DirectMcpRememberedApproval approval,
  ) => _serialize(() async {
    _requireMutationAdmission();
    final registry = ref.read(directRunRegistryProvider);
    final store = ref.read(directMcpServerStoreProvider);
    final servers = await store.rememberApproval(expectedServer, approval);
    if (ref.mounted) state = AsyncData(servers);
    registry.synchronizeMcpServers(servers);
    return servers;
  });

  Future<List<DirectMcpServer>> revokeRememberedApproval(
    DirectMcpServer expectedServer,
    String digest,
  ) => _serialize(() async {
    _requireMutationAdmission();
    final registry = ref.read(directRunRegistryProvider);
    final store = ref.read(directMcpServerStoreProvider);
    final servers = await store.revokeRememberedApproval(
      expectedServer,
      digest,
    );
    if (ref.mounted) state = AsyncData(servers);
    registry.synchronizeMcpServers(servers);
    return servers;
  });

  Future<List<DirectMcpServer>> revokeAllRememberedApprovals(
    DirectMcpServer expectedServer,
  ) => _serialize(() async {
    _requireMutationAdmission();
    final registry = ref.read(directRunRegistryProvider);
    final store = ref.read(directMcpServerStoreProvider);
    final servers = await store.revokeAllRememberedApprovals(expectedServer);
    if (ref.mounted) state = AsyncData(servers);
    registry.synchronizeMcpServers(servers);
    return servers;
  });

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _mutationQueue.then<T>(
      (_) => operation(),
      onError: (Object _, StackTrace _) => operation(),
    );
    _mutationQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void _requireMutationAdmission() {
    if (ref.read(incompleteLogoutFenceProvider)) {
      throw StateError('MCP server changes are unavailable while signing out.');
    }
  }
}

final directMcpServersProvider =
    AsyncNotifierProvider<DirectMcpServersController, List<DirectMcpServer>>(
      DirectMcpServersController.new,
    );

typedef DirectMcpSessionBuilder = Future<DirectMcpToolSession> Function(
  List<DirectMcpServer> servers,
);

final directMcpSessionBuilderProvider = Provider<DirectMcpSessionBuilder>((
  ref,
) {
  final oauth = ref.watch(directMcpOAuthCoordinatorProvider);
  final store = ref.watch(directMcpServerStoreProvider);
  final registry = ref.watch(directRunRegistryProvider);
  return (servers) async {
    final session = await DirectMcpToolSession.open(
      servers,
      authorizationResolver: oauth.accessTokenFor,
    );
    try {
      final persisted = await store.pruneRememberedApprovals(servers, {
        for (final server in servers)
          server.id: {
            for (final definition in session.definitions)
              if (definition.serverId == server.id)
                definition.approvalFingerprint,
          },
      });
      registry.synchronizeMcpServers(persisted);
      return session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  };
});

/// Volatile server bundles for the Direct composer; never persisted to Drift.
final directMcpToolsProvider = FutureProvider<List<Tool>>((ref) async {
  final servers = await ref.watch(directMcpServersProvider.future);
  final enabled = servers.where((server) => server.enabled).toList();
  if (enabled.isEmpty) return const [];

  final session = await ref.watch(directMcpSessionBuilderProvider)(enabled);
  try {
    return List.unmodifiable([
      for (final server in enabled)
        Tool(
          id: 'local_mcp:${server.id}',
          name: server.name,
          description: 'MCP tools available from this server.',
          specs: [
            for (final definition in session.definitions.where(
              (tool) => tool.serverId == server.id,
            ))
              Map<String, dynamic>.from(
                definition.toFunctionJson()['function']! as Map,
              ),
          ],
          meta: const {'source': 'local_mcp'},
        ),
    ]);
  } finally {
    await session.close();
  }
});
