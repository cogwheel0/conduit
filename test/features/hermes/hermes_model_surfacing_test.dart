import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/auth/auth_state_manager.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/providers/backend_mode_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void _addOwnedApiCleanup(
  ProviderContainer container,
  ApiService api,
  WorkerManager workerManager,
) {
  addTearDown(() {
    container.dispose();
    api.dispose();
    workerManager.dispose();
  });
}

const _modelsServer = ServerConfig(
  id: 'models-test',
  name: 'Models test',
  url: 'https://openwebui.example',
);

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

  @override
  Future<Model?> getLocalDefaultModel() async => null;

  @override
  Future<void> saveLocalDefaultModel(Model? model) async {}
}

class _MutableHermesConfigController extends HermesConfigController {
  _MutableHermesConfigController(this._initial);

  final HermesConfig _initial;

  @override
  HermesConfig build() => _initial;

  void setConfig(HermesConfig config) => state = config;
}

class _MutableReviewerMode extends ReviewerMode {
  @override
  bool build() => false;

  @override
  Future<void> setEnabled(bool enabled) async => state = enabled;
}

class _PendingInitialAuthStateManager extends AuthStateManager {
  _PendingInitialAuthStateManager(this._result, this.started);

  final Future<AuthState> _result;
  final Completer<void> started;

  @override
  Future<AuthState> build() {
    if (!started.isCompleted) started.complete();
    return _result;
  }
}

class _PendingDirectDiscovery extends DirectModelDiscoveryController {
  _PendingDirectDiscovery(this._result, this.started);

  final Future<DirectModelDiscoveryState> _result;
  final Completer<void> started;

  @override
  Future<DirectModelDiscoveryState> build() {
    if (!started.isCompleted) started.complete();
    return _result;
  }

  @override
  Future<void> refresh() async {}
}

class _FakePreferredBackendController extends PreferredBackendController {
  _FakePreferredBackendController(this._backend);

  final PreferredBackend _backend;

  @override
  PreferredBackend build() => _backend;
}

class _ModelsApiService extends ApiService {
  _ModelsApiService(this.workerManager, {this.responseGate})
    : super(serverConfig: _modelsServer, workerManager: workerManager);

  final WorkerManager workerManager;
  final Completer<void>? responseGate;
  final Completer<void> getModelsStarted = Completer<void>();
  int getModelsCalls = 0;
  bool fail = false;

  @override
  Future<List<Model>> getModels({bool includeHidden = false}) async {
    getModelsCalls += 1;
    if (!getModelsStarted.isCompleted) getModelsStarted.complete();
    await responseGate?.future;
    if (fail) throw StateError('temporary models outage');
    return const <Model>[Model(id: 'owui-model', name: 'OpenWebUI model')];
  }
}

class _PendingDefaultModelApi extends ApiService {
  _PendingDefaultModelApi(this.workerManager, this._defaultModel, this.started)
    : super(serverConfig: _modelsServer, workerManager: workerManager);

  final WorkerManager workerManager;
  final Future<String?> _defaultModel;
  final Completer<void> started;

  @override
  Future<String?> getDefaultModel() {
    if (!started.isCompleted) started.complete();
    return _defaultModel;
  }

  @override
  Future<List<Model>> getModels({bool includeHidden = false}) async => const [
    Model(id: 'owui/stale', name: 'Stale OpenWebUI model'),
  ];
}

class _PendingModels extends Models {
  _PendingModels(this.models, {this.started});

  final Future<List<Model>> models;
  final Completer<void>? started;

  @override
  Future<List<Model>> build() {
    final started = this.started;
    if (started != null && !started.isCompleted) started.complete();
    return models;
  }
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
      'active server reload does not retire an in-flight models future',
      () async {
        final workerManager = WorkerManager();
        final responseGate = Completer<void>();
        final reloadGate = Completer<ServerConfig?>();
        final reloadStarted = Completer<void>();
        final api = _ModelsApiService(
          workerManager,
          responseGate: responseGate,
        );
        var activeServerBuilds = 0;
        addTearDown(() {
          if (!responseGate.isCompleted) responseGate.complete();
          if (!reloadGate.isCompleted) reloadGate.complete(_modelsServer);
        });
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWithValue(false),
            isAuthenticatedProvider2.overrideWithValue(true),
            activeServerProvider.overrideWith((_) {
              activeServerBuilds += 1;
              if (activeServerBuilds == 1) return _modelsServer;
              if (!reloadStarted.isCompleted) reloadStarted.complete();
              return reloadGate.future;
            }),
            apiServiceProvider.overrideWithValue(api),
            optimizedStorageServiceProvider.overrideWithValue(
              _FakeOptimizedStorageService(),
            ),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_incompleteHermes),
            ),
          ],
        );
        _addOwnedApiCleanup(container, api, workerManager);

        check(
          await container.read(activeServerProvider.future),
        ).equals(_modelsServer);
        final pendingModels = container.read(modelsProvider.future);
        await api.getModelsStarted.future;

        container.invalidate(activeServerProvider);
        await reloadStarted.future;

        final reloadingServer = container.read(activeServerProvider);
        check(reloadingServer.isLoading).isTrue();
        check(reloadingServer.value?.id).equals(_modelsServer.id);

        responseGate.complete();
        final models = await pendingModels;

        check(
          models.map((model) => model.id).toList(),
        ).deepEquals(<String>['owui-model']);
        check(api.getModelsCalls).equals(1);
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
      'authenticated default still selects Hermes when the api is unavailable',
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

        final model = await container.read(defaultModelProvider.future);

        check(model).isNotNull();
        check(isHermesModel(model!)).isTrue();
        check(container.read(selectedModelProvider)).identicalTo(model);
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

    test('default model reacts when reviewer mode is enabled', () async {
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWith(_MutableReviewerMode.new),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          optimizedStorageServiceProvider.overrideWithValue(
            _FakeOptimizedStorageService(),
          ),
          hermesConfigProvider.overrideWith(
            () => _FakeHermesConfigController(_incompleteHermes),
          ),
        ],
      );
      addTearDown(container.dispose);

      check(await container.read(defaultModelProvider.future)).isNull();

      await container.read(reviewerModeProvider.notifier).setEnabled(true);
      final reviewerDefault = await container.read(defaultModelProvider.future);

      check(reviewerDefault).isNotNull();
      check(reviewerDefault!.id).equals('demo/gemma-2-mini');
    });

    test(
      'reviewer enable during Hermes handoff resolves reviewer model',
      () async {
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWith(_MutableReviewerMode.new),
            preferredBackendProvider.overrideWith(
              () => _FakePreferredBackendController(PreferredBackend.hermes),
            ),
            isAuthenticatedProvider2.overrideWithValue(false),
            isAuthLoadingProvider2.overrideWithValue(false),
            authStatusProvider.overrideWithValue(AuthStatus.unauthenticated),
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

        final pendingDefault = container.read(defaultModelProvider.future);
        var defaultSettled = false;
        unawaited(
          pendingDefault.then<void>((_) {
            defaultSettled = true;
          }),
        );
        // The Hermes fast path deliberately yields before publishing its local
        // model. Enter that real in-flight handoff before changing universes;
        // otherwise this can pass as a simple reviewer-first resolution test.
        await Future<void>.microtask(() {});
        check(defaultSettled).isFalse();
        await container.read(reviewerModeProvider.notifier).setEnabled(true);

        final resolved = await pendingDefault.timeout(
          const Duration(seconds: 5),
        );
        check(resolved)
            .isNotNull()
            .has((model) => model.id, 'id')
            .equals('demo/gemma-2-mini');
        check(container.read(selectedModelProvider)).identicalTo(resolved);
      },
    );

    test(
      'reviewer enable during final Hermes publish is re-resolved',
      () async {
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWith(_MutableReviewerMode.new),
            preferredBackendProvider.overrideWith(
              () => _FakePreferredBackendController(PreferredBackend.hermes),
            ),
            isAuthenticatedProvider2.overrideWithValue(false),
            isAuthLoadingProvider2.overrideWithValue(false),
            authStatusProvider.overrideWithValue(AuthStatus.unauthenticated),
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
        final selectionSub = container.listen<Model?>(selectedModelProvider, (
          previous,
          next,
        ) {
          if (next != null && isHermesModel(next)) {
            unawaited(
              container.read(reviewerModeProvider.notifier).setEnabled(true),
            );
          }
        });
        addTearDown(selectionSub.close);
        container.read(selectedModelProvider.notifier).clear();

        final resolved = await container
            .read(defaultModelProvider.future)
            .timeout(const Duration(seconds: 5));

        check(resolved)
            .isNotNull()
            .has((model) => model.id, 'id')
            .equals('demo/gemma-2-mini');
        check(container.read(selectedModelProvider)).identicalTo(resolved);
      },
    );

    test(
      'reviewer enable during Direct discovery resolves reviewer model',
      () async {
        final discoveryResult = Completer<DirectModelDiscoveryState>();
        final discoveryStarted = Completer<void>();
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWith(_MutableReviewerMode.new),
            preferredBackendProvider.overrideWith(
              () => _FakePreferredBackendController(PreferredBackend.direct),
            ),
            isAuthenticatedProvider2.overrideWithValue(false),
            isAuthLoadingProvider2.overrideWithValue(false),
            authStatusProvider.overrideWithValue(AuthStatus.unauthenticated),
            apiServiceProvider.overrideWithValue(null),
            optimizedStorageServiceProvider.overrideWithValue(
              _FakeOptimizedStorageService(),
            ),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_incompleteHermes),
            ),
            directModelDiscoveryProvider.overrideWith(
              () => _PendingDirectDiscovery(
                discoveryResult.future,
                discoveryStarted,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final pendingDefault = container.read(defaultModelProvider.future);
        await discoveryStarted.future;
        await container.read(reviewerModeProvider.notifier).setEnabled(true);
        discoveryResult.complete(DirectModelDiscoveryState());

        final resolved = await pendingDefault.timeout(
          const Duration(seconds: 5),
        );
        check(resolved)
            .isNotNull()
            .has((model) => model.id, 'id')
            .equals('demo/gemma-2-mini');
        check(container.read(selectedModelProvider)).identicalTo(resolved);
      },
    );

    test(
      'new manual selection wins a reviewer transition during await',
      () async {
        final discoveryResult = Completer<DirectModelDiscoveryState>();
        final discoveryStarted = Completer<void>();
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWith(_MutableReviewerMode.new),
            preferredBackendProvider.overrideWith(
              () => _FakePreferredBackendController(PreferredBackend.direct),
            ),
            isAuthenticatedProvider2.overrideWithValue(false),
            isAuthLoadingProvider2.overrideWithValue(false),
            authStatusProvider.overrideWithValue(AuthStatus.unauthenticated),
            apiServiceProvider.overrideWithValue(null),
            optimizedStorageServiceProvider.overrideWithValue(
              _FakeOptimizedStorageService(),
            ),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_incompleteHermes),
            ),
            directModelDiscoveryProvider.overrideWith(
              () => _PendingDirectDiscovery(
                discoveryResult.future,
                discoveryStarted,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final pendingDefault = container.read(defaultModelProvider.future);
        await discoveryStarted.future;
        const manual = Model(id: 'manual/new', name: 'New manual choice');
        container.read(selectedModelProvider.notifier).set(manual);
        container.read(isManualModelSelectionProvider.notifier).set(true);
        await container.read(reviewerModeProvider.notifier).setEnabled(true);
        discoveryResult.complete(DirectModelDiscoveryState());

        check(
          await pendingDefault.timeout(const Duration(seconds: 5)),
        ).identicalTo(manual);
        check(container.read(selectedModelProvider)).identicalTo(manual);
      },
    );

    test(
      'reviewer enable during cold auth wait resolves reviewer model',
      () async {
        final authResult = Completer<AuthState>();
        final authStarted = Completer<void>();
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWith(_MutableReviewerMode.new),
            preferredBackendProvider.overrideWith(
              () => _FakePreferredBackendController(PreferredBackend.hermes),
            ),
            authStateManagerProvider.overrideWith(
              () => _PendingInitialAuthStateManager(
                authResult.future,
                authStarted,
              ),
            ),
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

        final pendingDefault = container.read(defaultModelProvider.future);
        await authStarted.future;
        await container.read(reviewerModeProvider.notifier).setEnabled(true);
        authResult.complete(
          const AuthState(status: AuthStatus.unauthenticated),
        );

        final resolved = await pendingDefault.timeout(
          const Duration(seconds: 5),
        );
        check(resolved)
            .isNotNull()
            .has((model) => model.id, 'id')
            .equals('demo/gemma-2-mini');
        check(container.read(selectedModelProvider)).identicalTo(resolved);
      },
    );

    test(
      'reviewer enable during API default wait resolves reviewer model',
      () async {
        final workerManager = WorkerManager();
        final apiResult = Completer<String?>();
        final apiStarted = Completer<void>();
        final api = _PendingDefaultModelApi(
          workerManager,
          apiResult.future,
          apiStarted,
        );
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWith(_MutableReviewerMode.new),
            preferredBackendProvider.overrideWith(
              () => _FakePreferredBackendController(PreferredBackend.owui),
            ),
            isAuthenticatedProvider2.overrideWithValue(true),
            isAuthLoadingProvider2.overrideWithValue(false),
            authStatusProvider.overrideWithValue(AuthStatus.authenticated),
            authTokenProvider3.overrideWithValue('token'),
            activeServerProvider.overrideWith((ref) async => _modelsServer),
            apiServiceProvider.overrideWithValue(api),
            appSettingsProvider.overrideWithValue(
              const AppSettings(defaultModel: ''),
            ),
            optimizedStorageServiceProvider.overrideWithValue(
              _FakeOptimizedStorageService(),
            ),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_incompleteHermes),
            ),
          ],
        );
        _addOwnedApiCleanup(container, api, workerManager);
        await container.read(activeServerProvider.future);

        final pendingDefault = container.read(defaultModelProvider.future);
        await apiStarted.future.timeout(const Duration(seconds: 5));
        await container.read(reviewerModeProvider.notifier).setEnabled(true);
        apiResult.complete('owui/stale');

        final resolved = await pendingDefault.timeout(
          const Duration(seconds: 5),
        );
        check(resolved)
            .isNotNull()
            .has((model) => model.id, 'id')
            .equals('demo/gemma-2-mini');
        check(container.read(selectedModelProvider)).identicalTo(resolved);
      },
    );

    test(
      'reviewer on-off-on flap restarts the recursive off resolution',
      () async {
        const reviewerModel = Model(
          id: 'demo/reviewer-final',
          name: 'Reviewer final',
        );
        final reviewerModels = Completer<List<Model>>();
        final reviewerModelsStarted = Completer<void>();
        final workerManager = WorkerManager();
        final apiResult = Completer<String?>();
        final apiStarted = Completer<void>();
        final api = _PendingDefaultModelApi(
          workerManager,
          apiResult.future,
          apiStarted,
        );
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWith(_MutableReviewerMode.new),
            preferredBackendProvider.overrideWith(
              () => _FakePreferredBackendController(PreferredBackend.owui),
            ),
            isAuthenticatedProvider2.overrideWithValue(true),
            isAuthLoadingProvider2.overrideWithValue(false),
            authStatusProvider.overrideWithValue(AuthStatus.authenticated),
            authTokenProvider3.overrideWithValue('token'),
            activeServerProvider.overrideWith((ref) async => _modelsServer),
            apiServiceProvider.overrideWithValue(api),
            appSettingsProvider.overrideWithValue(
              const AppSettings(defaultModel: ''),
            ),
            optimizedStorageServiceProvider.overrideWithValue(
              _FakeOptimizedStorageService(),
            ),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_incompleteHermes),
            ),
            modelsProvider.overrideWith(
              () => _PendingModels(
                reviewerModels.future,
                started: reviewerModelsStarted,
              ),
            ),
          ],
        );
        _addOwnedApiCleanup(container, api, workerManager);
        await container.read(activeServerProvider.future);
        await container.read(reviewerModeProvider.notifier).setEnabled(true);

        final pendingDefault = container.read(defaultModelProvider.future);
        await reviewerModelsStarted.future;
        await container.read(reviewerModeProvider.notifier).setEnabled(false);
        reviewerModels.complete(const <Model>[reviewerModel]);

        await apiStarted.future.timeout(const Duration(seconds: 5));
        await container.read(reviewerModeProvider.notifier).setEnabled(true);
        apiResult.complete('owui/stale');

        check(
          await pendingDefault.timeout(const Duration(seconds: 5)),
        ).identicalTo(reviewerModel);
        check(container.read(selectedModelProvider)).identicalTo(reviewerModel);
      },
    );

    test(
      'reviewer-off during model load resolves usable Hermes on the same future',
      () async {
        final modelsCompleter = Completer<List<Model>>();
        final modelsStarted = Completer<void>();
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWith(_MutableReviewerMode.new),
            preferredBackendProvider.overrideWith(
              () => _FakePreferredBackendController(PreferredBackend.hermes),
            ),
            isAuthenticatedProvider2.overrideWithValue(false),
            apiServiceProvider.overrideWithValue(null),
            optimizedStorageServiceProvider.overrideWithValue(
              _FakeOptimizedStorageService(),
            ),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_usableHermes),
            ),
            modelsProvider.overrideWith(
              () => _PendingModels(
                modelsCompleter.future,
                started: modelsStarted,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        await container.read(reviewerModeProvider.notifier).setEnabled(true);
        final pendingDefault = container.read(defaultModelProvider.future);
        await modelsStarted.future;

        await container.read(reviewerModeProvider.notifier).setEnabled(false);
        modelsCompleter.complete(const <Model>[
          Model(id: 'demo/stale', name: 'Stale reviewer model'),
        ]);

        final resolved = await pendingDefault;
        check(resolved).isNotNull();
        check(isHermesModel(resolved!)).isTrue();
        check(container.read(selectedModelProvider)).identicalTo(resolved);
      },
    );

    test(
      'reviewer default preserves a manual selection made during model load',
      () async {
        final modelsCompleter = Completer<List<Model>>();
        final modelsStarted = Completer<void>();
        final container = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWith(_MutableReviewerMode.new),
            isAuthenticatedProvider2.overrideWithValue(false),
            apiServiceProvider.overrideWithValue(null),
            optimizedStorageServiceProvider.overrideWithValue(
              _FakeOptimizedStorageService(),
            ),
            hermesConfigProvider.overrideWith(
              () => _FakeHermesConfigController(_incompleteHermes),
            ),
            modelsProvider.overrideWith(
              () => _PendingModels(
                modelsCompleter.future,
                started: modelsStarted,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        await container.read(reviewerModeProvider.notifier).setEnabled(true);
        final pendingDefault = container.read(defaultModelProvider.future);
        await modelsStarted.future;

        const manual = Model(id: 'manual/current', name: 'Manual selection');
        container.read(selectedModelProvider.notifier).set(manual);
        container.read(isManualModelSelectionProvider.notifier).set(true);
        modelsCompleter.complete(const <Model>[
          Model(id: 'demo/stale', name: 'Stale reviewer model'),
        ]);

        check(await pendingDefault).identicalTo(manual);
        check(container.read(selectedModelProvider)).identicalTo(manual);
      },
    );

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
      _addOwnedApiCleanup(container, api, workerManager);

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
        _addOwnedApiCleanup(container, api, workerManager);

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
      _addOwnedApiCleanup(container, api, workerManager);

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
