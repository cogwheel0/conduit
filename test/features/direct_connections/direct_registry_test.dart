import 'package:conduit/core/models/model.dart';
import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit/features/direct_connections/services/direct_provider_adapter.dart';
import 'package:conduit/features/direct_connections/services/direct_run_registry.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stable model ids round-trip arbitrary provider ids', () {
    final encoded = DirectModelId.encode('profile-one', 'org/model:版本');
    final decoded = DirectModelId.decode(encoded);

    expect(encoded, startsWith('direct:profile-one:'));
    expect(decoded?.profileId, 'profile-one');
    expect(decoded?.remoteModelId, 'org/model:版本');
  });

  test('remote models compare structurally, including capabilities', () {
    final first = DirectRemoteModel(
      id: 'model',
      name: 'Model',
      description: 'Example',
      isMultimodal: true,
      capabilities: const {
        'families': ['clip'],
        'limits': {'context': 4096},
      },
    );
    final second = DirectRemoteModel(
      id: 'model',
      name: 'Model',
      description: 'Example',
      isMultimodal: true,
      capabilities: const {
        'families': ['clip'],
        'limits': {'context': 4096},
      },
    );

    expect(second, first);
    expect(second.hashCode, first.hashCode);
    expect(
      DirectRemoteModel(id: 'model', capabilities: const {'vision': false}),
      isNot(first),
    );
  });

  test('remote model capabilities are recursively copied and frozen', () {
    final source = <String, dynamic>{
      'families': <String>['clip'],
      'limits': <String, dynamic>{'context': 4096},
    };
    final model = DirectRemoteModel(id: 'model', capabilities: source);
    final initialHash = model.hashCode;

    (source['families'] as List<String>).add('mutated');
    (source['limits'] as Map<String, dynamic>)['context'] = 1;

    expect(model.capabilities['families'], ['clip']);
    expect((model.capabilities['limits'] as Map)['context'], 4096);
    expect(model.hashCode, initialHash);
    expect(
      () => (model.capabilities['families'] as List).add('blocked'),
      throwsUnsupportedError,
    );
    expect(
      () => (model.capabilities['limits'] as Map)['context'] = 2,
      throwsUnsupportedError,
    );
  });

  test('only locally minted and currently registered models resolve', () {
    final registry = DirectModelRegistry();
    final profile = DirectConnectionProfile(
      id: 'profile-one',
      name: 'Example',
      adapterKey: kOllamaAdapterKey,
      baseUrl: 'http://localhost:11434',
    );
    final models = registry.replaceProfileModels(profile, [
      DirectRemoteModel(id: 'llava:latest', isMultimodal: true),
    ]);
    final minted = models.single;
    final forged = Model(
      id: minted.id,
      name: minted.name,
      metadata: const {'backend': 'direct'},
    );

    expect(registry.resolve(minted)?.remoteModelId, 'llava:latest');
    expect(registry.resolve(forged), isNull);
    expect(registry.resolveRegisteredId(minted.id), isNotNull);

    registry.removeProfile(profile.id);
    expect(registry.resolve(minted), isNull);
    expect(registry.resolveRegisteredId(minted.id), isNull);
  });

  test('stale model cannot resolve through a recreated equal binding', () {
    final registry = DirectModelRegistry();
    final profile = DirectConnectionProfile(
      id: 'profile-one',
      name: 'Example',
      adapterKey: kOllamaAdapterKey,
      baseUrl: 'http://localhost:11434',
    );
    final stale = registry.replaceProfileModels(profile, [
      DirectRemoteModel(id: 'model'),
    ]).single;

    registry.removeProfile(profile.id);
    final current = registry.replaceProfileModels(profile, [
      DirectRemoteModel(id: 'model'),
    ]).single;

    expect(stale.id, current.id);
    expect(registry.resolve(stale), isNull);
    expect(registry.resolve(current)?.remoteModelId, 'model');
  });

  test(
    'profile prefixes and tags decorate models without changing routing',
    () {
      final registry = DirectModelRegistry();
      final profile = DirectConnectionProfile(
        id: 'lm-studio',
        name: 'LM Studio',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'http://localhost:1234/v1',
        modelIdPrefix: 'studio',
        tags: const ['local', 'private'],
      );

      final model = registry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'qwen', name: 'Qwen'),
      ]).single;

      expect(model.name, 'studio.Qwen');
      expect(model.modelTags, ['local', 'private']);
      expect(model.metadata?['remoteModelDisplayId'], 'studio.qwen');
      expect(registry.resolve(model)?.remoteModelId, 'qwen');
    },
  );

  test('display reconciliation removes remote reserved identities', () {
    final registry = DirectModelRegistry();
    final remote = [
      const Model(id: 'normal', name: 'Normal'),
      const Model(id: 'direct:forged:value', name: 'Forged'),
      const Model(
        id: 'also-forged',
        name: 'Forged metadata',
        metadata: {'direct': true},
      ),
    ];

    final reconciled = reconcileDirectModelsForDisplay(
      remoteModels: remote,
      directModels: const [],
      registry: registry,
    );

    expect(reconciled.map((model) => model.id), ['normal']);
  });

  test('display reconciliation removes stale locally minted models', () {
    final registry = DirectModelRegistry();
    final profile = DirectConnectionProfile(
      id: 'profile-one',
      name: 'Example',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://example.test/v1',
    );
    final stale = registry.replaceProfileModels(profile, [
      DirectRemoteModel(id: 'stale-model'),
    ]).single;

    expect(
      reconcileDirectModelsForDisplay(
        remoteModels: const [],
        directModels: [stale],
        registry: registry,
      ),
      [stale],
    );

    registry.removeProfile(profile.id);
    final reconciled = reconcileDirectModelsForDisplay(
      remoteModels: const [],
      directModels: [stale],
      registry: registry,
    );

    expect(reconciled, isEmpty);
  });

  test('adapter registry is string-keyed and rejects duplicates', () {
    final first = _Adapter('custom-provider');
    final registry = DirectProviderAdapterRegistry([first]);

    expect(registry.require('custom-provider'), same(first));
    expect(registry.lookup('  custom-provider  '), same(first));
    expect(
      () => registry.register(_Adapter('custom-provider')),
      throwsStateError,
    );
    expect(registry.unregister(' custom-provider '), isTrue);
    expect(registry.lookup('custom-provider'), isNull);
  });

  test('a stop during preflight cancels the run before registration', () async {
    final registry = DirectRunRegistry();
    final reservation = registry.reserve('assistant-one', 'profile-one');

    final stop = registry.cancel('assistant-one');
    expect(stop, isNotNull);
    await stop;
    expect(registry.isCancelled(reservation), isTrue);

    final token = CancelToken();
    final run = _run('run-one', token);
    expect(registry.register(reservation, run), isFalse);
    await Future<void>.delayed(Duration.zero);

    expect(token.isCancelled, isTrue);
    expect(registry.runFor('assistant-one'), isNull);
  });

  test(
    'a stale reservation cannot release or publish over its replacement',
    () async {
      final registry = DirectRunRegistry();
      final stale = registry.reserve('assistant-one', 'profile-one');
      final current = registry.reserve('assistant-one', 'profile-one');

      registry.releaseReservation(stale);
      expect(registry.isCancelled(stale), isTrue);
      expect(registry.isCancelled(current), isFalse);

      final staleCancelToken = CancelToken();
      final staleRun = _run('stale-run', staleCancelToken);
      expect(registry.register(stale, staleRun), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(staleCancelToken.isCancelled, isTrue);
      expect(registry.isCancelled(current), isFalse);

      final currentRun = _run('current-run', CancelToken());
      expect(registry.register(current, currentRun), isTrue);
      expect(registry.runFor('assistant-one'), same(currentRun));
    },
  );
}

DirectCompletionRun _run(String id, CancelToken cancelToken) =>
    DirectCompletionRun(
      id: id,
      profileId: 'profile-one',
      remoteModelId: 'model-one',
      events: const Stream<DirectStreamEvent>.empty(),
      cancelToken: cancelToken,
      done: Future<void>.value(),
    );

final class _Adapter implements DirectProviderAdapter {
  const _Adapter(this.key);

  @override
  final String key;

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async => const [];

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async =>
      const DirectConnectionProbe(reachable: true);

  @override
  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  ) => throw UnimplementedError();
}
