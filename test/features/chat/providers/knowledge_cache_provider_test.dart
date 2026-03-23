import 'package:checks/checks.dart';
import 'package:conduit/core/models/knowledge_base.dart';
import 'package:conduit/core/models/knowledge_base_file.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/chat/providers/knowledge_cache_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    KnowledgeCacheManager().clear();
  });

  tearDown(() {
    KnowledgeCacheManager().clear();
  });

  group('KnowledgeCacheNotifier', () {
    test('ensureBases loads knowledge bases from the API', () async {
      final api = _FakeApiService(
        bases: [
          KnowledgeBase(
            id: 'kb-1',
            name: 'Alpha',
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 2),
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [apiServiceProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      await container.read(knowledgeCacheProvider.notifier).ensureBases();

      final state = container.read(knowledgeCacheProvider);
      check(state.bases).has((it) => it.length, 'length').equals(1);
      check(state.bases.single.name).equals('Alpha');
      check(api.basesCallCount).equals(1);
    });

    test('fetchFilesForBase loads and caches knowledge files', () async {
      final api = _FakeApiService(
        filesByBase: {
          'kb-1': [
            KnowledgeBaseFile(
              id: 'file-1',
              filename: 'alpha.md',
              meta: const {
                'name': 'Alpha Doc',
                'source': 'https://example.com',
              },
              createdAt: DateTime.utc(2026, 1, 1),
            ),
          ],
        },
      );
      final container = ProviderContainer(
        overrides: [apiServiceProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      await container
          .read(knowledgeCacheProvider.notifier)
          .fetchFilesForBase('kb-1');
      await container
          .read(knowledgeCacheProvider.notifier)
          .fetchFilesForBase('kb-1');

      final state = container.read(knowledgeCacheProvider);
      final files = state.files['kb-1'];
      check(files).isNotNull();
      check(files!).has((it) => it.length, 'length').equals(1);
      check(files.single.id).equals('file-1');
      check(files.single.meta?['name']).equals('Alpha Doc');
      check(api.fileCalls['kb-1']).equals(1);
    });
  });
}

class _FakeApiService extends ApiService {
  _FakeApiService({this.bases = const [], this.filesByBase = const {}})
    : super(
        serverConfig: const ServerConfig(
          id: 'test',
          name: 'Test',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  final List<KnowledgeBase> bases;
  final Map<String, List<KnowledgeBaseFile>> filesByBase;

  int basesCallCount = 0;
  final Map<String, int> fileCalls = <String, int>{};

  @override
  Future<List<KnowledgeBase>> getKnowledgeBases() async {
    basesCallCount += 1;
    return bases;
  }

  @override
  Future<List<KnowledgeBaseFile>> getAllKnowledgeBaseFiles(
    String knowledgeBaseId,
  ) async {
    fileCalls.update(knowledgeBaseId, (count) => count + 1, ifAbsent: () => 1);
    return filesByBase[knowledgeBaseId] ?? const <KnowledgeBaseFile>[];
  }
}
