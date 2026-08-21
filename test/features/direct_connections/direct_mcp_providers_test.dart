import 'package:conduit/core/providers/storage_providers.dart';
import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/providers/direct_mcp_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('secure provider loads and serializes server mutations', () async {
    const storage = FlutterSecureStorage();
    final container = ProviderContainer(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    expect(await container.read(directMcpServersProvider.future), isEmpty);
    final notifier = container.read(directMcpServersProvider.notifier);

    await Future.wait([
      notifier.upsert(_server('one')),
      notifier.upsert(_server('two')),
    ]);

    expect(
      container
          .read(directMcpServersProvider)
          .requireValue
          .map((server) => server.id),
      ['one', 'two'],
    );
    await notifier.remove('one');
    expect(
      container.read(directMcpServersProvider).requireValue.single.id,
      'two',
    );
  });

  test('disabled servers never enter volatile composer inventory', () async {
    const storage = FlutterSecureStorage();
    final container = ProviderContainer(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    await container.read(directMcpServersProvider.future);
    await container
        .read(directMcpServersProvider.notifier)
        .upsert(_server('disabled', enabled: false));

    expect(await container.read(directMcpToolsProvider.future), isEmpty);
  });

  test('clear removes the secure document and in-memory state', () async {
    const storage = FlutterSecureStorage();
    final container = ProviderContainer(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    await container.read(directMcpServersProvider.future);
    final notifier = container.read(directMcpServersProvider.notifier);
    await notifier.upsert(_server('one'));

    await notifier.clear();

    expect(container.read(directMcpServersProvider).requireValue, isEmpty);
    expect(await container.read(directMcpServerStoreProvider).load(), isEmpty);
  });

  test(
    'secure reload clears session approval after configuration drift',
    () async {
      const storage = FlutterSecureStorage();
      final container = ProviderContainer(
        overrides: [secureStorageProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(directMcpServersProvider.notifier);
      final server = _server('one');
      await notifier.upsert(server);
      final registry = container.read(directRunRegistryProvider);
      final definition = DirectToolDefinition(
        name: 'mcp_one_lookup',
        serverId: server.id,
        serverName: server.name,
        remoteName: 'lookup',
        displayName: 'Lookup',
        description: '',
        approvalFingerprint: 'a' * 64,
        inputSchema: const {'type': 'object'},
      );
      final first = registry.requestMcpApproval(
        registry.reserve((
          ownerConversationId: 'direct-local:first',
          assistantMessageId: 'assistant-1',
        ), 'profile'),
        callId: 'call-1',
        definition: definition,
        arguments: const {},
        expectedServer: server,
      );
      registry.resolveMcpApprovalById(
        first.request.id,
        DirectToolApprovalDecision.allowSession,
      );
      expect(await first.decision, DirectToolApprovalDecision.allowSession);

      final changed = server.copyWith(name: 'Changed');
      await container
          .read(directMcpServerStoreProvider)
          .upsert(changed, expectedPrevious: server);
      await notifier.reload();
      final afterReload = registry.requestMcpApproval(
        registry.reserve((
          ownerConversationId: 'direct-local:second',
          assistantMessageId: 'assistant-2',
        ), 'profile'),
        callId: 'call-2',
        definition: definition,
        arguments: const {},
        expectedServer: changed,
      );
      expect(afterReload.requiresUserDecision, isTrue);
    },
  );
}

DirectMcpServer _server(String id, {bool enabled = true}) => DirectMcpServer(
  id: id,
  name: 'Server $id',
  endpoint: 'https://$id.example/mcp',
  enabled: enabled,
);
