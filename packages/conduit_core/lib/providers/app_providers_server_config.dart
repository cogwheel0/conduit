part of 'app_providers.dart';

// Server connection providers - optimized with caching
Duration? _doNotRetryServerConfigRead(int retryCount, Object error) => null;

@Riverpod(keepAlive: true, retry: _doNotRetryServerConfigRead)
Future<List<ServerConfig>> serverConfigs(Ref ref) async {
  final storage = ref.watch(optimizedStorageServiceProvider);
  return storage.getServerConfigsStrict();
}

@Riverpod(keepAlive: true)
Future<ServerConfig?> activeServer(Ref ref) async {
  final storage = ref.watch(optimizedStorageServiceProvider);
  final configs = await ref.watch(serverConfigsProvider.future);
  // A trusted-proxy login stages its validated config before committing the
  // active id and token. Never let the legacy fallback below auto-promote that
  // provisional row during an unrelated provider rebuild.
  final publishedConfigs = configs
      .where((config) => !storage.isUncommittedServerConfigCandidate(config))
      .toList(growable: false);

  if (publishedConfigs.isEmpty) return null;

  final activeId = await storage.getActiveServerId();

  ServerConfig? fallback;
  for (final config in publishedConfigs) {
    if (activeId != null && config.id == activeId) {
      return config;
    }
    if (fallback == null && config.isActive) {
      fallback = config;
    }
  }
  fallback ??= publishedConfigs.length == 1 ? publishedConfigs.first : null;
  if (fallback == null) return null;

  // Resolution must stay side-effect free. Persisting a fallback derived from
  // an async snapshot can race a server switch/auth transaction and overwrite
  // the newer active id after its lock is released.
  return fallback.isActive ? fallback : fallback.copyWith(isActive: true);
}

final serverConnectionStateProvider = Provider<bool>((ref) {
  final activeServer = ref.watch(activeServerProvider);
  return activeServer.maybeWhen(
    data: (server) => server != null,
    orElse: () => false,
  );
});

/// Whether the *active* server reports a version newer than this app build is
/// known to support (see [ServerVersionCompat]).
///
/// The cached backend config is global, not per-server, so this warns only
/// when the config was fetched from the currently-active server
/// ([BackendConfig.serverId] matches). That makes the decision robust against
/// a stale config from a previously-active server — whether left over after a
/// server switch, an out-of-order refresh, or restored from disk on a cold
/// start — which would otherwise warn for a supported server.
///
/// Fails open while the active server or backend config is still loading, when
/// the config belongs to a different server, or when the version is unknown, so
/// the warning never flashes during startup or appears for a server whose
/// version we can't parse.
final serverIncompatibleProvider = Provider<bool>((ref) {
  final activeId = ref.watch(activeServerProvider).asData?.value?.id;
  final config = ref.watch(backendConfigProvider).asData?.value;
  if (activeId == null || config == null) return false;
  // Warn only on a config confirmed to belong to the active server — i.e. one
  // tagged (in _loadBackendConfig) with the active server id. Anything else
  // fails open:
  //  - a config tagged for a *different* server is stale after a switch and
  //    must not warn for the (possibly supported) new server;
  //  - a null serverId is a legacy cache written before tagging existed, or a
  //    not-yet-tagged fetch — we can't attribute it to a server, so we don't
  //    act on it.
  // The trade-off is that, right after upgrading the app while connected to an
  // unsupported server, the warning stays hidden until the refresh kicked off
  // in BackendConfigNotifier.build() returns a freshly-tagged config (~one
  // round-trip). That's intentional: a stale warning is more confusing than a
  // brief delay before showing a confirmed warning.
  if (config.serverId != activeId) return false;
  return ServerVersionCompat.isUnsupported(config.version);
});

@Riverpod(keepAlive: true)
class BackendConfigNotifier extends _$BackendConfigNotifier {
  // AsyncNotifier instances survive dependency-triggered rebuilds. This must
  // be rebound on every build so auth/server transitions cannot either throw
  // on a second `late final` assignment or retain the prior storage owner.
  late OptimizedStorageService _storage;

  @override
  Future<BackendConfig?> build() async {
    _storage = ref.watch(optimizedStorageServiceProvider);
    // These ownership boundaries can change while ApiService itself remains
    // stable (same-server logout/login). Rebuild so a discarded stale refresh
    // is followed by a request owned by the new session.
    ref.watch(openWebUiAuthSessionEpochProvider);
    ref.watch(openWebUiDatabaseAccessProvider);
    ref.watch(openWebUiCertifiedDatabaseServerProvider);
    ref.watch(activeServerProvider);
    ref.watch(apiServiceProvider);
    final cached = await _storage.getLocalBackendConfig();
    if (ref.mounted) {
      unawaited(_refreshBackendConfig());
    }
    return cached;
  }

  Future<void> refresh() => _refreshBackendConfig();

  /// Stores a configuration that was just verified while connecting to
  /// [serverId]. This avoids a stale global cache hiding server-specific
  /// capability state during the first authenticated frame.
  Future<void> cacheForServer(BackendConfig config, String serverId) async {
    final api = ref.read(apiServiceProvider);
    if (api == null || api.serverConfig.id != serverId) return;
    final ownership = captureOpenWebUiCacheOwnership(
      ref,
      api: api,
      requireAuthenticated: false,
    );
    if (ownership == null) return;

    final tagged = config.copyWith(serverId: serverId);
    await _storage.saveLocalBackendConfig(tagged);
    if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) return;

    final options = _resolveTransportAvailability(tagged);
    await _storage.saveLocalTransportOptions(options);
    if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) return;
    state = AsyncData(tagged);
  }

  Future<void> _refreshBackendConfig() async {
    final loaded = await _loadBackendConfig(ref);
    if (loaded == null || !ref.mounted) {
      return;
    }
    final config = loaded.config;
    final ownership = loaded.ownership;
    if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) return;

    await _storage.saveLocalBackendConfig(config);
    if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) return;

    // Persist resolved transport options based on backend config
    final options = _resolveTransportAvailability(config);
    await _storage.saveLocalTransportOptions(options);
    if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) return;
    state = AsyncData(config);
  }
}

typedef _OwnedBackendConfig = ({
  BackendConfig config,
  OpenWebUiCacheOwnershipSnapshot ownership,
});

Future<_OwnedBackendConfig?> _loadBackendConfig(Ref ref) async {
  if (!ref.mounted) return null;
  // The notifier's build method owns dependency subscriptions. Refresh can
  // also be invoked later by UI actions, where adding a new `watch` dependency
  // is invalid; take point-in-time values and fence their async result below.
  final api = ref.read(apiServiceProvider);
  if (api == null) {
    return null;
  }

  final server = await ref.read(activeServerProvider.future);
  if (!ref.mounted) return null;
  if (server == null) {
    return null;
  }
  if (api.serverConfig.id != server.id) return null;
  final ownership = captureOpenWebUiCacheOwnership(
    ref,
    api: api,
    requireAuthenticated: false,
  );
  if (ownership == null) return null;

  try {
    final config = await api.getBackendConfig();
    if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) return null;
    if (config != null) {
      final forcedMode = config.enforcedTransportMode;
      if (forcedMode != null) {
        final settings = ref.read(appSettingsProvider);
        if (settings.socketTransportMode != forcedMode) {
          Future.microtask(() {
            if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) return;
            ref
                .read(appSettingsProvider.notifier)
                .setSocketTransportMode(forcedMode);
          });
        }
      }
    }
    // Tag the config with the server it was fetched from so the compatibility
    // warning can ignore a globally-cached config that belongs to a different
    // server (e.g. after a server switch, or a stale config restored on a
    // cold start). See serverIncompatibleProvider.
    final tagged = config?.copyWith(serverId: api.serverConfig.id);
    return tagged == null ? null : (config: tagged, ownership: ownership);
  } catch (_) {
    return null;
  }
}

/// Provides resolved socket transport options based on backend configuration.
///
/// This is a synchronous provider that:
/// - Returns cached transport options when backend config is not yet loaded
/// - Derives transport options from backend config once available
/// - Does NOT perform side effects (persistence is handled by BackendConfigNotifier)
///
/// The persistence of resolved options happens asynchronously when the
/// backend config is refreshed, ensuring the sync provider remains pure.
final socketTransportOptionsProvider = Provider<SocketTransportAvailability>((
  ref,
) {
  final storage = ref.watch(optimizedStorageServiceProvider);
  // Watch async backend config for proper invalidation
  final backendConfigAsync = ref.watch(backendConfigProvider);
  final config = backendConfigAsync.maybeWhen(
    data: (value) => value,
    orElse: () => null,
  );

  if (config == null) {
    // Return cached value or defaults when config not available
    return storage.getLocalTransportOptionsSync() ??
        const SocketTransportAvailability(
          allowPolling: true,
          allowWebsocketOnly: true,
        );
  }

  // Determine transport availability from backend config
  return _resolveTransportAvailability(config);
});

/// Fail-closed process/restart fence for an incomplete logout.
///
/// A failed Keychain/preferences rewrite must not let an ApiService rebuild
/// from a still-unsanitized ServerConfig, reattach its Cookie header, or let
/// bootstrap restore a surviving bearer/credential. The marker remains set
/// until cleanup or a durable session commit establishes a new owner.
@Riverpod(keepAlive: true)
final class IncompleteLogoutFence extends _$IncompleteLogoutFence {
  Future<void> _writeTail = Future<void>.value();
  bool _desiredSuppressed = false;
  int _writeGeneration = 0;

  @override
  bool build() {
    final stored =
        PreferencesStore.getBool(PreferenceKeys.incompleteLogoutFence) ?? false;
    _desiredSuppressed = stored;
    return stored;
  }

  /// Latest requested durable state, including a write that is queued or
  /// currently blocked before SharedPreferences reflects it.
  bool get desiredSuppressed => _desiredSuppressed;

  /// Identifies whether an asynchronous completion still belongs to the most
  /// recent fence request. Older failures must not enqueue a fail-closed write
  /// over a newer checked clear that is establishing a valid session.
  int get requestGeneration => _writeGeneration;

  bool ownsRequest(int generation) => generation == _writeGeneration;

  void setSuppressed(bool suppressed) {
    if (state == suppressed) return;
    state = suppressed;
  }

  /// Updates the live request boundary first, then makes the fail-safe marker
  /// durable. Callers may recover from a failed preference flush while the
  /// in-memory suppression remains active.
  Future<bool> persist(bool suppressed, {bool publishState = true}) async {
    final generation = ++_writeGeneration;
    // A checked clear is not safe until its write succeeds. Keep both pending
    // intent and (when requested) the live boundary fail-closed while it is
    // queued/in flight. A newer request owns the final desired state.
    _desiredSuppressed = true;
    if (publishState) setSuppressed(true);
    final operation = _writeTail.then<bool>((_) async {
      if (!PreferencesStore.isReady) return false;
      final admitted = await PreferencesStore.putCheckedIf(
        PreferenceKeys.incompleteLogoutFence,
        suppressed ? true : null,
        // A fail-closed write is always safe. A clear must still own the most
        // recent request at SharedPreferences' synchronous mutation boundary.
        canWrite: () => suppressed || generation == _writeGeneration,
        bypassAppDataClearBarrier: true,
      );
      return admitted;
    });
    // A failed write must not poison the queue: later fail-closed writes still
    // need to reach durable preferences in invocation order.
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    final succeeded = await operation;
    if (!suppressed && succeeded) {
      // A newer request makes this clear stale even though its own disk write
      // completed. It is still important to report the disk result accurately:
      // duplicate clear callers otherwise mistake a successful older write for
      // failure and enqueue a new fail-closed marker over the newer clear.
      // Security-sensitive publishers separately require desiredSuppressed to
      // be false before exposing authentication.
      if (generation == _writeGeneration) {
        _desiredSuppressed = false;
        if (publishState) setSuppressed(false);
      }
    }
    return succeeded;
  }
}
