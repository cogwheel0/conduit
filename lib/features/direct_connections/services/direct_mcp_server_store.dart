import '../../../core/services/secure_credential_storage.dart';
import '../../../core/utils/debug_logger.dart';
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
  bool _appDataClearBlocked = false;

  Future<List<DirectMcpServer>> load() async {
    final raw = await _storage.getDirectMcpServers();
    if (raw == null || raw.trim().isEmpty) return const [];
    final decoded = DirectMcpServersDocument.decodeLenient(raw);
    if (decoded.dropped > 0) {
      DebugLogger.warning(
        'dropped-invalid-servers',
        scope: 'direct-connections/mcp',
        data: {'count': decoded.dropped},
      );
    }
    return decoded.document.servers;
  }

  Future<void> blockMutationsForAppDataClear() async {
    _appDataClearBlocked = true;
    await _mutationQueue;
  }

  void resumeMutationsAfterAppDataClearAbort() {
    _appDataClearBlocked = false;
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
    safe.validate();
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

  Future<List<DirectMcpServer>> rememberApproval(
    DirectMcpServer expectedServer,
    DirectMcpRememberedApproval approval,
  ) => _mutateRememberedApprovals(expectedServer, (current) {
    approval.validate();
    if (current.any((item) => item.digest == approval.digest)) return current;
    return [...current, approval];
  });

  Future<List<DirectMcpServer>> revokeRememberedApproval(
    DirectMcpServer expectedServer,
    String digest,
  ) => _mutateRememberedApprovals(
    expectedServer,
    (current) => [
      for (final approval in current)
        if (approval.digest != digest) approval,
    ],
  );

  Future<List<DirectMcpServer>> revokeAllRememberedApprovals(
    DirectMcpServer expectedServer,
  ) => _mutateRememberedApprovals(expectedServer, (_) => const []);

  /// Prunes against a complete, successfully loaded inventory.
  /// An included server with an empty digest set loses every remembered grant.
  Future<List<DirectMcpServer>> pruneRememberedApprovals(
    Iterable<DirectMcpServer> expectedServers,
    Map<String, Set<String>> validDigestsByServer,
  ) => _serializeMutation(() async {
    final current = await load();
    final expectedById = {
      for (final server in expectedServers) server.id: server,
    };
    var changed = false;
    final updated = <DirectMcpServer>[];
    for (final server in current) {
      final expected = expectedById[server.id];
      final valid = validDigestsByServer[server.id];
      if (expected == null ||
          valid == null ||
          !sameDirectMcpApprovalConfiguration(server, expected)) {
        updated.add(server);
        continue;
      }
      final approvals = [
        for (final approval in server.rememberedApprovals)
          if (valid.contains(approval.digest)) approval,
      ];
      changed |= approvals.length != server.rememberedApprovals.length;
      updated.add(server.copyWith(rememberedApprovals: approvals));
    }
    return changed ? _persist(updated) : current;
  });

  Future<void> clear() => _serializeMutation(_storage.deleteDirectMcpServers);

  Future<List<DirectMcpServer>> _mutateRememberedApprovals(
    DirectMcpServer expectedServer,
    List<DirectMcpRememberedApproval> Function(
      List<DirectMcpRememberedApproval> current,
    )
    mutate,
  ) => _serializeMutation(() async {
    final current = await load();
    final index = current.indexWhere(
      (server) => server.id == expectedServer.id,
    );
    if (index < 0 ||
        !sameDirectMcpApprovalConfiguration(current[index], expectedServer)) {
      throw DirectMcpServerConflictException(currentServers: current);
    }
    final nextServer = current[index].copyWith(
      rememberedApprovals: mutate(current[index].rememberedApprovals),
    );
    nextServer.validate();
    final updated = [...current]..[index] = nextServer;
    return _persist(updated);
  });

  Future<List<DirectMcpServer>> _persist(List<DirectMcpServer> servers) async {
    if (servers.where((server) => server.enabled).length >
        kDirectMcpMaxServers) {
      throw const FormatException('At most 8 MCP servers may be enabled.');
    }
    final document = DirectMcpServersDocument(servers);
    await _storage.saveDirectMcpServers(document.encode());
    return document.servers;
  }

  Future<T> _serializeMutation<T>(Future<T> Function() operation) {
    if (_appDataClearBlocked) {
      return Future.error(
        StateError('MCP server changes are unavailable while signing out.'),
      );
    }
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
