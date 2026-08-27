import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mcp_dart/mcp_dart.dart' as mcp;

import '../../../core/models/tool.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/secure_credential_storage.dart';
import '../models/direct_completion.dart';
import '../models/direct_mcp_server.dart';
import '../models/direct_mcp_content.dart';
import '../services/direct_mcp_client.dart';
import '../services/direct_mcp_oauth.dart';
import '../services/direct_mcp_server_store.dart';
import '../services/direct_run_registry.dart';
import '../../tools/providers/tools_providers.dart';
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
  bool _appDataClearBlocked = false;

  @override
  Future<List<DirectMcpServer>> build() async {
    ref.listen<List<String>>(selectedToolIdsProvider, (_, selected) {
      final servers = state.asData?.value;
      if (servers == null) return;
      Future.microtask(() {
        if (ref.mounted) _sanitizeSelections(servers, selected);
      });
    });
    if (ref.watch(incompleteLogoutFenceProvider)) return Future.value(const []);
    final registry = ref.read(directRunRegistryProvider);
    final servers = await ref.watch(directMcpServerStoreProvider).load();
    _synchronize(servers, registry);
    return servers;
  }

  Future<void> reload() => _serialize(() async {
    _requireMutationAdmission();
    final store = ref.read(directMcpServerStoreProvider);
    final registry = ref.read(directRunRegistryProvider);
    if (ref.mounted) state = const AsyncLoading();
    try {
      final servers = await store.load();
      _publish(servers, registry);
    } catch (error, stack) {
      if (ref.mounted) state = AsyncError(error, stack);
      rethrow;
    }
  });

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
    _publish(servers, registry);
    return servers;
  });

  Future<List<DirectMcpServer>> remove(String id) => _serialize(() async {
    _requireMutationAdmission();
    final registry = ref.read(directRunRegistryProvider);
    final oauth = ref.read(directMcpOAuthCoordinatorProvider);
    final store = ref.read(directMcpServerStoreProvider);
    await oauth.cancel(id);
    final servers = await store.remove(id);
    _publish(servers, registry);
    return servers;
  });

  Future<void> clear() => _serialize(() async {
    _requireMutationAdmission();
    final registry = ref.read(directRunRegistryProvider);
    final oauth = ref.read(directMcpOAuthCoordinatorProvider);
    final store = ref.read(directMcpServerStoreProvider);
    await oauth.cancelAll();
    await store.clear();
    _publish(const [], registry);
  });

  Future<List<DirectMcpServer>> rememberApproval(
    DirectMcpServer expectedServer,
    DirectMcpRememberedApproval approval,
  ) => _serialize(() async {
    _requireMutationAdmission();
    final registry = ref.read(directRunRegistryProvider);
    final store = ref.read(directMcpServerStoreProvider);
    final servers = await store.rememberApproval(expectedServer, approval);
    _publish(servers, registry);
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
    _publish(servers, registry);
    return servers;
  });

  Future<List<DirectMcpServer>> revokeAllRememberedApprovals(
    DirectMcpServer expectedServer,
  ) => _serialize(() async {
    _requireMutationAdmission();
    final registry = ref.read(directRunRegistryProvider);
    final store = ref.read(directMcpServerStoreProvider);
    final servers = await store.revokeAllRememberedApprovals(expectedServer);
    _publish(servers, registry);
    return servers;
  });

  Future<List<DirectMcpServer>> pruneRememberedApprovals(
    List<DirectMcpServer> expectedServers,
    Map<String, Set<String>> validFingerprints,
  ) => _serialize(() async {
    _requireMutationAdmission();
    final servers = await ref
        .read(directMcpServerStoreProvider)
        .pruneRememberedApprovals(expectedServers, validFingerprints);
    final previous = state.asData?.value;
    var changed = previous == null || previous.length != servers.length;
    for (var index = 0; !changed && index < servers.length; index++) {
      changed = !sameDirectMcpServerValues(previous![index], servers[index]);
    }
    if (changed) {
      _publish(servers, ref.read(directRunRegistryProvider));
    }
    return servers;
  });

  void _publish(List<DirectMcpServer> servers, DirectRunRegistry registry) {
    if (ref.mounted) state = AsyncData(servers);
    _synchronize(servers, registry);
  }

  void _synchronize(List<DirectMcpServer> servers, DirectRunRegistry registry) {
    registry.synchronizeMcpServers(servers);
    _sanitizeSelections(servers, ref.read(selectedToolIdsProvider));
  }

  Future<void> blockMutationsForAppDataClear() async {
    _appDataClearBlocked = true;
    await _mutationQueue;
  }

  void resumeMutationsAfterAppDataClearAbort() {
    _appDataClearBlocked = false;
  }

  void _sanitizeSelections(
    List<DirectMcpServer> servers,
    List<String> selected,
  ) {
    final valid = {
      for (final server in servers)
        if (server.enabled) 'local_mcp:${server.id}',
    };
    final sanitized = selected
        .where((id) => !id.startsWith('local_mcp:') || valid.contains(id))
        .toList(growable: false);
    if (!listEquals(selected, sanitized)) {
      ref.read(selectedToolIdsProvider.notifier).set(sanitized);
    }
  }

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
    if (_appDataClearBlocked || ref.read(incompleteLogoutFenceProvider)) {
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
  return (servers) async {
    final session = await DirectMcpToolSession.open(
      servers,
      authorizationResolver: oauth.accessTokenFor,
    );
    try {
      await ref
          .read(directMcpServersProvider.notifier)
          .pruneRememberedApprovals(servers, {
            for (final server in servers)
              server.id: {
                for (final definition in session.definitions)
                  if (definition.serverId == server.id)
                    definition.approvalFingerprint,
              },
          });
      return session;
    } catch (error, stackTrace) {
      return runDirectMcpContentOperation(
        operation: () => Error.throwWithStackTrace(error, stackTrace),
        close: session.close,
      );
    }
  };
});

typedef DirectMcpContentSessionBuilder =
    Future<DirectMcpContentSession> Function(DirectMcpServer server);

Future<T> _withDirectMcpContentSession<T>(
  DirectMcpContentSessionBuilder buildSession,
  DirectMcpServer server,
  Future<T> Function(DirectMcpContentSession session) operation,
) async {
  final session = await buildSession(server);
  return runDirectMcpContentOperation(
    operation: () => operation(session),
    close: session.close,
  );
}

@visibleForTesting
Future<T> runDirectMcpContentOperation<T>({
  required Future<T> Function() operation,
  required Future<void> Function() close,
}) async {
  Object? operationError;
  try {
    return await operation();
  } catch (error) {
    operationError = error;
    rethrow;
  } finally {
    try {
      await close();
    } catch (_) {
      if (operationError == null) rethrow;
    }
  }
}

final directMcpContentSessionBuilderProvider =
    Provider<DirectMcpContentSessionBuilder>((ref) {
      final oauth = ref.watch(directMcpOAuthCoordinatorProvider);
      return (server) => DirectMcpContentSession.open(
        server,
        authorizationResolver: oauth.accessTokenFor,
      );
    });

typedef DirectMcpContentInventoryLoader =
    Future<DirectMcpContentInventory> Function(DirectMcpServer server);

final directMcpContentInventoryLoaderProvider =
    Provider<DirectMcpContentInventoryLoader>((ref) {
      final buildSession = ref.watch(directMcpContentSessionBuilderProvider);
      return (server) => _withDirectMcpContentSession(
        buildSession,
        server,
        (session) => session.loadInventory(),
      );
    });

typedef DirectMcpPromptPreviewLoader = Future<DirectMcpPromptPreview> Function(
  DirectMcpServer server,
  DirectMcpPromptSummary prompt,
  Map<String, String> arguments,
  mcp.AbortSignal signal,
);

final directMcpPromptPreviewLoaderProvider =
    Provider<DirectMcpPromptPreviewLoader>((ref) {
      final buildSession = ref.watch(directMcpContentSessionBuilderProvider);
      return (server, prompt, arguments, signal) =>
          _withDirectMcpContentSession(
            buildSession,
            server,
            (session) => session.getPrompt(prompt, arguments, signal: signal),
          );
    });

typedef DirectMcpResourcePreviewLoader =
    Future<DirectMcpResourcePreview> Function(
      DirectMcpServer server,
      DirectMcpResourceSummary resource,
      mcp.AbortSignal signal,
    );

final directMcpResourcePreviewLoaderProvider =
    Provider<DirectMcpResourcePreviewLoader>((ref) {
      final buildSession = ref.watch(directMcpContentSessionBuilderProvider);
      return (server, resource, signal) => _withDirectMcpContentSession(
        buildSession,
        server,
        (session) => session.readResource(resource, signal: signal),
      );
    });

/// Volatile prompt/resource summaries for one enabled server.
final directMcpContentInventoryProvider = FutureProvider.autoDispose
    .family<DirectMcpContentInventory, String>((ref, serverId) async {
      final servers = await ref.watch(directMcpServersProvider.future);
      final matches = servers.where(
        (server) => server.id == serverId && server.enabled,
      );
      if (matches.length != 1) {
        throw const DirectProviderException(
          'The MCP content server is unavailable.',
        );
      }
      return ref.watch(directMcpContentInventoryLoaderProvider)(matches.single);
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
        if (session.definitions.any((tool) => tool.serverId == server.id))
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
