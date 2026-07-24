import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/database/database_provider.dart';
import '../../../core/models/model.dart' as model;
import '../../../core/persistence/persistence_keys.dart';
import '../../../core/persistence/preferences_store.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/secure_credential_storage.dart';
import '../../../core/services/socket_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../auth/providers/unified_auth_providers.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';
import '../models/ollama_keep_alive.dart';
import '../models/ollama_thinking.dart';
import '../models/openwebui_direct_connection.dart';
import '../services/direct_adapter_helpers.dart';
import '../services/direct_connection_profile_store.dart';
import '../services/direct_http_client.dart';
import '../services/direct_model_registry.dart';
import '../services/direct_provider_adapter.dart';
import '../services/direct_run_registry.dart';
import '../services/ollama_adapter.dart';
import '../services/openwebui_direct_connection_store.dart';
import '../services/openwebui_direct_completion_relay.dart';
import '../services/openai_compatible_adapter.dart';

export '../services/direct_connection_profile_store.dart'
    show DirectConnectionProfileConflictException;
export '../services/openwebui_direct_connection_store.dart'
    show
        OpenWebUiDirectConnectionCommitUncertainException,
        OpenWebUiDirectConnectionConflictException;

part 'direct_connection_providers.g.dart';

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

/// Durable device secret used to authenticate app-owned Direct identities.
///
/// The HMAC key is persisted only in platform secure storage and is held in
/// memory while deriving domain-separated identities. Open WebUI persists its
/// provider-facing model id for server-backed chats, so this device-local key
/// does not affect cross-device history/model rebinding.
final directDeviceTrustKeyProvider = FutureProvider<List<int>>(
  (ref) => SecureCredentialStorage(
    instance: ref.watch(secureStorageProvider),
  ).getOrCreateOpenWebUiDirectIdentityKey(),
);

/// Compatibility name retained for the Open WebUI record-identity callers.
final openWebUiDirectIdentityKeyProvider = directDeviceTrustKeyProvider;

/// Ephemeral Open WebUI profile source for the exact authenticated account.
///
/// Returning `null` is intentional when the active server disables direct
/// connections or the Open WebUI ownership boundary is incomplete. Server
/// credentials are never copied into Conduit's device profile store.
final openWebUiDirectConnectionStoreProvider =
    Provider<OpenWebUiDirectConnectionStore?>((ref) {
      final isAuthenticated = ref.watch(isAuthenticatedProvider2);
      final token = ref.watch(authTokenProvider3);
      final userId = ref.watch(currentUserProvider2.select((user) => user?.id));
      // Recreate the store on same-server session transitions so late reads
      // can be rejected by object identity even when the API instance survives.
      ref.watch(openWebUiAuthSessionEpochProvider);
      // The shared ownership fence includes database certification. Watch both
      // values so a certification transition creates a fresh captured fence.
      ref.watch(openWebUiDatabaseAccessProvider);
      ref.watch(openWebUiCertifiedDatabaseServerProvider);
      if (!isAuthenticated ||
          token == null ||
          token.isEmpty ||
          userId == null) {
        return null;
      }
      final identityKey = ref.watch(openWebUiDirectIdentityKeyProvider).value;
      if (identityKey == null) return null;

      final api = ref.watch(apiServiceProvider);
      final activeServerId = ref.watch(
        activeServerProvider.select((server) => server.value?.id),
      );
      final backendCapability = ref.watch(
        backendConfigProvider.select(
          (config) => (
            serverId: config.value?.serverId,
            enableDirectConnections:
                config.value?.enableDirectConnections ?? false,
          ),
        ),
      );
      final ownership = api == null
          ? null
          : captureOpenWebUiCacheOwnership(ref, api: api);
      if (api == null ||
          activeServerId != api.serverConfig.id ||
          backendCapability.serverId != api.serverConfig.id ||
          !backendCapability.enableDirectConnections ||
          ownership == null) {
        return null;
      }
      final authSnapshot = api.captureAuthSnapshot();

      return OpenWebUiDirectConnectionStore(
        serverId: api.serverConfig.id,
        accountId: userId,
        identityKey: identityKey,
        serializeSettingsMutation: api.serializeUserSettingsMutation,
        readSettings: () async {
          if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) {
            throw StateError('Open WebUI settings ownership changed.');
          }
          final settings = await api.getUserSettings(
            authSnapshot: authSnapshot,
          );
          if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) {
            throw StateError('Open WebUI settings ownership changed.');
          }
          return settings;
        },
        writeSettings: (settings) async {
          if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) {
            throw StateError('Open WebUI settings ownership changed.');
          }
          await api.updateUserSettings(settings, authSnapshot: authSnapshot);
          if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) {
            throw StateError('Open WebUI settings ownership changed.');
          }
        },
      );
    });

final openWebUiDirectConnectionsAvailableProvider = Provider<bool>(
  (ref) => ref.watch(openWebUiDirectConnectionStoreProvider) != null,
);

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

@Riverpod(keepAlive: true)
DirectHttpClientPool directHttpClientPool(Ref ref) {
  final pool = DirectHttpClientPool();
  ref.onDispose(pool.dispose);
  return pool;
}

typedef _DirectProfileMutationResources = ({
  DirectConnectionProfileStore store,
  DirectHttpClientPool clientPool,
  DirectModelRegistry modelRegistry,
  DirectRunRegistry runRegistry,
});

final directProviderAdapterRegistryProvider =
    Provider<DirectProviderAdapterRegistry>((ref) {
      final pool = ref.watch(directHttpClientPoolProvider);
      return DirectProviderAdapterRegistry([
        OpenAiCompatibleAdapter(clientPool: pool),
        OllamaAdapter(clientPool: pool),
      ]);
    });

class DirectConnectionProfilesController
    extends AsyncNotifier<List<DirectConnectionProfile>> {
  Future<void> _mutationQueue = Future<void>.value();
  bool _appDataClearBlocked = false;
  bool _durableLogoutFenceBlocked = false;
  List<DirectConnectionProfile>? _profilesBeforeAppDataClear;

  bool get _mutationsBlocked =>
      _appDataClearBlocked || _durableLogoutFenceBlocked;

  DirectConnectionProfileStore get _store =>
      ref.read(directConnectionProfileStoreProvider);

  @override
  Future<List<DirectConnectionProfile>> build() {
    _durableLogoutFenceBlocked = ref.watch(incompleteLogoutFenceProvider);
    if (_durableLogoutFenceBlocked) {
      ref.read(directRunRegistryProvider).blockAdmissionForAppDataClear();
      return Future.value(const []);
    }
    if (_appDataClearBlocked) {
      ref.read(directRunRegistryProvider).blockAdmissionForAppDataClear();
      return Future.value(
        _profilesBeforeAppDataClear ?? const <DirectConnectionProfile>[],
      );
    }
    ref.read(directRunRegistryProvider).resumeAdmissionAfterAppDataClearAbort();
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
  }) async {
    final resources = _captureMutationResources();
    await _serializeMutation(
      () => _upsert(
        profile,
        resources: resources,
        expectedPrevious: expectedPrevious,
        secretsConfirmedForNewOrigin: secretsConfirmedForNewOrigin,
      ),
    );
  }

  Future<void> _upsert(
    DirectConnectionProfile profile, {
    required _DirectProfileMutationResources resources,
    DirectConnectionProfile? expectedPrevious,
    bool secretsConfirmedForNewOrigin = false,
  }) async {
    _ensureMounted();
    profile.validate();
    final current = state.value ?? await resources.store.load();
    final index = current.indexWhere((item) => item.id == profile.id);
    final previous = index < 0 ? null : current[index];
    late final List<DirectConnectionProfile> persisted;
    try {
      persisted = await resources.store.upsert(
        profile,
        expectedPrevious: expectedPrevious,
        secretsConfirmedForNewOrigin: secretsConfirmedForNewOrigin,
      );
    } on DirectConnectionProfileConflictException catch (conflict) {
      _publishConflictWinner(
        previous: current,
        persisted: conflict.currentProfiles,
        resources: resources,
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
      _invalidateDirectProfileTransportBestEffort(
        resources.clientPool,
        profile.id,
      );
      _removeProfileModelsBestEffort(resources.modelRegistry, profile.id);
    }
    if (ref.mounted) state = AsyncValue.data(persisted);
    if (transportChanged) {
      _cancelProfileRunsBestEffort(resources.runRegistry, profile.id);
    }
  }

  void _publishConflictWinner({
    required List<DirectConnectionProfile> previous,
    required List<DirectConnectionProfile> persisted,
    required _DirectProfileMutationResources resources,
  }) {
    final persistedById = <String, DirectConnectionProfile>{
      for (final profile in persisted) profile.id: profile,
    };
    final invalidatedProfileIds = <String>{};
    for (final oldProfile in previous) {
      final nextProfile = persistedById[oldProfile.id];
      if (nextProfile == null || _transportChanged(oldProfile, nextProfile)) {
        invalidatedProfileIds.add(oldProfile.id);
        _invalidateDirectProfileTransportBestEffort(
          resources.clientPool,
          oldProfile.id,
        );
        _removeProfileModelsBestEffort(resources.modelRegistry, oldProfile.id);
      }
    }
    if (ref.mounted) state = AsyncValue.data(persisted);
    for (final profileId in invalidatedProfileIds) {
      _cancelProfileRunsBestEffort(resources.runRegistry, profileId);
    }
  }

  Future<void> remove(String profileId) async {
    final resources = _captureMutationResources();
    await _serializeMutation(() async {
      _ensureMounted();
      final current = state.value ?? await resources.store.load();
      final updated = current
          .where((profile) => profile.id != profileId)
          .toList(growable: false);
      if (updated.length == current.length) return;
      final persisted = await resources.store.save(updated);
      _invalidateDirectProfileTransportBestEffort(
        resources.clientPool,
        profileId,
      );
      _removeProfileModelsBestEffort(resources.modelRegistry, profileId);
      if (ref.mounted) state = AsyncValue.data(persisted);
      _cancelProfileRunsBestEffort(resources.runRegistry, profileId);
    });
  }

  Future<void> setEnabled(String profileId, bool enabled) async {
    final resources = _captureMutationResources();
    await _serializeMutation(() async {
      _ensureMounted();
      final current = state.value ?? await resources.store.load();
      final profile = current.where((item) => item.id == profileId).firstOrNull;
      if (profile == null) {
        throw StateError('Direct connection profile not found.');
      }
      await _upsert(profile.copyWith(enabled: enabled), resources: resources);
    });
  }

  Future<void> setOllamaThinking(
    String profileId,
    String remoteModelId,
    OllamaThinkingSetting? setting,
  ) async {
    final resources = _captureMutationResources();
    await _serializeMutation(() async {
      _ensureMounted();
      final modelId = remoteModelId.trim();
      if (modelId.isEmpty) {
        throw const FormatException('Ollama model id is missing.');
      }
      final current = state.value ?? await resources.store.load();
      final profile = current
          .where(
            (item) =>
                item.id == profileId &&
                item.enabled &&
                item.adapterKey == kOllamaAdapterKey,
          )
          .firstOrNull;
      if (profile == null) {
        throw StateError('Ollama connection is unavailable.');
      }
      final settings = Map<String, String>.of(profile.ollamaThinkingByModel);
      if (setting == null) {
        settings.remove(modelId);
      } else {
        settings[modelId] = setting.storageValue;
      }
      await _upsert(
        profile.copyWith(ollamaThinkingByModel: settings),
        resources: resources,
        expectedPrevious: profile,
      );
    });
  }

  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async {
    _ensureMounted();
    if (_mutationsBlocked) {
      throw StateError(
        'Direct connection probes are blocked while app data is being cleared.',
      );
    }
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

  Future<void> reload() async {
    final resources = _captureMutationResources();
    await _serializeMutation(() => _reload(resources));
  }

  Future<void> _reload(_DirectProfileMutationResources resources) async {
    _ensureMounted();
    final previous = state.value;
    state = const AsyncValue.loading();
    final next = await AsyncValue.guard(resources.store.load);
    if (!ref.mounted) return;
    if (previous != null && next.hasError) {
      for (final profile in previous) {
        _invalidateDirectProfileTransportBestEffort(
          resources.clientPool,
          profile.id,
        );
        _removeProfileModelsBestEffort(resources.modelRegistry, profile.id);
      }
      for (final profile in previous) {
        _cancelProfileRunsBestEffort(resources.runRegistry, profile.id);
      }
      // Preserve no alternate in-memory source on a secure-storage outage: the
      // error state makes the outage visible and prevents unsafe edits.
      state = next;
      return;
    }
    final nextProfiles = next.value ?? const <DirectConnectionProfile>[];
    final nextById = <String, DirectConnectionProfile>{
      for (final profile in nextProfiles) profile.id: profile,
    };
    final invalidatedProfileIds = <String>{};
    if (previous != null) {
      for (final oldProfile in previous) {
        final newProfile = nextById[oldProfile.id];
        if (newProfile == null || _transportChanged(oldProfile, newProfile)) {
          invalidatedProfileIds.add(oldProfile.id);
          _invalidateDirectProfileTransportBestEffort(
            resources.clientPool,
            oldProfile.id,
          );
          _removeProfileModelsBestEffort(
            resources.modelRegistry,
            oldProfile.id,
          );
        }
      }
    }
    state = next;
    if (invalidatedProfileIds.isNotEmpty) {
      for (final profileId in invalidatedProfileIds) {
        _cancelProfileRunsBestEffort(resources.runRegistry, profileId);
      }
    }
  }

  Future<void> clear() async {
    final resources = _captureMutationResources();
    await _serializeMutation(() async {
      _ensureMounted();
      final current = state.value ?? await resources.store.load();
      await resources.store.clear();
      for (final profile in current) {
        _invalidateDirectProfileTransportBestEffort(
          resources.clientPool,
          profile.id,
        );
        _removeProfileModelsBestEffort(resources.modelRegistry, profile.id);
      }
      if (ref.mounted) state = const AsyncValue.data([]);
      for (final profile in current) {
        _cancelProfileRunsBestEffort(resources.runRegistry, profile.id);
      }
    });
  }

  /// Rejects new profile mutations and waits for already-queued writes to
  /// settle before a full app-data wipe.
  Future<void> blockMutationsForAppDataClear() async {
    _ensureMounted();
    _appDataClearBlocked = true;
    await _mutationQueue;
    if (!ref.mounted) return;
    final profiles = state.value ?? await _store.load();
    if (!ref.mounted) return;
    _profilesBeforeAppDataClear ??= profiles;
  }

  /// Restores mutation admission when a newer authenticated session wins the
  /// ownership race and the app-data wipe is abandoned.
  void resumeMutationsAfterAppDataClearAbort() {
    if (ref.mounted) {
      _appDataClearBlocked = false;
      final runRegistry = ref.read(directRunRegistryProvider);
      if (_durableLogoutFenceBlocked) {
        runRegistry.blockAdmissionForAppDataClear();
      } else {
        runRegistry.resumeAdmissionAfterAppDataClearAbort();
      }
      final previous = _profilesBeforeAppDataClear;
      if (previous != null) {
        state = AsyncValue.data(previous);
        _profilesBeforeAppDataClear = null;
      }
    }
  }

  /// Drops every in-memory transport authority after a partial wipe while the
  /// durable incomplete-logout fence keeps the controller blocked.
  void revokeRuntimeAfterIncompleteAppDataClear() {
    if (!ref.mounted) return;
    // The durable logout fence now owns the long-lived block. Releasing the
    // transient preparation flag lets a later successful login resume this
    // controller when that durable fence is cleared.
    _appDataClearBlocked = false;
    _profilesBeforeAppDataClear = null;
    final current = state.value ?? const <DirectConnectionProfile>[];
    final clientPool = ref.read(directHttpClientPoolProvider);
    final modelRegistry = ref.read(directModelRegistryProvider);
    final runRegistry = ref.read(directRunRegistryProvider);
    for (final profile in current) {
      _invalidateDirectProfileTransportBestEffort(clientPool, profile.id);
      _removeProfileModelsBestEffort(modelRegistry, profile.id);
      _cancelProfileRunsBestEffort(runRegistry, profile.id);
    }
    state = const AsyncValue.data([]);
  }

  _DirectProfileMutationResources _captureMutationResources() {
    _ensureMounted();
    if (_mutationsBlocked) {
      throw StateError(
        'Direct connection changes are unavailable while signing out.',
      );
    }
    return (
      store: _store,
      clientPool: ref.read(directHttpClientPoolProvider),
      modelRegistry: ref.read(directModelRegistryProvider),
      runRegistry: ref.read(directRunRegistryProvider),
    );
  }

  void _ensureMounted() {
    if (!ref.mounted) {
      throw StateError('Direct connection profile controller is disposed.');
    }
  }

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

final class OllamaModelLifecycleState {
  OllamaModelLifecycleState({
    Iterable<String> loadedModelIds = const [],
    Iterable<String> busyModelIds = const [],
  }) : loadedModelIds = Set.unmodifiable(loadedModelIds),
       busyModelIds = Set.unmodifiable(busyModelIds);

  final Set<String> loadedModelIds;
  final Set<String> busyModelIds;

  bool isLoaded(String remoteModelId) => loadedModelIds.contains(remoteModelId);

  bool isBusy(String remoteModelId) => busyModelIds.contains(remoteModelId);

  OllamaModelLifecycleState copyWith({
    Iterable<String>? loadedModelIds,
    Iterable<String>? busyModelIds,
  }) => OllamaModelLifecycleState(
    loadedModelIds: loadedModelIds ?? this.loadedModelIds,
    busyModelIds: busyModelIds ?? this.busyModelIds,
  );
}

/// Runtime status and lifecycle actions for one device-owned Ollama profile.
///
/// The family auto-disposes when no model selector is visible, so `/api/ps`
/// does not become a background polling request.
@riverpod
class OllamaModelLifecycle extends _$OllamaModelLifecycle {
  int _operationGeneration = 0;

  @override
  Future<OllamaModelLifecycleState> build(String profileId) async {
    final profile = await _watchProfile();
    final adapter = _requireLifecycleAdapter(profile);
    final loaded = await adapter.listRunningModelIds(profile);
    return OllamaModelLifecycleState(loadedModelIds: loaded);
  }

  Future<void> refresh() async {
    final generation = ++_operationGeneration;
    final previous = state.value ?? OllamaModelLifecycleState();
    try {
      final profile = await _readProfile();
      final loaded = await _requireLifecycleAdapter(
        profile,
      ).listRunningModelIds(profile);
      if (ref.mounted && generation == _operationGeneration) {
        final latest = state.value ?? previous;
        state = AsyncData(latest.copyWith(loadedModelIds: loaded));
      }
    } catch (_) {
      if (ref.mounted) {
        state = AsyncData(state.value ?? previous);
      }
      rethrow;
    }
  }

  Future<void> loadModel(String remoteModelId) => _mutateModel(remoteModelId, (
    adapter,
    profile,
    modelId,
  ) {
    final configured = profile.ollamaKeepAliveFor(modelId);
    // `0` means unload after the request, which conflicts with an explicit
    // warm action. Warm for the server default instead; ordinary chats still
    // honor the saved zero override.
    final warmKeepAlive = configured == '0' ? null : configured;
    return adapter.loadModel(profile, modelId, keepAlive: warmKeepAlive);
  });

  Future<void> unloadModel(String remoteModelId) => _mutateModel(
    remoteModelId,
    (adapter, profile, modelId) => adapter.unloadModel(profile, modelId),
  );

  Future<void> setKeepAlive(String remoteModelId, String? keepAlive) async {
    final modelId = remoteModelId.trim();
    if (modelId.isEmpty) {
      throw const FormatException('Ollama model id is missing.');
    }
    final normalized = keepAlive == null
        ? null
        : normalizeOllamaKeepAlive(keepAlive);
    final profile = await _readProfile();
    final updated = Map<String, String>.of(profile.ollamaKeepAliveByModel);
    if (normalized == null) {
      updated.remove(modelId);
    } else {
      updated[modelId] = normalized;
    }
    await ref
        .read(directConnectionProfilesProvider.notifier)
        .upsert(
          profile.copyWith(ollamaKeepAliveByModel: updated),
          expectedPrevious: profile,
        );
  }

  Future<void> _mutateModel(
    String remoteModelId,
    Future<void> Function(
      DirectModelLifecycleAdapter adapter,
      DirectConnectionProfile profile,
      String modelId,
    )
    operation,
  ) async {
    final modelId = remoteModelId.trim();
    if (modelId.isEmpty) {
      throw const FormatException('Ollama model id is missing.');
    }
    ++_operationGeneration;
    final previous = state.value ?? OllamaModelLifecycleState();
    state = AsyncData(
      previous.copyWith(busyModelIds: {...previous.busyModelIds, modelId}),
    );
    try {
      final profile = await _readProfile();
      final adapter = _requireLifecycleAdapter(profile);
      await operation(adapter, profile, modelId);
      final loaded = await adapter.listRunningModelIds(profile);
      if (ref.mounted) {
        final latest = state.value ?? previous;
        state = AsyncData(
          latest.copyWith(
            // Each mutation finishes with a new `/api/ps` read. Even if a
            // later-started operation completed first, this response is the
            // newest authoritative snapshot to arrive.
            loadedModelIds: loaded,
            busyModelIds: latest.busyModelIds.difference({modelId}),
          ),
        );
      }
    } catch (_) {
      if (ref.mounted) {
        final latest = state.value ?? previous;
        state = AsyncData(
          latest.copyWith(
            busyModelIds: latest.busyModelIds.difference({modelId}),
          ),
        );
      }
      rethrow;
    }
  }

  Future<DirectConnectionProfile> _watchProfile() async {
    final profiles = await ref.watch(directConnectionProfilesProvider.future);
    return _findProfile(profiles);
  }

  Future<DirectConnectionProfile> _readProfile() async {
    final profiles = await ref.read(directConnectionProfilesProvider.future);
    return _findProfile(profiles);
  }

  DirectConnectionProfile _findProfile(List<DirectConnectionProfile> profiles) {
    final profile = profiles
        .where(
          (item) =>
              item.id == profileId &&
              item.enabled &&
              item.supportsOllamaModelLifecycle,
        )
        .firstOrNull;
    if (profile == null) {
      throw StateError('Ollama direct connection is unavailable.');
    }
    return profile;
  }

  DirectModelLifecycleAdapter _requireLifecycleAdapter(
    DirectConnectionProfile profile,
  ) {
    final adapter = ref
        .read(directProviderAdapterRegistryProvider)
        .require(profile.adapterKey);
    if (adapter is! DirectModelLifecycleAdapter) {
      throw StateError('Ollama model lifecycle is unavailable.');
    }
    return adapter as DirectModelLifecycleAdapter;
  }
}

typedef _OpenWebUiMutationSource = ({
  OpenWebUiDirectConnectionStore store,
  OpenWebUiDirectConnectionsSnapshot snapshot,
  _DirectTransportCleanupResources cleanup,
});

typedef _DirectTransportCleanupResources = ({
  DirectHttpClientPool clientPool,
  DirectModelRegistry modelRegistry,
  DirectRunRegistry runRegistry,
});

/// Owns the ephemeral direct connections loaded for the current Open WebUI
/// authentication session.
///
/// These profiles deliberately never pass through [DirectConnectionProfileStore].
/// A dependency-triggered rebuild revokes the previous store's routing authority
/// synchronously, before the next account/server request is allowed to publish.
class OpenWebUiDirectConnectionsController
    extends AsyncNotifier<OpenWebUiDirectConnectionsSnapshot?> {
  Future<void> _mutationQueue = Future<void>.value();
  OpenWebUiDirectConnectionStore? _publishedStore;
  OpenWebUiDirectConnectionsSnapshot? _publishedSnapshot;
  int _loadGeneration = 0;

  @override
  Future<OpenWebUiDirectConnectionsSnapshot?> build() async {
    final generation = ++_loadGeneration;
    final cleanup = _captureCleanupResources();
    final store = ref.watch(openWebUiDirectConnectionStoreProvider);
    if (!identical(store, _publishedStore)) {
      _replacePublishedSnapshot(
        null,
        store: null,
        cleanup: cleanup,
        publishState: false,
      );
    }
    if (store == null) return null;

    final snapshot = await store.load();
    if (!_storeIsCurrent(store) || generation != _loadGeneration) {
      return _publishedSnapshot;
    }
    _replacePublishedSnapshot(
      snapshot,
      store: store,
      cleanup: cleanup,
      publishState: false,
    );
    return snapshot;
  }

  Future<void> reload() {
    if (!ref.mounted) return _unavailableMutation();
    final generation = ++_loadGeneration;
    final capturedStore = ref.read(openWebUiDirectConnectionStoreProvider);
    final cleanup = _captureCleanupResources();
    return _serializeMutation(() async {
      if (!ref.mounted) return;
      if (generation != _loadGeneration) return;
      if (capturedStore == null) {
        if (ref.read(openWebUiDirectConnectionStoreProvider) != null) return;
        _replacePublishedSnapshot(null, store: null, cleanup: cleanup);
        return;
      }
      if (!_storeIsCurrent(capturedStore)) return;

      try {
        final snapshot = await capturedStore.load();
        if (!_storeIsCurrent(capturedStore) || generation != _loadGeneration) {
          return;
        }
        _replacePublishedSnapshot(
          snapshot,
          store: capturedStore,
          cleanup: cleanup,
        );
      } catch (error, stackTrace) {
        if (!_storeIsCurrent(capturedStore) || generation != _loadGeneration) {
          return;
        }
        _replacePublishedSnapshot(
          null,
          store: capturedStore,
          cleanup: cleanup,
          publishState: false,
        );
        state = AsyncError<OpenWebUiDirectConnectionsSnapshot?>(
          error,
          stackTrace,
        );
      }
    });
  }

  Future<void> add(DirectConnectionProfile profile, {String? authType}) {
    // Bind the user's intent to this account, but capture its latest document
    // only after earlier mutations have finished.
    final expectedStore = _publishedStore;
    if (expectedStore == null) return _unavailableMutation();
    return _serializeMutation(() {
      final source = _captureMutationSource();
      if (source == null) return _unavailableMutation();
      if (!identical(source.store, expectedStore)) {
        return Future<void>.error(
          StateError('Open WebUI direct connection ownership changed.'),
        );
      }
      return _mutate(
        source.store,
        source.snapshot,
        source.cleanup,
        (store, current) => store.add(
          profile,
          authType: authType,
          expectedDocumentRevision: current?.documentRevision,
        ),
      );
    });
  }

  Future<void> updateConnection(
    OpenWebUiDirectConnectionRecord record,
    DirectConnectionProfile profile, {
    String? authType,
  }) {
    final source = _captureMutationSource();
    if (source == null) return _unavailableMutation();
    return _serializeMutation(
      () => _mutate(
        source.store,
        source.snapshot,
        source.cleanup,
        (store, _) => store.update(
          record,
          profile,
          authType: authType,
          expectedRevision: record.revision,
        ),
      ),
    );
  }

  Future<void> delete(OpenWebUiDirectConnectionRecord record) {
    final source = _captureMutationSource();
    if (source == null) return _unavailableMutation();
    return _serializeMutation(
      () => _mutate(
        source.store,
        source.snapshot,
        source.cleanup,
        (store, _) => store.delete(record, expectedRevision: record.revision),
      ),
    );
  }

  _OpenWebUiMutationSource? _captureMutationSource() {
    if (!ref.mounted) return null;
    final store = ref.read(openWebUiDirectConnectionStoreProvider);
    final snapshot = _publishedSnapshot;
    if (store == null ||
        snapshot == null ||
        !identical(store, _publishedStore)) {
      return null;
    }
    return (
      store: store,
      snapshot: snapshot,
      cleanup: _captureCleanupResources(),
    );
  }

  Future<void> _unavailableMutation() => Future<void>.error(
    StateError('Open WebUI direct connections are unavailable.'),
  );

  Future<void> _mutate(
    OpenWebUiDirectConnectionStore store,
    OpenWebUiDirectConnectionsSnapshot? capturedSnapshot,
    _DirectTransportCleanupResources cleanup,
    Future<OpenWebUiDirectConnectionsSnapshot> Function(
      OpenWebUiDirectConnectionStore store,
      OpenWebUiDirectConnectionsSnapshot? current,
    )
    operation,
  ) async {
    if (!_storeIsCurrent(store) || !identical(store, _publishedStore)) {
      throw StateError('Open WebUI direct connection ownership changed.');
    }
    try {
      final snapshot = await operation(store, capturedSnapshot);
      if (!_storeIsCurrent(store)) return;
      _replacePublishedSnapshot(snapshot, store: store, cleanup: cleanup);
    } on OpenWebUiDirectConnectionConflictException catch (conflict) {
      if (_storeIsCurrent(store)) {
        _replacePublishedSnapshot(
          conflict.currentSnapshot,
          store: store,
          cleanup: cleanup,
        );
      }
      rethrow;
    } on OpenWebUiDirectConnectionCommitUncertainException catch (
      error,
      stackTrace
    ) {
      if (_storeIsCurrent(store)) {
        // The POST may have changed connection indexes or credentials. Revoke
        // the old snapshot and require a fresh GET before another mutation.
        _replacePublishedSnapshot(
          null,
          store: store,
          cleanup: cleanup,
          publishState: false,
        );
        state = AsyncError<OpenWebUiDirectConnectionsSnapshot?>(
          error,
          stackTrace,
        );
      }
      rethrow;
    }
  }

  bool _storeIsCurrent(OpenWebUiDirectConnectionStore store) =>
      ref.mounted &&
      identical(ref.read(openWebUiDirectConnectionStoreProvider), store);

  void _replacePublishedSnapshot(
    OpenWebUiDirectConnectionsSnapshot? next, {
    required OpenWebUiDirectConnectionStore? store,
    required _DirectTransportCleanupResources cleanup,
    bool publishState = true,
  }) {
    final previous = _publishedSnapshot;
    final nextById = <String, OpenWebUiDirectConnectionRecord>{
      for (final record
          in next?.records ?? const <OpenWebUiDirectConnectionRecord>[])
        if (record.isCompatible) record.profile.id: record,
    };
    final invalidatedProfileIds = <String>{};
    if (previous != null) {
      for (final oldRecord in previous.records) {
        if (!oldRecord.isCompatible) continue;
        final oldProfile = oldRecord.profile;
        final newRecord = nextById[oldProfile.id];
        if (newRecord == null ||
            newRecord.index != oldRecord.index ||
            _transportChanged(oldProfile, newRecord.profile)) {
          invalidatedProfileIds.add(oldProfile.id);
          _invalidateDirectProfileTransportBestEffort(
            cleanup.clientPool,
            oldProfile.id,
          );
          _removeDirectProfileModelsBestEffort(
            cleanup.modelRegistry,
            oldProfile.id,
          );
        }
      }
    }

    _publishedStore = store;
    _publishedSnapshot = next;
    if (publishState && ref.mounted) state = AsyncData(next);

    if (invalidatedProfileIds.isNotEmpty) {
      for (final profileId in invalidatedProfileIds) {
        _cancelDirectProfileRunsBestEffort(cleanup.runRegistry, profileId);
      }
    }
  }

  _DirectTransportCleanupResources _captureCleanupResources() {
    if (!ref.mounted) {
      throw StateError('Open WebUI direct connection controller is disposed.');
    }
    return (
      clientPool: ref.read(directHttpClientPoolProvider),
      modelRegistry: ref.read(directModelRegistryProvider),
      runRegistry: ref.read(directRunRegistryProvider),
    );
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

final openWebUiDirectConnectionsProvider =
    AsyncNotifierProvider<
      OpenWebUiDirectConnectionsController,
      OpenWebUiDirectConnectionsSnapshot?
    >(OpenWebUiDirectConnectionsController.new);

const int _maxConcurrentOpenWebUiDirectRelays = 8;

typedef OpenWebUiDirectCompletionRelayFactory =
    OpenWebUiDirectCompletionRelay Function({
      required OpenWebUiDirectChannelEmitter emitChannel,
    });

final openWebUiDirectCompletionRelayFactoryProvider =
    Provider<OpenWebUiDirectCompletionRelayFactory>((ref) {
      final pool = ref.watch(directHttpClientPoolProvider);
      return ({required emitChannel}) => OpenWebUiDirectCompletionRelay(
        emitChannel: emitChannel,
        clientPool: pool,
      );
    });

/// Global Socket.IO handler for Open WebUI's client-side direct-completion RPC.
///
/// Upstream installs this at layout/session scope rather than inside one chat
/// stream. Keeping the same lifetime ensures the handler is ready before
/// `/api/chat/completions` starts a background task that waits for its RPC ACK.
final openWebUiDirectCompletionSocketRelayProvider = Provider<void>((ref) {
  final socket = ref.watch(socketServiceProvider);
  final api = ref.watch(apiServiceProvider);
  final authSessionEpoch = ref.watch(openWebUiAuthSessionEpochProvider);
  final store = ref.watch(openWebUiDirectConnectionStoreProvider);
  final relayFactory = ref.watch(openWebUiDirectCompletionRelayFactoryProvider);
  if (socket == null ||
      api == null ||
      store == null ||
      socket.serverConfig.id != api.serverConfig.id ||
      store.serverId != api.serverConfig.id) {
    return;
  }

  // Start the snapshot load without making AsyncValue refreshes part of this
  // Socket.IO handler's ownership. Requests read the latest published snapshot
  // below, while the stable store identity owns in-flight relays.
  ref.read(openWebUiDirectConnectionsProvider);

  final activeRuns = <String, OpenWebUiDirectCompletionRelayRun>{};
  // Keep every lease by run identity, not only the latest channel owner. A
  // defensive same-channel replacement can occur through a re-entrant relay
  // factory before the first handler publishes [activeRuns]. Provider teardown
  // must still release both leases if either terminal future never settles.
  final activeRunLeases = <SocketBackgroundActivityLease>{};
  var ownerDisposed = false;

  OpenWebUiDirectConnectionsSnapshot? currentSnapshot() {
    if (!ref.mounted ||
        !identical(store, ref.read(openWebUiDirectConnectionStoreProvider))) {
      return null;
    }
    final snapshot = ref.read(openWebUiDirectConnectionsProvider).value;
    if (snapshot == null ||
        snapshot.serverId != store.serverId ||
        snapshot.accountId != store.accountId) {
      return null;
    }
    return snapshot;
  }

  bool ownsCapturedSession() =>
      !ownerDisposed &&
      identical(socket, ref.read(socketServiceProvider)) &&
      identical(api, ref.read(apiServiceProvider)) &&
      identical(
        authSessionEpoch,
        ref.read(openWebUiAuthSessionEpochProvider),
      ) &&
      identical(store, ref.read(openWebUiDirectConnectionStoreProvider));

  bool ownsCapturedSnapshot(String documentRevision) =>
      ownsCapturedSession() &&
      currentSnapshot()?.documentRevision == documentRevision;

  void cancelActiveRuns(String reason) {
    final runs = activeRuns.values.toList(growable: false);
    for (final run in runs) {
      unawaited(run.cancel(reason));
    }
  }

  void rejectRpc(void Function(dynamic)? acknowledge, String message) {
    if (acknowledge == null) return;
    try {
      acknowledge(<String, dynamic>{'status': false, 'error': message});
    } catch (_) {}
  }

  ref.listen<AsyncValue<OpenWebUiDirectConnectionsSnapshot?>>(
    openWebUiDirectConnectionsProvider,
    (previous, next) {
      final previousRevision = previous?.value?.documentRevision;
      final nextRevision = next.value?.documentRevision;
      if (previousRevision == null || previousRevision == nextRevision) return;
      cancelActiveRuns('Direct connection settings changed');
    },
  );

  final subscription = socket.addChatEventHandler(
    requireFocus: false,
    // This session-level listener is idle almost all the time. An admitted run
    // below acquires its own bounded background transport lease.
    keepsAliveInBackground: false,
    handler: (event, acknowledge) {
      final envelope = event['data'];
      if (envelope is! Map || envelope['type'] != 'request:chat:completion') {
        return;
      }
      if (acknowledge == null) return;
      if (!ownsCapturedSession()) {
        rejectRpc(acknowledge, 'The direct connection session changed.');
        return;
      }
      final snapshot = currentSnapshot();
      if (snapshot == null) {
        rejectRpc(acknowledge, 'The direct connection is unavailable.');
        return;
      }

      final rawPayload = envelope['data'];
      if (rawPayload is! Map) {
        rejectRpc(acknowledge, 'Invalid direct-completion request.');
        return;
      }
      Map<String, dynamic> payload;
      try {
        payload = Map<String, dynamic>.from(rawPayload);
      } catch (_) {
        rejectRpc(acknowledge, 'Invalid direct-completion request.');
        return;
      }

      final currentSessionId = socket.sessionId;
      if (!socket.isConnected ||
          currentSessionId == null ||
          payload['session_id'] != currentSessionId) {
        rejectRpc(acknowledge, 'The server socket session changed.');
        return;
      }

      final model = payload['model'];
      final urlIndex = model is Map
          ? _parseOpenWebUiDirectUrlIndex(model['urlIdx'])
          : null;
      final record = urlIndex == null
          ? null
          : snapshot.records
                .where((candidate) => candidate.index == urlIndex)
                .firstOrNull;
      if (record == null ||
          !record.isCompatible ||
          !record.profile.enabled ||
          record.profile.adapterKey != kOpenAiCompatibleAdapterKey) {
        rejectRpc(acknowledge, 'The direct connection is unavailable.');
        return;
      }

      final formData = payload['form_data'];
      final wireModelId = formData is Map
          ? formData['model']?.toString()
          : null;
      if (wireModelId == null || wireModelId.trim().isEmpty) {
        rejectRpc(acknowledge, 'Invalid direct-completion request.');
        return;
      }
      final binding = ref
          .read(directModelRegistryProvider)
          .resolveOpenWebUiWireBinding(
            profileId: record.profile.id,
            urlIndex: record.index,
            wireModelId: wireModelId,
          );
      if (binding == null) {
        rejectRpc(acknowledge, 'The direct model is unavailable.');
        return;
      }

      final channel = payload['channel']?.toString();
      if (channel == null || channel.isEmpty) {
        rejectRpc(acknowledge, 'Invalid direct-completion request.');
        return;
      }
      if (activeRuns.containsKey(channel)) {
        rejectRpc(
          acknowledge,
          'The direct-completion request is already active.',
        );
        return;
      }
      if (activeRuns.length >= _maxConcurrentOpenWebUiDirectRelays) {
        rejectRpc(
          acknowledge,
          'Too many direct-completion requests are active.',
        );
        return;
      }

      try {
        late final OpenWebUiDirectCompletionRelayRun run;
        final relay = relayFactory(
          emitChannel: (eventName, data) {
            final ownsSnapshot = ownsCapturedSnapshot(
              snapshot.documentRevision,
            );
            final mayTerminateCancelledChannel =
                eventName == channel &&
                _isOpenWebUiDirectTerminalPayload(data) &&
                ownsCapturedSession();
            if (!ownsSnapshot && !mayTerminateCancelledChannel) return false;
            return socket.emitForSession(currentSessionId, eventName, data);
          },
        );
        try {
          final backgroundLease = socket.acquireBackgroundActivityLease();
          try {
            run = relay.start(
              profile: record.profile,
              trustedRemoteModelId: binding.remoteModelId,
              trustedUrlIndex: record.index,
              expectedAccountId: snapshot.accountId,
              expectedSessionId: currentSessionId,
              payload: payload,
              acknowledge: acknowledge,
            );
          } catch (_) {
            backgroundLease.dispose();
            rethrow;
          }
          activeRuns[channel] = run;
          activeRunLeases.add(backgroundLease);

          void settleRun() {
            relay.dispose();
            activeRunLeases.remove(backgroundLease);
            backgroundLease.dispose();
            if (identical(activeRuns[channel], run)) {
              activeRuns.remove(channel);
            }
          }

          unawaited(
            run.done.then<void>(
              (_) => settleRun(),
              onError: (Object _, StackTrace _) => settleRun(),
            ),
          );
        } catch (_) {
          relay.dispose();
          rethrow;
        }
      } catch (_) {
        rejectRpc(acknowledge, 'The direct connection is unavailable.');
      }
    },
  );
  final reconnectSubscription = socket.onReconnect.listen((_) {
    cancelActiveRuns('Socket reconnected');
  });
  final healthSubscription = socket.healthStream.listen((health) {
    if (!health.isConnected) cancelActiveRuns('Socket disconnected');
  });

  ref.onDispose(() {
    ownerDisposed = true;
    subscription.dispose();
    unawaited(reconnectSubscription.cancel());
    unawaited(healthSubscription.cancel());
    cancelActiveRuns('Direct relay owner changed');
    // Provider teardown can outlive a broken relay's terminal future. Socket
    // ownership is changing anyway, so release every remaining bounded lease.
    for (final lease in activeRunLeases) {
      lease.dispose();
    }
    activeRunLeases.clear();
    activeRuns.clear();
  });
});

int? _parseOpenWebUiDirectUrlIndex(Object? value) {
  if (value is int) return value >= 0 ? value : null;
  if (value is num && value.isFinite && value == value.truncateToDouble()) {
    final parsed = value.toInt();
    return parsed >= 0 ? parsed : null;
  }
  if (value is String && RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value)) {
    return int.tryParse(value);
  }
  return null;
}

bool _isOpenWebUiDirectTerminalPayload(Object? value) =>
    value is Map && value.length == 1 && value['done'] == true;

/// Runtime view used by discovery, routing, and direct chat dispatch. Server
/// sync failures remain visible on the settings page but do not make healthy
/// device-only connections unavailable.
final effectiveDirectConnectionProfilesProvider =
    Provider<AsyncValue<List<DirectConnectionProfile>>>((ref) {
      final local = ref.watch(directConnectionProfilesProvider);
      // Device profile storage remains the required source. Preserve its
      // loading/error gates even when Riverpod carries a previous value.
      if (local.isLoading) {
        return const AsyncLoading<List<DirectConnectionProfile>>();
      }
      if (local.hasError) {
        return AsyncError(local.error!, local.stackTrace!);
      }
      if (!local.hasValue) {
        return const AsyncLoading<List<DirectConnectionProfile>>();
      }

      final localProfiles = local.requireValue;
      if (!ref.watch(openWebUiDirectConnectionsAvailableProvider)) {
        return AsyncData(localProfiles);
      }

      final remote = ref.watch(openWebUiDirectConnectionsProvider);
      if (remote.isLoading) {
        return localProfiles.isEmpty
            ? const AsyncLoading<List<DirectConnectionProfile>>()
            : AsyncData(localProfiles);
      }
      if (remote.hasError) return AsyncData(localProfiles);
      final remoteProfiles = remote.value?.compatibleProfiles;

      final localIds = localProfiles.map((profile) => profile.id).toSet();
      return AsyncData(<DirectConnectionProfile>[
        ...localProfiles,
        ...?remoteProfiles?.where((profile) => !localIds.contains(profile.id)),
      ]);
    });

/// Awaitable companion that stays reactive to data-to-data profile updates.
final effectiveDirectConnectionProfilesFutureProvider =
    FutureProvider<List<DirectConnectionProfile>>((ref) async {
      final effective = ref.watch(effectiveDirectConnectionProfilesProvider);
      if (effective.hasValue) return effective.requireValue;
      if (effective.hasError) {
        Error.throwWithStackTrace(effective.error!, effective.stackTrace!);
      }

      // Capture every dependency before awaiting. The provider may be disposed
      // while secure storage is still loading, and a late Ref read would then
      // be invalid even though completing the already-owned future is safe.
      final localFuture = ref.watch(directConnectionProfilesProvider.future);
      final remoteAvailable = ref.watch(
        openWebUiDirectConnectionsAvailableProvider,
      );
      final remoteFuture = remoteAvailable
          ? ref.watch(openWebUiDirectConnectionsProvider.future)
          : Future<OpenWebUiDirectConnectionsSnapshot?>.value(null);
      final local = await localFuture;
      if (!remoteAvailable) return local;
      try {
        final remote = await remoteFuture;
        final localIds = local.map((profile) => profile.id).toSet();
        return <DirectConnectionProfile>[
          ...local,
          ...?remote?.compatibleProfiles.where(
            (profile) => !localIds.contains(profile.id),
          ),
        ];
      } catch (_) {
        return local;
      }
    });

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

const int _maxConcurrentDirectProfileDiscoveries = 4;

@Riverpod(keepAlive: true)
_DirectDiscoveryGate _directDiscoveryGate(Ref ref) =>
    _DirectDiscoveryGate(_maxConcurrentDirectProfileDiscoveries);

class DirectModelDiscoveryController
    extends AsyncNotifier<DirectModelDiscoveryState> {
  final Map<String, List<DirectRemoteModel>> _cache = {};
  final Map<String, int> _profileSignatures = {};
  final Map<String, List<model.Model>> _mintedModels = {};
  final Map<String, DirectConnectionProfile> _mintedModelProfiles = {};
  int _discoveryGeneration = 0;
  DirectDiscoveryCancellation? _activeDiscovery;
  Future<void>? _refreshInFlight;
  bool _refreshRequested = false;

  @override
  Future<DirectModelDiscoveryState> build() async {
    // One callback belongs to each provider build lifecycle. Refreshes rotate
    // `_activeDiscovery` without registering additional callbacks; Riverpod
    // clears this callback before a dependency-driven rebuild and the next
    // build installs a fresh one.
    ref.onDispose(() => _activeDiscovery?.cancel());
    final cancellation = _beginDiscoveryGeneration();
    final fallback = state.value ?? DirectModelDiscoveryState();
    // A build-scoped listener is no longer active after this build errors, so
    // keep the error boundary as a watched dependency. This rebuilds discovery
    // when profile storage recovers without duplicating the initial loading
    // publication already owned by the future below.
    ref.watch(
      directConnectionProfilesProvider.select((profiles) => profiles.hasError),
    );
    ref.listen<AsyncValue<List<DirectConnectionProfile>>>(
      effectiveDirectConnectionProfilesProvider,
      (previous, _) {
        if (previous?.asData != null) ref.invalidateSelf();
      },
    );
    try {
      final profiles = await ref.read(
        effectiveDirectConnectionProfilesFutureProvider.future,
      );
      cancellation.throwIfCancelled();
      return await _discover(profiles, cancellation: cancellation);
    } on DirectDiscoveryCancelled {
      return ref.mounted ? state.value ?? fallback : fallback;
    }
  }

  Future<void> refresh() {
    if (!ref.mounted) {
      return Future<void>.error(
        StateError('Direct model discovery controller is disposed.'),
      );
    }
    _refreshRequested = true;
    _activeDiscovery?.cancel();
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;

    // Defer the first pass by one event turn so bursts of UI/system refresh
    // requests collapse into one provider discovery. Requests arriving while
    // that pass is active schedule at most one superseding pass.
    final operation = Future<void>(() => _runRefreshLoop());
    _refreshInFlight = operation;
    return operation;
  }

  Future<void> _runRefreshLoop() async {
    try {
      do {
        _refreshRequested = false;
        await _refreshOnce();
      } while (_refreshRequested && ref.mounted);
    } finally {
      _refreshInFlight = null;
    }
  }

  Future<void> _refreshOnce() async {
    if (!ref.mounted) return;
    final cancellation = _beginDiscoveryGeneration();
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
    try {
      if (ref.read(openWebUiDirectConnectionsAvailableProvider)) {
        try {
          await ref.read(openWebUiDirectConnectionsProvider.notifier).reload();
        } catch (_) {
          cancellation.throwIfCancelled();
          // The synced source exposes its own retry/error state. Keep device
          // profiles usable when that optional refresh fails.
        }
      }
      cancellation.throwIfCancelled();
      final profiles = await ref.read(
        effectiveDirectConnectionProfilesFutureProvider.future,
      );
      cancellation.throwIfCancelled();
      final result = await _discover(profiles, cancellation: cancellation);
      if (_isCurrentDiscovery(cancellation)) {
        state = AsyncValue.data(result);
      }
    } on DirectDiscoveryCancelled {
      // A newer build/refresh owns publication and error reporting.
    } catch (error, stackTrace) {
      if (_isCurrentDiscovery(cancellation)) {
        state = AsyncValue.error(error, stackTrace);
      }
    }
  }

  DirectDiscoveryCancellation _beginDiscoveryGeneration() {
    _activeDiscovery?.cancel();
    final cancellation = DirectDiscoveryCancellation(++_discoveryGeneration);
    _activeDiscovery = cancellation;
    return cancellation;
  }

  bool _isCurrentDiscovery(DirectDiscoveryCancellation cancellation) =>
      ref.mounted &&
      !cancellation.isCancelled &&
      identical(_activeDiscovery, cancellation);

  void _ensureCurrentDiscovery(DirectDiscoveryCancellation cancellation) {
    cancellation.throwIfCancelled();
    if (!ref.mounted || !identical(_activeDiscovery, cancellation)) {
      throw DirectDiscoveryCancelled(cancellation.generation);
    }
  }

  Future<DirectModelDiscoveryState> _discover(
    List<DirectConnectionProfile> allProfiles, {
    required DirectDiscoveryCancellation cancellation,
  }) async {
    _ensureCurrentDiscovery(cancellation);
    final profiles = allProfiles.where((profile) => profile.enabled).toList();
    final activeIds = profiles.map((profile) => profile.id).toSet();
    final localProfileIds =
        ref
            .read(directConnectionProfilesProvider)
            .value
            ?.map((profile) => profile.id)
            .toSet() ??
        const <String>{};
    final openWebUiRecordsByProfileId =
        <String, OpenWebUiDirectConnectionRecord>{
          for (final record
              in ref.read(openWebUiDirectConnectionsProvider).value?.records ??
                  const <OpenWebUiDirectConnectionRecord>[])
            if (record.isCompatible &&
                !localProfileIds.contains(record.profile.id))
              record.profile.id: record,
        };
    final registry = ref.read(directModelRegistryProvider)
      ..retainProfiles(activeIds);
    final adapterRegistry = ref.read(directProviderAdapterRegistryProvider);
    final discoveryGate = ref.read(_directDiscoveryGateProvider);
    _ensureCurrentDiscovery(cancellation);

    // Profile persistence invalidates route bindings before it publishes the
    // new profile list. Hide models whose exact binding is no longer current
    // before waiting for the remaining profiles to finish rediscovery; an
    // unrelated slow provider must not keep a removed/disabled model visible.
    _pruneStaleDiscoveryState(activeIds, registry);

    final outcomes = await Future.wait([
      for (final profile in profiles)
        _discoverProfile(
          profile,
          signature: _profileSignature(profile),
          cancellation: cancellation,
          adapterRegistry: adapterRegistry,
          discoveryGate: discoveryGate,
        ),
    ]);
    _ensureCurrentDiscovery(cancellation);

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
      final openWebUiRecord = openWebUiRecordsByProfileId[outcome.profile.id];
      final source = openWebUiRecord == null
          ? DirectModelSource.device
          : DirectModelSource.openWebUi;
      final canReuseMinted =
          previousMinted != null &&
          previousProfile != null &&
          previousCached != null &&
          listEquals(previousCached, cached) &&
          sameDirectConnectionProfileValues(previousProfile, outcome.profile) &&
          previousMinted.every((item) {
            final binding = registry.resolve(item);
            return binding != null &&
                binding.source == source &&
                binding.openWebUiUrlIndex == openWebUiRecord?.index;
          });
      final profileModels = canReuseMinted
          ? previousMinted
          : registry.replaceProfileModels(
              outcome.profile,
              cached,
              source: source,
              openWebUiUrlIndex: openWebUiRecord?.index,
            );
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
    required DirectDiscoveryCancellation cancellation,
    required DirectProviderAdapterRegistry adapterRegistry,
    required _DirectDiscoveryGate discoveryGate,
  }) async {
    cancellation.throwIfCancelled();
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
    final adapter = adapterRegistry.lookup(profile.adapterKey);
    if (adapter == null) {
      return _DiscoveryOutcome(
        profile: profile,
        signature: signature,
        models: canReuseCache ? _cache[profile.id] : null,
        error: 'Provider adapter is unavailable.',
      );
    }
    try {
      final models = await discoveryGate.run(
        cancellation,
        () => adapter is CancellableDirectModelDiscovery
            ? (adapter as CancellableDirectModelDiscovery)
                  .listModelsCancellable(profile, cancellation: cancellation)
            : adapter.listModels(profile),
      );
      cancellation.throwIfCancelled();
      return _DiscoveryOutcome(
        profile: profile,
        signature: signature,
        models: models,
      );
    } on DirectDiscoveryCancelled {
      rethrow;
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

/// Caps profile-level discovery across overlapping generations. A cancelled
/// caller returns immediately, but its permit remains occupied until an
/// adapter that ignores cancellation actually settles; this keeps the cap
/// truthful even for runtime/third-party adapters.
final class _DirectDiscoveryGate {
  _DirectDiscoveryGate(this.maxConcurrent) {
    if (maxConcurrent <= 0) {
      throw RangeError.value(maxConcurrent, 'maxConcurrent');
    }
  }

  final int maxConcurrent;
  final Queue<_DirectDiscoveryGateWaiter> _waiters =
      Queue<_DirectDiscoveryGateWaiter>();
  int _active = 0;

  Future<T> run<T>(
    DirectDiscoveryCancellation cancellation,
    Future<T> Function() operation,
  ) async {
    await _acquire(cancellation);
    try {
      cancellation.throwIfCancelled();
    } catch (_) {
      _release();
      rethrow;
    }

    final operationFuture = Future<T>.sync(operation);
    var released = false;
    void releaseWhenSettled() {
      if (released) return;
      released = true;
      _release();
    }

    unawaited(
      operationFuture.then<void>(
        (_) => releaseWhenSettled(),
        onError: (Object _, StackTrace _) => releaseWhenSettled(),
      ),
    );
    return Future.any<T>([
      operationFuture,
      cancellation.whenCancelled.then<T>(
        (_) => throw DirectDiscoveryCancelled(cancellation.generation),
      ),
    ]);
  }

  Future<void> _acquire(DirectDiscoveryCancellation cancellation) {
    cancellation.throwIfCancelled();
    if (_active < maxConcurrent) {
      _active++;
      return Future<void>.value();
    }

    final waiter = _DirectDiscoveryGateWaiter(cancellation);
    _waiters.addLast(waiter);
    unawaited(
      cancellation.whenCancelled.then<void>((_) {
        if (_waiters.remove(waiter) && !waiter.completer.isCompleted) {
          waiter.completer.completeError(
            DirectDiscoveryCancelled(cancellation.generation),
          );
        }
      }),
    );
    return waiter.completer.future;
  }

  void _release() {
    assert(_active > 0);
    _active--;
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      if (waiter.cancellation.isCancelled) {
        if (!waiter.completer.isCompleted) {
          waiter.completer.completeError(
            DirectDiscoveryCancelled(waiter.cancellation.generation),
          );
        }
        continue;
      }
      _active++;
      waiter.completer.complete();
      return;
    }
  }
}

final class _DirectDiscoveryGateWaiter {
  _DirectDiscoveryGateWaiter(this.cancellation);

  final DirectDiscoveryCancellation cancellation;
  final Completer<void> completer = Completer<void>();
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

void _invalidateDirectProfileTransportBestEffort(
  DirectHttpClientPool pool,
  String profileId,
) {
  try {
    pool.invalidateProfile(profileId);
  } catch (_) {
    DebugLogger.error(
      'Failed to retire direct HTTP transports',
      scope: 'direct/profiles',
    );
  }
}

bool _sameModelIdentities(List<model.Model> left, List<model.Model> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (!identical(left[index], right[index])) return false;
  }
  return true;
}

void _removeDirectProfileModelsBestEffort(
  DirectModelRegistry registry,
  String profileId,
) {
  try {
    registry.removeProfile(profileId);
  } catch (_) {
    DebugLogger.error(
      'Failed to invalidate synced direct-model bindings',
      scope: 'direct/profiles',
    );
  }
}

void _cancelDirectProfileRunsBestEffort(
  DirectRunRegistry registry,
  String profileId,
) {
  try {
    for (final cancellation in registry.cancelProfile(profileId)) {
      try {
        unawaited(
          cancellation.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {
              DebugLogger.error(
                'Failed to finish synced direct-run cancellation',
                scope: 'direct/profiles',
              );
            },
          ),
        );
      } catch (_) {
        DebugLogger.error(
          'Failed to observe synced direct-run cancellation',
          scope: 'direct/profiles',
        );
      }
    }
  } catch (_) {
    DebugLogger.error(
      'Failed to revoke synced direct runs',
      scope: 'direct/profiles',
    );
  }
}
