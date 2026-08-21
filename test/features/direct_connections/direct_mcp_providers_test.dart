import 'package:conduit/core/providers/storage_providers.dart';
import 'package:conduit/features/direct_connections/models/direct_mcp_server.dart';
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
}

DirectMcpServer _server(String id, {bool enabled = true}) => DirectMcpServer(
  id: id,
  name: 'Server $id',
  endpoint: 'https://$id.example/mcp',
  enabled: enabled,
);
