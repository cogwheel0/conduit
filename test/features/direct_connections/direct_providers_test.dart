import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/secure_credential_storage.dart';
import 'package:conduit_core/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:conduit/features/direct_connections/services/apple_pcc_adapter.dart';
import 'package:conduit_core/features/direct_connections/services/direct_adapter_helpers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_connection_profile_store.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_cache_store.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/direct_connections/services/direct_provider_adapter.dart';
import 'package:conduit_core/features/direct_connections/services/direct_run_registry.dart';
import 'package:conduit_core/features/direct_connections/services/ollama_adapter.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit/platform/flutter_secure_key_value_store.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit/features/direct_connections/providers/apple_pcc_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  });

  tearDown(PreferencesStore.debugReset);

  group('Apple model status off iOS', () {
    ProviderContainer buildContainer() {
      final container = ProviderContainer(
        overrides: [
          applePccPlatformSupportedProvider.overrideWithValue(false),
          applePccAdapterProvider.overrideWithValue(
            ApplePccAdapter(hostApi: _UnreachablePccHost()),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('reports unsupported without probing the platform channel', () async {
      final container = buildContainer();

      final onDevice = await container.read(appleOnDeviceStatusProvider.future);
      final pcc = await container.read(applePccStatusProvider.future);

      check(onDevice.availability).equals(PlatformPccAvailability.unsupported);
      check(pcc.availability).equals(PlatformPccAvailability.unsupported);
      check(onDevice.quotaLimitReached).isFalse();
      check(pcc.quotaLimitReached).isFalse();
    });
  });

  test('history policy defaults to sync and persists local-only', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      container.read(directHistoryPolicyProvider),
      DirectHistoryPolicy.syncWithOpenWebUI,
    );
    await container
        .read(directHistoryPolicyProvider.notifier)
        .setPolicy(DirectHistoryPolicy.localOnly);

    expect(
      PreferencesStore.getString(PreferenceKeys.directHistoryPolicy),
      'local-only',
    );
  });

  test('history policy writes are applied in invocation order', () async {
    final firstWrite = Completer<void>();
    final writes = <DirectHistoryPolicy>[];
    final container = ProviderContainer(
      overrides: [
        directHistoryPolicyWriterProvider.overrideWithValue((policy) {
          writes.add(policy);
          return writes.length == 1 ? firstWrite.future : Future.value();
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(directHistoryPolicyProvider.notifier);

    final first = controller.setPolicy(DirectHistoryPolicy.localOnly);
    await Future<void>.delayed(Duration.zero);
    final second = controller.setPolicy(DirectHistoryPolicy.syncWithOpenWebUI);
    await Future<void>.delayed(Duration.zero);

    expect(writes, [DirectHistoryPolicy.localOnly]);
    firstWrite.complete();
    await Future.wait([first, second]);
    expect(writes, [
      DirectHistoryPolicy.localOnly,
      DirectHistoryPolicy.syncWithOpenWebUI,
    ]);
    expect(
      container.read(directHistoryPolicyProvider),
      DirectHistoryPolicy.syncWithOpenWebUI,
    );
  });

  test('context length fallback persists by trusted Direct model id', () async {
    final modelId = DirectModelId.encode('profile', 'model');
    final container = ProviderContainer();
    var containerDisposed = false;
    addTearDown(() {
      if (!containerDisposed) container.dispose();
    });

    await container
        .read(directContextLengthOverridesProvider.notifier)
        .set(modelId, 8192);
    expect(container.read(directContextLengthOverridesProvider)[modelId], 8192);
    container.dispose();
    containerDisposed = true;

    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    expect(restored.read(directContextLengthOverridesProvider)[modelId], 8192);
  });

  test('concurrent context overrides preserve invocation order', () async {
    final firstModelId = DirectModelId.encode('profile', 'first');
    final secondModelId = DirectModelId.encode('profile', 'second');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(
      directContextLengthOverridesProvider.notifier,
    );

    await Future.wait([
      controller.set(firstModelId, 4096),
      controller.set(secondModelId, 8192),
    ]);

    expect(container.read(directContextLengthOverridesProvider), {
      firstModelId: 4096,
      secondModelId: 8192,
    });
  });

  test('concurrent Apple preferences apply the latest invocation', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(appleOnDeviceEnabledProvider.notifier);

    await Future.wait([
      controller.setEnabled(true),
      controller.setEnabled(false),
    ]);

    expect(container.read(appleOnDeviceEnabledProvider), isFalse);
    expect(
      PreferencesStore.getBool(PreferenceKeys.appleOnDeviceEnabled),
      isFalse,
    );
  });

  test('Apple profiles are enabled by default on supported iOS', () async {
    final container = ProviderContainer(
      overrides: [applePccPlatformSupportedProvider.overrideWithValue(true)],
    );
    addTearDown(container.dispose);

    await container.read(directConnectionProfilesProvider.future);
    final profiles = container
        .read(effectiveDirectConnectionProfilesProvider)
        .requireValue;

    expect(profiles.map((profile) => profile.id), {
      kAppleOnDeviceProfileId,
      kApplePccProfileId,
    });
  });

  test('enabled PCC is exposed as a built-in Direct profile on iOS', () async {
    await PreferencesStore.put(PreferenceKeys.appleOnDeviceEnabled, false);
    await PreferencesStore.put(PreferenceKeys.applePccEnabled, true);
    final container = ProviderContainer(
      overrides: [applePccPlatformSupportedProvider.overrideWithValue(true)],
    );
    addTearDown(container.dispose);

    await container.read(directConnectionProfilesProvider.future);
    final profiles = container
        .read(effectiveDirectConnectionProfilesProvider)
        .requireValue;

    expect(profiles, hasLength(1));
    expect(profiles.single.isApplePrivateCloudCompute, isTrue);
  });

  test('enabled Apple profiles stay hidden on unsupported platforms', () async {
    await PreferencesStore.put(PreferenceKeys.appleOnDeviceEnabled, true);
    await PreferencesStore.put(PreferenceKeys.applePccEnabled, true);
    final container = ProviderContainer(
      overrides: [applePccPlatformSupportedProvider.overrideWithValue(false)],
    );
    addTearDown(container.dispose);

    await container.read(directConnectionProfilesProvider.future);
    final profiles = container
        .read(effectiveDirectConnectionProfilesProvider)
        .requireValue;

    expect(profiles, isEmpty);
  });

  test(
    'enabled Apple On-Device is exposed as a built-in Direct profile',
    () async {
      await PreferencesStore.put(PreferenceKeys.appleOnDeviceEnabled, true);
      await PreferencesStore.put(PreferenceKeys.applePccEnabled, false);
      final container = ProviderContainer(
        overrides: [applePccPlatformSupportedProvider.overrideWithValue(true)],
      );
      addTearDown(container.dispose);

      await container.read(directConnectionProfilesProvider.future);
      final profiles = container
          .read(effectiveDirectConnectionProfilesProvider)
          .requireValue;

      expect(profiles, hasLength(1));
      expect(profiles.single.isAppleOnDevice, isTrue);
    },
  );

  test('manual models bypass discovery network calls', () async {
    final adapter = _QueuedAdapter();
    final profile = _profile(
      manualModelIds: const ['manual-one', 'manual-two'],
    );
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        profile,
      ]).encode(),
    });
    final container = _container(adapter);
    addTearDown(container.dispose);

    final discovery = await container.read(directModelDiscoveryProvider.future);

    expect(adapter.listCalls, 0);
    expect(discovery.models, hasLength(2));
    expect(discovery.models.every((model) => model.isMultimodal), isTrue);
  });

  test('failed refresh retains same-profile cached models', () async {
    final adapter = _QueuedAdapter()
      ..responses.add([DirectRemoteModel(id: 'first')])
      ..errors.add(const DirectProviderException('offline'));
    final profile = _profile();
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        profile,
      ]).encode(),
    });
    final container = _container(adapter);
    addTearDown(container.dispose);

    final first = await container.read(directModelDiscoveryProvider.future);
    expect(first.models.single.name, 'first');

    await container.read(directModelDiscoveryProvider.notifier).refresh();
    final refreshed = container.read(directModelDiscoveryProvider).requireValue;

    expect(adapter.listCalls, 2);
    expect(refreshed.models.single.name, 'first');
    expect(refreshed.errorsByProfile['profile-one'], 'offline');
  });

  test('persisted models publish before restart discovery completes', () async {
    String? persisted;
    final cacheStore = DirectModelCacheStore(
      read: () async => persisted,
      write: (value) async => persisted = value,
      delete: () async => persisted = null,
    );
    final profile = _profile(apiKey: 'restart-secret');
    final manualProfile = _profile(
      id: 'manual-profile',
      name: 'Manual',
      manualModelIds: const ['manual-model'],
    );
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        profile,
        manualProfile,
      ]).encode(),
    });
    final initialAdapter = _QueuedAdapter()
      ..responses.add([
        DirectRemoteModel(
          id: 'cached-model',
          name: 'Cached model',
          isMultimodal: true,
          capabilities: const {
            'context_length': 8192,
            'reasoning': {
              'supported_efforts': ['high', 'minimal'],
              'default_effort': 'minimal',
              'mandatory': false,
            },
          },
        ),
      ]);
    final initialContainer = _container(initialAdapter, cacheStore: cacheStore);
    var initialDisposed = false;
    addTearDown(() {
      if (!initialDisposed) initialContainer.dispose();
    });

    final initial = await initialContainer.read(
      directModelDiscoveryProvider.future,
    );
    expect(
      initial.models.map((model) => model.name),
      containsAll(<String>['Cached model', 'manual-model']),
    );
    await Future.doWhile(() async {
      if (persisted != null) return false;
      await Future<void>.delayed(const Duration(milliseconds: 1));
      return true;
    }).timeout(const Duration(seconds: 5));
    expect(persisted, isNotNull);
    initialContainer.dispose();
    initialDisposed = true;

    final restartAdapter = _BlockingDiscoveryAdapter();
    final restartedContainer = _container(
      restartAdapter,
      cacheStore: cacheStore,
    );
    addTearDown(restartedContainer.dispose);

    final restored = await restartedContainer
        .read(directModelDiscoveryProvider.future)
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () =>
              throw StateError('Persisted startup models did not publish.'),
        );
    expect(
      restored.models.map((model) => model.name),
      containsAll(<String>['Cached model', 'manual-model']),
    );
    final restoredCached = restored.models.firstWhere(
      (model) => model.name == 'Cached model',
    );
    expect(restoredCached.isMultimodal, isTrue);
    expect(restoredCached.capabilities?['context_length'], 8192);
    check(restoredCached.capabilities?['reasoning']).isA<Map>().deepEquals({
      'supported_efforts': ['high', 'minimal'],
      'default_effort': 'minimal',
      'mandatory': false,
    });
    expect(restored.isRefreshing, isTrue);

    await restartAdapter.started.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw StateError('Restart discovery did not begin.'),
    );
    restartAdapter.release.complete([
      DirectRemoteModel(id: 'fresh-model', name: 'Fresh model'),
    ]);
    await Future.doWhile(() async {
      final state = restartedContainer.read(directModelDiscoveryProvider).value;
      if (state != null &&
          !state.isRefreshing &&
          state.models.any((model) => model.name == 'Fresh model') &&
          state.models.any((model) => model.name == 'manual-model')) {
        return false;
      }
      await Future<void>.delayed(Duration.zero);
      return true;
    }).timeout(
      const Duration(seconds: 5),
      onTimeout: () =>
          throw StateError('Fresh and manual models did not settle together.'),
    );

    expect(restartAdapter.listCalls, 1);
    expect(
      restartedContainer
          .read(directModelDiscoveryProvider)
          .requireValue
          .models
          .map((model) => model.name),
      containsAll(<String>['Fresh model', 'manual-model']),
    );
  });

  test('Ollama lifecycle refresh preserves a concurrent busy model', () async {
    final adapter = _GatedLifecycleAdapter();
    final profile = _profile(
      adapterKey: kOllamaAdapterKey,
      baseUrl: 'http://localhost:11434',
    );
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        profile,
      ]).encode(),
    });
    final container = _container(adapter);
    addTearDown(container.dispose);
    final subscription = container.listen(
      ollamaModelLifecycleProvider(profile.id),
      (_, _) {},
    );
    addTearDown(subscription.close);

    await container.read(ollamaModelLifecycleProvider(profile.id).future);
    final controller = container.read(
      ollamaModelLifecycleProvider(profile.id).notifier,
    );
    final refresh = controller.refresh();
    await adapter.refreshStarted.future;

    final load = controller.loadModel('model-one');
    await adapter.loadStarted.future;
    expect(
      container
          .read(ollamaModelLifecycleProvider(profile.id))
          .requireValue
          .isBusy('model-one'),
      isTrue,
    );

    adapter.refreshResult.complete(const {'stale-model'});
    await refresh;
    final refreshing = container
        .read(ollamaModelLifecycleProvider(profile.id))
        .requireValue;
    expect(refreshing.isBusy('model-one'), isTrue);
    expect(refreshing.isLoaded('stale-model'), isFalse);

    adapter.releaseLoad.complete();
    await load;
    final settled = container
        .read(ollamaModelLifecycleProvider(profile.id))
        .requireValue;
    expect(settled.isBusy('model-one'), isFalse);
    expect(settled.isLoaded('model-one'), isTrue);
  });

  test(
    'Ollama lifecycle applies the last completed running-model snapshot',
    () async {
      final adapter = _OverlappingLifecycleAdapter();
      final profile = _profile(
        adapterKey: kOllamaAdapterKey,
        baseUrl: 'http://localhost:11434',
      );
      FlutterSecureStorage.setMockInitialValues({
        'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
          profile,
        ]).encode(),
      });
      final container = _container(adapter);
      addTearDown(container.dispose);
      final subscription = container.listen(
        ollamaModelLifecycleProvider(profile.id),
        (_, _) {},
      );
      addTearDown(subscription.close);

      await container.read(ollamaModelLifecycleProvider(profile.id).future);
      final controller = container.read(
        ollamaModelLifecycleProvider(profile.id).notifier,
      );
      final first = controller.loadModel('model-one');
      await adapter.firstMutationListStarted.future;

      await controller.loadModel('model-two');
      expect(
        container
            .read(ollamaModelLifecycleProvider(profile.id))
            .requireValue
            .loadedModelIds,
        {'model-two'},
      );

      adapter.firstMutationListResult.complete({'model-one', 'model-two'});
      await first;

      expect(
        container
            .read(ollamaModelLifecycleProvider(profile.id))
            .requireValue
            .loadedModelIds,
        {'model-one', 'model-two'},
      );
    },
  );

  test('probe sanitizes messages returned by runtime adapters', () async {
    const apiKey = '  probe-api-secret  ';
    const headerValue = '  probe-header-secret  ';
    final profile = _profile(
      apiKey: apiKey,
      customHeaders: const {'X-Private': headerValue},
    );
    final unsafeMessage =
        'Connection rejected: raw=<$apiKey> trimmed=${apiKey.trim()} '
        'header=<$headerValue> header-trimmed=${headerValue.trim()}\u0000\u001b '
        '${List.filled(700, 'x').join()}';
    final adapter = _UnsafeMessageAdapter(
      probeResult: DirectConnectionProbe(
        reachable: false,
        modelCount: 17,
        message: unsafeMessage,
      ),
    );
    final container = _container(adapter);
    addTearDown(container.dispose);

    final result = await container
        .read(directConnectionProfilesProvider.notifier)
        .probe(profile);

    expect(result.reachable, isFalse);
    expect(result.modelCount, 17);
    expect(result.message, contains('Connection rejected'));
    expect(result.message, contains('[REDACTED]'));
    expect(result.message, isNot(contains(apiKey)));
    expect(result.message, isNot(contains(apiKey.trim())));
    expect(result.message, isNot(contains(headerValue)));
    expect(result.message, isNot(contains(headerValue.trim())));
    expect(result.message, isNot(contains('\u0000')));
    expect(result.message, isNot(contains('\u001b')));
    expect(result.message!.runes.length, lessThanOrEqualTo(512));
  });

  test('discovery sanitizes errors thrown by runtime adapters', () async {
    const apiKey = '  discovery-api-secret  ';
    const headerValue = '  discovery-header-secret  ';
    const cookieToken = 'discovery-cookie-component-secret';
    const authorizationToken = 'discovery-authorization-component-secret';
    final profile = _profile(
      apiKey: apiKey,
      customHeaders: const {
        'X-Private': headerValue,
        'Cookie': 'session=$cookieToken',
        'X-Authorization-Context': 'Bearer $authorizationToken',
      },
    );
    final unsafeMessage =
        'Discovery rejected: raw=<$apiKey> trimmed=${apiKey.trim()} '
        'header=<$headerValue> header-trimmed=${headerValue.trim()} '
        'cookie=$cookieToken authorization=$authorizationToken\u0000\u007f '
        '${List.filled(700, 'y').join()}';
    final adapter = _UnsafeMessageAdapter(
      discoveryError: DirectProviderException(unsafeMessage),
    );
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        profile,
      ]).encode(),
    });
    final container = _container(adapter);
    addTearDown(container.dispose);

    final discovery = await container.read(directModelDiscoveryProvider.future);
    final message = discovery.errorsByProfile[profile.id];

    expect(message, contains('Discovery rejected'));
    expect(message, contains('[REDACTED]'));
    expect(message, isNot(contains(apiKey)));
    expect(message, isNot(contains(apiKey.trim())));
    expect(message, isNot(contains(headerValue)));
    expect(message, isNot(contains(headerValue.trim())));
    expect(message, isNot(contains(cookieToken)));
    expect(message, isNot(contains(authorizationToken)));
    expect(message, isNot(contains('\u0000')));
    expect(message, isNot(contains('\u007f')));
    expect(message!.runes.length, lessThanOrEqualTo(512));
  });

  test('probe sanitizes thrown runtime-adapter mTLS credentials', () async {
    const privatePassword = 'mtls-private-password-secret';
    const privateKey =
        '-----BEGIN PRIVATE KEY-----\nPRIVATE_KEY_SECRET\n-----END PRIVATE KEY-----';
    final profile = DirectConnectionProfile(
      id: 'mtls-profile',
      name: 'mTLS',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://example.test/v1',
      mtlsCertificateChainPem:
          '-----BEGIN CERTIFICATE-----\nCERT\n-----END CERTIFICATE-----',
      mtlsPrivateKeyPem: privateKey,
      mtlsPrivateKeyPassword: privatePassword,
    );
    final adapter = _UnsafeMessageAdapter(
      probeError: const DirectProviderException(
        'Probe reflected $privatePassword and PRIVATE_KEY_SECRET',
      ),
    );
    final container = _container(adapter);
    addTearDown(container.dispose);

    final result = await container
        .read(directConnectionProfilesProvider.notifier)
        .probe(profile);

    expect(result.reachable, isFalse);
    expect(result.message, contains('[REDACTED]'));
    expect(result.message, isNot(contains(privatePassword)));
    expect(result.message, isNot(contains('PRIVATE_KEY_SECRET')));
  });

  test(
    'unconfirmed profile origin edit is persisted without old credentials',
    () async {
      final old = _profile(apiKey: 'old-secret');
      FlutterSecureStorage.setMockInitialValues({
        'direct_connection_profiles_v1': DirectConnectionProfilesDocument([old])
            .encode(),
      });
      final container = _container(_QueuedAdapter());
      addTearDown(container.dispose);
      await container.read(directConnectionProfilesProvider.future);

      await container
          .read(directConnectionProfilesProvider.notifier)
          .upsert(old.copyWith(baseUrl: 'https://other.test/v1'));

      final saved = container
          .read(directConnectionProfilesProvider)
          .requireValue
          .single;
      expect(saved.baseUrl, 'https://other.test/v1');
      expect(saved.apiKey, isNull);
    },
  );

  test('profile updates and removal retire retained HTTP clients', () async {
    final original = _profile(apiKey: 'old-secret');
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        original,
      ]).encode(),
    });
    final container = _container(_QueuedAdapter());
    addTearDown(container.dispose);
    await container.read(directConnectionProfilesProvider.future);
    final controller = container.read(
      directConnectionProfilesProvider.notifier,
    );
    final pool = container.read(directHttpClientPoolProvider);

    final originalLease = pool.acquire(original);
    final originalDio = originalLease.dio;
    originalLease.release();

    await controller.upsert(original.copyWith(apiKey: 'new-secret'));

    final staleLease = pool.acquire(original);
    expect(staleLease.dio, isNot(same(originalDio)));
    staleLease.release();

    final updated = container
        .read(directConnectionProfilesProvider)
        .requireValue
        .single;
    final updatedLease = pool.acquire(updated);
    final updatedDio = updatedLease.dio;
    updatedLease.release();

    await controller.remove(updated.id);

    final removedSnapshotLease = pool.acquire(updated);
    expect(removedSnapshotLease.dio, isNot(same(updatedDio)));
    removedSnapshotLease.release();
  });

  test('setEnabled observes earlier queued profile edits', () async {
    final original = _profile();
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        original,
      ]).encode(),
    });
    final container = _container(_QueuedAdapter());
    addTearDown(container.dispose);
    await container.read(directConnectionProfilesProvider.future);
    final controller = container.read(
      directConnectionProfilesProvider.notifier,
    );

    final rename = controller.upsert(original.copyWith(name: 'Renamed'));
    final disable = controller.setEnabled(original.id, false);
    await Future.wait([rename, disable]);

    final saved = container
        .read(directConnectionProfilesProvider)
        .requireValue
        .single;
    expect(saved.name, 'Renamed');
    expect(saved.enabled, isFalse);
  });

  test('stale expected profile cannot overwrite a newer edit', () async {
    final original = _profile(apiKey: 'original-secret');
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        original,
      ]).encode(),
    });
    final container = _container(_QueuedAdapter());
    addTearDown(container.dispose);
    await container.read(directConnectionProfilesProvider.future);
    final controller = container.read(
      directConnectionProfilesProvider.notifier,
    );

    await controller.upsert(
      original.copyWith(name: 'Concurrent', apiKey: 'concurrent-secret'),
    );

    await expectLater(
      controller.upsert(
        original.copyWith(name: 'Stale rename'),
        expectedPrevious: original,
      ),
      throwsA(isA<DirectConnectionProfileConflictException>()),
    );

    final saved = container
        .read(directConnectionProfilesProvider)
        .requireValue
        .single;
    expect(saved.name, 'Concurrent');
    expect(saved.apiKey, 'concurrent-secret');
    final durable = await _loadDurableProfiles();
    expect(durable.single.name, 'Concurrent');
    expect(durable.single.apiKey, 'concurrent-secret');
  });

  test('durable expected profile check rejects a stale controller', () async {
    final original = _profile(apiKey: 'original-secret');
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        original,
      ]).encode(),
    });
    final container = _container(_QueuedAdapter());
    addTearDown(container.dispose);
    await container.read(directConnectionProfilesProvider.future);
    final controller = container.read(
      directConnectionProfilesProvider.notifier,
    );
    final store = container.read(directConnectionProfileStoreProvider);
    final modelRegistry = container.read(directModelRegistryProvider);
    final staleModel = modelRegistry.replaceProfileModels(original, [
      DirectRemoteModel(id: 'stale-model'),
    ]).single;
    expect(modelRegistry.resolve(staleModel), isNotNull);
    final concurrent = original.copyWith(
      name: 'Concurrent',
      apiKey: 'concurrent-secret',
    );
    final unrelated = _profile(
      id: 'profile-two',
      name: 'Unrelated',
      apiKey: 'unrelated-secret',
    );
    await store.save([concurrent, unrelated]);

    await expectLater(
      controller.upsert(
        original.copyWith(name: 'Stale rename'),
        expectedPrevious: original,
      ),
      throwsA(isA<DirectConnectionProfileConflictException>()),
    );

    final published = container
        .read(directConnectionProfilesProvider)
        .requireValue;
    expect(published, hasLength(2));
    expect(
      published.singleWhere((profile) => profile.id == original.id).name,
      'Concurrent',
    );
    expect(
      published.singleWhere((profile) => profile.id == original.id).apiKey,
      'concurrent-secret',
    );
    expect(
      published.singleWhere((profile) => profile.id == unrelated.id).apiKey,
      'unrelated-secret',
    );
    expect(modelRegistry.resolve(staleModel), isNull);

    final durable = await store.load();
    expect(durable, hasLength(2));
    expect(
      durable.singleWhere((profile) => profile.id == original.id).name,
      'Concurrent',
    );
    expect(
      durable.singleWhere((profile) => profile.id == original.id).apiKey,
      'concurrent-secret',
    );
    expect(
      durable.singleWhere((profile) => profile.id == unrelated.id).apiKey,
      'unrelated-secret',
    );
  });

  test(
    'a conflict completing after disposal preserves its original result',
    () async {
      final original = _profile(apiKey: 'original-secret');
      final winner = original.copyWith(
        name: 'Durable winner',
        apiKey: 'winner-secret',
      );
      final storage = _DisposeConflictSecureStorage(
        initialDocument: DirectConnectionProfilesDocument([original]).encode(),
        conflictDocument: DirectConnectionProfilesDocument([winner]).encode(),
      );
      final store = DirectConnectionProfileStore(
        SecureCredentialStorage(instance: storage),
      );
      final container = ProviderContainer(
        overrides: [
          directConnectionProfileStoreProvider.overrideWithValue(store),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([_QueuedAdapter()]),
          ),
        ],
      );
      var disposed = false;
      try {
        await container.read(directConnectionProfilesProvider.future);
        final controller = container.read(
          directConnectionProfilesProvider.notifier,
        );

        final mutation = controller.upsert(
          original.copyWith(name: 'Stale edit'),
          expectedPrevious: original,
        );
        await storage.conflictReadStarted.future.timeout(
          const Duration(seconds: 1),
        );
        container.dispose();
        disposed = true;
        storage.releaseConflictRead.complete();

        await expectLater(
          mutation.timeout(const Duration(seconds: 1)),
          throwsA(isA<DirectConnectionProfileConflictException>()),
        );
      } finally {
        if (!storage.releaseConflictRead.isCompleted) {
          storage.releaseConflictRead.complete();
        }
        if (!disposed) container.dispose();
      }
    },
  );

  test('atomic profile edit preserves unrelated durable profiles', () async {
    final original = _profile(apiKey: 'original-secret');
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        original,
      ]).encode(),
    });
    final container = _container(_QueuedAdapter());
    addTearDown(container.dispose);
    await container.read(directConnectionProfilesProvider.future);
    final controller = container.read(
      directConnectionProfilesProvider.notifier,
    );
    final store = container.read(directConnectionProfileStoreProvider);
    final unrelated = _profile(
      id: 'profile-two',
      name: 'Unrelated',
      apiKey: 'unrelated-secret',
    );
    await store.save([original, unrelated]);

    await controller.upsert(
      original.copyWith(name: 'Renamed'),
      expectedPrevious: original,
    );

    final durable = await store.load();
    expect(durable, hasLength(2));
    expect(
      durable.singleWhere((profile) => profile.id == original.id).name,
      'Renamed',
    );
    expect(
      durable.singleWhere((profile) => profile.id == original.id).apiKey,
      'original-secret',
    );
    expect(
      durable.singleWhere((profile) => profile.id == unrelated.id).apiKey,
      'unrelated-secret',
    );
  });

  test('reload is serialized with profile mutations', () async {
    final original = _profile();
    final storage = _ReloadGateSecureStorage(
      DirectConnectionProfilesDocument([original]).encode(),
    );
    final store = DirectConnectionProfileStore(
      SecureCredentialStorage(instance: storage),
    );
    final container = ProviderContainer(
      overrides: [
        directConnectionProfileStoreProvider.overrideWithValue(store),
        directProviderAdapterRegistryProvider.overrideWithValue(
          DirectProviderAdapterRegistry([_QueuedAdapter()]),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(directConnectionProfilesProvider.future);
    final controller = container.read(
      directConnectionProfilesProvider.notifier,
    );

    final reload = controller.reload();
    await storage.reloadReadStarted.future;
    final rename = controller.upsert(original.copyWith(name: 'Renamed'));

    // Let all queued microtasks drain. A mutation that bypasses reload would
    // have started another secure-storage read while the captured reload is
    // still blocked.
    await Future<void>.delayed(Duration.zero);
    expect(storage.profileReadCalls, 2);

    storage.allowReloadRead.complete();
    await Future.wait([reload, rename]);

    expect(
      container.read(directConnectionProfilesProvider).requireValue.single.name,
      'Renamed',
    );
    expect((await store.load()).single.name, 'Renamed');
  });

  test(
    'failed reload revokes models and runs before publishing its error',
    () async {
      final original = _profile();
      final storage = _FailingReloadSecureStorage(
        DirectConnectionProfilesDocument([original]).encode(),
      );
      final store = DirectConnectionProfileStore(
        SecureCredentialStorage(instance: storage),
      );
      final container = ProviderContainer(
        overrides: [
          directConnectionProfileStoreProvider.overrideWithValue(store),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([_QueuedAdapter()]),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(directConnectionProfilesProvider.future);

      final modelRegistry = container.read(directModelRegistryProvider);
      final staleModel = modelRegistry.replaceProfileModels(original, [
        DirectRemoteModel(id: 'stale-model'),
      ]).single;
      final cancellation = _registerPendingRun(
        container.read(directRunRegistryProvider),
        profileId: original.id,
      );
      var authorityRevokedWhenErrorPublished = false;
      final subscription = container.listen(directConnectionProfilesProvider, (
        _,
        next,
      ) {
        if (next.hasError) {
          authorityRevokedWhenErrorPublished =
              modelRegistry.resolve(staleModel) == null &&
              cancellation.token.isCancelled;
        }
      });
      addTearDown(subscription.close);

      await container.read(directConnectionProfilesProvider.notifier).reload();

      expect(container.read(directConnectionProfilesProvider).hasError, isTrue);
      expect(authorityRevokedWhenErrorPublished, isTrue);
      expect(modelRegistry.resolveRegisteredId(staleModel.id), isNull);
      expect(cancellation.token.isCancelled, isTrue);
      cancellation.done.complete();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'transport edit and queued mutation settle while run cleanup never does',
    () async {
      final original = _profile();
      FlutterSecureStorage.setMockInitialValues({
        'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
          original,
        ]).encode(),
      });
      final container = _container(_QueuedAdapter());
      addTearDown(container.dispose);
      await container.read(directConnectionProfilesProvider.future);

      final modelRegistry = container.read(directModelRegistryProvider);
      final staleModel = modelRegistry.replaceProfileModels(original, [
        DirectRemoteModel(id: 'stale-model'),
      ]).single;
      final cancellation = _registerPendingRun(
        container.read(directRunRegistryProvider),
        profileId: original.id,
      );
      final controller = container.read(
        directConnectionProfilesProvider.notifier,
      );

      final mutation = controller.upsert(
        original.copyWith(baseUrl: 'https://new.example.test/v1'),
      );
      await cancellation.token.whenCancel.timeout(const Duration(seconds: 5));

      expect(
        container
            .read(directConnectionProfilesProvider)
            .requireValue
            .single
            .baseUrl,
        'https://new.example.test/v1',
      );
      expect(modelRegistry.resolve(staleModel), isNull);
      expect(modelRegistry.resolveRegisteredId(staleModel.id), isNull);

      await mutation.timeout(const Duration(seconds: 1));

      await controller
          .setEnabled(original.id, false)
          .timeout(const Duration(seconds: 1));
      final durable = await _loadDurableProfiles();
      expect(durable.single.baseUrl, 'https://new.example.test/v1');
      expect(durable.single.enabled, isFalse);

      cancellation.done.completeError(StateError('cancel failed'));
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('remove cannot resurrect a profile when cancellation fails', () async {
    final original = _profile();
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        original,
      ]).encode(),
    });
    final container = _container(_QueuedAdapter());
    addTearDown(container.dispose);
    await container.read(directConnectionProfilesProvider.future);
    final controller = container.read(
      directConnectionProfilesProvider.notifier,
    );
    final cancellation = _registerPendingRun(
      container.read(directRunRegistryProvider),
      profileId: original.id,
    );

    final removal = controller.remove(original.id);
    await cancellation.token.whenCancel.timeout(const Duration(seconds: 5));
    expect(
      container.read(directConnectionProfilesProvider).requireValue,
      isEmpty,
    );

    await removal.timeout(const Duration(seconds: 1));

    final replacement = _profile(id: 'profile-two', name: 'Replacement');
    await controller.upsert(replacement).timeout(const Duration(seconds: 1));
    final durable = await _loadDurableProfiles();
    expect(durable.map((profile) => profile.id), ['profile-two']);

    cancellation.done.completeError(StateError('cancel failed'));
    await Future<void>.delayed(Duration.zero);
  });

  test('clear cannot resurrect profiles when cancellation fails', () async {
    final original = _profile();
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        original,
      ]).encode(),
    });
    final container = _container(_QueuedAdapter());
    addTearDown(container.dispose);
    await container.read(directConnectionProfilesProvider.future);
    final controller = container.read(
      directConnectionProfilesProvider.notifier,
    );
    final cancellation = _registerPendingRun(
      container.read(directRunRegistryProvider),
      profileId: original.id,
    );

    final clear = controller.clear();
    await cancellation.token.whenCancel.timeout(const Duration(seconds: 5));
    expect(
      container.read(directConnectionProfilesProvider).requireValue,
      isEmpty,
    );

    await clear.timeout(const Duration(seconds: 1));

    final replacement = _profile(id: 'profile-two', name: 'Replacement');
    await controller.upsert(replacement).timeout(const Duration(seconds: 1));
    final durable = await _loadDurableProfiles();
    expect(durable.map((profile) => profile.id), ['profile-two']);

    cancellation.done.completeError(StateError('cancel failed'));
    await Future<void>.delayed(Duration.zero);
  });

  test('an older discovery cannot overwrite a newer refresh', () async {
    final adapter = _OverlappingAdapter();
    final profile = _profile();
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        profile,
      ]).encode(),
    });
    final container = _container(adapter);
    addTearDown(container.dispose);
    final subscription = container.listen(
      directModelDiscoveryProvider,
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    final initial = container.read(directModelDiscoveryProvider.future);
    await Future.doWhile(() async {
      if (adapter.listCalls > 0) return false;
      await Future<void>.delayed(Duration.zero);
      return true;
    }).timeout(const Duration(seconds: 5));

    await container.read(directModelDiscoveryProvider.notifier).refresh();
    expect(
      container
          .read(directModelDiscoveryProvider)
          .requireValue
          .models
          .single
          .name,
      'new-model',
    );

    adapter.first.complete([DirectRemoteModel(id: 'stale-model')]);
    await initial;
    await Future<void>.delayed(Duration.zero);

    final state = container.read(directModelDiscoveryProvider).requireValue;
    expect(state.models.single.name, 'new-model');
    expect(
      container
          .read(directModelRegistryProvider)
          .resolveRegisteredId(
            DirectModelId.encode('profile-one', 'stale-model'),
          ),
      isNull,
    );
  });

  test('profile discovery globally caps concurrent adapter calls', () async {
    final adapter = _ConcurrencyAdapter();
    final profiles = [
      for (var index = 0; index < 10; index++)
        _profile(id: 'profile-$index', name: 'Profile $index'),
    ];
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument(
        profiles,
      ).encode(),
    });
    final container = _container(adapter);
    addTearDown(container.dispose);

    final discovery = container.read(directModelDiscoveryProvider.future);
    await adapter.firstWaveStarted.future.timeout(const Duration(seconds: 5));

    expect(adapter.listCalls, 4);
    expect(adapter.maxActive, 4);

    adapter.release.complete();
    final result = await discovery.timeout(const Duration(seconds: 5));

    expect(adapter.listCalls, 10);
    expect(adapter.maxActive, 4);
    expect(result.models, hasLength(10));
  });

  test(
    'superseded Ollama discovery stops launching stale enrichment',
    () async {
      final http = _SupersededOllamaHttpAdapter();
      final adapter = OllamaAdapter(
        dioFactory: (_) => _dio(http),
        closeClients: false,
      );
      final profile = _profile(
        adapterKey: kOllamaAdapterKey,
        baseUrl: 'http://localhost:11434',
      );
      FlutterSecureStorage.setMockInitialValues({
        'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
          profile,
        ]).encode(),
      });
      final container = _container(adapter);
      addTearDown(() {
        container.dispose();
        adapter.dispose();
      });

      final initial = container.read(directModelDiscoveryProvider.future);
      await http.oldWaveStarted.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError(
          'Initial Ollama enrichment did not start '
          '(tags=${http.tagsRequests}, shows=${http.oldShowRequests}).',
        ),
      );

      final controller = container.read(directModelDiscoveryProvider.notifier);
      final firstRefresh = controller.refresh();
      final coalescedRefresh = controller.refresh();
      expect(identical(firstRefresh, coalescedRefresh), isTrue);
      await firstRefresh.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError(
          'Superseding refresh did not settle '
          '(tags=${http.tagsRequests}, old=${http.oldShowRequests}, '
          'new=${http.newShowRequests}).',
        ),
      );

      final result = container.read(directModelDiscoveryProvider).requireValue;
      expect(http.tagsRequests, 2);
      expect(result.models.map((item) => item.name), ['new-model']);

      http.releaseOldShows.complete();
      await initial.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError('Initial discovery did not settle.'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        http.oldShowRequests,
        4,
        reason: 'cancelled workers must not reserve more stale models',
      );
      expect(http.newShowRequests, 1);
    },
  );

  for (final disableProfile in [false, true]) {
    test(
      '${disableProfile ? 'disabled' : 'removed'} profile models disappear while other profiles rediscover',
      () async {
        final removed = _profile(id: 'profile-one', name: 'Removed');
        final retained = _profile(id: 'profile-two', name: 'Retained');
        final adapter = _RediscoveryGateAdapter();
        FlutterSecureStorage.setMockInitialValues({
          'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
            removed,
            retained,
          ]).encode(),
        });
        final container = _container(adapter);
        addTearDown(container.dispose);
        final discoverySubscription = container.listen(
          directModelDiscoveryProvider,
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(discoverySubscription.close);

        final initial = await container.read(
          directModelDiscoveryProvider.future,
        );
        expect(initial.models, hasLength(2));
        adapter.blockProfile(retained.id);

        final profilesController = container.read(
          directConnectionProfilesProvider.notifier,
        );
        if (disableProfile) {
          await profilesController.setEnabled(removed.id, false);
        } else {
          await profilesController.remove(removed.id);
        }
        await adapter.rediscoveryStarted.future.timeout(
          const Duration(seconds: 5),
        );

        final interim = container.read(directModelDiscoveryProvider).value;
        expect(interim, isNotNull);
        expect(interim!.models.map((item) => item.metadata?['profileId']), [
          retained.id,
        ]);
        expect(interim.isRefreshing, isTrue);
        expect(
          container
              .read(directModelRegistryProvider)
              .resolveRegisteredId(
                DirectModelId.encode(removed.id, 'model-${removed.id}'),
              ),
          isNull,
        );

        adapter.finishRediscovery();
        final settled = await container.read(
          directModelDiscoveryProvider.future,
        );
        expect(settled.models.map((item) => item.metadata?['profileId']), [
          retained.id,
        ]);
      },
    );
  }

  test(
    'disposing during discovery does not read disposed notifier state',
    () async {
      final adapter = _OverlappingAdapter();
      final profile = _profile();
      FlutterSecureStorage.setMockInitialValues({
        'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
          profile,
        ]).encode(),
      });
      final container = _container(adapter);
      final discovery = container.read(directModelDiscoveryProvider.future);
      await Future.doWhile(() async {
        if (adapter.listCalls > 0) return false;
        await Future<void>.delayed(Duration.zero);
        return true;
      }).timeout(const Duration(seconds: 5));

      container.dispose();
      adapter.first.complete([DirectRemoteModel(id: 'late-model')]);

      await expectLater(discovery, completes);
    },
  );

  test(
    'disposing while discovery awaits profiles does not publish stale state',
    () async {
      final profiles = Completer<List<DirectConnectionProfile>>();
      final container = ProviderContainer(
        overrides: [
          directConnectionProfilesProvider.overrideWith(
            () => _GatedProfilesController(profiles.future),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([_QueuedAdapter()]),
          ),
        ],
      );
      final discovery = container.read(directModelDiscoveryProvider.future);
      await Future<void>.delayed(Duration.zero);

      container.dispose();
      profiles.complete([_profile()]);

      await expectLater(discovery, completes);
    },
  );

  test(
    'discovery recovers when profile storage recovers from an error',
    () async {
      final adapter = _QueuedAdapter()
        ..responses.add([DirectRemoteModel(id: 'recovered-model')]);
      late _RecoveringProfilesController profilesController;
      final container = ProviderContainer(
        overrides: [
          directConnectionProfilesProvider.overrideWith(
            () => profilesController = _RecoveringProfilesController(),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([adapter]),
          ),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        directModelDiscoveryProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await expectLater(
        container.read(directModelDiscoveryProvider.future),
        throwsStateError,
      );
      expect(container.read(directConnectionProfilesProvider).hasError, isTrue);

      profilesController.recover([_profile()]);
      expect(
        container.read(directConnectionProfilesProvider).requireValue,
        hasLength(1),
      );
      expect(
        container.read(effectiveDirectConnectionProfilesProvider).requireValue,
        hasLength(1),
      );

      await Future.doWhile(() async {
        if (container.read(directModelDiscoveryProvider).hasValue) return false;
        await Future<void>.delayed(Duration.zero);
        return true;
      }).timeout(const Duration(seconds: 5));
      final recovered = container
          .read(directModelDiscoveryProvider)
          .requireValue;
      expect(recovered.models.map((item) => item.name), ['recovered-model']);
    },
  );

  test(
    'app-data clear barrier rejects and can resume profile writes',
    () async {
      final container = _container(_QueuedAdapter());
      addTearDown(container.dispose);
      final controller = container.read(
        directConnectionProfilesProvider.notifier,
      );
      await container.read(directConnectionProfilesProvider.future);

      await controller.blockMutationsForAppDataClear();
      await expectLater(controller.upsert(_profile()), throwsStateError);
      final blockedProbe = await controller.probe(_profile());
      check(blockedProbe.reachable).isFalse();
      check(blockedProbe.message).isNotNull().contains('app data');

      controller.resumeMutationsAfterAppDataClearAbort();
      await controller.upsert(_profile());
      expect(
        container.read(directConnectionProfilesProvider).requireValue,
        hasLength(1),
      );
    },
  );

  test('provider rebuild cannot lower an in-memory clear barrier', () async {
    final container = _container(_QueuedAdapter());
    addTearDown(container.dispose);
    final controller = container.read(
      directConnectionProfilesProvider.notifier,
    );
    await container.read(directConnectionProfilesProvider.future);
    await controller.upsert(_profile());

    await controller.blockMutationsForAppDataClear();
    final fence = container.read(incompleteLogoutFenceProvider.notifier);
    fence.setSuppressed(true);
    await container.read(directConnectionProfilesProvider.future);
    fence.setSuppressed(false);
    await container.read(directConnectionProfilesProvider.future);

    expect(
      container.read(directConnectionProfilesProvider).requireValue,
      hasLength(1),
    );
    await expectLater(controller.upsert(_profile()), throwsStateError);
    controller.resumeMutationsAfterAppDataClearAbort();
    await controller.setEnabled('profile-one', false);
  });

  test(
    'clear abort restores the result of an admitted profile write',
    () async {
      final original = _profile();
      final storage = _WriteGateSecureStorage(
        DirectConnectionProfilesDocument([original]).encode(),
      );
      final store = DirectConnectionProfileStore(
        SecureCredentialStorage(instance: storage),
      );
      final container = ProviderContainer(
        overrides: [
          directConnectionProfileStoreProvider.overrideWithValue(store),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([_QueuedAdapter()]),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(directConnectionProfilesProvider.future);
      final controller = container.read(
        directConnectionProfilesProvider.notifier,
      );

      final rename = controller.upsert(original.copyWith(name: 'Renamed'));
      await storage.writeStarted.future;
      final blocked = controller.blockMutationsForAppDataClear();
      storage.allowWrite.complete();
      await Future.wait([rename, blocked]);

      controller.resumeMutationsAfterAppDataClearAbort();
      expect(
        container
            .read(directConnectionProfilesProvider)
            .requireValue
            .single
            .name,
        'Renamed',
      );
    },
  );

  test(
    'clear abort preserves profiles while initial load is pending',
    () async {
      final original = _profile();
      final storage = _InitialReadGateSecureStorage(
        DirectConnectionProfilesDocument([original]).encode(),
      );
      final store = DirectConnectionProfileStore(
        SecureCredentialStorage(instance: storage),
      );
      final container = ProviderContainer(
        overrides: [
          directConnectionProfileStoreProvider.overrideWithValue(store),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([_QueuedAdapter()]),
          ),
        ],
      );
      addTearDown(container.dispose);

      final initialLoad = container.read(
        directConnectionProfilesProvider.future,
      );
      final controller = container.read(
        directConnectionProfilesProvider.notifier,
      );
      await storage.readStarted.future;
      final blocked = controller.blockMutationsForAppDataClear();
      storage.allowRead.complete();
      await Future.wait([initialLoad, blocked]);

      controller.resumeMutationsAfterAppDataClearAbort();
      final restored = container
          .read(directConnectionProfilesProvider)
          .requireValue
          .single;
      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.baseUrl, original.baseUrl);
    },
  );

  test(
    'incomplete logout fence does not hide Direct profiles or block setup',
    () async {
      await PreferencesStore.putChecked(
        PreferenceKeys.incompleteLogoutFence,
        true,
      );
      FlutterSecureStorage.setMockInitialValues({
        'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
          _profile(),
        ]).encode(),
      });
      final adapter = _CountingProbeAdapter();
      final container = _container(adapter);
      addTearDown(container.dispose);
      check(container.read(incompleteLogoutFenceProvider)).isTrue();

      expect(
        await container.read(directConnectionProfilesProvider.future),
        hasLength(1),
      );
      final controller = container.read(
        directConnectionProfilesProvider.notifier,
      );

      final probe = await controller.probe(_profile(id: 'profile-two'));
      check(probe.reachable).isTrue();
      check(adapter.probeCalls).equals(1);

      await controller.upsert(_profile(id: 'profile-two'));
      expect(
        container.read(directConnectionProfilesProvider).requireValue,
        hasLength(2),
      );
    },
  );

  test(
    'incomplete app-data clear hides surviving profiles until the fence lifts',
    () async {
      final adapter = _CountingProbeAdapter();
      final container = _container(adapter);
      addTearDown(container.dispose);
      await container.read(directConnectionProfilesProvider.future);
      final controller = container.read(
        directConnectionProfilesProvider.notifier,
      );
      await controller.upsert(_profile());
      final fence = container.read(incompleteLogoutFenceProvider.notifier);
      fence.setSuppressed(true);

      await controller.blockMutationsForAppDataClear();
      // The coordinator still holds the preference barrier at this point; the
      // marker must land regardless so it survives a restart.
      await PreferencesStore.blockWritesForAppDataClear();
      await controller.revokeRuntimeAfterIncompleteAppDataClear();
      PreferencesStore.resumeWritesAfterAppDataClear();

      expect(
        container.read(directConnectionProfilesProvider).requireValue,
        isEmpty,
      );
      check(PreferencesStore.getBool(PreferenceKeys.incompleteAppDataClear))
          .equals(true);
      final probe = await controller.probe(_profile(id: 'profile-two'));
      check(probe.reachable).isFalse();
      check(adapter.probeCalls).equals(0);
      await expectLater(
        controller.upsert(_profile(id: 'profile-two')),
        throwsStateError,
      );

      // A rebuild while the fence is still up stays blocked.
      container.invalidate(directConnectionProfilesProvider);
      expect(
        await container.read(directConnectionProfilesProvider.future),
        isEmpty,
      );

      // A completed cleanup or a new authenticated session clears the fence
      // and releases the block; the surviving profile is visible again.
      fence.setSuppressed(false);
      expect(
        await container.read(directConnectionProfilesProvider.future),
        hasLength(1),
      );
      await Future<void>.delayed(Duration.zero);
      check(PreferencesStore.getBool(PreferenceKeys.incompleteAppDataClear))
          .isNull();
      await controller.upsert(_profile(id: 'profile-two'));
      expect(
        container.read(directConnectionProfilesProvider).requireValue,
        hasLength(2),
      );
    },
  );

  test(
    'a failed incomplete-clear marker write propagates instead of hiding',
    () async {
      PreferencesStore.debugOverride(
        await FlutterKeyValueStore.load(),
        writeInterceptor: (prefs, key, value) async =>
            key == PreferenceKeys.incompleteAppDataClear ? false : null,
      );
      final container = _container(_CountingProbeAdapter());
      addTearDown(container.dispose);
      await container.read(directConnectionProfilesProvider.future);
      final controller = container.read(
        directConnectionProfilesProvider.notifier,
      );
      await controller.upsert(_profile());
      await controller.blockMutationsForAppDataClear();

      await expectLater(
        controller.revokeRuntimeAfterIncompleteAppDataClear(),
        throwsStateError,
      );
      // The in-memory block still holds for this process.
      expect(
        container.read(directConnectionProfilesProvider).requireValue,
        isEmpty,
      );
      await expectLater(controller.upsert(_profile()), throwsStateError);
    },
  );

  test('probe reports a validation failure instead of throwing', () async {
    final adapter = _CountingProbeAdapter();
    final container = _container(adapter);
    addTearDown(container.dispose);
    await container.read(directConnectionProfilesProvider.future);
    final controller = container.read(
      directConnectionProfilesProvider.notifier,
    );

    final probe = await controller.probe(_profile(name: '   '));
    check(probe.reachable).isFalse();
    check(probe.message).equals('Profile name is required.');
    check(adapter.probeCalls).equals(0);
  });

  test('probe reports a missing adapter instead of throwing', () async {
    final container = _container(_CountingProbeAdapter());
    addTearDown(container.dispose);
    await container.read(directConnectionProfilesProvider.future);
    final controller = container.read(
      directConnectionProfilesProvider.notifier,
    );

    final probe = await controller.probe(_profile(adapterKey: 'unknown'));
    check(probe.reachable).isFalse();
    check(probe.message).isNotNull().contains('not available');
  });

  group('HTTP 401 auth-mode hint', () {
    DioException unauthorized() {
      final request = RequestOptions(path: '/models');
      return DioException(
        requestOptions: request,
        type: DioExceptionType.badResponse,
        response: Response<void>(requestOptions: request, statusCode: 401),
      );
    }

    test('thrown 401 with api-key header mode mentions Bearer', () async {
      final container = _container(
        _UnsafeMessageAdapter(probeError: unauthorized()),
      );
      addTearDown(container.dispose);
      await container.read(directConnectionProfilesProvider.future);
      final controller = container.read(
        directConnectionProfilesProvider.notifier,
      );

      final probe = await controller.probe(
        _profile(apiKey: 'secret-key')
            .copyWith(apiKeyAuthMode: DirectApiKeyAuthMode.apiKeyHeader),
      );
      check(probe.reachable).isFalse();
      check(probe.message)
          .equals('The provider returned HTTP 401. $kDirectBearerAuthModeHint');
    });

    test(
      'returned 401 probe with api-key header mode mentions Bearer',
      () async {
        final container = _container(
          _UnsafeMessageAdapter(
            probeResult: const DirectConnectionProbe(
              reachable: false,
              message: 'The provider returned HTTP 401.',
            ),
          ),
        );
        addTearDown(container.dispose);
        await container.read(directConnectionProfilesProvider.future);
        final controller = container.read(
          directConnectionProfilesProvider.notifier,
        );

        final probe = await controller.probe(
          _profile(apiKey: 'secret-key')
              .copyWith(apiKeyAuthMode: DirectApiKeyAuthMode.apiKeyHeader),
        );
        check(probe.reachable).isFalse();
        check(probe.message).isNotNull().contains(kDirectBearerAuthModeHint);
      },
    );

    test('401 with bearer mode does not mention the hint', () async {
      final container = _container(
        _UnsafeMessageAdapter(probeError: unauthorized()),
      );
      addTearDown(container.dispose);
      await container.read(directConnectionProfilesProvider.future);
      final controller = container.read(
        directConnectionProfilesProvider.notifier,
      );

      final probe = await controller.probe(_profile(apiKey: 'secret-key'));
      check(probe.reachable).isFalse();
      check(probe.message).equals('The provider returned HTTP 401.');
    });
  });
}

final class _CountingProbeAdapter implements DirectProviderAdapter {
  int probeCalls = 0;

  @override
  String get key => kOpenAiCompatibleAdapterKey;

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async => const [];

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async {
    probeCalls++;
    return const DirectConnectionProbe(reachable: true);
  }

  @override
  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  ) => throw UnimplementedError();
}

ProviderContainer _container(
  DirectProviderAdapter adapter, {
  DirectModelCacheStore? cacheStore,
}) => ProviderContainer(
  overrides: [
    secureStorageProvider.overrideWithValue(FlutterSecureKeyValueStore()),
    if (cacheStore != null)
      directModelCacheStoreProvider.overrideWithValue(cacheStore),
    directProviderAdapterRegistryProvider.overrideWithValue(
      DirectProviderAdapterRegistry([adapter]),
    ),
  ],
);

DirectConnectionProfile _profile({
  String id = 'profile-one',
  String name = 'Direct',
  String adapterKey = kOpenAiCompatibleAdapterKey,
  String baseUrl = 'https://example.test/v1',
  String? apiKey,
  Map<String, String> customHeaders = const {},
  List<String> manualModelIds = const [],
}) => DirectConnectionProfile(
  id: id,
  name: name,
  adapterKey: adapterKey,
  baseUrl: baseUrl,
  apiKey: apiKey,
  customHeaders: customHeaders,
  manualModelIds: manualModelIds,
);

({CancelToken token, Completer<void> done}) _registerPendingRun(
  DirectRunRegistry registry, {
  required String profileId,
}) {
  final token = CancelToken();
  final done = Completer<void>();
  final reservation = registry.reserve((
    ownerConversationId: 'chat-$profileId',
    assistantMessageId: 'assistant-$profileId',
  ), profileId);
  final registered = registry.register(
    reservation,
    DirectCompletionRun(
      id: 'run-$profileId',
      profileId: profileId,
      remoteModelId: 'model-one',
      events: const Stream<DirectStreamEvent>.empty(),
      cancelToken: token,
      done: done.future,
    ),
  );
  expect(registered, isTrue);
  return (token: token, done: done);
}

Future<List<DirectConnectionProfile>> _loadDurableProfiles() =>
    DirectConnectionProfileStore(
      SecureCredentialStorage(instance: FlutterSecureKeyValueStore()),
    ).load();

final class _QueuedAdapter implements DirectProviderAdapter {
  final List<List<DirectRemoteModel>> responses = [];
  final List<Object> errors = [];
  int listCalls = 0;

  @override
  String get key => kOpenAiCompatibleAdapterKey;

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async {
    listCalls++;
    if (responses.isNotEmpty) return responses.removeAt(0);
    if (errors.isNotEmpty) throw errors.removeAt(0);
    return const [];
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

final class _BlockingDiscoveryAdapter implements DirectProviderAdapter {
  final Completer<void> started = Completer<void>();
  final Completer<List<DirectRemoteModel>> release =
      Completer<List<DirectRemoteModel>>();
  int listCalls = 0;

  @override
  String get key => kOpenAiCompatibleAdapterKey;

  @override
  Future<List<DirectRemoteModel>> listModels(DirectConnectionProfile profile) {
    listCalls++;
    if (!started.isCompleted) started.complete();
    return release.future;
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

final class _GatedLifecycleAdapter
    implements DirectProviderAdapter, DirectModelLifecycleAdapter {
  final Completer<void> refreshStarted = Completer<void>();
  final Completer<Set<String>> refreshResult = Completer<Set<String>>();
  final Completer<void> loadStarted = Completer<void>();
  final Completer<void> releaseLoad = Completer<void>();
  int _runningListCalls = 0;

  @override
  String get key => kOllamaAdapterKey;

  @override
  Future<Set<String>> listRunningModelIds(
    DirectConnectionProfile profile,
  ) async {
    _runningListCalls++;
    if (_runningListCalls == 1) return const {};
    if (_runningListCalls == 2) {
      refreshStarted.complete();
      return refreshResult.future;
    }
    return const {'model-one'};
  }

  @override
  Future<void> loadModel(
    DirectConnectionProfile profile,
    String remoteModelId, {
    String? keepAlive,
  }) async {
    loadStarted.complete();
    await releaseLoad.future;
  }

  @override
  Future<void> unloadModel(
    DirectConnectionProfile profile,
    String remoteModelId,
  ) async {}

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

final class _OverlappingLifecycleAdapter
    implements DirectProviderAdapter, DirectModelLifecycleAdapter {
  final Completer<void> firstMutationListStarted = Completer<void>();
  final Completer<Set<String>> firstMutationListResult =
      Completer<Set<String>>();
  int _runningListCalls = 0;

  @override
  String get key => kOllamaAdapterKey;

  @override
  Future<Set<String>> listRunningModelIds(DirectConnectionProfile profile) {
    _runningListCalls++;
    return switch (_runningListCalls) {
      1 => Future.value(const <String>{}),
      2 => () {
        firstMutationListStarted.complete();
        return firstMutationListResult.future;
      }(),
      _ => Future.value(const {'model-two'}),
    };
  }

  @override
  Future<void> loadModel(
    DirectConnectionProfile profile,
    String remoteModelId, {
    String? keepAlive,
  }) async {}

  @override
  Future<void> unloadModel(
    DirectConnectionProfile profile,
    String remoteModelId,
  ) async {}

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

final class _UnsafeMessageAdapter implements DirectProviderAdapter {
  _UnsafeMessageAdapter({
    this.probeResult = const DirectConnectionProbe(reachable: true),
    this.probeError,
    this.discoveryError,
  });

  final DirectConnectionProbe probeResult;
  final Object? probeError;
  final Object? discoveryError;

  @override
  String get key => kOpenAiCompatibleAdapterKey;

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async {
    final error = discoveryError;
    if (error != null) throw error;
    return const [];
  }

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async {
    final error = probeError;
    if (error != null) throw error;
    return probeResult;
  }

  @override
  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  ) => throw UnimplementedError();
}

final class _GatedProfilesController
    extends DirectConnectionProfilesController {
  _GatedProfilesController(this.profiles);

  final Future<List<DirectConnectionProfile>> profiles;

  @override
  Future<List<DirectConnectionProfile>> build() => profiles;
}

final class _RecoveringProfilesController
    extends DirectConnectionProfilesController {
  @override
  Future<List<DirectConnectionProfile>> build() =>
      Future.error(StateError('profile storage unavailable'));

  void recover(List<DirectConnectionProfile> profiles) {
    state = AsyncData(profiles);
  }
}

final class _OverlappingAdapter implements DirectProviderAdapter {
  final Completer<List<DirectRemoteModel>> first = Completer();
  int listCalls = 0;

  @override
  String get key => kOpenAiCompatibleAdapterKey;

  @override
  Future<List<DirectRemoteModel>> listModels(DirectConnectionProfile profile) {
    listCalls++;
    if (listCalls == 1) return first.future;
    return Future.value([DirectRemoteModel(id: 'new-model')]);
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

final class _RediscoveryGateAdapter implements DirectProviderAdapter {
  final Completer<void> rediscoveryStarted = Completer<void>();
  final Completer<List<DirectRemoteModel>> _rediscovery = Completer();
  String? _blockedProfileId;

  @override
  String get key => kOpenAiCompatibleAdapterKey;

  void blockProfile(String profileId) => _blockedProfileId = profileId;

  void finishRediscovery() {
    final profileId = _blockedProfileId;
    if (!_rediscovery.isCompleted && profileId != null) {
      _rediscovery.complete([DirectRemoteModel(id: 'model-$profileId')]);
    }
  }

  @override
  Future<List<DirectRemoteModel>> listModels(DirectConnectionProfile profile) {
    if (profile.id == _blockedProfileId) {
      if (!rediscoveryStarted.isCompleted) rediscoveryStarted.complete();
      return _rediscovery.future;
    }
    return Future.value([DirectRemoteModel(id: 'model-${profile.id}')]);
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

final class _ConcurrencyAdapter implements DirectProviderAdapter {
  final Completer<void> firstWaveStarted = Completer<void>();
  final Completer<void> release = Completer<void>();
  int listCalls = 0;
  int _active = 0;
  int maxActive = 0;

  @override
  String get key => kOpenAiCompatibleAdapterKey;

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async {
    listCalls++;
    _active++;
    if (_active > maxActive) maxActive = _active;
    if (listCalls == 4 && !firstWaveStarted.isCompleted) {
      firstWaveStarted.complete();
    }
    try {
      await release.future;
      return [DirectRemoteModel(id: 'model-${profile.id}')];
    } finally {
      _active--;
    }
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

final class _SupersededOllamaHttpAdapter implements HttpClientAdapter {
  final Completer<void> oldWaveStarted = Completer<void>();
  final Completer<void> releaseOldShows = Completer<void>();
  int tagsRequests = 0;
  int oldShowRequests = 0;
  int newShowRequests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.endsWith('api/tags')) {
      tagsRequests++;
      return _jsonResponse({
        'models': tagsRequests == 1
            ? [
                for (var index = 0; index < 12; index++)
                  {
                    'name': 'old-model-$index',
                    'details': {
                      'families': ['llama'],
                    },
                  },
              ]
            : [
                {
                  'name': 'new-model',
                  'details': {
                    'families': ['llama'],
                  },
                },
              ],
      });
    }
    if (options.path.endsWith('api/show')) {
      final data = options.data as Map;
      final modelId = data['model']?.toString() ?? '';
      if (modelId.startsWith('old-model-')) {
        oldShowRequests++;
        if (oldShowRequests == 4 && !oldWaveStarted.isCompleted) {
          oldWaveStarted.complete();
        }
        // Deliberately ignore cancelFuture. The adapter's generation checks
        // after these in-flight requests settle must prevent more work.
        await releaseOldShows.future;
      } else {
        newShowRequests++;
      }
      return _jsonResponse({
        'capabilities': ['completion'],
      });
    }
    throw StateError('Unexpected Ollama request: ${options.uri}');
  }

  ResponseBody _jsonResponse(Map<String, dynamic> value) => ResponseBody(
    Stream<Uint8List>.value(Uint8List.fromList(utf8.encode(jsonEncode(value)))),
    200,
    headers: {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    },
  );

  @override
  void close({bool force = false}) {}
}

Dio _dio(HttpClientAdapter adapter) {
  final dio = Dio();
  dio.httpClientAdapter = adapter;
  return dio;
}

final class _ReloadGateSecureStorage implements SecureKeyValueStore {
  _ReloadGateSecureStorage(String initialDocument)
    : _profileDocument = initialDocument;

  static const _profilesKey = 'direct_connection_profiles_v1';

  final Completer<void> reloadReadStarted = Completer<void>();
  final Completer<void> allowReloadRead = Completer<void>();
  String? _profileDocument;
  int profileReadCalls = 0;

  @override
  Future<String?> read({required String key}) async {
    if (key != _profilesKey) return null;
    profileReadCalls++;
    final captured = _profileDocument;
    if (profileReadCalls == 2) {
      reloadReadStarted.complete();
      await allowReloadRead.future;
    }
    return captured;
  }

  @override
  Future<void> write({required String key, required String? value}) async {
    if (key == _profilesKey) _profileDocument = value;
  }

  @override
  Future<void> delete({required String key}) async {
    if (key == _profilesKey) _profileDocument = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _WriteGateSecureStorage implements SecureKeyValueStore {
  _WriteGateSecureStorage(this._profileDocument);

  static const _profilesKey = 'direct_connection_profiles_v1';

  final Completer<void> writeStarted = Completer<void>();
  final Completer<void> allowWrite = Completer<void>();
  String? _profileDocument;

  @override
  Future<String?> read({required String key}) async {
    if (key == _profilesKey) return _profileDocument;
    return null;
  }

  @override
  Future<void> write({required String key, required String? value}) async {
    if (key != _profilesKey) return;
    writeStarted.complete();
    await allowWrite.future;
    _profileDocument = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _InitialReadGateSecureStorage implements SecureKeyValueStore {
  _InitialReadGateSecureStorage(this._profileDocument);

  static const _profilesKey = 'direct_connection_profiles_v1';

  final Completer<void> readStarted = Completer<void>();
  final Completer<void> allowRead = Completer<void>();
  final String _profileDocument;

  @override
  Future<String?> read({required String key}) async {
    if (key != _profilesKey) return null;
    if (!readStarted.isCompleted) readStarted.complete();
    await allowRead.future;
    return _profileDocument;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _DisposeConflictSecureStorage implements SecureKeyValueStore {
  _DisposeConflictSecureStorage({
    required this.initialDocument,
    required this.conflictDocument,
  });

  static const _profilesKey = 'direct_connection_profiles_v1';

  final String initialDocument;
  final String conflictDocument;
  final Completer<void> conflictReadStarted = Completer<void>();
  final Completer<void> releaseConflictRead = Completer<void>();
  int _profileReadCalls = 0;

  @override
  Future<String?> read({required String key}) async {
    if (key != _profilesKey) return null;
    _profileReadCalls++;
    if (_profileReadCalls == 1) return initialDocument;
    conflictReadStarted.complete();
    await releaseConflictRead.future;
    return conflictDocument;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FailingReloadSecureStorage implements SecureKeyValueStore {
  _FailingReloadSecureStorage(this._profileDocument);

  static const _profilesKey = 'direct_connection_profiles_v1';

  final String _profileDocument;
  int _profileReadCalls = 0;

  @override
  Future<String?> read({required String key}) async {
    if (key != _profilesKey) return null;
    _profileReadCalls++;
    if (_profileReadCalls > 1) {
      throw StateError('secure storage unavailable');
    }
    return _profileDocument;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Fails loudly if a status probe reaches the platform channel where Apple
/// models cannot exist.
final class _UnreachablePccHost extends PccHostApi {
  @override
  Future<PlatformPccStatus> getStatus(PlatformAppleModel model) =>
      throw StateError('Apple status probed on an unsupported platform');
}
