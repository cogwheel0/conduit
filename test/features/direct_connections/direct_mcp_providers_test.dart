import 'dart:async';

import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/providers/direct_mcp_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conduit/features/tools/providers/tools_providers.dart';

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

  test(
    'disabled and deleted servers are removed from composer selection',
    () async {
      const storage = FlutterSecureStorage();
      final container = ProviderContainer(
        overrides: [secureStorageProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(directMcpServersProvider.notifier);
      await notifier.upsert(_server('one'));
      container.read(selectedToolIdsProvider.notifier).set(const [
        'calculator',
        'local_mcp:one',
        'local_mcp:missing',
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(selectedToolIdsProvider), [
        'calculator',
        'local_mcp:one',
      ]);

      await notifier.upsert(_server('one', enabled: false));
      expect(container.read(selectedToolIdsProvider), ['calculator']);
    },
  );

  test('server configuration changes deny pending approvals', () async {
    const storage = FlutterSecureStorage();
    final container = ProviderContainer(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(directMcpServersProvider.notifier);
    final server = _server('one');
    await notifier.upsert(server);
    final registry = container.read(directRunRegistryProvider);
    final approval = registry.requestMcpApproval(
      registry.reserve((
        ownerConversationId: 'direct-local:chat',
        assistantMessageId: 'assistant',
      ), 'profile'),
      callId: 'call',
      definition: DirectToolDefinition(
        name: 'mcp_one_lookup',
        serverId: server.id,
        serverName: server.name,
        remoteName: 'lookup',
        displayName: 'Lookup',
        description: '',
        approvalFingerprint: 'a' * 64,
        inputSchema: const {'type': 'object'},
      ),
      arguments: const {},
      expectedServer: server,
    );

    await notifier.upsert(
      server.copyWith(enabled: false),
      expectedPrevious: server,
    );

    expect(await approval.decision, DirectToolApprovalDecision.deny);
    expect(registry.hasLiveMcpApproval(approval.request.id), isFalse);
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

  test('reload stays closed behind the durable logout fence', () async {
    final container = ProviderContainer(
      overrides: [incompleteLogoutFenceProvider.overrideWithValue(true)],
    );
    addTearDown(container.dispose);
    expect(await container.read(directMcpServersProvider.future), isEmpty);

    await expectLater(
      container.read(directMcpServersProvider.notifier).reload(),
      throwsStateError,
    );
  });

  test('app-data clear drains an admitted MCP server write', () async {
    final storage = _BlockingMcpSecureStorage();
    final container = ProviderContainer(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    await container.read(directMcpServersProvider.future);
    final notifier = container.read(directMcpServersProvider.notifier);
    storage.blockNextWrite();
    final write = notifier.upsert(_server('one'));
    await storage.writeStarted.future;

    var blocked = false;
    final barrier = notifier.blockMutationsForAppDataClear().then((_) {
      blocked = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(blocked, isFalse);
    storage.releaseWrite();
    await write;
    await barrier;
    expect(blocked, isTrue);
    await expectLater(notifier.upsert(_server('two')), throwsStateError);
  });

  test('incomplete clear leaves recovery owned by the durable fence', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(directMcpServersProvider.notifier);
    await notifier.upsert(_server('one'));

    await notifier.blockMutationsForAppDataClear();
    container.read(incompleteLogoutFenceProvider.notifier).setSuppressed(true);
    notifier.revokeRuntimeAfterIncompleteAppDataClear();
    await expectLater(notifier.upsert(_server('two')), throwsStateError);

    container.read(incompleteLogoutFenceProvider.notifier).setSuppressed(false);
    await container.read(directMcpServersProvider.future);
    await notifier.upsert(_server('two'));
  });

  test(
    'app-data clear rejects OAuth store writes outside the controller',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(directMcpServersProvider.notifier);
      await container.read(directMcpServersProvider.future);

      await notifier.blockMutationsForAppDataClear();
      final store = container.read(directMcpServerStoreProvider);
      await expectLater(store.upsert(_server('late')), throwsStateError);

      notifier.resumeMutationsAfterAppDataClearAbort();
      await store.upsert(_server('recovered'));
    },
  );

  test('unchanged approval pruning does not republish servers', () async {
    const storage = FlutterSecureStorage();
    final container = ProviderContainer(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(directMcpServersProvider.notifier);
    final server = _server('one');
    await notifier.upsert(server);
    final published = <AsyncValue<List<DirectMcpServer>>>[];
    final subscription = container.listen(directMcpServersProvider, (_, next) {
      published.add(next);
    });
    addTearDown(subscription.close);

    await notifier.pruneRememberedApprovals([server], const {'one': {}});

    expect(published, isEmpty);
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

final class _BlockingMcpSecureStorage implements FlutterSecureStorage {
  String? _source;
  bool _block = false;
  final writeStarted = Completer<void>();
  final _writeRelease = Completer<void>();

  void blockNextWrite() => _block = true;
  void releaseWrite() => _writeRelease.complete();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #read) return Future<String?>.value(_source);
    if (invocation.memberName == #delete) {
      _source = null;
      return Future<void>.value();
    }
    if (invocation.memberName == #write) {
      final value = invocation.namedArguments[#value] as String?;
      if (!_block) {
        _source = value;
        return Future<void>.value();
      }
      _block = false;
      writeStarted.complete();
      return _writeRelease.future.then<void>((_) => _source = value);
    }
    return super.noSuchMethod(invocation);
  }
}
