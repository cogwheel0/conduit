import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/tool.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/secure_credential_storage.dart';
import '../models/direct_mcp_server.dart';
import '../services/direct_mcp_client.dart';
import '../services/direct_mcp_server_store.dart';

final directMcpServerStoreProvider = Provider<DirectMcpServerStore>((ref) {
  return DirectMcpServerStore(
    SecureCredentialStorage(instance: ref.watch(secureStorageProvider)),
  );
});

final class DirectMcpServersController
    extends AsyncNotifier<List<DirectMcpServer>> {
  Future<void> _mutationQueue = Future<void>.value();

  @override
  Future<List<DirectMcpServer>> build() =>
      ref.watch(directMcpServerStoreProvider).load();

  Future<void> reload() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(ref.read(directMcpServerStoreProvider).load);
  }

  Future<List<DirectMcpServer>> upsert(
    DirectMcpServer server, {
    DirectMcpServer? expectedPrevious,
    bool secretsConfirmedForNewOrigin = false,
  }) => _serialize(() async {
    final servers = await ref
        .read(directMcpServerStoreProvider)
        .upsert(
          server,
          expectedPrevious: expectedPrevious,
          secretsConfirmedForNewOrigin: secretsConfirmedForNewOrigin,
        );
    if (ref.mounted) state = AsyncData(servers);
    ref.invalidate(directMcpToolsProvider);
    return servers;
  });

  Future<List<DirectMcpServer>> remove(String id) => _serialize(() async {
    final servers = await ref.read(directMcpServerStoreProvider).remove(id);
    if (ref.mounted) state = AsyncData(servers);
    ref.invalidate(directMcpToolsProvider);
    return servers;
  });

  Future<void> clear() => _serialize(() async {
    await ref.read(directMcpServerStoreProvider).clear();
    if (ref.mounted) state = const AsyncData([]);
    ref.invalidate(directMcpToolsProvider);
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
}

final directMcpServersProvider =
    AsyncNotifierProvider<DirectMcpServersController, List<DirectMcpServer>>(
      DirectMcpServersController.new,
    );

typedef DirectMcpSessionBuilder = Future<DirectMcpToolSession> Function(
  List<DirectMcpServer> servers,
);

final directMcpSessionBuilderProvider = Provider<DirectMcpSessionBuilder>(
  (ref) => DirectMcpToolSession.open,
);

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
