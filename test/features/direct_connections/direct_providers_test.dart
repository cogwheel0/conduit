import 'dart:async';

import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/storage_providers.dart';
import 'package:conduit/core/services/secure_credential_storage.dart';
import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_connection_profile_store.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit/features/direct_connections/services/direct_provider_adapter.dart';
import 'package:conduit/features/direct_connections/services/direct_run_registry.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
  });

  tearDown(PreferencesStore.debugReset);

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
        'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
          old,
        ]).encode(),
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
}

ProviderContainer _container(DirectProviderAdapter adapter) =>
    ProviderContainer(
      overrides: [
        secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        directProviderAdapterRegistryProvider.overrideWithValue(
          DirectProviderAdapterRegistry([adapter]),
        ),
      ],
    );

DirectConnectionProfile _profile({
  String id = 'profile-one',
  String name = 'Direct',
  String? apiKey,
  Map<String, String> customHeaders = const {},
  List<String> manualModelIds = const [],
}) => DirectConnectionProfile(
  id: id,
  name: name,
  adapterKey: kOpenAiCompatibleAdapterKey,
  baseUrl: 'https://example.test/v1',
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
      SecureCredentialStorage(instance: const FlutterSecureStorage()),
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

final class _ReloadGateSecureStorage implements FlutterSecureStorage {
  _ReloadGateSecureStorage(String initialDocument)
    : _profileDocument = initialDocument;

  static const _profilesKey = 'direct_connection_profiles_v1';

  final Completer<void> reloadReadStarted = Completer<void>();
  final Completer<void> allowReloadRead = Completer<void>();
  String? _profileDocument;
  int profileReadCalls = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
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
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == _profilesKey) _profileDocument = value;
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == _profilesKey) _profileDocument = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
