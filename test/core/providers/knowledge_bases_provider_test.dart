import 'package:checks/checks.dart';
import 'package:conduit/core/models/knowledge_base.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('KnowledgeBases', () {
    test('loads knowledge bases sorted by most recent update', () async {
      final api = _FakeKnowledgeBasesApiService(
        bases: [
          _knowledgeBase('kb-1', updatedAt: DateTime.utc(2026, 1, 1)),
          _knowledgeBase('kb-2', updatedAt: DateTime.utc(2026, 1, 3)),
        ],
      );
      final container = _container(api);
      addTearDown(container.dispose);

      final bases = await container.read(knowledgeBasesProvider.future);

      check(bases.map((base) => base.id).toList()).deepEquals(['kb-2', 'kb-1']);
      check(api.getKnowledgeBasesCalls).equals(1);
    });

    test(
      'upsert and remove mutate the loaded list while preserving sort',
      () async {
        final api = _FakeKnowledgeBasesApiService(
          bases: [
            _knowledgeBase('kb-1', updatedAt: DateTime.utc(2026, 1, 1)),
            _knowledgeBase('kb-2', updatedAt: DateTime.utc(2026, 1, 2)),
          ],
        );
        final container = _container(api);
        addTearDown(container.dispose);

        await container.read(knowledgeBasesProvider.future);
        final notifier = container.read(knowledgeBasesProvider.notifier);

        notifier.upsert(
          _knowledgeBase(
            'kb-1',
            name: 'KB 1 Updated',
            updatedAt: DateTime.utc(2026, 1, 4),
          ),
        );
        notifier.upsert(
          _knowledgeBase(
            'kb-3',
            name: 'KB 3',
            updatedAt: DateTime.utc(2026, 1, 3),
          ),
        );

        final afterUpserts = container
            .read(knowledgeBasesProvider)
            .requireValue;
        check(
          afterUpserts.map((base) => base.id).toList(),
        ).deepEquals(['kb-1', 'kb-3', 'kb-2']);
        check(afterUpserts.first.name).equals('KB 1 Updated');

        notifier.remove('kb-2');

        final afterRemove = container.read(knowledgeBasesProvider).requireValue;
        check(
          afterRemove.map((base) => base.id).toList(),
        ).deepEquals(['kb-1', 'kb-3']);
      },
    );

    test(
      'refresh replaces local mutations with the latest server state',
      () async {
        final bases = <KnowledgeBase>[
          _knowledgeBase('kb-1', updatedAt: DateTime.utc(2026, 1, 1)),
        ];
        final api = _FakeKnowledgeBasesApiService(bases: bases);
        final container = _container(api);
        addTearDown(container.dispose);

        await container.read(knowledgeBasesProvider.future);
        final notifier = container.read(knowledgeBasesProvider.notifier);

        notifier.upsert(
          _knowledgeBase('kb-local', updatedAt: DateTime.utc(2026, 1, 5)),
        );
        check(
          container
              .read(knowledgeBasesProvider)
              .requireValue
              .map((base) => base.id),
        ).deepEquals(['kb-local', 'kb-1']);

        bases
          ..clear()
          ..add(
            _knowledgeBase('kb-remote', updatedAt: DateTime.utc(2026, 1, 3)),
          );

        await notifier.refresh();

        check(api.getKnowledgeBasesCalls).equals(2);
        check(
          container
              .read(knowledgeBasesProvider)
              .requireValue
              .map((base) => base.id),
        ).deepEquals(['kb-remote']);
      },
    );
  });
}

ProviderContainer _container(_FakeKnowledgeBasesApiService api) {
  return ProviderContainer(
    overrides: [
      isAuthenticatedProvider2.overrideWithValue(true),
      apiServiceProvider.overrideWithValue(api),
    ],
  );
}

class _FakeKnowledgeBasesApiService extends ApiService {
  _FakeKnowledgeBasesApiService({this.bases = const <KnowledgeBase>[]})
    : super(
        serverConfig: const ServerConfig(
          id: 'test-server',
          name: 'Test Server',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  final List<KnowledgeBase> bases;
  int getKnowledgeBasesCalls = 0;

  @override
  Future<List<KnowledgeBase>> getKnowledgeBases() async {
    getKnowledgeBasesCalls += 1;
    return bases;
  }
}

KnowledgeBase _knowledgeBase(
  String id, {
  String? name,
  required DateTime updatedAt,
}) {
  return KnowledgeBase(
    id: id,
    name: name ?? id.toUpperCase(),
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: updatedAt,
  );
}
