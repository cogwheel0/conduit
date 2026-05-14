import 'package:checks/checks.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/models/server_memory.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _serverConfig = ServerConfig(
  id: 'test-server',
  name: 'Test Server',
  url: 'https://example.com',
  isActive: true,
);

void main() {
  group('UserMemories', () {
    test('loads memories sorted by most recent update', () async {
      final api = _FakeUserMemoriesApiService(
        initialMemories: [
          _memory('memory-1', updatedAtEpoch: 10),
          _memory('memory-2', updatedAtEpoch: 20),
        ],
      );
      final container = _container(api);
      addTearDown(container.dispose);

      final memories = await _loadMemories(container);

      check(
        memories.map((memory) => memory.id).toList(),
      ).deepEquals(['memory-2', 'memory-1']);
    });

    test('add, update, and delete keep local state sorted', () async {
      final api = _FakeUserMemoriesApiService(
        initialMemories: [
          _memory('memory-1', updatedAtEpoch: 10, content: 'First'),
          _memory('memory-2', updatedAtEpoch: 20, content: 'Second'),
        ],
        createdMemory: _memory(
          'memory-3',
          updatedAtEpoch: 30,
          content: 'Third',
        ),
        updatedMemories: {
          'memory-1': _memory(
            'memory-1',
            updatedAtEpoch: 40,
            content: 'First updated',
          ),
        },
      );
      final container = _container(api);
      addTearDown(container.dispose);

      await _loadMemories(container);
      final notifier = container.read(userMemoriesProvider.notifier);

      final created = await notifier.add('remember this');
      check(created.id).equals('memory-3');
      check(api.createdContents).deepEquals(['remember this']);
      check(
        container.read(userMemoriesProvider).requireValue.map((it) => it.id),
      ).deepEquals(['memory-3', 'memory-2', 'memory-1']);

      final updated = await notifier.updateItem('memory-1', 'revise first');
      check(updated.content).equals('First updated');
      check(
        api.updatedRequests,
      ).deepEquals([(memoryId: 'memory-1', content: 'revise first')]);
      final currentAfterUpdate = container
          .read(userMemoriesProvider)
          .requireValue;
      check(
        currentAfterUpdate.map((it) => it.id),
      ).deepEquals(['memory-1', 'memory-3', 'memory-2']);
      check(currentAfterUpdate.first.content).equals('First updated');

      await notifier.deleteItem('memory-2');
      check(api.deletedIds).deepEquals(['memory-2']);
      check(
        container.read(userMemoriesProvider).requireValue.map((it) => it.id),
      ).deepEquals(['memory-1', 'memory-3']);
    });

    test('updateItem leaves missing local memories unchanged', () async {
      final api = _FakeUserMemoriesApiService(
        initialMemories: [_memory('memory-1', updatedAtEpoch: 10)],
        updatedMemories: {
          'missing': _memory(
            'missing',
            updatedAtEpoch: 50,
            content: 'Server-side only',
          ),
        },
      );
      final container = _container(api);
      addTearDown(container.dispose);

      await _loadMemories(container);

      await container
          .read(userMemoriesProvider.notifier)
          .updateItem('missing', 'ignored locally');

      final memories = container.read(userMemoriesProvider).requireValue;
      check(
        memories.map((memory) => memory.id).toList(),
      ).deepEquals(['memory-1']);
    });

    test(
      'clearAll empties local state after the server confirms deletion',
      () async {
        final api = _FakeUserMemoriesApiService(
          initialMemories: [
            _memory('memory-1', updatedAtEpoch: 10),
            _memory('memory-2', updatedAtEpoch: 20),
          ],
        );
        final container = _container(api);
        addTearDown(container.dispose);

        await _loadMemories(container);

        await container.read(userMemoriesProvider.notifier).clearAll();

        check(api.clearAllCalls).equals(1);
        check(container.read(userMemoriesProvider).requireValue).isEmpty();
      },
    );

    test(
      'refresh replaces local mutations with the latest server state',
      () async {
        final memories = <ServerMemory>[
          _memory('memory-1', updatedAtEpoch: 10),
        ];
        final api = _FakeUserMemoriesApiService(
          initialMemories: memories,
          createdMemory: _memory('memory-local', updatedAtEpoch: 30),
        );
        final container = _container(api);
        addTearDown(container.dispose);

        await _loadMemories(container);
        final notifier = container.read(userMemoriesProvider.notifier);

        await notifier.add('remember this');
        check(
          container.read(userMemoriesProvider).requireValue.map((it) => it.id),
        ).deepEquals(['memory-local', 'memory-1']);

        memories
          ..clear()
          ..add(_memory('memory-2', updatedAtEpoch: 20));

        await notifier.refresh();

        check(api.getMemoriesCalls).equals(2);
        check(
          container.read(userMemoriesProvider).requireValue.map((it) => it.id),
        ).deepEquals(['memory-2']);
      },
    );
  });
}

ProviderContainer _container(_FakeUserMemoriesApiService api) {
  return ProviderContainer(
    overrides: [
      apiServiceProvider.overrideWithValue(api),
      optimizedStorageServiceProvider.overrideWithValue(
        _FakeOptimizedStorageService(),
      ),
    ],
  );
}

Future<List<ServerMemory>> _loadMemories(ProviderContainer container) async {
  await container.read(activeServerProvider.future);
  return container.read(userMemoriesProvider.future);
}

class _FakeOptimizedStorageService extends Fake
    implements OptimizedStorageService {
  @override
  Future<List<ServerConfig>> getServerConfigs() async => const [_serverConfig];

  @override
  Future<String?> getActiveServerId() async => _serverConfig.id;
}

class _FakeUserMemoriesApiService extends ApiService {
  _FakeUserMemoriesApiService({
    this.initialMemories = const <ServerMemory>[],
    this.createdMemory,
    this.updatedMemories = const <String, ServerMemory>{},
  }) : super(serverConfig: _serverConfig, workerManager: WorkerManager());

  final List<ServerMemory> initialMemories;
  final ServerMemory? createdMemory;
  final Map<String, ServerMemory> updatedMemories;

  final createdContents = <String>[];
  final updatedRequests = <({String memoryId, String content})>[];
  final deletedIds = <String>[];
  int clearAllCalls = 0;
  int getMemoriesCalls = 0;

  @override
  Future<List<ServerMemory>> getMemories() async {
    getMemoriesCalls += 1;
    return initialMemories;
  }

  @override
  Future<ServerMemory> createMemory({required String content}) async {
    createdContents.add(content);
    final created = createdMemory;
    if (created == null) {
      throw StateError('Missing createMemory response');
    }
    return created;
  }

  @override
  Future<ServerMemory> updateMemory({
    required String memoryId,
    required String content,
  }) async {
    updatedRequests.add((memoryId: memoryId, content: content));
    final updated = updatedMemories[memoryId];
    if (updated == null) {
      throw StateError('Missing updateMemory response for $memoryId');
    }
    return updated;
  }

  @override
  Future<void> deleteMemory(String memoryId) async {
    deletedIds.add(memoryId);
  }

  @override
  Future<void> clearAllMemories() async {
    clearAllCalls += 1;
  }
}

ServerMemory _memory(
  String id, {
  required int updatedAtEpoch,
  int? createdAtEpoch,
  String? content,
}) {
  return ServerMemory(
    id: id,
    userId: 'user-1',
    content: content ?? id,
    updatedAtEpoch: updatedAtEpoch,
    createdAtEpoch: createdAtEpoch ?? updatedAtEpoch - 1,
  );
}
