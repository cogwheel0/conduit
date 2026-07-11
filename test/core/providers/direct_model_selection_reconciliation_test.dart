import 'dart:async';

import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
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
}
