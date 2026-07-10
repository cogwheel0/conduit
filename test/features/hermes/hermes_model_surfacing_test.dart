import 'package:checks/checks.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
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
  Future<void> saveLocalModels(List<Model> models) async {}
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
  });
}
