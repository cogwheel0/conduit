import 'package:checks/checks.dart';
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
    implements OptimizedStorageService {}

const _usableHermes = HermesConfig(
  enabled: true,
  baseUrl: 'https://hermes.example/v1',
  apiKey: 'secret-key',
);

void main() {
  group('Hermes model surfacing without an OWUI server', () {
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
