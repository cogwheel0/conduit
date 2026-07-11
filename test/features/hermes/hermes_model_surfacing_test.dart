import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [HermesConfigController] stand-in yielding a fixed config without touching
/// shared preferences or secure storage.
class _FakeHermesConfigController extends HermesConfigController {
  _FakeHermesConfigController(this._config);

  final HermesConfig _config;

  @override
  HermesConfig build() => _config;
}

/// `defaultModelProvider` reads the storage service at the top but never calls a
/// method on it before the Hermes-only branch returns, so an empty fake is fine.
class _FakeOptimizedStorageService extends Fake
    implements OptimizedStorageService {
  @override
  Future<List<Model>> getLocalModels() async => const <Model>[];

  @override
  Future<void> saveLocalModels(List<Model> models) async {}
}

class _MutableHermesConfigController extends HermesConfigController {
  _MutableHermesConfigController(this._initial);

  final HermesConfig _initial;

  @override
  HermesConfig build() => _initial;

  void setConfig(HermesConfig config) => state = config;
}

class _ModelsApiService extends ApiService {
  _ModelsApiService(this.workerManager)
    : super(
        serverConfig: const ServerConfig(
          id: 'models-test',
          name: 'Models test',
          url: 'https://openwebui.example',
        ),
        workerManager: workerManager,
      );

  final WorkerManager workerManager;
  bool fail = false;

  @override
  Future<List<Model>> getModels({bool includeHidden = false}) async {
    if (fail) throw StateError('temporary models outage');
    return const <Model>[Model(id: 'owui-model', name: 'OpenWebUI model')];
  }
}

class _PendingModels extends Models {
  _PendingModels(this.models);

  final Future<List<Model>> models;

  @override
  Future<List<Model>> build() => models;
}

const _usableHermes = HermesConfig(
  enabled: true,
  baseUrl: 'https://hermes.example/v1',
  apiKey: 'secret-key',
);

const _incompleteHermes = HermesConfig(
  enabled: true,
  baseUrl: 'https://hermes.example/v1',
);

void main() {
  group('Hermes model surfacing without an OWUI server', () {
    test('synthetic model requires a usable Hermes connection', () {
      const remote = <Model>[Model(id: 'safe', name: 'Safe')];

      final incomplete = appendHermesModelIfUsable(
        remote,
        hermesUsable: _incompleteHermes.isUsable,
      );
      check(incomplete).length.equals(1);
      check(incomplete.any(isHermesModel)).isFalse();

      final usable = appendHermesModelIfUsable(
        remote,
        hermesUsable: _usableHermes.isUsable,
      );
      check(usable).length.equals(2);
      check(usable.any(isHermesModel)).isTrue();
    });

    test('malicious server default cannot claim Hermes routing', () {
      const remote = [
        Model(id: '${kHermesModelIdPrefix}shadow', name: 'Looks like GPT'),
        Model(id: 'safe', name: 'Safe'),
      ];

      final selected = resolveSafeRemoteDefaultModel(
        remote,
        '${kHermesModelIdPrefix}shadow',
      );
      check(selected).isNotNull().has((m) => m.id, 'id').equals('safe');
      check(isHermesModel(selected!)).isFalse();
    });

    test('modelsProvider surfaces only the synthetic Hermes model', () async {
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          hermesConfigProvider.overrideWith(
            () => _FakeHermesConfigController(_usableHermes),
          ),
        ],
      );
      addTearDown(container.dispose);

      final models = await container.read(modelsProvider.future);
      check(models).length.equals(1);
      check(isHermesModel(models.first)).isTrue();
    });

    test(
      'refresh preserves the synthetic model while unauthenticated',
      () async {
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            isAuthenticatedProvider2.overrideWithValue(false),
            optimizedStorageServiceProvider.overrideWithValue(
              _FakeOptimizedStorageService(),
            ),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_usableHermes),
            ),
          ],
        );
        addTearDown(container.dispose);

        await container.read(modelsProvider.future);
        await container.read(modelsProvider.notifier).refresh();

        final models = container.read(modelsProvider).requireValue;
        check(models).length.equals(1);
        check(isHermesModel(models.single)).isTrue();
      },
    );

    test(
      'authenticated build preserves Hermes while the api is unavailable',
      () async {
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            isAuthenticatedProvider2.overrideWithValue(true),
            apiServiceProvider.overrideWithValue(null),
            optimizedStorageServiceProvider.overrideWithValue(
              _FakeOptimizedStorageService(),
            ),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_usableHermes),
            ),
          ],
        );
        addTearDown(container.dispose);

        final models = await container.read(modelsProvider.future);

        check(models).length.equals(1);
        check(isHermesModel(models.single)).isTrue();
      },
    );

    test(
      'authenticated refresh preserves Hermes while the api is unavailable',
      () async {
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            isAuthenticatedProvider2.overrideWithValue(true),
            apiServiceProvider.overrideWithValue(null),
            optimizedStorageServiceProvider.overrideWithValue(
              _FakeOptimizedStorageService(),
            ),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_usableHermes),
            ),
          ],
        );
        addTearDown(container.dispose);

        await container.read(modelsProvider.future);
        await container.read(modelsProvider.notifier).refresh();

        final models = container.read(modelsProvider).requireValue;
        check(models).length.equals(1);
        check(isHermesModel(models.single)).isTrue();
      },
    );

    test(
      'defaultModelProvider auto-selects Hermes when there is no api',
      () async {
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            isAuthenticatedProvider2.overrideWithValue(false),
            apiServiceProvider.overrideWithValue(null),
            optimizedStorageServiceProvider.overrideWithValue(
              _FakeOptimizedStorageService(),
            ),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_usableHermes),
            ),
          ],
        );
        addTearDown(container.dispose);

        final model = await container.read(defaultModelProvider.future);
        check(model).isNotNull();
        check(isHermesModel(model!)).isTrue();

        // The auto-select wrote through to the selected-model provider.
        final selected = container.read(selectedModelProvider);
        check(selected).isNotNull();
        check(isHermesModel(selected!)).isTrue();
      },
    );

    test(
      'default model stops safely when disposed during Hermes model loading',
      () async {
        final modelsCompleter = Completer<List<Model>>();
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            apiServiceProvider.overrideWithValue(null),
            optimizedStorageServiceProvider.overrideWithValue(
              _FakeOptimizedStorageService(),
            ),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_usableHermes),
            ),
            modelsProvider.overrideWith(
              () => _PendingModels(modelsCompleter.future),
            ),
          ],
        );

        final pendingDefault = container.read(defaultModelProvider.future);
        container.dispose();
        modelsCompleter.complete(<Model>[hermesSyntheticModel()]);

        check(await pendingDefault).isNull();
      },
    );

    test('default model reacts when Hermes becomes usable', () async {
      final hermesController = _MutableHermesConfigController(
        _incompleteHermes,
      );
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          optimizedStorageServiceProvider.overrideWithValue(
            _FakeOptimizedStorageService(),
          ),
          hermesConfigProvider.overrideWith(() => hermesController),
        ],
      );
      addTearDown(container.dispose);

      check(await container.read(defaultModelProvider.future)).isNull();

      hermesController.setConfig(_usableHermes);
      final model = await container.read(defaultModelProvider.future);

      check(model).isNotNull();
      check(isHermesModel(model!)).isTrue();
    });

    test(
      'unauthenticated rebuild clears a selected Hermes model when unusable',
      () async {
        final hermesController = _MutableHermesConfigController(_usableHermes);
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            isAuthenticatedProvider2.overrideWithValue(false),
            optimizedStorageServiceProvider.overrideWithValue(
              _FakeOptimizedStorageService(),
            ),
            hermesConfigProvider.overrideWith(() => hermesController),
          ],
        );
        addTearDown(container.dispose);

        final initialModels = await container.read(modelsProvider.future);
        container
            .read(selectedModelProvider.notifier)
            .set(initialModels.single);
        container.read(isManualModelSelectionProvider.notifier).set(true);

        hermesController.setConfig(_incompleteHermes);
        final rebuiltModels = await container.read(modelsProvider.future);
        await Future<void>.delayed(Duration.zero);

        check(rebuiltModels).isEmpty();
        check(container.read(selectedModelProvider)).isNull();
        check(container.read(isManualModelSelectionProvider)).isFalse();
      },
    );

    test(
      'unauthenticated refresh clears a stale selected Hermes model',
      () async {
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            isAuthenticatedProvider2.overrideWithValue(false),
            optimizedStorageServiceProvider.overrideWithValue(
              _FakeOptimizedStorageService(),
            ),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_incompleteHermes),
            ),
          ],
        );
        addTearDown(container.dispose);

        await container.read(modelsProvider.future);
        container
            .read(selectedModelProvider.notifier)
            .set(hermesSyntheticModel());
        container.read(isManualModelSelectionProvider.notifier).set(true);

        await container.read(modelsProvider.notifier).refresh();

        check(container.read(selectedModelProvider)).isNull();
        check(container.read(isManualModelSelectionProvider)).isFalse();
      },
    );

    test('authenticated rebuild clears unusable Hermes selection', () async {
      final workerManager = WorkerManager();
      final api = _ModelsApiService(workerManager);
      final hermesController = _MutableHermesConfigController(_usableHermes);
      addTearDown(workerManager.dispose);
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(true),
          apiServiceProvider.overrideWithValue(api),
          optimizedStorageServiceProvider.overrideWithValue(
            _FakeOptimizedStorageService(),
          ),
          hermesConfigProvider.overrideWith(() => hermesController),
        ],
      );
      addTearDown(container.dispose);

      final initialModels = await container.read(modelsProvider.future);
      container
          .read(selectedModelProvider.notifier)
          .set(initialModels.firstWhere(isHermesModel));
      container.read(isManualModelSelectionProvider.notifier).set(true);

      hermesController.setConfig(_incompleteHermes);
      final rebuiltModels = await container.read(modelsProvider.future);
      await Future<void>.delayed(Duration.zero);

      check(
        rebuiltModels.map((model) => model.id).toList(),
      ).deepEquals(<String>['owui-model']);
      check(container.read(selectedModelProvider)).isNull();
      check(container.read(isManualModelSelectionProvider)).isFalse();
    });

    test(
      'failed authenticated rebuild still clears unusable Hermes selection',
      () async {
        final workerManager = WorkerManager();
        final api = _ModelsApiService(workerManager);
        final hermesController = _MutableHermesConfigController(_usableHermes);
        addTearDown(workerManager.dispose);
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            isAuthenticatedProvider2.overrideWithValue(true),
            apiServiceProvider.overrideWithValue(api),
            optimizedStorageServiceProvider.overrideWithValue(
              _FakeOptimizedStorageService(),
            ),
            hermesConfigProvider.overrideWith(() => hermesController),
          ],
        );
        addTearDown(container.dispose);

        final initialModels = await container.read(modelsProvider.future);
        container
            .read(selectedModelProvider.notifier)
            .set(initialModels.firstWhere(isHermesModel));
        container.read(isManualModelSelectionProvider.notifier).set(true);

        api.fail = true;
        hermesController.setConfig(_incompleteHermes);
        await expectLater(
          container.read(modelsProvider.future),
          throwsA(isA<StateError>()),
        );
        await Future<void>.delayed(Duration.zero);

        check(container.read(selectedModelProvider)).isNull();
        check(container.read(isManualModelSelectionProvider)).isFalse();
      },
    );

    test('failed model refresh preserves the OpenWebUI selection', () async {
      final workerManager = WorkerManager();
      final api = _ModelsApiService(workerManager);
      addTearDown(workerManager.dispose);
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(true),
          apiServiceProvider.overrideWithValue(api),
          optimizedStorageServiceProvider.overrideWithValue(
            _FakeOptimizedStorageService(),
          ),
          hermesConfigProvider.overrideWith(
            () => _FakeHermesConfigController(_usableHermes),
          ),
        ],
      );
      addTearDown(container.dispose);

      final initialModels = await container.read(modelsProvider.future);
      final openWebUiModel = initialModels.firstWhere(
        (model) => model.id == 'owui-model',
      );
      container.read(selectedModelProvider.notifier).set(openWebUiModel);

      api.fail = true;
      await container.read(modelsProvider.notifier).refresh();

      check(container.read(modelsProvider).hasError).isTrue();
      check(container.read(selectedModelProvider)?.id).equals('owui-model');
    });
  });
}
