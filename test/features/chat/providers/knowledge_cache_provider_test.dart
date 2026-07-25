import 'dart:async';

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

final _activeKnowledgeApiProvider =
    NotifierProvider<_ActiveKnowledgeApi, ApiService?>(
      () => _ActiveKnowledgeApi(),
    );

class _ActiveKnowledgeApi extends Notifier<ApiService?> {
  @override
  ApiService? build() => null;

  void set(ApiService? api) => state = api;
}

void main() {
  setUp(() {
    KnowledgeCacheManager().clear();
  });

  tearDown(() {
    KnowledgeCacheManager().clear();
  });

  group('KnowledgeCacheNotifier', () {
    test(
      'switching API owners cannot reuse the previous knowledge cache',
      () async {
        final firstApi = _FakeApiService(
          serverId: 'server-a',
          bases: [
            KnowledgeBase(
              id: 'kb-a',
              name: 'Account A',
              createdAt: DateTime.utc(2026, 1, 1),
              updatedAt: DateTime.utc(2026, 1, 2),
            ),
          ],
        );
        final secondApi = _FakeApiService(
          serverId: 'server-b',
          bases: [
            KnowledgeBase(
              id: 'kb-b',
              name: 'Account B',
              createdAt: DateTime.utc(2026, 2, 1),
              updatedAt: DateTime.utc(2026, 2, 2),
            ),
          ],
        );
        final container = ProviderContainer(
          overrides: [
            apiServiceProvider.overrideWith(
              (ref) => ref.watch(_activeKnowledgeApiProvider),
            ),
          ],
        );
        addTearDown(container.dispose);

        container.read(_activeKnowledgeApiProvider.notifier).set(firstApi);
        await container.read(knowledgeCacheProvider.notifier).ensureBases();
        check(
          container.read(knowledgeCacheProvider).bases.single.id,
        ).equals('kb-a');

        container.read(_activeKnowledgeApiProvider.notifier).set(secondApi);
        await container.read(knowledgeCacheProvider.notifier).ensureBases();

        check(
          container.read(knowledgeCacheProvider).bases.single.id,
        ).equals('kb-b');
        check(secondApi.basesCallCount).equals(1);
      },
    );

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

    test('concurrent ensureBases calls share one network request', () async {
      final gate = Completer<void>();
      final api = _FakeApiService(basesGate: gate.future);
      final container = ProviderContainer(
        overrides: [apiServiceProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      final notifier = container.read(knowledgeCacheProvider.notifier);
      final first = notifier.ensureBases();
      final second = notifier.ensureBases();
      await Future<void>.delayed(Duration.zero);
      check(api.basesCallCount).equals(1);

      gate.complete();
      await Future.wait([first, second]);
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

    test('concurrent file loads coalesce independently per base', () async {
      final firstGate = Completer<void>();
      final secondGate = Completer<void>();
      final api = _FakeApiService(
        fileGates: {'kb-1': firstGate.future, 'kb-2': secondGate.future},
      );
      final container = ProviderContainer(
        overrides: [apiServiceProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(knowledgeCacheProvider.notifier);

      final first = notifier.fetchFilesForBase('kb-1');
      final duplicate = notifier.fetchFilesForBase('kb-1');
      final otherBase = notifier.fetchFilesForBase('kb-2');
      await Future<void>.delayed(Duration.zero);
      check(api.fileCalls['kb-1']).equals(1);
      check(api.fileCalls['kb-2']).equals(1);

      firstGate.complete();
      secondGate.complete();
      await Future.wait([first, duplicate, otherBase]);
      check(api.fileCalls['kb-1']).equals(1);
      check(api.fileCalls['kb-2']).equals(1);
    });
  });
}

class _FakeApiService extends ApiService {
  _FakeApiService({
    String serverId = 'test',
    this.bases = const [],
    this.filesByBase = const {},
    this.basesGate,
    this.fileGates = const {},
  }) : super(
         serverConfig: ServerConfig(
           id: serverId,
           name: 'Test',
           url: 'https://example.com',
         ),
         workerManager: WorkerManager(),
       );

  final List<KnowledgeBase> bases;
  final Map<String, List<KnowledgeBaseFile>> filesByBase;
  final Future<void>? basesGate;
  final Map<String, Future<void>> fileGates;

  int basesCallCount = 0;
  final Map<String, int> fileCalls = <String, int>{};

  @override
  Future<List<KnowledgeBase>> getKnowledgeBases() async {
    basesCallCount += 1;
    await basesGate;
    return bases;
  }

  @override
  Future<List<KnowledgeBaseFile>> getAllKnowledgeBaseFiles(
    String knowledgeBaseId,
  ) async {
    fileCalls.update(knowledgeBaseId, (count) => count + 1, ifAbsent: () => 1);
    await fileGates[knowledgeBaseId];
    return filesByBase[knowledgeBaseId] ?? const <KnowledgeBaseFile>[];
  }
}
