import 'dart:async';

import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit/features/direct_connections/services/direct_provider_adapter.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _PendingDiscovery extends DirectModelDiscoveryController {
  _PendingDiscovery(this.completer);

  final Completer<DirectModelDiscoveryState> completer;

  @override
  Future<DirectModelDiscoveryState> build() => completer.future;
}

final class _Storage extends Fake implements OptimizedStorageService {
  @override
  Future<void> saveLocalModels(List<Model> models) async {}
}

final class _CachedStorage extends _Storage {
  @override
  Future<List<Model>> getLocalModels() async => const [
    Model(id: 'cached-model', name: 'Cached model'),
  ];
}

final class _FixedProfiles extends DirectConnectionProfilesController {
  _FixedProfiles(this.profile);

  final DirectConnectionProfile profile;

  @override
  Future<List<DirectConnectionProfile>> build() async => [profile];
}

final class _StableAdapter implements DirectProviderAdapter {
  int listCalls = 0;

  @override
  String get key => kOllamaAdapterKey;

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async {
    listCalls++;
    await Future<void>.delayed(Duration.zero);
    return [DirectRemoteModel(id: 'stable-model')];
  }

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async =>
      const DirectConnectionProbe(reachable: true);

  @override
  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  ) => throw UnimplementedError();
}

final class _CountingModelsApi extends ApiService {
  _CountingModelsApi(WorkerManager workerManager)
    : super(
        serverConfig: const ServerConfig(
          id: 'direct-refresh-test',
          name: 'Direct refresh test',
          url: 'https://openwebui.example',
        ),
        workerManager: workerManager,
      );

  int getModelsCalls = 0;

  @override
  Future<List<Model>> getModels({bool includeHidden = false}) async {
    getModelsCalls++;
    await Future<void>.delayed(Duration.zero);
    return const [Model(id: 'fresh-model', name: 'Fresh model')];
  }
}

final class _FixedHermesConfig extends HermesConfigController {
  _FixedHermesConfig(this.config);

  final HermesConfig config;

  @override
  HermesConfig build() => config;
}

({
  ProviderContainer container,
  Completer<DirectModelDiscoveryState> discovery,
  Model selected,
})
_createFixture({HermesConfig hermesConfig = const HermesConfig()}) {
  final profile = DirectConnectionProfile(
    id: 'profile',
    name: 'Provider',
    adapterKey: 'ollama',
    baseUrl: 'http://localhost:11434',
  );
  final registry = DirectModelRegistry();
  final selected = registry.replaceProfileModels(profile, [
    DirectRemoteModel(id: 'persisted-model'),
  ]).single;
  final discovery = Completer<DirectModelDiscoveryState>();
  final container = ProviderContainer(
    overrides: [
      reviewerModeProvider.overrideWithValue(false),
      isAuthenticatedProvider2.overrideWithValue(false),
      optimizedStorageServiceProvider.overrideWithValue(_Storage()),
      directModelRegistryProvider.overrideWithValue(registry),
      directModelDiscoveryProvider.overrideWith(
        () => _PendingDiscovery(discovery),
      ),
      hermesConfigProvider.overrideWith(() => _FixedHermesConfig(hermesConfig)),
    ],
  );
  container.read(selectedModelProvider.notifier).set(selected);
  container.read(isManualModelSelectionProvider.notifier).set(true);
  return (container: container, discovery: discovery, selected: selected);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'initial direct discovery does not discard persisted selection',
    () async {
      final fixture = _createFixture();
      addTearDown(fixture.container.dispose);

      await fixture.container.read(modelsProvider.future);
      await Future<void>.delayed(Duration.zero);

      expect(
        fixture.container.read(selectedModelProvider),
        same(fixture.selected),
      );

      fixture.discovery.complete(
        DirectModelDiscoveryState(models: [fixture.selected]),
      );
      final discovery = await fixture.container.read(
        directModelDiscoveryProvider.future,
      );
      expect(discovery.models, contains(same(fixture.selected)));
      expect(isLocallyMintedDirectModel(discovery.models.single), isTrue);
      expect(
        fixture.container
            .read(directModelRegistryProvider)
            .resolve(discovery.models.single),
        isNotNull,
      );
      await Future<void>.delayed(Duration.zero);

      final models = await fixture.container.read(modelsProvider.future);
      await Future<void>.delayed(Duration.zero);
      expect(models, contains(same(fixture.selected)));
      expect(
        fixture.container.read(selectedModelProvider),
        same(fixture.selected),
      );
    },
  );

  test('terminal empty discovery clears the deferred selection', () async {
    final fixture = _createFixture();
    addTearDown(fixture.container.dispose);

    await fixture.container.read(modelsProvider.future);
    await Future<void>.delayed(Duration.zero);
    expect(
      fixture.container.read(selectedModelProvider),
      same(fixture.selected),
    );

    fixture.discovery.complete(DirectModelDiscoveryState());
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(fixture.container.read(selectedModelProvider), isNull);
    expect(fixture.container.read(isManualModelSelectionProvider), isFalse);
  });

  test('terminal discovery error reconciles to an available model', () async {
    final fixture = _createFixture(
      hermesConfig: const HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example/v1',
        apiKey: 'test-key',
      ),
    );
    addTearDown(fixture.container.dispose);

    await fixture.container.read(modelsProvider.future);
    await Future<void>.delayed(Duration.zero);
    final discovery = fixture.container.read(
      directModelDiscoveryProvider.future,
    );

    fixture.discovery.completeError(StateError('discovery failed'));
    await expectLater(discovery, throwsA(isA<StateError>()));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(
      isHermesModel(fixture.container.read(selectedModelProvider)!),
      isTrue,
    );
    expect(fixture.container.read(isManualModelSelectionProvider), isFalse);
  });

  test(
    'equivalent direct discovery does not loop cached model refreshes',
    () async {
      final profile = DirectConnectionProfile(
        id: 'stable-profile',
        name: 'Stable profile',
        adapterKey: kOllamaAdapterKey,
        baseUrl: 'http://localhost:11434',
      );
      final adapter = _StableAdapter();
      final workerManager = WorkerManager();
      final api = _CountingModelsApi(workerManager);
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(true),
          apiServiceProvider.overrideWithValue(api),
          optimizedStorageServiceProvider.overrideWithValue(_CachedStorage()),
          directConnectionProfilesProvider.overrideWith(
            () => _FixedProfiles(profile),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([adapter]),
          ),
          hermesConfigProvider.overrideWith(
            () => _FixedHermesConfig(const HermesConfig()),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(workerManager.dispose);

      await container.read(directModelDiscoveryProvider.future);
      final initialModels = await container.read(modelsProvider.future);
      expect(initialModels.map((model) => model.id), contains('cached-model'));
      final initialDirectModel = initialModels.singleWhere(
        isLocallyMintedDirectModel,
      );

      await Future<void>.delayed(const Duration(milliseconds: 40));
      final settledDiscoveryCalls = adapter.listCalls;
      final settledApiCalls = api.getModelsCalls;
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(adapter.listCalls, settledDiscoveryCalls);
      expect(api.getModelsCalls, settledApiCalls);
      expect(settledDiscoveryCalls, lessThanOrEqualTo(3));
      expect(settledApiCalls, lessThanOrEqualTo(2));
      final currentDirectModel = container
          .read(modelsProvider)
          .requireValue
          .singleWhere(isLocallyMintedDirectModel);
      expect(currentDirectModel, same(initialDirectModel));
      expect(
        container.read(directModelRegistryProvider).resolve(initialDirectModel),
        isNotNull,
      );
    },
  );
}
