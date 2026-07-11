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
    'transport edit commits and invalidates stale models when cancellation fails',
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

      cancellation.done.completeError(StateError('cancel failed'));
      await expectLater(mutation, completes);

      await controller.setEnabled(original.id, false);
      final durable = await _loadDurableProfiles();
      expect(durable.single.baseUrl, 'https://new.example.test/v1');
      expect(durable.single.enabled, isFalse);
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

    cancellation.done.completeError(StateError('cancel failed'));
    await expectLater(removal, completes);

    final replacement = _profile(id: 'profile-two', name: 'Replacement');
    await controller.upsert(replacement);
    final durable = await _loadDurableProfiles();
    expect(durable.map((profile) => profile.id), ['profile-two']);
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

    cancellation.done.completeError(StateError('cancel failed'));
    await expectLater(clear, completes);

    final replacement = _profile(id: 'profile-two', name: 'Replacement');
    await controller.upsert(replacement);
    final durable = await _loadDurableProfiles();
    expect(durable.map((profile) => profile.id), ['profile-two']);
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
  List<String> manualModelIds = const [],
}) => DirectConnectionProfile(
  id: id,
  name: name,
  adapterKey: kOpenAiCompatibleAdapterKey,
  baseUrl: 'https://example.test/v1',
  apiKey: apiKey,
  manualModelIds: manualModelIds,
);

({CancelToken token, Completer<void> done}) _registerPendingRun(
  DirectRunRegistry registry, {
  required String profileId,
}) {
  final token = CancelToken();
  final done = Completer<void>();
  final reservation = registry.reserve('assistant-$profileId', profileId);
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
