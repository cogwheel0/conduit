import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/model.dart' as model;
import '../../../core/persistence/persistence_keys.dart';
import '../../../core/persistence/preferences_store.dart';
import '../../../core/providers/storage_providers.dart';
import '../../../core/services/secure_credential_storage.dart';
import '../../../core/utils/debug_logger.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';
import '../services/direct_adapter_helpers.dart';
import '../services/direct_connection_profile_store.dart';
import '../services/direct_model_registry.dart';
import '../services/direct_provider_adapter.dart';
import '../services/direct_run_registry.dart';
import '../services/ollama_adapter.dart';
import '../services/openai_compatible_adapter.dart';

export '../services/direct_connection_profile_store.dart'
    show DirectConnectionProfileConflictException;

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

/// Provider-independent guardrails for normalized completion events.
///
/// Kept overrideable so dispatcher deadline and budget behavior can be tested
/// without waiting for production-scale limits.
final directNormalizedStreamLimitsProvider =
    Provider<DirectNormalizedStreamLimits>(
      (ref) => const DirectNormalizedStreamLimits(),
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
    DirectConnectionProfile? expectedPrevious,
    bool secretsConfirmedForNewOrigin = false,
  }) => _serializeMutation(
    () => _upsert(
      profile,
      expectedPrevious: expectedPrevious,
      secretsConfirmedForNewOrigin: secretsConfirmedForNewOrigin,
    ),
  );

  Future<void> _upsert(
    DirectConnectionProfile profile, {
    DirectConnectionProfile? expectedPrevious,
    bool secretsConfirmedForNewOrigin = false,
  }) async {
    profile.validate();
    final current = state.value ?? await _store.load();
    final index = current.indexWhere((item) => item.id == profile.id);
    final previous = index < 0 ? null : current[index];
    final runRegistry = ref.read(directRunRegistryProvider);
    final modelRegistry = ref.read(directModelRegistryProvider);
    late final List<DirectConnectionProfile> persisted;
    try {
      persisted = await _store.upsert(
        profile,
        expectedPrevious: expectedPrevious,
        secretsConfirmedForNewOrigin: secretsConfirmedForNewOrigin,
      );
    } on DirectConnectionProfileConflictException catch (conflict) {
      _publishConflictWinner(
        previous: current,
        persisted: conflict.currentProfiles,
        runRegistry: runRegistry,
        modelRegistry: modelRegistry,
      );
      rethrow;
    }
    final persistedProfile = persisted
        .where((item) => item.id == profile.id)
        .single;
    final transportChanged =
        previous != null && _transportChanged(previous, persistedProfile);
    if (transportChanged) {
      // The secure-store write is authoritative. Invalidate old routing
      // authority before publishing the new state so no watcher can target the
      // previous endpoint while discovery catches up.
      _removeProfileModelsBestEffort(modelRegistry, profile.id);
    }
    if (ref.mounted) state = AsyncValue.data(persisted);
    if (transportChanged) {
      _cancelProfileRunsBestEffort(runRegistry, profile.id);
    }
  }

  void _publishConflictWinner({
    required List<DirectConnectionProfile> previous,
    required List<DirectConnectionProfile> persisted,
    required DirectRunRegistry runRegistry,
    required DirectModelRegistry modelRegistry,
  }) {
    final persistedById = <String, DirectConnectionProfile>{
      for (final profile in persisted) profile.id: profile,
    };
    final invalidatedProfileIds = <String>{};
    for (final oldProfile in previous) {
      final nextProfile = persistedById[oldProfile.id];
      if (nextProfile == null || _transportChanged(oldProfile, nextProfile)) {
        invalidatedProfileIds.add(oldProfile.id);
        _removeProfileModelsBestEffort(modelRegistry, oldProfile.id);
      }
    }
    modelRegistry.retainProfiles(persistedById.keys);
    if (ref.mounted) state = AsyncValue.data(persisted);
    for (final profileId in invalidatedProfileIds) {
      _cancelProfileRunsBestEffort(runRegistry, profileId);
    }
  }

  Future<void> remove(String profileId) => _serializeMutation(() async {
    final current = state.value ?? await _store.load();
    final updated = current
        .where((profile) => profile.id != profileId)
        .toList(growable: false);
    if (updated.length == current.length) return;
    final runRegistry = ref.read(directRunRegistryProvider);
    final modelRegistry = ref.read(directModelRegistryProvider);
    final persisted = await _store.save(updated);
    _removeProfileModelsBestEffort(modelRegistry, profileId);
    if (ref.mounted) state = AsyncValue.data(persisted);
    _cancelProfileRunsBestEffort(runRegistry, profileId);
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

  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async {
    profile.validate();
    final adapter = ref
        .read(directProviderAdapterRegistryProvider)
        .require(profile.adapterKey);
    try {
      final result = await adapter.probe(profile);
      final message = result.message;
      if (message == null) return result;
      return DirectConnectionProbe(
        reachable: result.reachable,
        modelCount: result.modelCount,
        message: _sanitizeRuntimeAdapterMessage(profile, message),
      );
    } catch (error) {
      final normalized = normalizeDirectProviderError(error);
      return DirectConnectionProbe(
        reachable: false,
        message: _sanitizeRuntimeAdapterMessage(profile, normalized.message),
      );
    }
  }

  Future<void> reload() => _serializeMutation(_reload);

  Future<void> _reload() async {
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
    final runRegistry = ref.read(directRunRegistryProvider);
    final modelRegistry = ref.read(directModelRegistryProvider);
    await _store.clear();
    _clearModelsBestEffort(modelRegistry);
    if (ref.mounted) state = const AsyncValue.data([]);
    _cancelAllRunsBestEffort(runRegistry);
  });

  void _cancelProfileRunsBestEffort(
    DirectRunRegistry registry,
    String profileId,
  ) {
    _bestEffort(() {
      for (final cancellation in registry.cancelProfile(profileId)) {
        _observeBestEffort(
          cancellation,
          'Failed to finish direct-run cancellation after profile persistence',
        );
      }
    }, 'Failed to revoke direct runs after profile persistence');
  }

  void _cancelAllRunsBestEffort(DirectRunRegistry registry) {
    _bestEffort(() {
      for (final cancellation in registry.cancelAll()) {
        _observeBestEffort(
          cancellation,
          'Failed to finish direct-run cancellation after clearing profiles',
        );
      }
    }, 'Failed to revoke direct runs after clearing profiles');
  }

  void _observeBestEffort(
    Future<void> operation,
    String message, {
    Map<String, Object?>? data,
  }) {
    void logSafeFailure() {
      // `DirectCompletionRun.done` belongs to a runtime-extensible adapter.
      // Its rejection object and stack are provider-controlled and may contain
      // credentials or reflected response data, so cleanup diagnostics stay
      // deliberately type- and value-free.
      DebugLogger.error(message, scope: 'direct/profiles', data: data);
    }

    try {
      unawaited(
        operation.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) => logSafeFailure(),
        ),
      );
    } catch (_) {
      logSafeFailure();
    }
  }

  void _removeProfileModelsBestEffort(
    DirectModelRegistry registry,
    String profileId,
  ) {
    _bestEffort(
      () => registry.removeProfile(profileId),
      'Failed to invalidate direct-model bindings after profile persistence',
    );
  }

  void _clearModelsBestEffort(DirectModelRegistry registry) {
    _bestEffort(
      registry.clear,
      'Failed to clear direct-model bindings after profile persistence',
    );
  }

  FutureOr<void> _bestEffort(
    FutureOr<void> Function() operation,
    String message, {
    Map<String, Object?>? data,
  }) {
    void logFailure() {
      DebugLogger.error(message, scope: 'direct/profiles', data: data);
    }

    try {
      final result = operation();
      if (result is Future<void>) {
        return result.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) => logFailure(),
        );
      }
    } catch (_) {
      logFailure();
    }
  }

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

  DirectModelDiscoveryState._withStableModels({
    required this.models,
    Map<String, String> errorsByProfile = const {},
    this.isRefreshing = false,
  }) : errorsByProfile = Map.unmodifiable(errorsByProfile);

  final List<model.Model> models;
  final Map<String, String> errorsByProfile;
  final bool isRefreshing;
}

class DirectModelDiscoveryController
    extends AsyncNotifier<DirectModelDiscoveryState> {
  final Map<String, List<DirectRemoteModel>> _cache = {};
  final Map<String, int> _profileSignatures = {};
  final Map<String, List<model.Model>> _mintedModels = {};
  final Map<String, DirectConnectionProfile> _mintedModelProfiles = {};
  int _discoveryGeneration = 0;

  @override
  Future<DirectModelDiscoveryState> build() async {
    final generation = ++_discoveryGeneration;
    // `.future` alone does not react to controller-owned data -> data
    // publications. Invalidate on later profile transitions, but do not watch
    // the initial loading -> data edge: this build is already awaiting that
    // future and a second rebuild would duplicate provider discovery calls.
    ref.listen<AsyncValue<List<DirectConnectionProfile>>>(
      directConnectionProfilesProvider,
      (previous, _) {
        if (previous?.asData != null) ref.invalidateSelf();
      },
    );
    final profiles = await ref.read(directConnectionProfilesProvider.future);
    return _discover(profiles, generation: generation);
  }

  Future<void> refresh() async {
    final generation = ++_discoveryGeneration;
    final previous = state.value;
    if (previous != null) {
      state = AsyncValue.data(
        DirectModelDiscoveryState._withStableModels(
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
    if (!ref.mounted) return DirectModelDiscoveryState();
    final profiles = allProfiles.where((profile) => profile.enabled).toList();
    final activeIds = profiles.map((profile) => profile.id).toSet();
    final registry = ref.read(directModelRegistryProvider)
      ..retainProfiles(activeIds);

    // Profile persistence invalidates route bindings before it publishes the
    // new profile list. Hide models whose exact binding is no longer current
    // before waiting for the remaining profiles to finish rediscovery; an
    // unrelated slow provider must not keep a removed/disabled model visible.
    _pruneStaleDiscoveryState(activeIds, registry);

    final outcomes = await Future.wait([
      for (final profile in profiles)
        _discoverProfile(profile, signature: _profileSignature(profile)),
    ]);
    if (!ref.mounted) return DirectModelDiscoveryState();
    if (generation != _discoveryGeneration) {
      return state.value ?? DirectModelDiscoveryState();
    }

    final models = <model.Model>[];
    final errors = <String, String>{};
    for (final outcome in outcomes) {
      final previousCached = _cache[outcome.profile.id];
      if (_profileSignatures[outcome.profile.id] != outcome.signature) {
        _cache.remove(outcome.profile.id);
      }
      _profileSignatures[outcome.profile.id] = outcome.signature;
      if (outcome.models != null) {
        _cache[outcome.profile.id] = outcome.models!;
      }
      final cached = _cache[outcome.profile.id] ?? const <DirectRemoteModel>[];
      final previousMinted = _mintedModels[outcome.profile.id];
      final previousProfile = _mintedModelProfiles[outcome.profile.id];
      final canReuseMinted =
          previousMinted != null &&
          previousProfile != null &&
          previousCached != null &&
          listEquals(previousCached, cached) &&
          sameDirectConnectionProfileValues(previousProfile, outcome.profile) &&
          previousMinted.every((item) => registry.resolve(item) != null);
      final profileModels = canReuseMinted
          ? previousMinted
          : registry.replaceProfileModels(outcome.profile, cached);
      _mintedModels[outcome.profile.id] = profileModels;
      _mintedModelProfiles[outcome.profile.id] = outcome.profile;
      models.addAll(profileModels);
      if (outcome.error != null) errors[outcome.profile.id] = outcome.error!;
    }
    final previousModels = state.value?.models;
    final stableModels =
        previousModels != null && _sameModelIdentities(previousModels, models)
        ? previousModels
        : List<model.Model>.unmodifiable(models);
    return DirectModelDiscoveryState._withStableModels(
      models: stableModels,
      errorsByProfile: errors,
    );
  }

  void _pruneStaleDiscoveryState(
    Set<String> activeIds,
    DirectModelRegistry registry,
  ) {
    _cache.removeWhere((id, _) => !activeIds.contains(id));
    _profileSignatures.removeWhere((id, _) => !activeIds.contains(id));
    _mintedModels.removeWhere((id, _) => !activeIds.contains(id));
    _mintedModelProfiles.removeWhere((id, _) => !activeIds.contains(id));

    final previous = state.value;
    if (previous == null) return;
    final retainedModels = previous.models
        .where((item) => registry.resolve(item) != null)
        .toList(growable: false);
    final retainedErrors = <String, String>{
      for (final entry in previous.errorsByProfile.entries)
        if (activeIds.contains(entry.key)) entry.key: entry.value,
    };
    if (retainedModels.length == previous.models.length &&
        retainedErrors.length == previous.errorsByProfile.length) {
      return;
    }
    if (!ref.mounted) return;
    state = AsyncValue.data(
      DirectModelDiscoveryState._withStableModels(
        models: List<model.Model>.unmodifiable(retainedModels),
        errorsByProfile: retainedErrors,
        isRefreshing: true,
      ),
    );
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
        error: _sanitizeRuntimeAdapterMessage(profile, normalized.message),
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

String _sanitizeRuntimeAdapterMessage(
  DirectConnectionProfile profile,
  String message,
) => sanitizeDirectProviderErrorMessage(
  message,
  sensitiveValues: directProfileSensitiveValues(profile),
);

int _profileSignature(DirectConnectionProfile profile) => Object.hashAll([
  profile.adapterKey,
  profile.baseUrl,
  profile.openAiApiMode,
  profile.apiKeyAuthMode,
  profile.apiVersion,
  profile.modelIdPrefix,
  ...profile.tags,
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

bool _sameModelIdentities(List<model.Model> left, List<model.Model> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (!identical(left[index], right[index])) return false;
  }
  return true;
}
