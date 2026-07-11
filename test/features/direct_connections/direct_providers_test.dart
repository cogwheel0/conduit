import 'dart:async';

import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/storage_providers.dart';
import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit/features/direct_connections/services/direct_provider_adapter.dart';
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
  String? apiKey,
  List<String> manualModelIds = const [],
}) => DirectConnectionProfile(
  id: 'profile-one',
  name: 'Direct',
  adapterKey: kOpenAiCompatibleAdapterKey,
  baseUrl: 'https://example.test/v1',
  apiKey: apiKey,
  manualModelIds: manualModelIds,
);

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
