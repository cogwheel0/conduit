import '../../../core/services/secure_credential_storage.dart';
import '../models/direct_mcp_server.dart';

final class DirectMcpServerConflictException implements Exception {
  DirectMcpServerConflictException({
    Iterable<DirectMcpServer> currentServers = const [],
  }) : currentServers = List.unmodifiable(currentServers);

  final List<DirectMcpServer> currentServers;

  @override
  String toString() => 'MCP server changed concurrently.';
}

final class DirectMcpServerStore {
  DirectMcpServerStore(this._storage);

  final SecureCredentialStorage _storage;
  Future<void> _mutationQueue = Future<void>.value();

  Future<List<DirectMcpServer>> load() async {
    final raw = await _storage.getDirectMcpServers();
    if (raw == null || raw.trim().isEmpty) return const [];
    return DirectMcpServersDocument.decode(raw).servers;
  }

  Future<List<DirectMcpServer>> save(
    Iterable<DirectMcpServer> servers, {
    Set<String> secretsConfirmedForNewOrigin = const {},
  }) => _serializeMutation(() async {
    final previousById = {for (final server in await load()) server.id: server};
    final safe = [
      for (final server in servers)
        if (previousById[server.id] case final previous?)
          DirectMcpServer.secureUpdate(
            previous: previous,
            next: server,
            secretsConfirmedForNewOrigin: secretsConfirmedForNewOrigin.contains(
              server.id,
            ),
          )
        else
          server,
    ];
    return _persist(safe);
  });

  Future<List<DirectMcpServer>> upsert(
    DirectMcpServer server, {
    DirectMcpServer? expectedPrevious,
    bool secretsConfirmedForNewOrigin = false,
    bool oauthFlowCompletedForExactMutation = false,
  }) => _serializeMutation(() async {
    server.validate();
    final current = await load();
    final index = current.indexWhere((item) => item.id == server.id);
    final previous = index < 0 ? null : current[index];
    if (expectedPrevious != null &&
        (previous == null ||
            !sameDirectMcpServerValues(previous, expectedPrevious))) {
      throw DirectMcpServerConflictException(currentServers: current);
    }
    final safe = previous == null
        ? server
        : DirectMcpServer.secureUpdate(
            previous: previous,
            next: server,
            secretsConfirmedForNewOrigin: secretsConfirmedForNewOrigin,
            oauthFlowCompletedForExactMutation:
                oauthFlowCompletedForExactMutation,
          );
    final updated = [...current];
    if (index < 0) {
      updated.add(safe);
    } else {
      updated[index] = safe;
    }
    return _persist(updated);
  });

  Future<List<DirectMcpServer>> remove(String id) =>
      _serializeMutation(() async {
        final updated = [
          for (final server in await load())
            if (server.id != id) server,
        ];
        return _persist(updated);
      });

  Future<void> clear() => _serializeMutation(_storage.deleteDirectMcpServers);

  Future<List<DirectMcpServer>> _persist(List<DirectMcpServer> servers) async {
    final document = DirectMcpServersDocument(servers);
    await _storage.saveDirectMcpServers(document.encode());
    return document.servers;
  }

  Future<T> _serializeMutation<T>(Future<T> Function() operation) {
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
