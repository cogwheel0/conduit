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
final _activeKnowledgeEpochProvider =
    NotifierProvider<_ActiveKnowledgeEpoch, Object>(
      () => _ActiveKnowledgeEpoch(),
    );

class _ActiveKnowledgeApi extends Notifier<ApiService?> {
  @override
  ApiService? build() => null;

  void set(ApiService? api) => state = api;
}

class _ActiveKnowledgeEpoch extends Notifier<Object> {
  @override
  Object build() => Object();

  void rotate() => state = Object();
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

        container.read(_activeKnowledgeApiProvider.notifier).set(firstApi);
        await container.read(knowledgeCacheProvider.notifier).ensureBases();

        check(
          container.read(knowledgeCacheProvider).bases.single.id,
        ).equals('kb-a');
        check(firstApi.basesCallCount).equals(1);
      },
    );

    test('retains only the eight most recently used API scopes', () async {
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWith(
            (ref) => ref.watch(_activeKnowledgeApiProvider),
          ),
        ],
      );
      addTearDown(container.dispose);

      final apis = List<_FakeApiService>.generate(
        12,
        (index) => _FakeApiService(
          serverId: 'server-$index',
          bases: [
            KnowledgeBase(
              id: 'kb-$index',
              name: 'Account $index',
              createdAt: DateTime.utc(2026, 1, 1),
              updatedAt: DateTime.utc(2026, 1, 2),
            ),
          ],
        ),
      );
      for (final api in apis.take(8)) {
        container.read(_activeKnowledgeApiProvider.notifier).set(api);
        await container.read(knowledgeCacheProvider.notifier).ensureBases();
      }

      container.read(_activeKnowledgeApiProvider.notifier).set(apis[0]);
      await container.read(knowledgeCacheProvider.notifier).ensureBases();
      for (final api in apis.skip(8)) {
        container.read(_activeKnowledgeApiProvider.notifier).set(api);
        await container.read(knowledgeCacheProvider.notifier).ensureBases();
      }
      check(KnowledgeCacheManager().stats()['scopes']).equals(8);

      container.read(_activeKnowledgeApiProvider.notifier).set(apis[0]);
      await container.read(knowledgeCacheProvider.notifier).ensureBases();
      check(apis[0].basesCallCount).equals(1);

      container.read(_activeKnowledgeApiProvider.notifier).set(apis[1]);
      await container.read(knowledgeCacheProvider.notifier).ensureBases();
      check(apis[1].basesCallCount).equals(2);
    });

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

    test('auth owner rebuild fences an older same-base file request', () async {
      final staleGate = Completer<void>();
      final freshGate = Completer<void>();
      final staleFile = KnowledgeBaseFile(
        id: 'stale-owner-file',
        filename: 'stale.md',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      final freshFile = KnowledgeBaseFile(
        id: 'fresh-owner-file',
        filename: 'fresh.md',
        createdAt: DateTime.utc(2026, 1, 2),
      );
      final api = _SequencedFilesApi(
        gates: [staleGate, freshGate],
        results: [
          [staleFile],
          [freshFile],
        ],
      );
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(api),
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => ref.watch(_activeKnowledgeEpochProvider),
          ),
        ],
      );
      addTearDown(container.dispose);

      final staleRequest = container
          .read(knowledgeCacheProvider.notifier)
          .fetchFilesForBase('kb-1');
      await Future<void>.delayed(Duration.zero);
      container.read(_activeKnowledgeEpochProvider.notifier).rotate();
      final freshRequest = container
          .read(knowledgeCacheProvider.notifier)
          .fetchFilesForBase('kb-1');
      await Future<void>.delayed(Duration.zero);

      freshGate.complete();
      await freshRequest;
      check(
        container.read(knowledgeCacheProvider).files['kb-1']!.single.id,
      ).equals('fresh-owner-file');

      staleGate.complete();
      await staleRequest;
      check(
        container.read(knowledgeCacheProvider).files['kb-1']!.single.id,
      ).equals('fresh-owner-file');
      check(api.fileCalls['kb-1']).equals(2);
    });

    for (final clearAll in [false, true]) {
      test('${clearAll ? 'clearAllCaches' : 'clearCache'} fences an older '
          'same-owner bases request', () async {
        final staleGate = Completer<void>();
        final freshGate = Completer<void>();
        final staleBase = KnowledgeBase(
          id: 'stale-base',
          name: 'Stale',
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
        );
        final freshBase = KnowledgeBase(
          id: 'fresh-base',
          name: 'Fresh',
          createdAt: DateTime.utc(2026, 1, 2),
          updatedAt: DateTime.utc(2026, 1, 2),
        );
        final api = _SequencedBasesApi(
          gates: [staleGate, freshGate],
          results: [
            [staleBase],
            [freshBase],
          ],
        );
        final container = ProviderContainer(
          overrides: [apiServiceProvider.overrideWithValue(api)],
        );
        addTearDown(container.dispose);
        final notifier = container.read(knowledgeCacheProvider.notifier);

        final staleRequest = notifier.ensureBases();
        await Future<void>.delayed(Duration.zero);
        if (clearAll) {
          notifier.clearAllCaches();
        } else {
          notifier.clearCache();
        }
        final freshRequest = notifier.ensureBases();
        await Future<void>.delayed(Duration.zero);

        freshGate.complete();
        await freshRequest;
        check(
          container.read(knowledgeCacheProvider).bases.single.id,
        ).equals('fresh-base');

        staleGate.complete();
        await staleRequest;
        check(
          container.read(knowledgeCacheProvider).bases.single.id,
        ).equals('fresh-base');
      });

      test('${clearAll ? 'clearAllCaches' : 'clearCache'} fences an older '
          'same-owner file request', () async {
        final staleGate = Completer<void>();
        final freshGate = Completer<void>();
        final staleFile = KnowledgeBaseFile(
          id: 'stale-file',
          filename: 'stale.md',
          createdAt: DateTime.utc(2026, 1, 1),
        );
        final freshFile = KnowledgeBaseFile(
          id: 'fresh-file',
          filename: 'fresh.md',
          createdAt: DateTime.utc(2026, 1, 2),
        );
        final api = _SequencedFilesApi(
          gates: [staleGate, freshGate],
          results: [
            [staleFile],
            [freshFile],
          ],
        );
        final container = ProviderContainer(
          overrides: [apiServiceProvider.overrideWithValue(api)],
        );
        addTearDown(container.dispose);
        final notifier = container.read(knowledgeCacheProvider.notifier);

        final staleRequest = notifier.fetchFilesForBase('kb-1');
        await Future<void>.delayed(Duration.zero);
        if (clearAll) {
          notifier.clearAllCaches();
        } else {
          notifier.clearCache();
        }
        final freshRequest = notifier.fetchFilesForBase('kb-1');
        await Future<void>.delayed(Duration.zero);

        freshGate.complete();
        await freshRequest;
        check(
          container.read(knowledgeCacheProvider).files['kb-1']!.single.id,
        ).equals('fresh-file');

        staleGate.complete();
        await staleRequest;
        check(
          container.read(knowledgeCacheProvider).files['kb-1']!.single.id,
        ).equals('fresh-file');
      });
    }
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

class _SequencedFilesApi extends _FakeApiService {
  _SequencedFilesApi({required this.gates, required this.results});

  final List<Completer<void>> gates;
  final List<List<KnowledgeBaseFile>> results;
  int _nextResult = 0;

  @override
  Future<List<KnowledgeBaseFile>> getAllKnowledgeBaseFiles(
    String knowledgeBaseId,
  ) async {
    final index = _nextResult++;
    fileCalls.update(knowledgeBaseId, (count) => count + 1, ifAbsent: () => 1);
    await gates[index].future;
    return results[index];
  }
}

class _SequencedBasesApi extends _FakeApiService {
  _SequencedBasesApi({required this.gates, required this.results});

  final List<Completer<void>> gates;
  final List<List<KnowledgeBase>> results;
  int _nextResult = 0;

  @override
  Future<List<KnowledgeBase>> getKnowledgeBases() async {
    final index = _nextResult++;
    basesCallCount += 1;
    await gates[index].future;
    return results[index];
  }
}
