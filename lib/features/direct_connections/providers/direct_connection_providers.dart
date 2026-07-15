import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_provider.dart';
import '../../../core/models/model.dart' as model;
import '../../../core/persistence/persistence_keys.dart';
import '../../../core/persistence/preferences_store.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/secure_credential_storage.dart';
import '../../../core/utils/debug_logger.dart';
import '../../auth/providers/unified_auth_providers.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';
import '../models/openwebui_direct_connection.dart';
import '../services/direct_adapter_helpers.dart';
import '../services/direct_connection_profile_store.dart';
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
    if (previous != null && next.hasError) {
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
      final modelRegistry = ref.read(directModelRegistryProvider);
      for (final oldProfile in previous) {
        final newProfile = nextById[oldProfile.id];
        if (newProfile == null || _transportChanged(oldProfile, newProfile)) {
          invalidatedProfileIds.add(oldProfile.id);
          _removeProfileModelsBestEffort(modelRegistry, oldProfile.id);
        }
      }
    }
    state = next;
    if (invalidatedProfileIds.isNotEmpty) {
      final runRegistry = ref.read(directRunRegistryProvider);
      for (final profileId in invalidatedProfileIds) {
        _cancelProfileRunsBestEffort(runRegistry, profileId);
      }
    }
  }

  Future<void> clear() => _serializeMutation(() async {
    final runRegistry = ref.read(directRunRegistryProvider);
    final modelRegistry = ref.read(directModelRegistryProvider);
    final current = state.value ?? await _store.load();
    await _store.clear();
    for (final profile in current) {
      _removeProfileModelsBestEffort(modelRegistry, profile.id);
    }
    if (ref.mounted) state = const AsyncValue.data([]);
    for (final profile in current) {
      _cancelProfileRunsBestEffort(runRegistry, profile.id);
    }
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

typedef _OpenWebUiMutationSource = ({
  OpenWebUiDirectConnectionStore store,
  OpenWebUiDirectConnectionsSnapshot snapshot,
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
    final store = ref.watch(openWebUiDirectConnectionStoreProvider);
    if (!identical(store, _publishedStore)) {
      _replacePublishedSnapshot(null, store: null, publishState: false);
    }
    if (store == null) return null;

    final snapshot = await store.load();
    if (!_storeIsCurrent(store) || generation != _loadGeneration) {
      return _publishedSnapshot;
    }
    _replacePublishedSnapshot(snapshot, store: store, publishState: false);
    return snapshot;
  }

  Future<void> reload() {
    final generation = ++_loadGeneration;
    final capturedStore = ref.read(openWebUiDirectConnectionStoreProvider);
    return _serializeMutation(() async {
      if (generation != _loadGeneration) return;
      if (capturedStore == null) {
        if (ref.read(openWebUiDirectConnectionStoreProvider) != null) return;
        _replacePublishedSnapshot(null, store: null);
        return;
      }
      if (!_storeIsCurrent(capturedStore)) return;

      try {
        final snapshot = await capturedStore.load();
        if (!_storeIsCurrent(capturedStore) || generation != _loadGeneration) {
          return;
        }
        _replacePublishedSnapshot(snapshot, store: capturedStore);
      } catch (error, stackTrace) {
        if (!_storeIsCurrent(capturedStore)) return;
        _replacePublishedSnapshot(
          null,
          store: capturedStore,
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
    final source = _captureMutationSource();
    if (source == null) return _unavailableMutation();
    return _serializeMutation(
      () => _mutate(
        source.store,
        source.snapshot,
        (store, current) => store.add(
          profile,
          authType: authType,
          expectedDocumentRevision: current?.documentRevision,
        ),
      ),
    );
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
        (store, _) => store.delete(record, expectedRevision: record.revision),
      ),
    );
  }

  _OpenWebUiMutationSource? _captureMutationSource() {
    final store = ref.read(openWebUiDirectConnectionStoreProvider);
    final snapshot = _publishedSnapshot;
    if (store == null ||
        snapshot == null ||
        !identical(store, _publishedStore)) {
      return null;
    }
    return (store: store, snapshot: snapshot);
  }

  Future<void> _unavailableMutation() => Future<void>.error(
    StateError('Open WebUI direct connections are unavailable.'),
  );

  Future<void> _mutate(
    OpenWebUiDirectConnectionStore store,
    OpenWebUiDirectConnectionsSnapshot? capturedSnapshot,
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
      _replacePublishedSnapshot(snapshot, store: store);
    } on OpenWebUiDirectConnectionConflictException catch (conflict) {
      if (_storeIsCurrent(store)) {
        _replacePublishedSnapshot(conflict.currentSnapshot, store: store);
      }
      rethrow;
    } on OpenWebUiDirectConnectionCommitUncertainException catch (
      error,
      stackTrace
    ) {
      if (_storeIsCurrent(store)) {
        // The POST may have changed connection indexes or credentials. Revoke
        // the old snapshot and require a fresh GET before another mutation.
        _replacePublishedSnapshot(null, store: store, publishState: false);
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
    bool publishState = true,
  }) {
    final previous = _publishedSnapshot;
    final nextById = <String, DirectConnectionProfile>{
      for (final profile
          in next?.compatibleProfiles ?? const <DirectConnectionProfile>[])
        profile.id: profile,
    };
    final invalidatedProfileIds = <String>{};
    if (previous != null) {
      final modelRegistry = ref.read(directModelRegistryProvider);
      for (final oldProfile in previous.compatibleProfiles) {
        final newProfile = nextById[oldProfile.id];
        if (newProfile == null || _transportChanged(oldProfile, newProfile)) {
          invalidatedProfileIds.add(oldProfile.id);
          _removeDirectProfileModelsBestEffort(modelRegistry, oldProfile.id);
        }
      }
    }

    _publishedStore = store;
    _publishedSnapshot = next;
    if (publishState && ref.mounted) state = AsyncData(next);

    if (invalidatedProfileIds.isNotEmpty) {
      final runRegistry = ref.read(directRunRegistryProvider);
      for (final profileId in invalidatedProfileIds) {
        _cancelDirectProfileRunsBestEffort(runRegistry, profileId);
      }
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
    Provider<OpenWebUiDirectCompletionRelayFactory>(
      (ref) =>
          ({required emitChannel}) =>
              OpenWebUiDirectCompletionRelay(emitChannel: emitChannel),
    );

/// Global Socket.IO handler for Open WebUI's client-side direct-completion RPC.
///
/// Upstream installs this at layout/session scope rather than inside one chat
/// stream. Keeping the same lifetime ensures the handler is ready before
/// `/api/chat/completions` starts a background task that waits for its RPC ACK.
final openWebUiDirectCompletionSocketRelayProvider = Provider<void>((ref) {
  final socket = ref.watch(socketServiceProvider);
  final api = ref.watch(apiServiceProvider);
  final authSessionEpoch = ref.watch(openWebUiAuthSessionEpochProvider);
  final snapshot = ref.watch(openWebUiDirectConnectionsProvider).value;
  final relayFactory = ref.watch(openWebUiDirectCompletionRelayFactoryProvider);
  if (socket == null ||
      api == null ||
      snapshot == null ||
      socket.serverConfig.id != api.serverConfig.id ||
      snapshot.serverId != api.serverConfig.id) {
    return;
  }

  final activeRuns = <String, OpenWebUiDirectCompletionRelayRun>{};
  var ownerDisposed = false;

  bool ownsCapturedSession() =>
      !ownerDisposed &&
      identical(socket, ref.read(socketServiceProvider)) &&
      identical(api, ref.read(apiServiceProvider)) &&
      identical(
        authSessionEpoch,
        ref.read(openWebUiAuthSessionEpochProvider),
      ) &&
      identical(snapshot, ref.read(openWebUiDirectConnectionsProvider).value);

  void cancelActiveRuns(String reason) {
    final runs = activeRuns.values.toList(growable: false);
    activeRuns.clear();
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

  final subscription = socket.addChatEventHandler(
    requireFocus: false,
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
          emitChannel: (eventName, data) =>
              ownsCapturedSession() &&
              socket.emitForSession(currentSessionId, eventName, data),
        );
        run = relay.start(
          profile: record.profile,
          trustedRemoteModelId: binding.remoteModelId,
          trustedUrlIndex: record.index,
          expectedAccountId: snapshot.accountId,
          expectedSessionId: currentSessionId,
          payload: payload,
          acknowledge: acknowledge,
        );
        activeRuns[channel] = run;
        unawaited(
          run.done.then<void>(
            (_) {
              if (identical(activeRuns[channel], run)) {
                activeRuns.remove(channel);
              }
            },
            onError: (Object _, StackTrace _) {
              if (identical(activeRuns[channel], run)) {
                activeRuns.remove(channel);
              }
            },
          ),
        );
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
    final profiles = await ref.read(
      effectiveDirectConnectionProfilesFutureProvider.future,
    );
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
      if (ref.read(openWebUiDirectConnectionsAvailableProvider)) {
        try {
          await ref.read(openWebUiDirectConnectionsProvider.notifier).reload();
        } catch (_) {
          // The synced source exposes its own retry/error state. Keep device
          // profiles usable when that optional refresh fails.
        }
      }
      final profiles = await ref.read(
        effectiveDirectConnectionProfilesFutureProvider.future,
      );
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
