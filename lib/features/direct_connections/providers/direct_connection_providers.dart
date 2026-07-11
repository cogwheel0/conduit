import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/model.dart' as model;
import '../../../core/persistence/persistence_keys.dart';
import '../../../core/persistence/preferences_store.dart';
import '../../../core/providers/storage_providers.dart';
import '../../../core/services/secure_credential_storage.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';
import '../services/direct_adapter_helpers.dart';
import '../services/direct_connection_profile_store.dart';
import '../services/direct_model_registry.dart';
import '../services/direct_provider_adapter.dart';
import '../services/direct_run_registry.dart';
import '../services/ollama_adapter.dart';
import '../services/openai_compatible_adapter.dart';

enum DirectHistoryPolicy {
  /// Mirror direct chats to the active OpenWebUI server when one is available;
  /// otherwise keep them in Conduit's local database.
  syncWithOpenWebUI('sync-with-openwebui'),

  /// Never send direct-chat history to OpenWebUI.
  localOnly('local-only');

  const DirectHistoryPolicy(this.storageValue);
  final String storageValue;

  static DirectHistoryPolicy fromStorage(String? value) =>
      values.where((item) => item.storageValue == value).firstOrNull ??
      syncWithOpenWebUI;
}

typedef DirectHistoryPolicyWriter =
    Future<void> Function(DirectHistoryPolicy policy);

/// Persistence seam kept separate so ordering can be verified without relying
/// on platform-specific preference write timing.
final directHistoryPolicyWriterProvider = Provider<DirectHistoryPolicyWriter>(
  (ref) =>
      (policy) => PreferencesStore.put(
        PreferenceKeys.directHistoryPolicy,
        policy.storageValue,
      ),
);

class DirectHistoryPolicyController extends Notifier<DirectHistoryPolicy> {
  Future<void> _mutationQueue = Future<void>.value();

  @override
  DirectHistoryPolicy build() => DirectHistoryPolicy.fromStorage(
    PreferencesStore.getString(PreferenceKeys.directHistoryPolicy),
  );

  Future<void> setPolicy(DirectHistoryPolicy policy) {
    final result = _mutationQueue.then<void>(
      (_) => _persistPolicy(policy),
      onError: (Object _, StackTrace _) => _persistPolicy(policy),
    );
    _mutationQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _persistPolicy(DirectHistoryPolicy policy) async {
    await ref.read(directHistoryPolicyWriterProvider)(policy);
    if (ref.mounted) state = policy;
  }
}

final directHistoryPolicyProvider =
    NotifierProvider<DirectHistoryPolicyController, DirectHistoryPolicy>(
      DirectHistoryPolicyController.new,
    );

final directConnectionProfileStoreProvider =
    Provider<DirectConnectionProfileStore>((ref) {
      return DirectConnectionProfileStore(
        SecureCredentialStorage(instance: ref.watch(secureStorageProvider)),
      );
    });

final directRunRegistryProvider = Provider<DirectRunRegistry>(
  (ref) => DirectRunRegistry(),
);

final directModelRegistryProvider = Provider<DirectModelRegistry>((ref) {
  final registry = DirectModelRegistry();
  ref.onDispose(registry.clear);
  return registry;
});

final directProviderAdapterRegistryProvider =
    Provider<DirectProviderAdapterRegistry>((ref) {
      return DirectProviderAdapterRegistry([
        OpenAiCompatibleAdapter(),
        OllamaAdapter(),
      ]);
    });

class DirectConnectionProfilesController
    extends AsyncNotifier<List<DirectConnectionProfile>> {
  Future<void> _mutationQueue = Future<void>.value();

  DirectConnectionProfileStore get _store =>
      ref.read(directConnectionProfileStoreProvider);

  @override
  Future<List<DirectConnectionProfile>> build() {
    // Some pure Riverpod tests intentionally do not initialize a Flutter
    // binding. The secure-storage plugin cannot be invoked in that state; keep
    // those provider graphs empty and override-friendly without masking any
    // storage failure in the app or in binding-backed tests.
    if (Platform.environment['FLUTTER_TEST'] == 'true' &&
        BindingBase.debugBindingType() == null) {
      return Future.value(const []);
    }
    return _store.load();
  }

  /// Inserts/replaces a profile. An origin change clears credentials unless
  /// [secretsConfirmedForNewOrigin] records an explicit user confirmation.
  Future<void> upsert(
    DirectConnectionProfile profile, {
    bool secretsConfirmedForNewOrigin = false,
  }) => _serializeMutation(
    () => _upsert(
      profile,
      secretsConfirmedForNewOrigin: secretsConfirmedForNewOrigin,
    ),
  );

  Future<void> _upsert(
    DirectConnectionProfile profile, {
    bool secretsConfirmedForNewOrigin = false,
  }) async {
    profile.validate();
    final current = state.value ?? await _store.load();
    final index = current.indexWhere((item) => item.id == profile.id);
    final previous = index < 0 ? null : current[index];
    final safeProfile = previous == null
        ? profile
        : DirectConnectionProfile.secureUpdate(
            previous: previous,
            next: profile,
            secretsConfirmedForNewOrigin: secretsConfirmedForNewOrigin,
          );
    safeProfile.validate();
    final updated = [...current];
    if (index < 0) {
      updated.add(safeProfile);
    } else {
      updated[index] = safeProfile;
    }
    final persisted = await _store.save(
      updated,
      secretsConfirmedForNewOrigin: secretsConfirmedForNewOrigin
          ? {profile.id}
          : const {},
    );
    final persistedProfile = persisted
        .where((item) => item.id == profile.id)
        .single;
    if (previous != null && _transportChanged(previous, persistedProfile)) {
      await Future.wait(
        ref.read(directRunRegistryProvider).cancelProfile(profile.id),
      );
    }
    if (ref.mounted) state = AsyncValue.data(persisted);
  }

  Future<void> remove(String profileId) => _serializeMutation(() async {
    final current = state.value ?? await _store.load();
    final updated = current
        .where((profile) => profile.id != profileId)
        .toList(growable: false);
    if (updated.length == current.length) return;
    final persisted = await _store.save(updated);
    await Future.wait(
      ref.read(directRunRegistryProvider).cancelProfile(profileId),
    );
    ref.read(directModelRegistryProvider).removeProfile(profileId);
    if (ref.mounted) state = AsyncValue.data(persisted);
  });

  Future<void> setEnabled(String profileId, bool enabled) => _serializeMutation(
    () async {
      final current = state.value ?? await _store.load();
      final profile = current.where((item) => item.id == profileId).firstOrNull;
      if (profile == null) {
        throw StateError('Direct connection profile not found.');
      }
      await _upsert(profile.copyWith(enabled: enabled));
    },
  );

  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) {
    profile.validate();
    return ref
        .read(directProviderAdapterRegistryProvider)
        .require(profile.adapterKey)
        .probe(profile);
  }

  Future<void> reload() async {
    final previous = state.value;
    state = const AsyncValue.loading();
    final next = await AsyncValue.guard(_store.load);
    if (!ref.mounted) return;
    state = next;
    final retained =
        next.value?.map((profile) => profile.id) ?? const <String>[];
    ref.read(directModelRegistryProvider).retainProfiles(retained);
    if (previous != null && next.hasError) {
      // Preserve no alternate in-memory source on a secure-storage outage: the
      // error state makes the outage visible and prevents unsafe edits.
      return;
    }
  }

  Future<void> clear() => _serializeMutation(() async {
    await _store.clear();
    await Future.wait(ref.read(directRunRegistryProvider).cancelAll());
    ref.read(directModelRegistryProvider).clear();
    if (ref.mounted) state = const AsyncValue.data([]);
  });

  Future<void> _serializeMutation(Future<void> Function() operation) {
    final result = _mutationQueue.then<void>(
      (_) => operation(),
      onError: (Object _, StackTrace _) => operation(),
    );
    _mutationQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}

final directConnectionProfilesProvider =
    AsyncNotifierProvider<
      DirectConnectionProfilesController,
      List<DirectConnectionProfile>
    >(DirectConnectionProfilesController.new);

final class DirectModelDiscoveryState {
  DirectModelDiscoveryState({
    Iterable<model.Model> models = const [],
    Map<String, String> errorsByProfile = const {},
    this.isRefreshing = false,
  }) : models = List.unmodifiable(models),
       errorsByProfile = Map.unmodifiable(errorsByProfile);

  final List<model.Model> models;
  final Map<String, String> errorsByProfile;
  final bool isRefreshing;
}

class DirectModelDiscoveryController
    extends AsyncNotifier<DirectModelDiscoveryState> {
  final Map<String, List<DirectRemoteModel>> _cache = {};
  final Map<String, int> _profileSignatures = {};
  int _discoveryGeneration = 0;

  @override
  Future<DirectModelDiscoveryState> build() async {
    final generation = ++_discoveryGeneration;
    final profiles = await ref.watch(directConnectionProfilesProvider.future);
    return _discover(profiles, generation: generation);
  }

  Future<void> refresh() async {
    final generation = ++_discoveryGeneration;
    final previous = state.value;
    if (previous != null) {
      state = AsyncValue.data(
        DirectModelDiscoveryState(
          models: previous.models,
          errorsByProfile: previous.errorsByProfile,
          isRefreshing: true,
        ),
      );
    }
    final result = await AsyncValue.guard(() async {
      final profiles = await ref.read(directConnectionProfilesProvider.future);
      return _discover(profiles, generation: generation);
    });
    if (ref.mounted && generation == _discoveryGeneration) state = result;
  }

  Future<DirectModelDiscoveryState> _discover(
    List<DirectConnectionProfile> allProfiles, {
    required int generation,
  }) async {
    final profiles = allProfiles.where((profile) => profile.enabled).toList();
    final activeIds = profiles.map((profile) => profile.id).toSet();

    final outcomes = await Future.wait([
      for (final profile in profiles)
        _discoverProfile(profile, signature: _profileSignature(profile)),
    ]);
    if (!ref.mounted) return DirectModelDiscoveryState();
    if (generation != _discoveryGeneration) {
      return state.value ?? DirectModelDiscoveryState();
    }

    final registry = ref.read(directModelRegistryProvider)
      ..retainProfiles(activeIds);
    _cache.removeWhere((id, _) => !activeIds.contains(id));
    _profileSignatures.removeWhere((id, _) => !activeIds.contains(id));
    final models = <model.Model>[];
    final errors = <String, String>{};
    for (final outcome in outcomes) {
      if (_profileSignatures[outcome.profile.id] != outcome.signature) {
        _cache.remove(outcome.profile.id);
      }
      _profileSignatures[outcome.profile.id] = outcome.signature;
      if (outcome.models != null) {
        _cache[outcome.profile.id] = outcome.models!;
      }
      final cached = _cache[outcome.profile.id] ?? const <DirectRemoteModel>[];
      models.addAll(registry.replaceProfileModels(outcome.profile, cached));
      if (outcome.error != null) errors[outcome.profile.id] = outcome.error!;
    }
    return DirectModelDiscoveryState(models: models, errorsByProfile: errors);
  }

  Future<_DiscoveryOutcome> _discoverProfile(
    DirectConnectionProfile profile, {
    required int signature,
  }) async {
    final canReuseCache = _profileSignatures[profile.id] == signature;
    final validation = profile.validateOrNull();
    if (validation != null) {
      return _DiscoveryOutcome(
        profile: profile,
        signature: signature,
        error: validation,
      );
    }
    if (profile.manualModelIds.isNotEmpty) {
      return _DiscoveryOutcome(
        profile: profile,
        signature: signature,
        models: directManualModels(profile),
      );
    }
    final adapter = ref
        .read(directProviderAdapterRegistryProvider)
        .lookup(profile.adapterKey);
    if (adapter == null) {
      return _DiscoveryOutcome(
        profile: profile,
        signature: signature,
        models: canReuseCache ? _cache[profile.id] : null,
        error: 'Provider adapter is unavailable.',
      );
    }
    try {
      return _DiscoveryOutcome(
        profile: profile,
        signature: signature,
        models: await adapter.listModels(profile),
      );
    } catch (error) {
      final normalized = normalizeDirectProviderError(error);
      return _DiscoveryOutcome(
        profile: profile,
        signature: signature,
        models: canReuseCache ? _cache[profile.id] : null,
        error: normalized.message,
      );
    }
  }
}

final directModelDiscoveryProvider =
    AsyncNotifierProvider<
      DirectModelDiscoveryController,
      DirectModelDiscoveryState
    >(DirectModelDiscoveryController.new);

final class _DiscoveryOutcome {
  const _DiscoveryOutcome({
    required this.profile,
    required this.signature,
    this.models,
    this.error,
  });
  final DirectConnectionProfile profile;
  final int signature;
  final List<DirectRemoteModel>? models;
  final String? error;
}

int _profileSignature(DirectConnectionProfile profile) => Object.hashAll([
  profile.adapterKey,
  profile.baseUrl,
  profile.apiKey,
  ...profile.customHeaders.entries.expand((entry) => [entry.key, entry.value]),
  ...profile.manualModelIds,
  profile.allowSelfSignedCertificates,
  profile.mtlsCertificateChainPem,
  profile.mtlsPrivateKeyPem,
  profile.mtlsPrivateKeyPassword,
]);

bool _transportChanged(
  DirectConnectionProfile previous,
  DirectConnectionProfile next,
) =>
    _profileSignature(previous) != _profileSignature(next) ||
    previous.enabled != next.enabled ||
    !listEquals(previous.manualModelIds, next.manualModelIds);
