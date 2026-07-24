import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../services/api_service.dart';
import '../services/attachment_upload_queue.dart';
import '../auth/auth_state_manager.dart';
import '../auth/openwebui_account_owner_marker.dart';
import '../../features/auth/providers/unified_auth_providers.dart';
import '../models/server_config.dart';
import '../models/user.dart';
import '../models/model.dart';
import '../models/conversation.dart';
import '../models/chat_message.dart';
import '../models/account_metadata.dart';
import '../models/backend_config.dart';
import '../models/folder.dart';
import '../models/file_info.dart';
import '../models/server_about_info.dart';
import '../models/server_memory.dart';
import '../models/server_user_settings.dart';
import '../models/tool.dart';
import '../models/user_settings.dart';
import '../models/knowledge_base.dart';
import '../services/settings_service.dart';
import '../services/optimized_storage_service.dart';
import '../services/secure_credential_storage.dart';
import '../services/socket_service.dart';
import '../services/connectivity_service.dart';
import '../services/conversation_parsing.dart';
import '../persistence/preferences_store.dart';
import '../persistence/persistence_keys.dart';
import '../utils/debug_logger.dart';
import '../utils/server_version_compat.dart';
import '../services/worker_manager.dart';
import '../../shared/theme/tweakcn_themes.dart';
import '../../shared/theme/app_theme.dart';
import '../../features/tools/providers/tools_providers.dart';
import '../../features/hermes/models/hermes_model.dart';
import '../../features/hermes/providers/hermes_providers.dart';
import '../../features/hermes/services/hermes_session_provenance.dart';
import '../../features/direct_connections/direct_connections.dart';
import 'backend_mode_providers.dart';
import '../models/socket_transport_availability.dart';
import 'storage_providers.dart';
import 'package:drift/drift.dart' show Value;
import '../database/app_database.dart';
import '../database/database_provider.dart';
import '../database/chat_database_repository.dart';
import '../database/local_conversation_loader.dart';
import '../database/mappers/conversation_assembler.dart';
import '../sync/chat_locks.dart';
import '../sync/pull_sync.dart';
import '../sync/sync_engine.dart';

export 'storage_providers.dart';

part 'app_providers.g.dart';

typedef _ModelAuthReadiness = ({
  bool authenticated,
  bool loading,
  AuthStatus status,
});

/// Rebuilds every long-lived provider that mirrors data removed by the broad
/// sign-out wipe.
void _resetProvidersAfterFullAppDataClear(Ref ref) {
  ref.read(activeConversationProvider.notifier).set(null);

  ref.invalidate(appSettingsProvider);
  ref.invalidate(appThemeModeProvider);
  ref.invalidate(appThemePaletteProvider);
  ref.invalidate(appLocaleProvider);
  ref.invalidate(reviewerModeProvider);
  ref.invalidate(preferredBackendProvider);

  ref.invalidate(directConnectionProfilesProvider);
  ref.invalidate(directHistoryPolicyProvider);
  ref.invalidate(directDeviceTrustKeyProvider);
  ref.invalidate(directRunRegistryProvider);
  ref.invalidate(directModelRegistryProvider);
  ref.invalidate(directProviderAdapterRegistryProvider);
  ref.invalidate(directHttpClientPoolProvider);

  ref.invalidate(hermesConfigProvider);
  ref.invalidate(hermesSecretsLoadingProvider);
  ref.invalidate(hermesSecretsErrorProvider);
  ref.invalidate(hermesActiveSessionProvider);
  ref.invalidate(hermesApiServiceProvider);
}

final signOutCoordinatorProvider = Provider<SignOutCoordinator>(
  SignOutCoordinator.new,
);

enum SignOutRequestResult { completed, conflictingRequestIgnored }

/// Coordinates a user-requested full local-data sign-out across auth and
/// backend providers. Connection mutation barriers are installed only after
/// auth ownership is confirmed, then held until the wipe commits or aborts.
final class SignOutCoordinator {
  SignOutCoordinator(this._ref);

  final Ref _ref;
  Future<SignOutRequestResult>? _activeSignOut;
  bool? _activeKeepServerDetails;

  Future<SignOutRequestResult> signOut({required bool keepServerDetails}) {
    final active = _activeSignOut;
    if (active != null) {
      if (_activeKeepServerDetails == keepServerDetails) return active;
      return Future<SignOutRequestResult>.value(
        SignOutRequestResult.conflictingRequestIgnored,
      );
    }
    late final Future<SignOutRequestResult> operation;
    operation = _signOut(keepServerDetails: keepServerDetails)
        .then((_) => SignOutRequestResult.completed)
        .whenComplete(() {
          if (identical(_activeSignOut, operation)) {
            _activeSignOut = null;
            _activeKeepServerDetails = null;
          }
        });
    _activeKeepServerDetails = keepServerDetails;
    _activeSignOut = operation;
    return operation;
  }

  Future<void> _signOut({required bool keepServerDetails}) async {
    final directProfiles = _ref.read(
      directConnectionProfilesProvider.notifier,
    );
    final hermesConfig = _ref.read(hermesConfigProvider.notifier);
    final directRuns = _ref.read(directRunRegistryProvider);
    FullAppDataClearOutcome? outcome;

    void resumeGlobalAdmission() {
      directRuns.resumeAdmissionAfterAppDataClearAbort();
      PreferencesStore.resumeWritesAfterAppDataClear();
      SecureCredentialStorage.resumeDirectIdentityWritesAfterAppDataClear();
    }

    Future<void> prepareForClear() async {
      directRuns.blockAdmissionForAppDataClear();
      try {
        await Future.wait<void>([
          PreferencesStore.blockWritesForAppDataClear(),
          SecureCredentialStorage.blockDirectIdentityWritesForAppDataClear(),
          directProfiles.blockMutationsForAppDataClear(),
          hermesConfig.blockMutationsForAppDataClear(),
        ]);
        _ref.invalidate(directProviderAdapterRegistryProvider);
        _ref.invalidate(directModelDiscoveryProvider);
        _ref.invalidate(directHttpClientPoolProvider);
        final directCleanup = directRuns.cancelAll();
        await Future.wait<void>([
          for (final cleanup in directCleanup)
            cleanup.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        ]);
      } catch (_) {
        resumeGlobalAdmission();
        directProfiles.resumeMutationsAfterAppDataClearAbort();
        hermesConfig.resumeMutationsAfterAppDataClearAbort();
        rethrow;
      }
    }

    try {
      outcome = await _ref
          .read(authStateManagerProvider.notifier)
          .logoutAndClearAppData(
            keepServerDetails: keepServerDetails,
            beforeClear: prepareForClear,
          );
      switch (outcome) {
        case FullAppDataClearOutcome.cleared:
          PreferencesStore.resumeWritesAfterAppDataClear();
          SecureCredentialStorage.resumeDirectIdentityWritesAfterAppDataClear();
          _resetProvidersAfterFullAppDataClear(_ref);
        case FullAppDataClearOutcome.incomplete:
          await Future.wait<void>([
            directProfiles.blockMutationsForAppDataClear(),
            hermesConfig.blockMutationsForAppDataClear(),
          ]);
          directProfiles.revokeRuntimeAfterIncompleteAppDataClear();
          hermesConfig.revokeRuntimeAfterIncompleteAppDataClear();
          PreferencesStore.resumeWritesAfterAppDataClear();
          SecureCredentialStorage.resumeDirectIdentityWritesAfterAppDataClear();
        case FullAppDataClearOutcome.ownershipYielded:
          resumeGlobalAdmission();
          directProfiles.resumeMutationsAfterAppDataClearAbort();
          hermesConfig.resumeMutationsAfterAppDataClearAbort();
      }
    } finally {
      PreferencesStore.resumeWritesAfterAppDataClear();
      SecureCredentialStorage.resumeDirectIdentityWritesAfterAppDataClear();
      if (outcome == null) {
        resumeGlobalAdmission();
        directProfiles.resumeMutationsAfterAppDataClearAbort();
        hermesConfig.resumeMutationsAfterAppDataClearAbort();
      }
    }
  }
}

/// A single, value-deduplicated auth dependency for model resolution. Watching
/// the three public derivations independently can restart an async provider
/// several times while one AuthState transition is being published.
final _modelAuthReadinessProvider = Provider<_ModelAuthReadiness>((ref) {
  return (
    authenticated: ref.watch(isAuthenticatedProvider2),
    loading: ref.watch(isAuthLoadingProvider2),
    status: ref.watch(authStatusProvider),
  );
});

bool _modelAuthRetainsOpenWebUiSession(_ModelAuthReadiness auth) =>
    auth.authenticated;

bool _modelAuthIsPending(_ModelAuthReadiness auth) =>
    auth.loading ||
    auth.status == AuthStatus.initial ||
    auth.status == AuthStatus.loading;

// Theme provider
@Riverpod(keepAlive: true)
class AppThemeMode extends _$AppThemeMode {
  // Notifier instances survive invalidation, so build() can run more than once.
  late OptimizedStorageService _storage;

  @override
  ThemeMode build() {
    _storage = ref.watch(optimizedStorageServiceProvider);
    final storedMode = _storage.getThemeMode();
    if (storedMode != null) {
      return ThemeMode.values.firstWhere(
        (e) => e.toString() == storedMode,
        orElse: () => ThemeMode.system,
      );
    }
    return ThemeMode.system;
  }

  void setTheme(ThemeMode mode) {
    state = mode;
    _storage.setThemeMode(mode.toString());
  }
}

@Riverpod(keepAlive: true)
class AppThemePalette extends _$AppThemePalette {
  // Notifier instances survive invalidation, so build() can run more than once.
  late OptimizedStorageService _storage;

  @override
  TweakcnThemeDefinition build() {
    _storage = ref.watch(optimizedStorageServiceProvider);
    final storedId = _storage.getThemePaletteId();
    return TweakcnThemes.byId(storedId);
  }

  Future<void> setPalette(String paletteId) async {
    final palette = TweakcnThemes.byId(paletteId);
    state = palette;
    await _storage.setThemePaletteId(palette.id);
  }
}

@Riverpod(keepAlive: true)
class AppLightTheme extends _$AppLightTheme {
  @override
  ThemeData build() {
    final palette = ref.watch(appThemePaletteProvider);
    return AppTheme.light(palette);
  }
}

@Riverpod(keepAlive: true)
class AppDarkTheme extends _$AppDarkTheme {
  @override
  ThemeData build() {
    final palette = ref.watch(appThemePaletteProvider);
    return AppTheme.dark(palette);
  }
}

@Riverpod(keepAlive: true)
class AppCupertinoLightTheme extends _$AppCupertinoLightTheme {
  @override
  CupertinoThemeData build() {
    final palette = ref.watch(appThemePaletteProvider);
    return AppTheme.cupertinoLight(palette);
  }
}

@Riverpod(keepAlive: true)
class AppCupertinoDarkTheme extends _$AppCupertinoDarkTheme {
  @override
  CupertinoThemeData build() {
    final palette = ref.watch(appThemePaletteProvider);
    return AppTheme.cupertinoDark(palette);
  }
}

// Locale provider
@Riverpod(keepAlive: true)
class AppLocale extends _$AppLocale {
  // Notifier instances survive invalidation, so build() can run more than once.
  late OptimizedStorageService _storage;

  @override
  Locale? build() {
    _storage = ref.watch(optimizedStorageServiceProvider);
    final code = _storage.getLocaleCode();
    if (code != null && code.isNotEmpty) {
      final parsed = _parseLocaleCode(code);
      if (parsed != null) return parsed;
    }
    return null; // system default
  }

  Future<void> setLocale(Locale? locale) async {
    state = locale;
    await _storage.setLocaleCode(locale?.toLanguageTag());
  }

  Locale? _parseLocaleCode(String code) {
    final normalized = code.replaceAll('_', '-');
    final parts = normalized.split('-');
    if (parts.isEmpty || parts.first.isEmpty) return null;

    final language = parts.first;
    String? script;
    String? country;

    for (var i = 1; i < parts.length; i++) {
      final part = parts[i];
      if (part.length == 4) {
        script = '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}';
      } else if (part.length == 2 || part.length == 3) {
        country = part.toUpperCase();
      }
    }

    return Locale.fromSubtags(
      languageCode: language,
      scriptCode: script,
      countryCode: country,
    );
  }
}

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

/// In-memory bearer mirror used when [apiServiceProvider] is rebuilt.
///
/// The API client watches transport configuration such as the incomplete-logout
/// Cookie fence and can therefore be replaced during authentication publication.
/// Keeping the current bearer in an independent process-local provider prevents
/// that replacement from reverting to an unauthenticated client. The token is
/// never persisted or logged here; secure credential storage remains owned by
/// [OptimizedStorageService].
final apiAuthTokenMirrorProvider =
    NotifierProvider<ApiAuthTokenMirror, String?>(ApiAuthTokenMirror.new);

final class ApiAuthTokenMirror extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? token) {
    if (state != token) state = token;
  }
}

// API Service provider with unified auth integration
final apiServiceProvider = Provider<ApiService?>((ref) {
  // If reviewer mode is enabled, skip creating ApiService
  final reviewerMode = ref.watch(reviewerModeProvider);
  if (reviewerMode) {
    return null;
  }
  final authToken = ref.watch(apiAuthTokenMirrorProvider);
  final activeServer = ref.watch(activeServerProvider);
  final workerManager = ref.watch(workerManagerProvider);
  final liveFence = ref.watch(incompleteLogoutFenceProvider);
  final suppressCookieHeader =
      liveFence ||
      ref.read(incompleteLogoutFenceProvider.notifier).desiredSuppressed;

  return activeServer.maybeWhen(
    data: (server) {
      if (server == null) return null;

      final apiService = ApiService(
        serverConfig: server,
        workerManager: workerManager,
        authToken: authToken,
        suppressCookieCustomHeader: suppressCookieHeader,
      );

      // Keep callbacks in sync so interceptor can notify auth manager
      apiService.setAuthCallbacks(
        onAuthTokenInvalid: () {
          // Called when auth errors occur (401/403)
          // Show connection issue page instead of logging out
          final authManager = ref.read(authStateManagerProvider.notifier);
          authManager.onAuthIssue();
        },
        onTokenInvalidated: () async {
          // Called for token expiry - attempt silent re-login
          final authManager = ref.read(authStateManagerProvider.notifier);
          await authManager.onTokenInvalidated();
        },
      );

      // Set up callback for unified auth state manager
      // (legacy properties kept during transition)
      apiService.onTokenInvalidated = () async {
        final authManager = ref.read(authStateManagerProvider.notifier);
        await authManager.onTokenInvalidated();
      };

      // Keep legacy callback for backward compatibility during transition
      apiService.onAuthTokenInvalid = () {
        // Show connection issue page instead of logging out
        final authManager = ref.read(authStateManagerProvider.notifier);
        authManager.onAuthIssue();
      };

      ref.onDispose(apiService.dispose);
      return apiService;
    },
    orElse: () => null,
  );
});

/// Whether server-backed Open WebUI settings are usable in the current
/// session. A retained server or API object after sign-out is not sufficient.
final openWebUiAccountAvailableProvider = Provider<bool>((ref) {
  return ref.watch(apiServiceProvider) != null &&
      ref.watch(isAuthenticatedProvider2);
});

// Socket.IO service provider
/// Monotonic identity for one OpenWebUI authentication session.
///
/// API and database objects are intentionally stable across logout on the same
/// server. Their identity therefore cannot distinguish user A's late async work
/// from a later user B session. Rebuilding this object on every auth-state
/// transition gives all server-bound work an ABA-safe ownership boundary.
final openWebUiAuthSessionEpochProvider = Provider<Object>((ref) {
  ref.watch(isAuthenticatedProvider2);
  ref.watch(authTokenProvider3);
  ref.watch(currentUserProvider2.select((user) => user?.id));
  return Object();
});

/// Immutable ownership fence for async OpenWebUI API results that may update
/// server-scoped state or cache rows after an await.
///
/// ApiService identity alone is insufficient: it can remain stable across a
/// same-server account transition. The auth epoch, token, active server,
/// database certification phase, and raw storage owner close that ABA window.
@immutable
final class OpenWebUiCacheOwnershipSnapshot {
  const OpenWebUiCacheOwnershipSnapshot({
    required this.api,
    required this.serverId,
    required this.activeServerId,
    required this.authSessionEpoch,
    required this.authToken,
    required this.authenticated,
    required this.databaseAccessPhase,
    required this.certifiedDatabaseServerId,
    required this.rawActiveServerId,
  });

  final ApiService api;
  final String serverId;
  final String? activeServerId;
  final Object authSessionEpoch;
  final String? authToken;
  final bool authenticated;
  final OpenWebUiDatabaseAccessPhase databaseAccessPhase;
  final String? certifiedDatabaseServerId;
  final String? rawActiveServerId;
}

OpenWebUiCacheOwnershipSnapshot? captureOpenWebUiCacheOwnership(
  Ref ref, {
  required ApiService api,
  bool requireAuthenticated = true,
}) {
  if (!ref.mounted) return null;
  final serverId = api.serverConfig.id;
  // Keep the last resolved owner through an AsyncLoading/AsyncError refresh.
  // Treating every transient refresh as "no server" can retire otherwise
  // valid same-server cache/API work while the server is being revalidated.
  final activeServerId = ref.read(activeServerProvider).value?.id;
  final rawActiveServerId = PreferencesStore.getString(
    PreferenceKeys.activeServerId,
  );
  final authenticated = ref.read(isAuthenticatedProvider2);
  final authToken = ref.read(authTokenProvider3);
  if (!identical(ref.read(apiServiceProvider), api) ||
      (activeServerId != null && activeServerId != serverId) ||
      (rawActiveServerId != null && rawActiveServerId != serverId) ||
      (requireAuthenticated &&
          (!authenticated || authToken == null || authToken.isEmpty))) {
    return null;
  }
  return OpenWebUiCacheOwnershipSnapshot(
    api: api,
    serverId: serverId,
    activeServerId: activeServerId,
    authSessionEpoch: ref.read(openWebUiAuthSessionEpochProvider),
    authToken: authToken,
    authenticated: authenticated,
    databaseAccessPhase: ref.read(openWebUiDatabaseAccessProvider),
    certifiedDatabaseServerId: ref.read(
      openWebUiCertifiedDatabaseServerProvider,
    ),
    rawActiveServerId: rawActiveServerId,
  );
}

bool openWebUiCacheOwnershipIsCurrent(
  Ref ref,
  OpenWebUiCacheOwnershipSnapshot snapshot,
) {
  if (!ref.mounted ||
      !identical(ref.read(apiServiceProvider), snapshot.api) ||
      ref.read(activeServerProvider).value?.id != snapshot.activeServerId ||
      !identical(
        ref.read(openWebUiAuthSessionEpochProvider),
        snapshot.authSessionEpoch,
      ) ||
      ref.read(authTokenProvider3) != snapshot.authToken ||
      ref.read(isAuthenticatedProvider2) != snapshot.authenticated ||
      ref.read(openWebUiDatabaseAccessProvider) !=
          snapshot.databaseAccessPhase ||
      ref.read(openWebUiCertifiedDatabaseServerProvider) !=
          snapshot.certifiedDatabaseServerId ||
      PreferencesStore.getString(PreferenceKeys.activeServerId) !=
          snapshot.rawActiveServerId) {
    return false;
  }
  return (snapshot.activeServerId == null ||
          snapshot.activeServerId == snapshot.serverId) &&
      (snapshot.rawActiveServerId == null ||
          snapshot.rawActiveServerId == snapshot.serverId);
}

/// Ownership token for an asynchronous OpenWebUI conversation read.
///
/// Conversation bodies can come from either the server database or the API.
/// Both objects may outlive the account that started a read, so object identity
/// alone is not an adequate fence. This token also captures the authentication
/// epoch and the database/server certification boundary used by account
/// isolation.
@immutable
final class OpenWebUiConversationReadSnapshot {
  const OpenWebUiConversationReadSnapshot._({
    required this.database,
    required this.api,
    required this.authSessionEpoch,
    required this.databaseAccessPhase,
    required this.certifiedDatabaseServerId,
    required this.activeServerId,
    required this.rawActiveServerId,
    required this.managedDatabaseServerId,
    required this.apiServerId,
  });

  final AppDatabase? database;
  final ApiService? api;
  final Object authSessionEpoch;
  final OpenWebUiDatabaseAccessPhase databaseAccessPhase;
  final String? certifiedDatabaseServerId;
  final String? activeServerId;
  final String? rawActiveServerId;
  final String? managedDatabaseServerId;
  final String? apiServerId;
}

/// Logical account/server owner for a user-initiated conversation selection.
///
/// Exact database and API identities belong to [OpenWebUiConversationReadSnapshot]
/// and may legitimately change while the same account finishes opening. This
/// owner survives that replacement while still canceling on logout, account
/// changes, or server changes.
@immutable
final class OpenWebUiConversationSelectionOwner {
  const OpenWebUiConversationSelectionOwner._({
    required this.serverId,
    required this.userId,
    required this.authToken,
    required this.authSessionEpoch,
  });

  final String serverId;
  final String? userId;
  final String authToken;
  final Object authSessionEpoch;
}

enum OpenWebUiConversationOwnershipFailureReason {
  unavailable,
  changedWhileLoading,
  changedWhileFetching,
}

final class OpenWebUiConversationOwnershipException extends StateError {
  OpenWebUiConversationOwnershipException(this.reason)
    : super(switch (reason) {
        OpenWebUiConversationOwnershipFailureReason.unavailable =>
          'OpenWebUI conversation ownership is unavailable',
        OpenWebUiConversationOwnershipFailureReason.changedWhileLoading =>
          'OpenWebUI conversation ownership changed while loading',
        OpenWebUiConversationOwnershipFailureReason.changedWhileFetching =>
          'OpenWebUI conversation ownership changed while fetching',
      });

  final OpenWebUiConversationOwnershipFailureReason reason;
}

typedef _OpenWebUiConversationReadContext = ({
  AppDatabase? database,
  ApiService? api,
  Object authSessionEpoch,
  OpenWebUiDatabaseAccessPhase databaseAccessPhase,
  String? certifiedDatabaseServerId,
  String? activeServerId,
  String? rawActiveServerId,
  String? managedDatabaseServerId,
  String? apiServerId,
});

bool _openWebUiConversationReaderIsMounted(dynamic ref) {
  try {
    final mounted = ref.mounted;
    return mounted is! bool || mounted;
  } catch (_) {
    // ProviderContainer intentionally has no mounted property. Its reads below
    // still fail after disposal, which is handled by the context reader.
    return true;
  }
}

_OpenWebUiConversationReadContext? _readOpenWebUiConversationContext(
  dynamic ref,
) {
  if (!_openWebUiConversationReaderIsMounted(ref)) return null;

  // The database and API are independent read sources. In particular, the
  // account database may be unavailable while it is opening (or a narrow test
  // may deliberately omit it), but that must not erase an otherwise exact API
  // ownership token. Read optional context components independently and keep
  // the mandatory auth/database-isolation fence fail-closed.
  AppDatabase? database;
  try {
    database = ref.read(appDatabaseProvider) as AppDatabase?;
  } catch (_) {}

  ApiService? api;
  try {
    api = ref.read(apiServiceProvider) as ApiService?;
  } catch (_) {}
  if (database == null && api == null) return null;

  late final Object authSessionEpoch;
  late final OpenWebUiDatabaseAccessPhase databaseAccessPhase;
  String? certifiedDatabaseServerId;
  try {
    authSessionEpoch = ref.read(openWebUiAuthSessionEpochProvider) as Object;
    databaseAccessPhase =
        ref.read(openWebUiDatabaseAccessProvider)
            as OpenWebUiDatabaseAccessPhase;
    certifiedDatabaseServerId =
        ref.read(openWebUiCertifiedDatabaseServerProvider) as String?;
  } catch (_) {
    return null;
  }

  String? managedDatabaseServerId;
  if (database != null) {
    try {
      managedDatabaseServerId = ref
          .read(databaseManagerProvider)
          .serverIdForDatabase(database);
    } catch (_) {
      // Provider overrides commonly use unmanaged in-memory databases. Exact
      // database identity remains their ownership boundary.
    }
  }

  String? apiServerId;
  if (api != null) {
    try {
      apiServerId = api.serverConfig.id;
    } catch (_) {
      // Lightweight ApiService fakes may not implement serverConfig. Real
      // services always do, and the remaining captured identities still
      // provide a deterministic test seam.
    }
  }

  String? rawActiveServerId;
  try {
    rawActiveServerId = PreferencesStore.isReady
        ? PreferencesStore.getString(PreferenceKeys.activeServerId)
        : null;
  } catch (_) {
    // A narrow test or early bootstrap can expose a synchronously torn-down
    // preferences seam. Provider/database/auth identity still forms the
    // ownership fence; absence of this optional corroborating id is safer
    // than making every otherwise coherent read unavailable.
    rawActiveServerId = null;
  }

  String? activeServerId;
  try {
    final activeServer = ref.read(activeServerProvider);
    activeServerId = activeServer is AsyncData<ServerConfig?>
        ? activeServer.value?.id
        : null;
  } catch (_) {
    // During server bootstrap the independently captured API/database identity
    // remains authoritative. A later active-server publication changes this
    // tuple and invalidates the snapshot before its result can be published.
  }

  return (
    database: database,
    api: api,
    authSessionEpoch: authSessionEpoch,
    databaseAccessPhase: databaseAccessPhase,
    certifiedDatabaseServerId: certifiedDatabaseServerId,
    activeServerId: activeServerId,
    rawActiveServerId: rawActiveServerId,
    managedDatabaseServerId: managedDatabaseServerId,
    apiServerId: apiServerId,
  );
}

String? _readOpenWebUiLogicalServerId(dynamic ref) {
  if (!_openWebUiConversationReaderIsMounted(ref)) return null;

  late final OpenWebUiDatabaseAccessPhase accessPhase;
  try {
    accessPhase =
        ref.read(openWebUiDatabaseAccessProvider)
            as OpenWebUiDatabaseAccessPhase;
  } catch (_) {
    return null;
  }

  final primaryIds = <String>{};
  try {
    final activeServer = ref.read(activeServerProvider);
    if (activeServer is AsyncData<ServerConfig?>) {
      final id = activeServer.value?.id;
      if (id != null && id.isNotEmpty) primaryIds.add(id);
    }
  } catch (_) {}
  try {
    if (PreferencesStore.isReady) {
      final id = PreferencesStore.getString(PreferenceKeys.activeServerId);
      if (id != null && id.isNotEmpty) primaryIds.add(id);
    }
  } catch (_) {}
  try {
    final api = ref.read(apiServiceProvider) as ApiService?;
    final id = api?.serverConfig.id;
    if (id != null && id.isNotEmpty) primaryIds.add(id);
  } catch (_) {}
  if (primaryIds.length > 1) return null;

  final storageIds = <String>{};
  try {
    final certified =
        ref.read(openWebUiCertifiedDatabaseServerProvider) as String?;
    if (certified != null && certified.isNotEmpty) storageIds.add(certified);
  } catch (_) {}
  try {
    final database = ref.read(appDatabaseProvider) as AppDatabase?;
    if (database != null) {
      final managed = ref
          .read(databaseManagerProvider)
          .serverIdForDatabase(database);
      if (managed != null && managed.isNotEmpty) storageIds.add(managed);
    }
  } catch (_) {}
  if (storageIds.length > 1) return null;

  final primary = primaryIds.isEmpty ? null : primaryIds.first;
  final storage = storageIds.isEmpty ? null : storageIds.first;
  if (accessPhase == OpenWebUiDatabaseAccessPhase.open &&
      primary != null &&
      storage != null &&
      primary != storage) {
    return null;
  }
  return primary ?? storage;
}

OpenWebUiConversationSelectionOwner? captureOpenWebUiConversationSelectionOwner(
  dynamic ref,
) {
  if (!_openWebUiConversationReaderIsMounted(ref)) return null;
  try {
    final authenticated = ref.read(isAuthenticatedProvider2) as bool;
    final authToken = ref.read(authTokenProvider3) as String?;
    final userId = (ref.read(currentUserProvider2) as User?)?.id.trim();
    final serverId = _readOpenWebUiLogicalServerId(ref);
    if (!authenticated ||
        authToken == null ||
        authToken.isEmpty ||
        serverId == null) {
      return null;
    }
    return OpenWebUiConversationSelectionOwner._(
      serverId: serverId,
      userId: userId == null || userId.isEmpty ? null : userId,
      authToken: authToken,
      authSessionEpoch: ref.read(openWebUiAuthSessionEpochProvider) as Object,
    );
  } catch (_) {
    return null;
  }
}

bool openWebUiConversationSelectionOwnerIsCurrent(
  dynamic ref,
  OpenWebUiConversationSelectionOwner owner,
) {
  final current = captureOpenWebUiConversationSelectionOwner(ref);
  if (current == null ||
      current.serverId != owner.serverId ||
      !identical(current.authSessionEpoch, owner.authSessionEpoch)) {
    return false;
  }
  final ownerUserId = owner.userId;
  final currentUserId = current.userId;
  if (ownerUserId != null && currentUserId != null) {
    return ownerUserId == currentUserId;
  }
  return owner.authToken == current.authToken;
}

/// Captures the single ownership token shared by all OpenWebUI conversation
/// read and publication paths.
///
/// [database] and [api], when supplied, must still be the current provider
/// instances. At least one current OpenWebUI data source must exist.
OpenWebUiConversationReadSnapshot? captureOpenWebUiConversationRead(
  dynamic ref, {
  AppDatabase? database,
  ApiService? api,
}) {
  final context = _readOpenWebUiConversationContext(ref);
  if (context == null ||
      (database != null && !identical(database, context.database)) ||
      (api != null && !identical(api, context.api)) ||
      (context.database == null && context.api == null) ||
      context.databaseAccessPhase == OpenWebUiDatabaseAccessPhase.purging ||
      context.databaseAccessPhase == OpenWebUiDatabaseAccessPhase.closed) {
    return null;
  }

  final databaseServerId = context.managedDatabaseServerId;
  if (databaseServerId != null) {
    if (context.databaseAccessPhase != OpenWebUiDatabaseAccessPhase.open ||
        context.certifiedDatabaseServerId != databaseServerId ||
        context.activeServerId != databaseServerId ||
        (context.rawActiveServerId != null &&
            context.rawActiveServerId != databaseServerId) ||
        (context.api != null && context.apiServerId != databaseServerId)) {
      return null;
    }
  }

  final apiServerId = context.apiServerId;
  if (apiServerId != null &&
      ((context.activeServerId != null &&
              context.activeServerId != apiServerId) ||
          (context.rawActiveServerId != null &&
              context.rawActiveServerId != apiServerId) ||
          (context.databaseAccessPhase == OpenWebUiDatabaseAccessPhase.open &&
              context.certifiedDatabaseServerId != null &&
              context.certifiedDatabaseServerId != apiServerId))) {
    return null;
  }

  return OpenWebUiConversationReadSnapshot._(
    database: context.database,
    api: context.api,
    authSessionEpoch: context.authSessionEpoch,
    databaseAccessPhase: context.databaseAccessPhase,
    certifiedDatabaseServerId: context.certifiedDatabaseServerId,
    activeServerId: context.activeServerId,
    rawActiveServerId: context.rawActiveServerId,
    managedDatabaseServerId: context.managedDatabaseServerId,
    apiServerId: context.apiServerId,
  );
}

/// Whether [snapshot] still owns the exact OpenWebUI account/server context.
bool openWebUiConversationReadIsCurrent(
  dynamic ref,
  OpenWebUiConversationReadSnapshot snapshot,
) {
  final context = _readOpenWebUiConversationContext(ref);
  return context != null &&
      identical(context.database, snapshot.database) &&
      identical(context.api, snapshot.api) &&
      identical(context.authSessionEpoch, snapshot.authSessionEpoch) &&
      context.databaseAccessPhase == snapshot.databaseAccessPhase &&
      context.certifiedDatabaseServerId == snapshot.certifiedDatabaseServerId &&
      context.activeServerId == snapshot.activeServerId &&
      context.rawActiveServerId == snapshot.rawActiveServerId &&
      context.managedDatabaseServerId == snapshot.managedDatabaseServerId &&
      context.apiServerId == snapshot.apiServerId;
}

/// Whether account-scoped OpenWebUI storage is safe for active chat content.
bool openWebUiAccountStorageIsCertified(dynamic ref) {
  try {
    if (ref.read(openWebUiDatabaseAccessProvider) !=
        OpenWebUiDatabaseAccessPhase.open) {
      return false;
    }
    final certifiedServerId = ref.read(
      openWebUiCertifiedDatabaseServerProvider,
    );
    final activeServer = ref.read(activeServerProvider);
    if (activeServer is AsyncData<ServerConfig?>) {
      final activeServerId = activeServer.value?.id;
      if (activeServerId != null) return activeServerId == certifiedServerId;
    }

    // Narrow tests override an unmanaged in-memory database without an active
    // server. Production databases always have a manager owner and therefore
    // require the certified logical server above.
    final database = ref.read(appDatabaseProvider) as AppDatabase?;
    if (database == null) return false;
    final managedServerId = ref
        .read(databaseManagerProvider)
        .serverIdForDatabase(database);
    return managedServerId == null;
  } catch (_) {
    return false;
  }
}

bool openWebUiConversationReadIsCertifiedForPublication(
  dynamic ref,
  OpenWebUiConversationReadSnapshot snapshot,
) {
  return snapshot.databaseAccessPhase == OpenWebUiDatabaseAccessPhase.open &&
      openWebUiConversationReadIsCurrent(ref, snapshot) &&
      openWebUiAccountStorageIsCertified(ref);
}

typedef SocketServiceFactory =
    SocketService Function({
      required ServerConfig serverConfig,
      required String authToken,
      required bool websocketOnly,
      required bool allowWebsocketUpgrade,
    });

final socketServiceFactoryProvider = Provider<SocketServiceFactory>((ref) {
  return ({
    required serverConfig,
    required authToken,
    required websocketOnly,
    required allowWebsocketUpgrade,
  }) => SocketService(
    serverConfig: serverConfig,
    authToken: authToken,
    websocketOnly: websocketOnly,
    allowWebsocketUpgrade: allowWebsocketUpgrade,
  );
});

@Riverpod(keepAlive: true)
class SocketServiceManager extends _$SocketServiceManager {
  SocketService? _service;
  ProviderSubscription<ConnectivityStatus>? _connectivitySubscription;
  String? _serviceToken;
  int _connectToken = 0;
  int _buildGeneration = 0;

  /// The current live service, available even while [build] is re-running (the
  /// async provider is briefly `loading` on every rebuild). [socketServiceProvider]
  /// falls back to this so the socket doesn't momentarily read as `null` — which
  /// would otherwise drop consumers to HTTP-only sends mid-session. Null only
  /// when there is genuinely no service (reviewer mode / no active server /
  /// disposed).
  SocketService? get currentService => _service;

  @override
  FutureOr<SocketService?> build() async {
    final buildGeneration = ++_buildGeneration;
    _registerDisposeHook(buildGeneration);
    final reviewerMode = ref.watch(reviewerModeProvider);
    final authenticated = ref.watch(isAuthenticatedProvider2);
    final token = ref.watch(authTokenProvider3);
    final authSessionEpoch = ref.watch(openWebUiAuthSessionEpochProvider);
    if (reviewerMode || !authenticated || token == null || token.isEmpty) {
      _disposeService();
      return null;
    }

    // A token transition may represent another user on the same server. Drop
    // the old socket synchronously, before the first await, so the provider's
    // loading fallback can never expose the prior session or its room handlers.
    if (_service != null && _serviceToken != token) {
      _disposeService();
    }

    final activeServerSnapshot = ref.watch(activeServerProvider);
    final immediatelyKnownServer = activeServerSnapshot.asData?.value;
    if (_service != null &&
        (immediatelyKnownServer == null ||
            _service!.serverConfig.id != immediatelyKnownServer.id)) {
      // A live socket is safe to expose during an ordinary rebuild only while
      // the active server is still provably the same. Server selection enters
      // loading before its replacement resolves, so fail closed instead of
      // letting socketServiceProvider's loading fallback expose the old host.
      _disposeService();
    }

    final server = await ref.watch(activeServerProvider.future);
    if (!_buildStillOwnsContext(
      buildGeneration: buildGeneration,
      token: token,
      authSessionEpoch: authSessionEpoch,
      server: server,
    )) {
      // AsyncNotifier ignores an obsolete build's returned state, but the
      // continuation can still execute side effects. Never let that stale
      // continuation dispose or replace the socket installed by a newer auth or
      // server generation.
      return null;
    }
    if (server == null) {
      _disposeService();
      return null;
    }

    final transportMode = ref.watch(
      appSettingsProvider.select((settings) => settings.socketTransportMode),
    );
    final websocketOnly = transportMode == 'ws';
    final transportAvailability = ref.watch(socketTransportOptionsProvider);
    final allowWebsocketUpgrade = transportAvailability.allowWebsocketOnly;

    final requiresNewService =
        _service == null ||
        _serviceToken != token ||
        _service!.serverConfig.id != server.id ||
        _service!.websocketOnly != websocketOnly ||
        _service!.allowWebsocketUpgrade != allowWebsocketUpgrade;
    if (requiresNewService) {
      _disposeService();
      _service = ref.read(socketServiceFactoryProvider)(
        serverConfig: server,
        authToken: token,
        websocketOnly: websocketOnly,
        allowWebsocketUpgrade: allowWebsocketUpgrade,
      );
      _serviceToken = token;
      _scheduleConnect(_service!);
    }

    // Listen to connectivity changes to proactively manage socket connection.
    // When network goes offline, we can save resources by not attempting
    // reconnections. When network comes back, we force a reconnect.
    _connectivitySubscription ??= ref.listen<ConnectivityStatus>(
      connectivityStatusProvider,
      (previous, next) {
        final service = _service;
        if (service == null) return;

        if (next == ConnectivityStatus.offline) {
          service.updateNetworkAvailability(false);
          DebugLogger.log(
            'Connectivity offline - socket transport suspended',
            scope: 'socket/provider',
          );
        } else if (previous == ConnectivityStatus.offline &&
            next == ConnectivityStatus.online) {
          // Network just came back online - force reconnect to restore socket
          DebugLogger.log(
            'Connectivity restored - forcing socket reconnect',
            scope: 'socket/provider',
          );
          service.updateNetworkAvailability(true);
        }
      },
      fireImmediately: true,
    );

    return _service;
  }

  void _registerDisposeHook(int buildGeneration) {
    ref.onDispose(() {
      if (buildGeneration != _buildGeneration) return;

      // Fence every continuation before releasing the currently-owned service.
      _buildGeneration++;
      _connectivitySubscription?.close();
      _connectivitySubscription = null;

      // Riverpod runs onDispose both before a rebuild and when the provider is
      // destroyed. Let a replacement build retain a same-context socket, but
      // release it once the notifier is genuinely unmounted.
      scheduleMicrotask(() {
        if (!ref.mounted) {
          _disposeService();
        }
      });
    });
  }

  bool _buildStillOwnsContext({
    required int buildGeneration,
    required String token,
    required Object authSessionEpoch,
    required ServerConfig? server,
  }) {
    if (!ref.mounted || buildGeneration != _buildGeneration) return false;
    if (ref.read(reviewerModeProvider) ||
        !ref.read(isAuthenticatedProvider2) ||
        ref.read(authTokenProvider3) != token ||
        !identical(
          ref.read(openWebUiAuthSessionEpochProvider),
          authSessionEpoch,
        )) {
      return false;
    }
    final currentServer = ref.read(activeServerProvider).asData;
    return currentServer != null && currentServer.value == server;
  }

  void _scheduleConnect(SocketService service) {
    final token = ++_connectToken;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!ref.mounted) return;
      if (_connectToken != token) return;
      if (!identical(_service, service)) return;
      service.connectBestEffort(reason: 'provider-post-frame');
    });
  }

  void _disposeService() {
    _connectToken++;
    _serviceToken = null;
    if (_service == null) return;
    try {
      _service!.dispose();
    } catch (_) {}
    _service = null;
  }
}

final socketServiceProvider = Provider<SocketService?>((ref) {
  final asyncService = ref.watch(socketServiceManagerProvider);
  // While the manager re-runs its async `build` (on any watched-dependency
  // change), it is briefly `loading`; don't collapse the live socket to `null`
  // then — that churns consumers and forces HTTP-only sends. Fall back to the
  // manager's current service during loading/error; it's only truly null when
  // there is no active server / reviewer mode / it was disposed.
  return asyncService.maybeWhen(
    data: (service) => service,
    orElse: () =>
        ref.read(socketServiceManagerProvider.notifier).currentService,
  );
});

// Attachment upload queue — one instance per active server.
//
// Constructs the queue and kicks off its (async) initialization against the
// active server's API + Drift table. Consumers `await queue.ready` before
// enqueueing so an upload never races the load; `ready` is owned by the queue
// instance, so — unlike a `FutureProvider.future` — awaiting it cannot hang if
// this provider rebuilds mid-initialization. The provider is also gated on the
// authenticated state: logout flips `isAuthenticatedProvider2` false before its
// first await, disposing the previous queue immediately even though the active
// server (and ApiService object) is deliberately preserved. On server switch or
// logout, `ref.onDispose` cancels in-flight uploads and closes the stream so
// awaiting upload completers resolve via `onDone`. Null while unauthenticated,
// in reviewer mode, when there is no active server, or until that server's
// durable database is available.
final attachmentUploadQueueProvider = Provider<AttachmentUploadQueue?>((ref) {
  if (!ref.watch(isAuthenticatedProvider2)) return null;
  final api = ref.watch(apiServiceProvider);
  if (api == null) return null;
  // Database opening can be temporarily deferred on iOS (for example while
  // protected data is unavailable). Stay null and rebuild reactively instead
  // of publishing an apparently-ready queue that skipped durable rows forever.
  final database = ref.watch(appDatabaseProvider);
  if (database == null) return null;

  final queue = AttachmentUploadQueue();
  ref.onDispose(queue.dispose);
  // Readiness is exposed via `queue.ready`, awaited by callers. Attach an
  // immediate error-consuming branch so a Drift load failure cannot surface as
  // an uncaught fire-and-forget error; `queue.ready` retains the ORIGINAL
  // future and still rejects, aborting the upload before enqueue.
  final initialization = queue.initialize(
    onUpload: (filePath, fileName, {cancelToken}) =>
        api.uploadFile(filePath, fileName, cancelToken: cancelToken),
    database: () => database,
  );
  unawaited(initialization.catchError((Object _, StackTrace _) {}));
  return queue;
});

// Auth providers
// Auth token integration with API service - using unified auth system
final apiTokenUpdaterProvider = Provider<void>((ref) {
  void syncToken(ApiService? api, String? token) {
    if (api == null) return;
    api.updateAuthToken(token != null && token.isNotEmpty ? token : null);
    final length = token?.length ?? 0;
    DebugLogger.auth(
      'token-updated',
      scope: 'auth/api',
      data: {'length': length},
    );
  }

  syncToken(ref.read(apiServiceProvider), ref.read(authTokenProvider3));

  ref.listen<ApiService?>(apiServiceProvider, (previous, next) {
    syncToken(next, ref.read(authTokenProvider3));
  });

  ref.listen<String?>(authTokenProvider3, (previous, next) {
    syncToken(ref.read(apiServiceProvider), next);
  });
});

@Riverpod(keepAlive: true)
Future<User?> currentUser(Ref ref) async {
  final api = ref.watch(apiServiceProvider);
  final authState = ref.watch(authStateManagerProvider);
  ref.watch(openWebUiAuthSessionEpochProvider);
  ref.watch(openWebUiDatabaseAccessProvider);
  ref.watch(openWebUiCertifiedDatabaseServerProvider);
  ref.watch(activeServerProvider);
  final isAuthenticated = authState.maybeWhen(
    data: (state) => state.isAuthenticated,
    orElse: () => false,
  );

  if (api == null || !isAuthenticated) return null;

  // Fast path: use user already in auth state.
  final authUser = authState.maybeWhen(
    data: (state) => state.user,
    orElse: () => null,
  );
  if (authUser != null) return authUser;

  final cacheOwnership = captureOpenWebUiCacheOwnership(
    ref,
    api: api,
    requireAuthenticated: false,
  );
  if (cacheOwnership == null) return null;

  // Next: try cached user from storage, then refresh in the background.
  final storage = ref.read(optimizedStorageServiceProvider);
  final cachedUser = await _getCachedUserWithAvatar(storage);
  if (!openWebUiCacheOwnershipIsCurrent(ref, cacheOwnership)) return null;
  final token = cacheOwnership.authToken;
  final marker = ref
      .read(openWebUiAccountOwnerMarkerStoreProvider)
      .read(cacheOwnership.serverId);
  final cachedOwnerMatches =
      cachedUser != null &&
      token != null &&
      openWebUiAccountOwnerMarkerMatches(
        marker: marker,
        token: token,
        userId: cachedUser.id,
      );
  if (cachedOwnerMatches) {
    final lastRefresh = ref.read(_lastUserRefreshProvider);
    final now = DateTime.now();
    final shouldRefresh =
        lastRefresh == null ||
        now.difference(lastRefresh) > const Duration(minutes: 5);

    if (shouldRefresh) {
      Future.microtask(() async {
        final fresh = await _refreshCurrentUser(ref);
        if (fresh != null && ref.mounted) {
          ref.read(_lastUserRefreshProvider.notifier).set(now);
          ref.invalidate(currentUserProvider);
        }
      });
    }
    return cachedUser;
  }

  // Fallback: fetch fresh.
  final fresh = await _refreshCurrentUser(ref);
  if (fresh != null && ref.mounted) {
    ref.read(_lastUserRefreshProvider.notifier).set(DateTime.now());
  }
  return ref.mounted ? fresh : null;
}

Future<User?> _getCachedUserWithAvatar(OptimizedStorageService storage) =>
    storage.getLocalUserWithAvatar();

Future<User?> _refreshCurrentUser(Ref ref) async {
  // A warm refresh is queued in a microtask. Authentication/server changes can
  // invalidate the provider build before that task starts, so do not perform
  // even the first provider read through a retired Ref.
  if (!ref.mounted) return null;
  final api = ref.read(apiServiceProvider);
  if (api == null) return null;
  final ownership = captureOpenWebUiCacheOwnership(
    ref,
    api: api,
    requireAuthenticated: false,
  );
  if (ownership == null) return null;

  try {
    final user = await api.getCurrentUser();
    if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) return null;
    final storage = ref.read(optimizedStorageServiceProvider);
    await storage.saveLocalUserWithAvatar(user, avatarUrl: user.profileImage);
    if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) return null;
    return user;
  } catch (_) {
    return null;
  }
}

@Riverpod(keepAlive: true)
class _LastUserRefresh extends _$LastUserRefresh {
  @override
  DateTime? build() => null;

  void set(DateTime? timestamp) => state = timestamp;
}

// Helper provider to force refresh auth state - now using unified system
final refreshAuthStateProvider = Provider<void>((ref) {
  // This provider can be invalidated to force refresh the unified auth system
  Future.microtask(() => ref.read(authActionsProvider).refresh());
  return;
});

// Model providers
@visibleForTesting
List<Model> appendHermesModelIfUsable(
  List<Model> models, {
  required bool hermesUsable,
}) {
  final directModels = models.where(isLocallyMintedDirectModel);
  final safeModels = sanitizeRemoteHermesModels(
    sanitizeRemoteDirectModels(models),
  );
  return hermesUsable
      ? <Model>[...safeModels, ...directModels, hermesSyntheticModel()]
      : <Model>[...safeModels, ...directModels];
}

String _modelBackendForDiagnostics(Model? model) {
  if (model == null) return 'none';
  if (isLocallyMintedDirectModel(model)) return 'direct';
  if (isHermesModel(model)) return 'hermes';
  return 'openwebui';
}

@Riverpod(keepAlive: true)
class Models extends _$Models {
  bool _terminalDirectDiscoveryNeedsReconciliation = false;

  @override
  Future<List<Model>> build() async {
    // Reviewer mode returns mock models
    if (ref.watch(reviewerModeProvider)) {
      return _demoModels();
    }

    final hermesUsable = ref.watch(
      hermesConfigProvider.select((config) => config.isUsable),
    );
    final directModels = ref.watch(
      directModelDiscoveryProvider.select((value) {
        final models = value.value?.models;
        // Keep loading -> empty discovery transitions referentially stable.
        // Otherwise an empty, newly wrapped list can cancel a concurrent
        // modelsProvider rebuild and leave callers awaiting its old future.
        return models == null || models.isEmpty ? const <Model>[] : models;
      }),
    );
    // Initial discovery loading is reconciliation context, not a model-list
    // dependency. Watching it would turn loading -> empty into an otherwise
    // spurious rebuild and could cancel a concurrent Hermes/auth rebuild.
    final directDiscovery = ref.read(directModelDiscoveryProvider);
    final deferDirectSelectionReconciliation =
        directDiscovery.isLoading && !directDiscovery.hasValue;
    // A backend switch must also reconcile a keepAlive model selection. This
    // is especially important after OpenWebUI logout, where the old remote
    // model can otherwise survive while the retained server remains present.
    ref.watch(preferredBackendProvider);
    ref.listen<AsyncValue<DirectModelDiscoveryState>>(
      directModelDiscoveryProvider,
      _handleDirectDiscoveryTransition,
    );
    ref.listen<bool>(hermesConfigProvider.select((config) => config.isUsable), (
      previous,
      next,
    ) {
      if (!next) _clearHermesSelection();
    });
    if (!hermesUsable) {
      // A build cannot synchronously mutate another provider. Queue the clear
      // before any model fetch so a failed cache/API load still fails closed.
      unawaited(
        Future<void>(() {
          if (ref.mounted && !ref.read(hermesConfigProvider).isUsable) {
            _clearHermesSelection();
          }
        }),
      );
    }

    final modelAuth = ref.watch(_modelAuthReadinessProvider);
    // `isAuthenticated` is false during a token-preserving refresh too. Watch
    // the richer auth signals so loading -> terminal sign-out triggers a
    // second reconciliation without clobbering a live mixed-mode selection in
    // the transient loading state.
    if (!modelAuth.authenticated && _modelAuthIsPending(modelAuth)) {
      // Pending credentials are not authority for cache/API work. Preserve an
      // already-rendered in-memory list until auth reaches a terminal state;
      // on cold start, expose only app-owned transports without mutating the
      // persisted OpenWebUI cache.
      final previous = state.value;
      if (previous != null) return previous;
      return _returnWithSelectionReconciliation(
        _withLocalModels(const <Model>[], directModels: directModels),
        deferDirectSelection: deferDirectSelectionReconciliation,
      );
    }
    if (!_modelAuthRetainsOpenWebUiSession(modelAuth)) {
      // Standalone mode surfaces app-owned transports without requiring an
      // Open WebUI session.
      final localModels = _withLocalModels(
        const <Model>[],
        directModels: directModels,
      );
      if (localModels.isNotEmpty) {
        return _returnWithSelectionReconciliation(
          localModels,
          deferDirectSelection: deferDirectSelectionReconciliation,
        );
      }
      DebugLogger.log('skip-unauthed', scope: 'models');
      _persistModelsAsync(const <Model>[]);
      return _returnWithSelectionReconciliation(
        const <Model>[],
        deferDirectSelection: deferDirectSelectionReconciliation,
      );
    }

    // These ownership dependencies fence only OpenWebUI cache/API work. Do
    // not initialize or subscribe to server storage in accountless
    // Direct/Hermes mode: doing so can repeatedly cancel the otherwise
    // synchronous local-model build while an optional retained server settles.
    ref.watch(openWebUiAuthSessionEpochProvider);
    ref.watch(openWebUiDatabaseAccessProvider);
    ref.watch(openWebUiCertifiedDatabaseServerProvider);
    ref.watch(activeServerProvider.select((value) => value.value?.id));

    // Re-run whenever Hermes connection usability changes so the synthetic
    // model cannot outlive (or appear before) its configured service.
    final api = ref.watch(apiServiceProvider);
    final cacheOwnership = api == null
        ? null
        : captureOpenWebUiCacheOwnership(
            ref,
            api: api,
            requireAuthenticated: false,
          );
    if (api != null && cacheOwnership == null) {
      return _returnWithSelectionReconciliation(
        _withLocalModels(const <Model>[], directModels: directModels),
        deferDirectSelection: deferDirectSelectionReconciliation,
      );
    }
    final storage = ref.watch(optimizedStorageServiceProvider);
    try {
      final cached = await storage.getLocalModels();
      if (cacheOwnership != null &&
          !openWebUiCacheOwnershipIsCurrent(ref, cacheOwnership)) {
        return _returnWithSelectionReconciliation(
          _withLocalModels(const <Model>[], directModels: directModels),
          deferDirectSelection: deferDirectSelectionReconciliation,
        );
      }
      if (cached.isNotEmpty) {
        final visibleCached = sanitizeRemoteHermesModels(
          sanitizeRemoteDirectModels(_visibleModels(cached)),
        );
        DebugLogger.log(
          'cache-restored',
          scope: 'models/cache',
          data: {
            'count': visibleCached.length,
            'hidden': cached.length - visibleCached.length,
          },
        );
        if (visibleCached.length != cached.length && cacheOwnership != null) {
          _persistModelsAsync(visibleCached, ownership: cacheOwnership);
        }
        Future.microtask(() async {
          if (!ref.mounted) return;
          try {
            await refresh();
          } catch (error, stackTrace) {
            DebugLogger.error(
              'warm-refresh-failed',
              scope: 'models/cache',
              error: error,
              stackTrace: stackTrace,
            );
          }
        });
        return _returnWithSelectionReconciliation(
          _withLocalModels(visibleCached, directModels: directModels),
          deferDirectSelection: deferDirectSelectionReconciliation,
        );
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'cache-load-failed',
        scope: 'models/cache',
        error: error,
        stackTrace: stackTrace,
      );
    }

    if (api == null) {
      DebugLogger.warning('api-missing', scope: 'models');
      _persistModelsAsync(const <Model>[]);
      return _returnWithSelectionReconciliation(
        _withLocalModels(const <Model>[], directModels: directModels),
        deferDirectSelection: deferDirectSelectionReconciliation,
      );
    }

    try {
      final loaded = await _load(api);
      if (loaded == null ||
          !openWebUiCacheOwnershipIsCurrent(ref, loaded.ownership)) {
        return _returnWithSelectionReconciliation(
          _withLocalModels(const <Model>[], directModels: directModels),
          deferDirectSelection: deferDirectSelectionReconciliation,
        );
      }
      return _returnWithSelectionReconciliation(
        _withLocalModels(loaded.models, directModels: directModels),
        deferDirectSelection: deferDirectSelectionReconciliation,
      );
    } catch (_) {
      final localModels = _withLocalModels(
        const <Model>[],
        directModels: directModels,
      );
      if (localModels.isNotEmpty) {
        return _returnWithSelectionReconciliation(
          localModels,
          deferDirectSelection: deferDirectSelectionReconciliation,
        );
      }
      _returnWithSelectionReconciliation(
        localModels,
        deferDirectSelection: deferDirectSelectionReconciliation,
      );
      rethrow;
    }
  }

  List<Model> _returnWithSelectionReconciliation(
    List<Model> models, {
    bool deferDirectSelection = false,
  }) {
    unawaited(
      Future<void>(() {
        if (ref.mounted) {
          final reconcileTerminalDiscovery =
              _terminalDirectDiscoveryNeedsReconciliation;
          if (reconcileTerminalDiscovery) {
            _terminalDirectDiscoveryNeedsReconciliation = false;
          }
          _reconcileLocalSelection(
            models,
            deferDirectSelection:
                deferDirectSelection && !reconcileTerminalDiscovery,
          );
        }
      }),
    );
    return models;
  }

  void _handleDirectDiscoveryTransition(
    AsyncValue<DirectModelDiscoveryState>? previous,
    AsyncValue<DirectModelDiscoveryState> next,
  ) {
    final isInitialLoading = next.isLoading && !next.hasValue;
    if (isInitialLoading) {
      _terminalDirectDiscoveryNeedsReconciliation = false;
      return;
    }
    final wasInitialLoading =
        previous?.isLoading == true && previous?.hasValue == false;
    if (!wasInitialLoading) return;

    final discoveredModels = next.value?.models ?? const <Model>[];
    if (discoveredModels.isNotEmpty) {
      _terminalDirectDiscoveryNeedsReconciliation = false;
      return;
    }

    _terminalDirectDiscoveryNeedsReconciliation = true;
    unawaited(
      Future<void>(() {
        if (!ref.mounted ||
            !_terminalDirectDiscoveryNeedsReconciliation ||
            (state.isLoading && !state.hasValue)) {
          return;
        }
        _terminalDirectDiscoveryNeedsReconciliation = false;
        _reconcileLocalSelection(state.value ?? const <Model>[]);
      }),
    );
  }

  /// Appends locally minted direct/Hermes models after the OpenWebUI list has
  /// been sanitized and persisted. Local transport models remain runtime-only.
  List<Model> _withLocalModels(
    List<Model> models, {
    List<Model>? directModels,
  }) {
    final withDirect = reconcileDirectModelsForDisplay(
      remoteModels: models,
      directModels:
          directModels ??
          ref.read(directModelDiscoveryProvider).value?.models ??
          const <Model>[],
      registry: ref.read(directModelRegistryProvider),
    );
    return appendHermesModelIfUsable(
      withDirect,
      hermesUsable: ref.read(hermesConfigProvider).isUsable,
    );
  }

  /// Prevents a disabled or incomplete Hermes connection from leaving the
  /// composer bound to a transport that can no longer handle the selection.
  /// Prefer the first available OpenWebUI model; Hermes-only mode clears it.
  List<Model> _reconcileLocalSelection(
    List<Model> models, {
    bool deferDirectSelection = false,
  }) {
    final currentSelected = ref.read(selectedModelProvider);
    final modelAuth = ref.read(_modelAuthReadinessProvider);
    if (!modelAuth.authenticated) {
      final shouldReconcile = _shouldUseAccountlessModelSelection(
        isAuthenticated: false,
        isAuthLoading: modelAuth.loading,
        authStatus: modelAuth.status,
        preferredBackend: ref.read(preferredBackendProvider),
        hasApiService: ref.read(apiServiceProvider) != null,
      );
      if (!shouldReconcile) return models;

      if (deferDirectSelection &&
          currentSelected != null &&
          isLocallyMintedDirectModel(currentSelected)) {
        return models;
      }

      final replacement = _accountlessSelection(
        models: models,
        current: currentSelected,
        preferredBackend: ref.read(preferredBackendProvider),
        preferredModelId:
            currentSelected != null && ref.read(isManualModelSelectionProvider)
            ? null
            : ref.read(appSettingsProvider).defaultModel,
      );
      if (identical(currentSelected, replacement)) return models;

      // Rebinding the same trusted model id after discovery should preserve a
      // deliberate manual selection. Crossing transports (or clearing a stale
      // remote selection) restores automatic selection semantics.
      if (currentSelected?.id != replacement?.id) {
        ref.read(isManualModelSelectionProvider.notifier).set(false);
      }
      ref.read(selectedModelProvider.notifier).set(replacement);
      DebugLogger.warning(
        'accountless-selection-reconciled',
        scope: 'models',
        data: {
          'previousBackend': _modelBackendForDiagnostics(currentSelected),
          'replacementBackend': _modelBackendForDiagnostics(replacement),
          'source': 'reconciliation',
        },
      );
      return models;
    }

    final isLocalTransport =
        currentSelected != null &&
        (isHermesModel(currentSelected) ||
            isLocallyMintedDirectModel(currentSelected));
    if (currentSelected == null || !isLocalTransport) {
      return models;
    }
    if (deferDirectSelection && isLocallyMintedDirectModel(currentSelected)) {
      return models;
    }

    final matching = models
        .where((model) => model.id == currentSelected.id)
        .firstOrNull;
    if (matching != null) {
      if (isLocallyMintedDirectModel(currentSelected)) {
        final registry = ref.read(directModelRegistryProvider);
        if (!identical(matching, currentSelected) ||
            registry.resolve(currentSelected) == null) {
          ref.read(selectedModelProvider.notifier).set(matching);
          DebugLogger.log(
            'direct-selection-rebound',
            scope: 'models',
            data: {'backend': 'direct', 'source': 'discovery'},
          );
        }
      }
      return models;
    }

    final replacement = models.isNotEmpty ? models.first : null;
    ref.read(isManualModelSelectionProvider.notifier).set(false);
    ref.read(selectedModelProvider.notifier).set(replacement);
    DebugLogger.warning(
      'local-selection-unavailable',
      scope: 'models',
      data: {
        'replacementBackend': _modelBackendForDiagnostics(replacement),
        'source': 'reconciliation',
      },
    );
    return models;
  }

  void _clearHermesSelection() {
    final currentSelected = ref.read(selectedModelProvider);
    if (currentSelected == null || !isHermesModel(currentSelected)) return;

    ref.read(isManualModelSelectionProvider.notifier).set(false);
    ref.read(selectedModelProvider.notifier).clear();
    DebugLogger.warning('hermes-selection-unavailable', scope: 'models');
  }

  Future<void> refresh() async {
    if (ref.read(reviewerModeProvider)) {
      state = AsyncData<List<Model>>(_reconcileLocalSelection(_demoModels()));
      return;
    }
    await ref.read(directModelDiscoveryProvider.notifier).refresh();
    final modelAuth = ref.read(_modelAuthReadinessProvider);
    if (!modelAuth.authenticated && _modelAuthIsPending(modelAuth)) {
      // An explicit refresh during login/revalidation is deferred. This keeps
      // the current in-memory list intact without treating retained or
      // candidate credentials as permission to touch OpenWebUI cache/API data.
      return;
    }
    if (!_modelAuthRetainsOpenWebUiSession(modelAuth)) {
      final models = _withLocalModels(const <Model>[]);
      state = AsyncData<List<Model>>(_reconcileLocalSelection(models));
      // Keep locally minted transport models runtime-only.
      _persistModelsAsync(const <Model>[]);
      return;
    }
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      state = AsyncData<List<Model>>(
        _reconcileLocalSelection(_withLocalModels(const <Model>[])),
      );
      _persistModelsAsync(const <Model>[]);
      return;
    }
    final result = await AsyncValue.guard(() => _load(api));
    if (!ref.mounted) return;
    final loaded = result.value;
    if (result.hasValue &&
        (loaded == null ||
            !openWebUiCacheOwnershipIsCurrent(ref, loaded.ownership))) {
      return;
    }
    final withLocal = result.whenData(
      (owned) => _reconcileLocalSelection(_withLocalModels(owned!.models)),
    );
    if (withLocal.hasError) {
      final selected = ref.read(selectedModelProvider);
      final preserveRemoteSelection =
          selected != null &&
          !isHermesModel(selected) &&
          !isLocallyMintedDirectModel(selected);
      if (preserveRemoteSelection) {
        // A transient OpenWebUI refresh failure must not replace an active
        // server model with the first standalone transport model.
        state = withLocal;
      } else {
        final localModels = _reconcileLocalSelection(
          _withLocalModels(const <Model>[]),
        );
        state = localModels.isEmpty
            ? withLocal
            : AsyncData<List<Model>>(localModels);
      }
    } else {
      state = withLocal;
    }

    // Update selected model with fresh data (e.g., filters) if it exists
    // in the new models list
    final currentState = state;
    if (currentState.hasValue) {
      final freshModels = currentState.value!;
      final currentSelected = ref.read(selectedModelProvider);
      if (currentSelected != null) {
        if (currentSelected.isHidden) {
          return;
        }
        try {
          final freshModel = freshModels.firstWhere(
            (m) => m.id == currentSelected.id,
          );
          // Update selected model with fresh data (filters, etc.)
          if (freshModel != currentSelected) {
            ref.read(selectedModelProvider.notifier).set(freshModel);
            DebugLogger.log(
              'selected-model-refreshed',
              scope: 'models',
              data: {
                'backend': _modelBackendForDiagnostics(freshModel),
                'filters': freshModel.filters?.length ?? 0,
                'source': 'refresh',
              },
            );
          }
        } catch (_) {
          final replacement = freshModels.isNotEmpty ? freshModels.first : null;
          ref.read(isManualModelSelectionProvider.notifier).set(false);
          ref.read(selectedModelProvider.notifier).set(replacement);
          DebugLogger.warning(
            'selected-model-unavailable',
            scope: 'models',
            data: {
              'previousBackend': _modelBackendForDiagnostics(currentSelected),
              'replacementBackend': _modelBackendForDiagnostics(replacement),
              'source': 'refresh',
            },
          );
        }
      }
    }
  }

  Future<_OwnedModels?> _load(ApiService api) async {
    final ownership = captureOpenWebUiCacheOwnership(
      ref,
      api: api,
      requireAuthenticated: false,
    );
    if (ownership == null) return null;
    try {
      DebugLogger.log('fetch-start', scope: 'models');
      final models = await api.getModels();
      if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) return null;
      final visibleModels = sanitizeRemoteHermesModels(
        sanitizeRemoteDirectModels(_visibleModels(models)),
      );
      DebugLogger.log(
        'fetch-ok',
        scope: 'models',
        data: {
          'count': visibleModels.length,
          'hidden': models.length - visibleModels.length,
        },
      );
      _persistModelsAsync(visibleModels, ownership: ownership);
      return (models: visibleModels, ownership: ownership);
    } catch (e, stackTrace) {
      DebugLogger.error(
        'fetch-failed',
        scope: 'models',
        error: e,
        stackTrace: stackTrace,
      );

      // If models endpoint returns 403, this should now clear auth token
      // and redirect user to login since it's marked as a core endpoint
      if (e.toString().contains('403')) {
        DebugLogger.warning('endpoint-403', scope: 'models');
      }
      // Preserve an existing selection on transient refresh failures. Returning
      // an empty list here makes the synthetic Hermes model look like the only
      // successful result and can silently switch an OpenWebUI conversation.
      rethrow;
    }
  }

  List<Model> _visibleModels(List<Model> models) {
    if (models.isEmpty) return const <Model>[];
    return models.where((model) => !model.isHidden).toList();
  }

  void _persistModelsAsync(
    List<Model> models, {
    OpenWebUiCacheOwnershipSnapshot? ownership,
  }) {
    if (ownership != null &&
        !openWebUiCacheOwnershipIsCurrent(ref, ownership)) {
      return;
    }
    final storage = ref.read(optimizedStorageServiceProvider);
    unawaited(
      storage.saveLocalModels(models).onError((error, stack) {
        DebugLogger.error(
          'Failed to persist models to cache',
          scope: 'models/cache',
          error: error,
          stackTrace: stack,
        );
      }),
    );
  }

  List<Model> _demoModels() => const [
    Model(
      id: 'demo/gemma-2-mini',
      name: 'Gemma 2 Mini (Demo)',
      description: 'Demo model for reviewer mode',
      isMultimodal: true,
      supportsStreaming: true,
      supportedParameters: ['max_tokens', 'stream'],
    ),
    Model(
      id: 'demo/llama-3-8b',
      name: 'Llama 3 8B (Demo)',
      description: 'Fast text model for demo',
      isMultimodal: false,
      supportsStreaming: true,
      supportedParameters: ['max_tokens', 'stream'],
    ),
  ];
}

typedef _OwnedModels = ({
  List<Model> models,
  OpenWebUiCacheOwnershipSnapshot ownership,
});

@Riverpod(keepAlive: true)
class SelectedModel extends _$SelectedModel {
  bool _authenticatedDefaultRestoreScheduled = false;
  bool _accountlessBackendReconciliationPending = false;

  @override
  Model? build() {
    // This provider is consumed before auth and secure Hermes secrets finish
    // hydrating on a cold start. Reconcile again when either one settles;
    // callers such as the chat page only await defaultModelProvider once.
    ref.listen<_ModelAuthReadiness>(_modelAuthReadinessProvider, (
      previous,
      next,
    ) {
      if (next.authenticated) {
        _scheduleAuthenticatedDefaultRestore();
      } else {
        _restorePrimaryAccountlessSelection();
      }
    });
    ref.listen<PreferredBackend>(preferredBackendProvider, (previous, next) {
      _accountlessBackendReconciliationPending =
          next == PreferredBackend.direct || next == PreferredBackend.hermes;
      _schedulePrimaryAccountlessRestore();
    });
    ref.listen<bool>(
      hermesConfigProvider.select((config) => config.isUsable),
      (previous, next) => _schedulePrimaryAccountlessRestore(),
    );
    ref.listen<AsyncValue<DirectModelDiscoveryState>>(
      directModelDiscoveryProvider,
      (previous, next) => _schedulePrimaryAccountlessRestore(),
    );
    ref.listen<ApiService?>(apiServiceProvider, (previous, next) {
      if (next != null) _scheduleAuthenticatedDefaultRestore();
    });
    ref.listen<String?>(authTokenProvider3, (previous, next) {
      if (previous != next &&
          ref.read(_modelAuthReadinessProvider).authenticated) {
        _scheduleAuthenticatedDefaultRestore();
      }
    });

    final initialDecision = _primaryAccountlessDecision(current: null);
    if (initialDecision.shouldReconcile &&
        ref.read(isManualModelSelectionProvider)) {
      // User-scoped sign-out cleanup invalidates the selected model but not the
      // manual-selection bit. Once selection is rebuilt automatically, that
      // bit must not later suppress an authenticated OpenWebUI default.
      unawaited(
        Future<void>.microtask(() {
          if (ref.mounted) {
            ref.read(isManualModelSelectionProvider.notifier).set(false);
          }
        }),
      );
    }
    return initialDecision.model;
  }

  ({bool shouldReconcile, Model? model}) _primaryAccountlessDecision({
    required Model? current,
  }) {
    // Sign-out cleanup invalidates user-scoped model state after auth settles.
    // A retained OpenWebUI server must not make that cleanup erase the primary
    // accountless transport that the router has already admitted to chat.
    final preferredBackend = ref.read(preferredBackendProvider);
    if (preferredBackend != PreferredBackend.hermes &&
        preferredBackend != PreferredBackend.direct) {
      return (shouldReconcile: false, model: null);
    }

    final modelAuth = ref.read(_modelAuthReadinessProvider);
    if (modelAuth.authenticated || modelAuth.loading) {
      return (shouldReconcile: false, model: null);
    }
    if (modelAuth.status == AuthStatus.initial ||
        modelAuth.status == AuthStatus.loading ||
        modelAuth.status == AuthStatus.authenticated) {
      return (shouldReconcile: false, model: null);
    }

    if (preferredBackend == PreferredBackend.hermes) {
      if (!ref.read(hermesConfigProvider).isUsable) {
        // A false value can be the initial secure-secret hydration state.
        // Models owns clearing a connection that is definitively unusable.
        return (shouldReconcile: false, model: null);
      }
      return (
        shouldReconcile: true,
        model: current != null && isHermesModel(current)
            ? current
            : hermesSyntheticModel(),
      );
    }

    final discovery = ref.read(directModelDiscoveryProvider);
    if (discovery.isLoading && !discovery.hasValue) {
      return (shouldReconcile: false, model: null);
    }
    final registry = ref.read(directModelRegistryProvider);
    final trustedModels = (discovery.value?.models ?? const <Model>[])
        .where((model) => registry.resolve(model) != null)
        .toList(growable: false);
    return (
      shouldReconcile: true,
      model: _accountlessSelection(
        models: trustedModels,
        current: current,
        preferredBackend: preferredBackend,
        preferredModelId:
            current != null && ref.read(isManualModelSelectionProvider)
            ? null
            : ref.read(appSettingsProvider).defaultModel,
      ),
    );
  }

  void _schedulePrimaryAccountlessRestore() {
    unawaited(
      Future<void>.microtask(() {
        if (!ref.mounted) return;
        _restorePrimaryAccountlessSelection();
      }),
    );
  }

  void _restorePrimaryAccountlessSelection() {
    if (!ref.mounted) return;
    final current = state;
    if (current != null && ref.read(isManualModelSelectionProvider)) {
      final preferredBackend = ref.read(preferredBackendProvider);
      final manualSelectionIsUsable =
          ref.read(reviewerModeProvider) ||
          switch (preferredBackend) {
            PreferredBackend.direct =>
              isLocallyMintedDirectModel(current) &&
                  ref.read(directModelRegistryProvider).resolve(current) != null,
            PreferredBackend.hermes =>
              isHermesModel(current) && ref.read(hermesConfigProvider).isUsable,
            _ => false,
          };
      if (manualSelectionIsUsable &&
          (!_accountlessBackendReconciliationPending ||
              _matchesPreferredBackend(current, preferredBackend))) {
        _accountlessBackendReconciliationPending = false;
        return;
      }
    }
    final decision = _primaryAccountlessDecision(current: current);
    if (!decision.shouldReconcile) return;
    final replacement = decision.model;
    final currentBindingIsValid =
        current != null &&
        isLocallyMintedDirectModel(current) &&
        ref.read(directModelRegistryProvider).resolve(current) != null;
    if (current == null && replacement == null) return;
    if (current != null &&
        replacement != null &&
        current.id == replacement.id &&
        (!isLocallyMintedDirectModel(replacement) || currentBindingIsValid)) {
      _accountlessBackendReconciliationPending = false;
      return;
    }

    if (current?.id != replacement?.id) {
      ref.read(isManualModelSelectionProvider.notifier).set(false);
    }
    state = replacement;
    _accountlessBackendReconciliationPending = false;
    DebugLogger.warning(
      'primary-accountless-selection-restored',
      scope: 'models/default',
      data: {
        'previousBackend': _modelBackendForDiagnostics(current),
        'replacementBackend': _modelBackendForDiagnostics(replacement),
        'source': 'reconciliation',
      },
    );
  }

  void _scheduleAuthenticatedDefaultRestore() {
    if (_authenticatedDefaultRestoreScheduled) return;
    _authenticatedDefaultRestoreScheduled = true;
    unawaited(
      Future<void>.microtask(() {
        _authenticatedDefaultRestoreScheduled = false;
        if (!ref.mounted) return;
        final current = state;
        final staleLocalTransport =
            current != null &&
            (isHermesModel(current) || isLocallyMintedDirectModel(current));
        if (current != null && !staleLocalTransport) return;
        final auth = ref.read(_modelAuthReadinessProvider);
        if (!auth.authenticated || ref.read(apiServiceProvider) == null) return;

        // A background saved-credential login can finish after an earlier
        // one-shot read cached null. Force a fresh authenticated resolution.
        // Dispatch instead of awaiting so a later token/session transition can
        // invalidate this attempt and immediately start the authoritative one.
        ref.invalidate(defaultModelProvider);
        final restore = ref.read(defaultModelProvider.future);
        unawaited(
          restore.then<void>(
            (_) {},
            onError: (Object error, StackTrace stackTrace) {
              if (!ref.mounted) return;
              DebugLogger.error(
                'authenticated-default-restore-failed',
                scope: 'models/default',
                error: error,
                stackTrace: stackTrace,
              );
            },
          ),
        );
      }),
    );
  }

  void set(Model? model, {bool allowHidden = false}) {
    if (model?.isHidden == true && !allowHidden) {
      state = null;
      return;
    }
    state = model;
  }

  void clear() => state = null;
}

/// Tracks a pending folder ID for the next new conversation.
///
/// When a user starts a new chat from within a folder context menu,
/// this provider holds the folder ID so that the conversation is
/// automatically placed in that folder upon creation.
@Riverpod(keepAlive: true)
class PendingFolderId extends _$PendingFolderId {
  @override
  String? build() => null;

  void set(String? folderId) => state = folderId;

  void clear() => state = null;
}

// Track if the current model selection is manual (user-selected) or automatic (default)
@Riverpod(keepAlive: true)
class IsManualModelSelection extends _$IsManualModelSelection {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

// Auto-apply model-specific tools when model changes or tools load
final modelToolsAutoSelectionProvider = Provider<void>((ref) {
  // Prevent disposal so listeners remain active throughout app lifecycle
  ref.keepAlive();

  Future<void> applyTools(Model? model) async {
    List<String> preserveDirectServerSelections(List<String> ids) {
      return ids.where((id) => id.startsWith('direct_server:')).toList();
    }

    // Skip if not authenticated - prevents API calls after logout
    final authState = ref.read(authStateManagerProvider).asData?.value;
    if (authState == null || !authState.isAuthenticated) {
      final current = ref.read(selectedToolIdsProvider);
      final preserved = preserveDirectServerSelections(current);
      if (!listEquals(current, preserved)) {
        ref.read(selectedToolIdsProvider.notifier).set(preserved);
      }
      return;
    }

    if (model == null) {
      final current = ref.read(selectedToolIdsProvider);
      final preserved = preserveDirectServerSelections(current);
      if (!listEquals(current, preserved)) {
        ref.read(selectedToolIdsProvider.notifier).set(preserved);
      }
      return;
    }

    final modelToolIds = model.toolIds ?? [];
    if (modelToolIds.isEmpty) {
      final current = ref.read(selectedToolIdsProvider);
      final preserved = preserveDirectServerSelections(current);
      if (!listEquals(current, preserved)) {
        ref.read(selectedToolIdsProvider.notifier).set(preserved);
      }
      return;
    }

    void updateSelection(List<Tool> availableTools) {
      final validToolIds = modelToolIds
          .where((id) => availableTools.any((tool) => tool.id == id))
          .toList();

      final currentSelection = ref.read(selectedToolIdsProvider);
      final preserved = preserveDirectServerSelections(currentSelection);
      final nextSelection = [...validToolIds, ...preserved];
      if (validToolIds.isEmpty) {
        if (!listEquals(currentSelection, preserved)) {
          ref.read(selectedToolIdsProvider.notifier).set(preserved);
        }
        return;
      }
      if (listEquals(currentSelection, nextSelection)) return;

      ref.read(selectedToolIdsProvider.notifier).set(nextSelection);
      DebugLogger.log(
        'auto-apply-tools',
        scope: 'models/tools',
        data: {
          'backend': _modelBackendForDiagnostics(model),
          'toolCount': validToolIds.length,
          'source': 'selection',
        },
      );
    }

    final toolsAsync = ref.read(toolsListProvider);
    if (toolsAsync.hasValue) {
      updateSelection(toolsAsync.value ?? const <Tool>[]);
      return;
    }

    try {
      final availableTools = await ref.read(toolsListProvider.future);
      if (!ref.mounted) return;
      updateSelection(availableTools);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'auto-apply-tools-failed',
        scope: 'models/tools',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> scheduleApply(Model? model) async {
    await applyTools(model);
  }

  Future.microtask(() => scheduleApply(ref.read(selectedModelProvider)));

  ref.listen<Model?>(selectedModelProvider, (previous, next) {
    if (previous?.id == next?.id && previous != null) {
      return;
    }
    Future.microtask(() => scheduleApply(next));
  });

  ref.listen(toolsListProvider, (previous, next) {
    if (!next.hasValue) return;
    Future.microtask(() => scheduleApply(ref.read(selectedModelProvider)));
  });
});

// Auto-apply model-specific terminal defaults when model changes.
final modelTerminalAutoSelectionProvider = Provider<void>((ref) {
  ref.keepAlive();

  String? extractModelTerminalId(Model? model) {
    final info = model?.metadata?['info'];
    if (info is! Map) {
      return null;
    }

    final infoMeta = info['meta'];
    if (infoMeta is! Map) {
      return null;
    }

    final terminalId = infoMeta['terminalId']?.toString().trim();
    if (terminalId == null || terminalId.isEmpty) {
      return null;
    }

    return terminalId;
  }

  void applyTerminalSelection(Model? model) {
    final terminalId = extractModelTerminalId(model);
    if (terminalId == null) {
      return;
    }

    if (ref.read(selectedTerminalIdProvider) == terminalId) {
      return;
    }

    ref.read(selectedTerminalIdProvider.notifier).set(terminalId);
    DebugLogger.log(
      'auto-apply-terminal',
      scope: 'models/terminal',
      data: {
        'backend': _modelBackendForDiagnostics(model),
        'source': 'selection',
      },
    );
  }

  Future.microtask(
    () => applyTerminalSelection(ref.read(selectedModelProvider)),
  );

  ref.listen<Model?>(selectedModelProvider, (previous, next) {
    Future.microtask(() => applyTerminalSelection(next));
  });
});

// Auto-clear invalid filter selections when model changes
// Filters are model-specific, so we need to validate selections against new model
final modelFiltersAutoSelectionProvider = Provider<void>((ref) {
  // Prevent disposal so listeners remain active throughout app lifecycle
  ref.keepAlive();

  void validateFilters(Model? model) {
    final currentFilterIds = ref.read(selectedFilterIdsProvider);
    if (currentFilterIds.isEmpty) return;

    // Get available filters from the model
    final availableFilters = model?.filters ?? const [];
    final validFilterIds = availableFilters.map((f) => f.id).toSet();

    // Filter out any selected IDs that aren't valid for this model
    final validSelection = currentFilterIds
        .where((id) => validFilterIds.contains(id))
        .toList();

    // Only update if something changed
    if (validSelection.length != currentFilterIds.length) {
      ref.read(selectedFilterIdsProvider.notifier).set(validSelection);
      DebugLogger.log(
        'filter-selection-validated',
        scope: 'models/filters',
        data: {
          'backend': _modelBackendForDiagnostics(model),
          'previousCount': currentFilterIds.length,
          'validCount': validSelection.length,
          'source': 'selection',
        },
      );
    }
  }

  // Validate on model change
  ref.listen<Model?>(selectedModelProvider, (previous, next) {
    if (previous?.id == next?.id && previous != null) {
      return;
    }
    Future.microtask(() => validateFilters(next));
  });
});

// Auto-apply default model from settings when it changes (and not manually overridden)
// keepAlive to maintain listener throughout app lifecycle
final defaultModelAutoSelectionProvider = Provider<void>((ref) {
  // Prevent disposal so listeners remain active throughout app lifecycle
  ref.keepAlive();

  // Initialize the model tools and filters auto-selection
  ref.watch(modelToolsAutoSelectionProvider);
  ref.watch(modelTerminalAutoSelectionProvider);
  ref.watch(modelFiltersAutoSelectionProvider);

  ref.listen<AppSettings>(appSettingsProvider, (previous, next) {
    // Only react when default model value changes
    if (previous?.defaultModel == next.defaultModel) return;

    // Reset manual selection flag when default model setting changes
    ref.read(isManualModelSelectionProvider.notifier).set(false);

    final desired = next.defaultModel;

    // If auto-select (null), invalidate defaultModelProvider to re-fetch server default
    if (desired == null || desired.isEmpty) {
      DebugLogger.log('auto-select-enabled', scope: 'models/default');
      ref.invalidate(defaultModelProvider);
      // Trigger re-read to apply server default
      Future(() async {
        try {
          await ref.read(defaultModelProvider.future);
        } catch (e) {
          DebugLogger.error(
            'auto-select-failed',
            scope: 'models/default',
            error: e,
          );
        }
      });
      return;
    }

    // Resolve the desired model against available models (by ID only)
    Future(() async {
      try {
        // Prefer already-loaded models to avoid unnecessary fetches
        List<Model> models;
        final modelsAsync = ref.read(modelsProvider);
        if (modelsAsync.hasValue) {
          models = modelsAsync.value!;
        } else {
          models = await ref.read(modelsProvider.future);
        }
        Model? selected;
        try {
          selected = ref
              .read(directModelRegistryProvider)
              .resolveOpenWebUiWireModel(models, desired);
          selected ??= models.firstWhere((model) => model.id == desired);
        } catch (_) {
          selected = null;
        }

        final current = ref.read(selectedModelProvider);
        if (selected == null &&
            current != null &&
            !current.isHidden &&
            models.any((model) => model.id == current.id)) {
          selected = models.firstWhere((model) => model.id == current.id);
        }

        selected ??= models.isNotEmpty ? models.first : null;

        if (selected != null) {
          ref.read(selectedModelProvider.notifier).set(selected);
          DebugLogger.log(
            'auto-apply',
            scope: 'models/default',
            data: {
              'backend': _modelBackendForDiagnostics(selected),
              'source': 'preference',
            },
          );
        }
      } catch (e) {
        DebugLogger.error(
          'auto-select-failed',
          scope: 'models/default',
          error: e,
        );
      }
    });
  });
});

/// Requests a debounced pull cycle from the sync engine and invalidates the
/// folder summary caches after the pull has had a chance to write rows
/// (CDT-RFC-001 Phase 1: every refresh path converges on the engine; Drift
/// streams deliver the resulting UI updates).
void refreshConversationsCache(dynamic ref, {bool includeFolders = false}) {
  final folderConversationRefresh = ref.read(
    _folderConversationRefreshTickProvider.notifier,
  );
  final syncEngine = ref.read(syncEngineProvider.notifier);
  // Invoke the notifier synchronously while the caller's provider/widget ref
  // is still known to be alive. Scheduling the invocation itself in a detached
  // Future leaves a teardown window where the owner can be disposed before
  // [requestPull] gets a chance to read its Riverpod dependencies.
  Future<PullResult?> pull;
  try {
    pull = syncEngine.requestPull(reason: 'cache-refresh');
  } catch (error, stackTrace) {
    DebugLogger.error(
      'refresh-cache-failed',
      scope: 'conversations',
      error: error,
      stackTrace: stackTrace,
    );
    return;
  }
  unawaited(
    pull
        .then<void>((_) {
          folderConversationRefresh.bumpIfMounted();
        })
        .catchError((Object error, StackTrace stackTrace) {
          DebugLogger.error(
            'refresh-cache-failed',
            scope: 'conversations',
            error: error,
            stackTrace: stackTrace,
          );
        }),
  );
}

typedef _UpdatedItem<T> = ({List<T> items, T item});
typedef _RemovedItems<T> = ({List<T> items, bool didRemove});

DateTime? _latestDateTime(DateTime? left, DateTime? right) {
  if (left == null) return right;
  if (right == null) return left;
  return right.isAfter(left) ? right : left;
}

List<T> _upsertItemById<T>(
  List<T> current,
  T item, {
  required String Function(T item) idOf,
}) {
  final updated = <T>[...current];
  final itemId = idOf(item);
  final index = updated.indexWhere((existing) => idOf(existing) == itemId);
  if (index >= 0) {
    updated[index] = item;
  } else {
    updated.add(item);
  }
  return updated;
}

_UpdatedItem<T>? _transformItemById<T>(
  List<T> current,
  String id,
  T Function(T item) transform, {
  required String Function(T item) idOf,
}) {
  final index = current.indexWhere((existing) => idOf(existing) == id);
  if (index < 0) {
    return null;
  }
  final updated = <T>[...current];
  final transformed = transform(updated[index]);
  updated[index] = transformed;
  return (items: updated, item: transformed);
}

_RemovedItems<T> _removeItemById<T>(
  List<T> current,
  String id, {
  required String Function(T item) idOf,
}) {
  final updated = <T>[...current];
  final index = updated.indexWhere((existing) => idOf(existing) == id);
  if (index >= 0) {
    updated.removeAt(index);
  }
  return (items: updated, didRemove: index >= 0);
}

/// Server-style epoch seconds for envelope writes derived from model
/// timestamps (which round-trip epoch seconds themselves).
int _epochSecondsOf(DateTime dateTime) =>
    dateTime.millisecondsSinceEpoch ~/ 1000;

void _submitReconcilePull(
  Ref ref, {
  required String reason,
  required String scope,
  required String action,
}) {
  DebugLogger.log(
    'reconcile-after-remote-mutation',
    scope: scope,
    data: {'action': action},
  );
  Future<PullResult?> pull;
  try {
    pull = ref.read(syncEngineProvider.notifier).requestPull(reason: reason);
  } catch (error, stackTrace) {
    DebugLogger.error(
      'reconcile-pull-failed',
      scope: scope,
      error: error,
      stackTrace: stackTrace,
      data: {'action': action},
    );
    return;
  }
  unawaited(
    pull.catchError((Object error, StackTrace stackTrace) {
      DebugLogger.error(
        'reconcile-pull-failed',
        scope: scope,
        error: error,
        stackTrace: stackTrace,
        data: {'action': action},
      );
      return null;
    }),
  );
}

/// Runtime provenance attached to conversation summaries and full loads.
///
/// Chat ids are not a sufficient discriminator because independent databases
/// can legally contain the same id. This marker is app-owned and never used as
/// routing authority for model requests.
const String kDirectChatBackend = 'direct';

Conversation withChatStorageProvenance(
  Conversation conversation,
  ChatStorageKind storage,
) {
  final annotated = annotateConversationStorage(conversation, storage);
  final metadata = <String, dynamic>{
    ...annotated.metadata,
    if (storage == ChatStorageKind.directLocal) ...{
      'backend': kDirectChatBackend,
      'onDevice': true,
    },
  };
  return annotated.copyWith(metadata: metadata);
}

ChatStorageKind? chatStorageKindOf(Conversation? conversation) {
  if (conversation == null) return null;
  return chatStorageFromConversation(conversation);
}

bool isDirectLocalConversation(Conversation? conversation) =>
    chatStorageKindOf(conversation) == ChatStorageKind.directLocal;

/// Whether [conversation] is a process-local direct shell that has not yet
/// acquired durable storage provenance.
///
/// An explicit storage annotation always wins: OpenWebUI-owned conversations
/// may legitimately record that their latest turn used the direct transport.
bool _isUnstoredDirectConversation(Conversation? conversation) =>
    conversation != null &&
    chatStorageKindOf(conversation) == null &&
    conversation.metadata['backend'] == kDirectChatBackend;

/// Collision-free identity for selections and widget/provider keys.
///
/// [Conversation.id] remains the provider/server id. This value is only for
/// app-internal identity where two independent databases may contain that id.
String conversationScopedId(Conversation conversation) {
  var storage = chatStorageKindOf(conversation);
  // Unannotated persisted conversations predate multi-store history and have
  // always meant OpenWebUI. Scope that legacy default too; otherwise a newly
  // created server chat can briefly expose an ambiguous raw id to listeners.
  if (storage == null &&
      !isTemporaryChat(conversation.id) &&
      !isNativeHermesConversation(conversation) &&
      !_isUnstoredDirectConversation(conversation)) {
    storage = ChatStorageKind.openWebUi;
  }
  return ChatStorageIdentity(rawId: conversation.id, storage: storage).scopedId;
}

bool conversationMatchesScopedId(Conversation conversation, String scopedId) {
  final identity = ChatStorageIdentity.parse(scopedId);
  if (conversation.id != identity.rawId) return false;
  final storage = identity.storage;
  // Native Hermes shells are runtime-owned and intentionally unscoped. A
  // persisted row can legally reuse the same raw id, but its scoped selection
  // must never match or mutate the native shell.
  if (storage != null &&
      (isNativeHermesConversation(conversation) ||
          _isUnstoredDirectConversation(conversation))) {
    return false;
  }
  return storage == null ||
      (chatStorageKindOf(conversation) ?? ChatStorageKind.openWebUi) == storage;
}

bool isSameStoredConversation(Conversation? left, Conversation? right) {
  if (left == null || right == null || left.id != right.id) return false;
  // A native Hermes shell is process-owned and deliberately has no persisted
  // storage annotation. Do not let a server row with the same raw id collide
  // with it through the legacy "unannotated means OpenWebUI" fallback.
  final leftIsNativeHermes = isNativeHermesConversation(left);
  final rightIsNativeHermes = isNativeHermesConversation(right);
  if (leftIsNativeHermes != rightIsNativeHermes) return false;
  if (leftIsNativeHermes) return true;
  // A temporary direct shell is runtime-owned just like a native Hermes
  // shell. It must not alias a colliding legacy OpenWebUI row merely because
  // both currently lack a storage annotation.
  final leftIsUnstoredDirect = _isUnstoredDirectConversation(left);
  final rightIsUnstoredDirect = _isUnstoredDirectConversation(right);
  if (leftIsUnstoredDirect != rightIsUnstoredDirect) return false;
  if (leftIsUnstoredDirect) return true;
  // Unannotated conversations predate multi-store history and therefore
  // retain their historical Open WebUI meaning.
  final leftStorage = chatStorageKindOf(left) ?? ChatStorageKind.openWebUi;
  final rightStorage = chatStorageKindOf(right) ?? ChatStorageKind.openWebUi;
  return leftStorage == rightStorage;
}

int _conversationIndexForSelection(
  List<Conversation> conversations,
  String scopedId,
) {
  final identity = ChatStorageIdentity.parse(scopedId);
  if (identity.storage != null) {
    return conversations.indexWhere(
      (conversation) => conversationMatchesScopedId(conversation, scopedId),
    );
  }

  final matchingIndexes = <int>[];
  for (var index = 0; index < conversations.length; index++) {
    if (conversations[index].id == identity.rawId) {
      matchingIndexes.add(index);
    }
  }
  if (matchingIndexes.length <= 1) {
    return matchingIndexes.firstOrNull ?? -1;
  }

  // Legacy unscoped callers historically referred to Open WebUI ids. Keep
  // that behavior deterministic when a new local row happens to collide.
  return matchingIndexes.firstWhere(
    (index) =>
        (chatStorageKindOf(conversations[index]) ??
            ChatStorageKind.openWebUi) ==
        ChatStorageKind.openWebUi,
    orElse: () => matchingIndexes.first,
  );
}

// Conversation list provider — Drift-backed read path (CDT-RFC-001 Phase 1).
//
// The list renders from `ChatsDao.watchChatList()` (a narrow projection that
// never selects message bodies). Mutators keep their synchronous in-memory
// update for snappiness and write the same envelope change to the database in
// the same call, so the next stream emission always agrees with the
// optimistic state.
@Riverpod(keepAlive: true)
class _ConversationListPageTick extends _$ConversationListPageTick {
  @override
  int build() => 0;

  void bump() => state++;
}

@Riverpod(keepAlive: true)
class Conversations extends _$Conversations {
  static const int _regularPageSize = 200;
  static const int _archivedPageSize = 200;

  int _databaseWatchGeneration = 0;
  StreamSubscription<List<LocatedChatListEntry>>? _databaseSubscription;
  StreamSubscription<int>? _archivedCountSubscription;
  Future<void> _databaseWatchCancellation = Future<void>.value();
  Object? _paginationRepository;
  bool? _paginationIncludesOpenWebUi;
  Object? _paginationAuthSessionEpoch;
  int _regularChatLimit = _regularPageSize;
  int _archivedChatLimit = 0;
  bool _hasMoreRegularChats = false;
  bool _isLoadingMoreRegularChats = false;
  int _archivedChatCount = 0;
  bool _hasMoreArchivedChats = false;
  bool _isLoadingMoreArchivedChats = false;
  List<Conversation>? _lastSuccessfulDatabaseProjection;

  bool hasMoreRegularChats() => _hasMoreRegularChats;
  bool isLoadingMoreRegularChats() => _isLoadingMoreRegularChats;
  int archivedChatCount() => _archivedChatCount;
  bool hasMoreArchivedChats() => _hasMoreArchivedChats;
  bool isLoadingMoreArchivedChats() => _isLoadingMoreArchivedChats;
  bool archivedChatsVisible() => _archivedChatLimit > 0;

  @override
  Future<List<Conversation>> build() async {
    ref.watch(_conversationListPageTickProvider);
    final generation = ++_databaseWatchGeneration;
    final previousSubscription = _databaseSubscription;
    final previousArchivedCountSubscription = _archivedCountSubscription;
    _databaseSubscription = null;
    _archivedCountSubscription = null;
    ref.onDispose(() {
      if (generation == _databaseWatchGeneration) {
        _databaseWatchGeneration++;
        final subscription = _databaseSubscription;
        final archivedCountSubscription = _archivedCountSubscription;
        _databaseSubscription = null;
        _archivedCountSubscription = null;
        unawaited(
          _queueDatabaseWatchCancellation(
            subscription,
            archivedCountSubscription,
          ),
        );
      }
    });
    await _queueDatabaseWatchCancellation(
      previousSubscription,
      previousArchivedCountSubscription,
    );
    if (!ref.mounted || generation != _databaseWatchGeneration) {
      return const <Conversation>[];
    }

    if (ref.watch(reviewerModeProvider)) {
      final conversations = _demoConversations();
      // Force the next real database build to establish a fresh ownership
      // context. Demo rows must never become the retained fallback for a
      // production watch that fails before its first emission.
      _paginationRepository = null;
      _paginationIncludesOpenWebUi = null;
      _paginationAuthSessionEpoch = null;
      _lastSuccessfulDatabaseProjection = conversations;
      _hasMoreRegularChats = false;
      _isLoadingMoreRegularChats = false;
      _archivedChatCount = conversations
          .where((chat) => !chat.pinned && chat.archived)
          .length;
      _hasMoreArchivedChats = false;
      _isLoadingMoreArchivedChats = false;
      return conversations;
    }

    final accessPhase = ref.watch(openWebUiDatabaseAccessProvider);
    final certifiedServerId = ref.watch(
      openWebUiCertifiedDatabaseServerProvider,
    );
    final activeServerId = ref.watch(
      activeServerProvider.select((value) => value.asData?.value?.id),
    );
    final openWebUiDatabase = ref.watch(appDatabaseProvider);
    final unmanagedOpenWebUiDatabase =
        openWebUiDatabase != null &&
        ref
                .watch(databaseManagerProvider)
                .serverIdForDatabase(openWebUiDatabase) ==
            null;
    final includeOpenWebUi =
        accessPhase == OpenWebUiDatabaseAccessPhase.open &&
        ((certifiedServerId != null && certifiedServerId == activeServerId) ||
            unmanagedOpenWebUiDatabase);

    // Rebuild the repository when the active Open WebUI database changes. The
    // direct-local database is independent and remains available while signed
    // out or while switching servers.
    final repository = ref.watch(chatDatabaseRepositoryProvider);
    final authSessionEpoch = ref.watch(openWebUiAuthSessionEpochProvider);
    if (!identical(_paginationRepository, repository) ||
        _paginationIncludesOpenWebUi != includeOpenWebUi ||
        !identical(_paginationAuthSessionEpoch, authSessionEpoch)) {
      _lastSuccessfulDatabaseProjection = null;
      _paginationRepository = repository;
      _paginationIncludesOpenWebUi = includeOpenWebUi;
      _paginationAuthSessionEpoch = authSessionEpoch;
      _regularChatLimit = _regularPageSize;
      _archivedChatLimit = 0;
      _hasMoreRegularChats = false;
      _isLoadingMoreRegularChats = false;
      _archivedChatCount = 0;
      _hasMoreArchivedChats = false;
      _isLoadingMoreArchivedChats = false;
    }

    final completer = Completer<List<Conversation>>();
    // Cold-start instrumentation (CDT-RFC-001 §10 Budget 1): time from build()
    // start to the FIRST narrow-projection emission. Numeric-only data (no chat
    // content) so nothing untrusted is logged.
    final coldStart = Stopwatch()..start();
    final listStream = includeOpenWebUi
        ? repository.watchMergedChatList(
            regularLimit: _regularChatLimit + 1,
            archivedLimit: _archivedChatLimit > 0 ? _archivedChatLimit + 1 : 0,
          )
        : repository.watchDirectLocalChatList(
            regularLimit: _regularChatLimit + 1,
            archivedLimit: _archivedChatLimit > 0 ? _archivedChatLimit + 1 : 0,
          );
    final archivedCountStream = includeOpenWebUi
        ? repository.watchMergedArchivedChatCount()
        : repository.watchDirectLocalArchivedChatCount();
    final archivedCountSubscription = archivedCountStream.listen(
      (count) {
        if (generation != _databaseWatchGeneration) return;
        final normalizedCount = math.max(0, count);
        final changed = normalizedCount != _archivedChatCount;
        _archivedChatCount = normalizedCount;
        _hasMoreArchivedChats = _archivedChatCount > _archivedChatLimit;
        if (changed && completer.isCompleted && ref.mounted) {
          final current = state.asData?.value;
          if (current != null) {
            state = AsyncData<List<Conversation>>(
              List<Conversation>.unmodifiable(current),
            );
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (generation != _databaseWatchGeneration) return;
        DebugLogger.error(
          'archived-count-watch-failed',
          scope: 'conversations/watch',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
    _archivedCountSubscription = archivedCountSubscription;
    final subscription = listStream.listen(
      (entries) {
        if (generation != _databaseWatchGeneration) return;
        final activeEntries = entries
            .where(
              (located) => !located.entry.pinned && !located.entry.archived,
            )
            .toList(growable: false);
        final archivedEntries = entries
            .where((located) => !located.entry.pinned && located.entry.archived)
            .toList(growable: false);
        final includedUnpinned = <LocatedChatListEntry>{
          ...activeEntries.take(_regularChatLimit),
          ...archivedEntries.take(_archivedChatLimit),
        };
        final pagedEntries = entries
            .where(
              (located) =>
                  located.entry.pinned || includedUnpinned.contains(located),
            )
            .toList(growable: false);
        _hasMoreRegularChats = activeEntries.length > _regularChatLimit;
        _isLoadingMoreRegularChats = false;
        _hasMoreArchivedChats =
            archivedEntries.length > _archivedChatLimit ||
            _archivedChatCount > _archivedChatLimit;
        _isLoadingMoreArchivedChats = false;
        final conversations = List<Conversation>.unmodifiable(
          pagedEntries.map((located) {
            return withChatStorageProvenance(
              conversationFromListEntry(located.entry),
              located.storage,
            );
          }),
        );
        _lastSuccessfulDatabaseProjection = conversations;
        if (!completer.isCompleted) {
          coldStart.stop();
          DebugLogger.log(
            'cold-start-ms',
            scope: 'perf/list',
            data: {'ms': coldStart.elapsedMilliseconds, 'rows': entries.length},
          );
          completer.complete(conversations);
          return;
        }
        if (ref.mounted) {
          state = AsyncData<List<Conversation>>(conversations);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (generation != _databaseWatchGeneration) return;
        _isLoadingMoreRegularChats = false;
        _isLoadingMoreArchivedChats = false;
        DebugLogger.error(
          'watch-failed',
          scope: 'conversations/watch',
          error: error,
          stackTrace: stackTrace,
        );
        if (!completer.isCompleted) {
          final retained = _lastSuccessfulDatabaseProjection;
          if (retained != null) {
            // A pagination/replacement watch can fail before its first row.
            // Keep the last projection from this exact repository/account
            // context instead of publishing a synthetic empty conversation
            // list. A true cold-start failure remains observable below.
            completer.complete(List<Conversation>.unmodifiable(retained));
          } else {
            completer.completeError(error, stackTrace);
          }
        } else if (ref.mounted) {
          final current = state.asData?.value;
          if (current != null) {
            state = AsyncData<List<Conversation>>(
              List<Conversation>.unmodifiable(current),
            );
          }
        }
      },
    );
    _databaseSubscription = subscription;
    return completer.future;
  }

  Future<void> _queueDatabaseWatchCancellation(
    StreamSubscription<List<LocatedChatListEntry>>? subscription, [
    StreamSubscription<int>? archivedCountSubscription,
  ]) {
    final prior = _databaseWatchCancellation;
    final cancellation = () async {
      await prior;
      try {
        await subscription?.cancel();
      } catch (_) {
        // A stale/closed Drift executor must not reject an async provider build
        // or escape as an unhandled error during provider disposal.
        try {
          DebugLogger.error(
            'watch-cancel-failed',
            scope: 'conversations/watch',
          );
        } catch (_) {}
      }
      try {
        await archivedCountSubscription?.cancel();
      } catch (_) {
        try {
          DebugLogger.error(
            'archived-count-watch-cancel-failed',
            scope: 'conversations/watch',
          );
        } catch (_) {}
      }
    }();
    _databaseWatchCancellation = cancellation;
    return cancellation;
  }

  /// Refreshing is a pull request; the database stream delivers the result.
  /// Folders are part of every pull cycle, so [includeFolders] needs no extra
  /// work.
  Future<void> refresh({
    bool includeFolders = false,
    bool forceFresh = false,
  }) async {
    final folderConversationRefresh = ref.read(
      _folderConversationRefreshTickProvider.notifier,
    );
    // Local-only direct chats are already live through Drift. Refresh the
    // optional Open WebUI side when it is available.
    if (ref.read(appDatabaseProvider) != null &&
        ref.read(isAuthenticatedProvider2)) {
      await ref
          .read(syncEngineProvider.notifier)
          .requestPull(reason: 'refresh');
    }
    folderConversationRefresh.bumpIfMounted();
  }

  /// Expands the live database window; the replacement stream remains the
  /// source of truth and includes all pinned rows regardless of age.
  Future<void> loadMore() async {
    if (_isLoadingMoreRegularChats || !_hasMoreRegularChats) return;
    _isLoadingMoreRegularChats = true;
    _regularChatLimit += _regularPageSize;
    ref.read(_conversationListPageTickProvider.notifier).bump();
    await Future<void>.delayed(Duration.zero);
  }

  /// Opens or releases the independently paged archived-row window.
  Future<void> setArchivedChatsVisible(bool visible) async {
    final nextLimit = visible ? _archivedPageSize : 0;
    if ((visible && _archivedChatLimit > 0) ||
        (!visible && _archivedChatLimit == 0)) {
      return;
    }
    _archivedChatLimit = nextLimit;
    _isLoadingMoreArchivedChats = visible;
    _hasMoreArchivedChats = _archivedChatCount > _archivedChatLimit;
    ref.read(_conversationListPageTickProvider.notifier).bump();
    await Future<void>.delayed(Duration.zero);
  }

  /// Expands only the archived-row window; active-chat pagination is untouched.
  Future<void> loadMoreArchived() async {
    if (_archivedChatLimit <= 0 ||
        _isLoadingMoreArchivedChats ||
        !_hasMoreArchivedChats) {
      return;
    }
    _isLoadingMoreArchivedChats = true;
    _archivedChatLimit += _archivedPageSize;
    _hasMoreArchivedChats = _archivedChatCount > _archivedChatLimit;
    ref.read(_conversationListPageTickProvider.notifier).bump();
    await Future<void>.delayed(Duration.zero);
  }

  void removeConversation(String id) {
    final identity = ChatStorageIdentity.parse(id);
    final current = state.asData?.value;
    final index = current == null
        ? -1
        : _conversationIndexForSelection(current, id);
    final removedConversation = index >= 0 ? current![index] : null;
    if (current != null) {
      if (index >= 0) {
        final updated = <Conversation>[...current]..removeAt(index);
        _replaceState(updated);
      }
    }
    // The caller already confirmed any required remote deletion. Drop the row
    // from the database that owns it. Local-only direct chats never touch the
    // active Open WebUI database or its outbox.
    final directLocal =
        isDirectLocalConversation(removedConversation) ||
        (removedConversation == null &&
            identity.storage == ChatStorageKind.directLocal);
    final db = directLocal
        ? ref.read(directLocalDatabaseProvider)
        : ref.read(appDatabaseProvider);
    final rawId = identity.rawId;
    if (db == null || isTemporaryChat(rawId)) return;
    final locks = ref.read(chatLocksProvider);
    final folderConversationRefresh = ref.read(
      _folderConversationRefreshTickProvider.notifier,
    );
    unawaited(
      locks
          .runExclusive(
            rawId,
            () => directLocal
                ? db.chatsDao.deleteLocalOnlyChat(rawId)
                : db.chatsDao.hardDelete(rawId),
          )
          .then((_) => folderConversationRefresh.bumpIfMounted())
          .catchError((Object error, StackTrace stackTrace) {
            DebugLogger.error(
              'row-delete-failed',
              scope: 'conversations',
              error: error,
              stackTrace: stackTrace,
              data: {'id': rawId},
            );
          }),
    );
  }

  void upsertConversation(
    Conversation conversation, {
    bool trustFolderConversation = false,
  }) {
    final current = state.asData?.value ?? const <Conversation>[];
    final existingIndex = _conversationIndexForSelection(
      current,
      conversationScopedId(conversation),
    );
    final existing = existingIndex >= 0 ? current[existingIndex] : null;
    var preparedConversation = existing == null
        ? conversation
        : conversation.copyWith(
            lastReadAt: _latestDateTime(
              existing.lastReadAt,
              conversation.lastReadAt,
            ),
          );
    final existingStorage = chatStorageKindOf(existing);
    if (existingStorage != null) {
      preparedConversation = withChatStorageProvenance(
        preparedConversation,
        existingStorage,
      );
    }
    final updated = <Conversation>[...current];
    if (existingIndex >= 0) {
      updated[existingIndex] = preparedConversation;
    } else {
      updated.add(preparedConversation);
    }
    _replaceState(updated);
    _writeEnvelopeStub(preparedConversation);
  }

  void upsertConversations(
    Iterable<Conversation> conversations, {
    bool trustFolderConversations = false,
  }) {
    for (final conversation in conversations) {
      upsertConversation(conversation);
    }
  }

  void updateConversation(
    String id,
    Conversation Function(Conversation conversation) transform, {
    bool trustFolderConversation = false,
  }) {
    final current = state.asData?.value;
    final index = current == null
        ? -1
        : _conversationIndexForSelection(current, id);
    if (current == null || index < 0) {
      // The chat list stream has not loaded yet, or this id is absent from the
      // loaded projection. Request a reconcile pull so the server-confirmed
      // envelope mutation is not lost (mirrors Folders.updateFolder).
      _requestConversationReconcilePull(
        action: current == null ? 'update-cold' : 'update-missing',
      );
      return;
    }
    final existing = current[index];
    var transformed = transform(existing);
    final storage = chatStorageKindOf(existing);
    if (storage != null) {
      transformed = withChatStorageProvenance(transformed, storage);
    }
    final updated = <Conversation>[...current]..[index] = transformed;
    _replaceState(updated);
    _writeEnvelopeUpdate(transformed);
  }

  void _requestConversationReconcilePull({required String action}) {
    _submitReconcilePull(
      ref,
      reason: 'conversations-reconcile',
      scope: 'conversations',
      action: action,
    );
  }

  void markConversationRead(String id, DateTime readAt) {
    if (id.isEmpty) return;
    final identity = ChatStorageIdentity.parse(id);
    final current = state.asData?.value;
    final index = current == null
        ? -1
        : _conversationIndexForSelection(current, id);
    Conversation? target = index >= 0 ? current![index] : null;
    if (current != null) {
      if (index >= 0) {
        final conversation = current[index];
        final existing = conversation.lastReadAt;
        if (existing != null && !readAt.isAfter(existing)) {
          return;
        }
        target = conversation.copyWith(lastReadAt: readAt);
        final updated = <Conversation>[...current]..[index] = target;
        _replaceState(updated);
      }
    }
    final directLocal =
        isDirectLocalConversation(target) ||
        (target == null && identity.storage == ChatStorageKind.directLocal);
    final db = directLocal
        ? ref.read(directLocalDatabaseProvider)
        : ref.read(appDatabaseProvider);
    final rawId = identity.rawId;
    if (db == null || isTemporaryChat(rawId)) return;
    // Pre-existing UI-only read marks come from the device clock; the DAO's
    // max() rule means the column is never lowered and the value never enters
    // watermark logic.
    unawaited(
      db.chatsDao.setLastReadAt(rawId, _epochSecondsOf(readAt)).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        DebugLogger.error(
          'read-mark-failed',
          scope: 'conversations',
          error: error,
          stackTrace: stackTrace,
          data: {'id': rawId},
        );
      }),
    );
  }

  /// Applies a server-confirmed conversation summary mutation.
  void updateConversationFromRemote(
    String id,
    Conversation Function(Conversation conversation) transform,
  ) {
    updateConversation(id, transform);
  }

  /// Rows are id-keyed in the database; the summary "trust" machinery is
  /// obsolete. Kept as a frozen no-op for callers.
  void trustConversation(String id) {}

  void _replaceState(List<Conversation> conversations) {
    state = AsyncData<List<Conversation>>(_sortByUpdatedAt(conversations));
  }

  void _writeEnvelopeStub(Conversation conversation) {
    final directLocal = isDirectLocalConversation(conversation);
    final db = directLocal
        ? ref.read(directLocalDatabaseProvider)
        : ref.read(appDatabaseProvider);
    if (db == null || isTemporaryChat(conversation.id)) return;
    final lastReadAt = conversation.lastReadAt;
    // ChatLocks discipline: every write touching one chat's rows serializes
    // through the per-chat mutex so a stale optimistic stub can never be
    // ordered after (and overwrite) a concurrent locked pull merge.
    final locks = ref.read(chatLocksProvider);
    final folderConversationRefresh = ref.read(
      _folderConversationRefreshTickProvider.notifier,
    );
    unawaited(
      locks
          .runExclusive(conversation.id, () {
            if (directLocal) {
              return db.chatsDao.updateLocalOnlyEnvelope(
                conversation.id,
                title: Value(conversation.title),
                folderId: Value(conversation.folderId),
                pinned: Value(conversation.pinned),
                archived: Value(conversation.archived),
                updatedAt: Value(_epochSecondsOf(conversation.updatedAt)),
              );
            }
            return db.chatsDao.upsertEnvelopeStub(
              id: conversation.id,
              title: conversation.title,
              createdAt: _epochSecondsOf(conversation.createdAt),
              updatedAt: _epochSecondsOf(conversation.updatedAt),
              pinned: conversation.pinned,
              archived: conversation.archived,
              folderId: Value(conversation.folderId),
              lastReadAt: lastReadAt == null
                  ? null
                  : _epochSecondsOf(lastReadAt),
            );
          })
          .then((_) => folderConversationRefresh.bumpIfMounted())
          .catchError((Object error, StackTrace stackTrace) {
            DebugLogger.error(
              'envelope-stub-failed',
              scope: 'conversations',
              error: error,
              stackTrace: stackTrace,
              data: {'id': conversation.id},
            );
          }),
    );
  }

  void _writeEnvelopeUpdate(Conversation conversation) {
    final directLocal = isDirectLocalConversation(conversation);
    final db = directLocal
        ? ref.read(directLocalDatabaseProvider)
        : ref.read(appDatabaseProvider);
    if (db == null || isTemporaryChat(conversation.id)) return;
    final locks = ref.read(chatLocksProvider);
    final folderConversationRefresh = ref.read(
      _folderConversationRefreshTickProvider.notifier,
    );
    unawaited(
      locks
          .runExclusive(conversation.id, () {
            return directLocal
                ? db.chatsDao.updateLocalOnlyEnvelope(
                    conversation.id,
                    title: Value(conversation.title),
                    folderId: Value(conversation.folderId),
                    pinned: Value(conversation.pinned),
                    archived: Value(conversation.archived),
                    updatedAt: Value(_epochSecondsOf(conversation.updatedAt)),
                  )
                : db.chatsDao.updateEnvelope(
                    conversation.id,
                    title: Value(conversation.title),
                    folderId: Value(conversation.folderId),
                    pinned: Value(conversation.pinned),
                    archived: Value(conversation.archived),
                    updatedAt: Value(_epochSecondsOf(conversation.updatedAt)),
                  );
          })
          .then((_) => folderConversationRefresh.bumpIfMounted())
          .catchError((Object error, StackTrace stackTrace) {
            DebugLogger.error(
              'envelope-update-failed',
              scope: 'conversations',
              error: error,
              stackTrace: stackTrace,
              data: {'id': conversation.id},
            );
          }),
    );
  }

  List<Conversation> _sortByUpdatedAt(List<Conversation> conversations) {
    final sorted = [...conversations];
    sorted.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List<Conversation>.unmodifiable(sorted);
  }

  List<Conversation> _demoConversations() => [
    Conversation(
      id: 'demo-conv-1',
      title: 'Welcome to Conduit (Demo)',
      createdAt: DateTime.now().subtract(const Duration(minutes: 15)),
      updatedAt: DateTime.now().subtract(const Duration(minutes: 10)),
      messages: [
        ChatMessage(
          id: 'demo-msg-1',
          role: 'assistant',
          content:
              '**Welcome to Conduit Demo Mode**\n\nThis is a demo for app review - responses are pre-written, not from real AI.\n\nTry these features:\n• Send messages\n• Attach images\n• Use voice input\n• Switch models (tap header)\n• Create new chats (menu)\n\nAll features work offline. No server needed.',
          timestamp: DateTime.now().subtract(const Duration(minutes: 10)),
          model: 'Gemma 2 Mini (Demo)',
          isStreaming: false,
        ),
      ],
    ),
  ];
}

final _folderConversationRefreshTickProvider =
    NotifierProvider<_FolderConversationRefreshTick, int>(
      _FolderConversationRefreshTick.new,
    );

class _FolderConversationRefreshTick extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;

  void bumpIfMounted() {
    if (!ref.mounted) return;
    bump();
  }
}

/// Loads folder conversation summaries from the local database
/// (CDT-RFC-001 Phase 1: per-folder server fetches are gone; pull sync keeps
/// the rows fresh and `_folderConversationRefreshTickProvider` invalidates
/// after pulls and mutations).
final folderConversationSummariesProvider =
    FutureProvider.family<List<Conversation>, String>((ref, folderId) async {
      ref.watch(_folderConversationRefreshTickProvider);

      if (!ref.watch(isAuthenticatedProvider2) ||
          ref.watch(reviewerModeProvider)) {
        return const <Conversation>[];
      }

      final db = ref.watch(appDatabaseProvider);
      if (db == null) {
        return const <Conversation>[];
      }

      final entries = await db.chatsDao.getChatsInFolder(folderId);
      return entries.map(conversationFromListEntry).toList(growable: false);
    });

/// Whether the current chat session is temporary (not persisted to server).
///
/// When true, conversations use `local:{socketId}` IDs and skip all
/// server persistence. Resets on app restart unless the user has
/// `temporaryChatByDefault` enabled in settings.
@riverpod
class TemporaryChatEnabled extends _$TemporaryChatEnabled {
  @override
  bool build() {
    // Use ref.read (not watch) so settings changes don't reset
    // the ephemeral toggle state mid-conversation.
    final settings = ref.read(appSettingsProvider);
    return settings.temporaryChatByDefault;
  }

  void set(bool value) => state = value;
}

/// Returns true if the given conversation ID represents a temporary chat.
bool isTemporaryChat(String? id) => id != null && id.startsWith('local:');

void markConversationRead(
  dynamic ref,
  String? conversationId, {
  DateTime? readAt,
}) {
  final scopedId = conversationId?.trim();
  if (scopedId == null || scopedId.isEmpty) {
    return;
  }
  final identity = ChatStorageIdentity.parse(scopedId);
  final id = identity.rawId;
  if (isTemporaryChat(id)) {
    return;
  }

  final timestamp = readAt ?? DateTime.now();
  Conversation? targetConversation;
  var resolvedSelectionId = scopedId;
  try {
    final conversations =
        (ref.read(conversationsProvider) as AsyncValue<List<Conversation>>)
            .asData
            ?.value;
    if (conversations != null) {
      final index = _conversationIndexForSelection(conversations, scopedId);
      if (index >= 0) {
        targetConversation = conversations[index];
        resolvedSelectionId = conversationScopedId(targetConversation);
      }
    }
    ref
        .read(conversationsProvider.notifier)
        .markConversationRead(resolvedSelectionId, timestamp);
  } catch (_) {}

  try {
    final active = ref.read(activeConversationProvider) as Conversation?;
    if (active != null &&
        (targetConversation != null
            ? isSameStoredConversation(active, targetConversation)
            : conversationMatchesScopedId(active, resolvedSelectionId))) {
      targetConversation ??= active;
      final current = active.lastReadAt;
      if (current == null || timestamp.isAfter(current)) {
        ref
            .read(activeConversationProvider.notifier)
            .set(active.copyWith(lastReadAt: timestamp));
      }
    }
  } catch (_) {}

  if (isDirectLocalConversation(targetConversation) ||
      identity.storage == ChatStorageKind.directLocal ||
      (identity.storage == null && id.startsWith('direct-local:'))) {
    return;
  }

  try {
    ref.read(socketServiceProvider)?.emit('events:chat', {
      'chat_id': id,
      'data': {'type': 'last_read_at'},
    });
  } catch (_) {}
}

final activeConversationProvider =
    NotifierProvider<ActiveConversationNotifier, Conversation?>(
      ActiveConversationNotifier.new,
    );

enum ActiveConversationRemapNamespace { openWebUi, direct, hermes }

@immutable
class ActiveConversationInPlaceRemap {
  const ActiveConversationInPlaceRemap({
    required this.fromId,
    required this.toId,
    this.namespace = ActiveConversationRemapNamespace.openWebUi,
    this.openWebUiDatabase,
    this.openWebUiApi,
    this.openWebUiAuthSessionEpoch,
  });

  final String fromId;
  final String toId;
  final ActiveConversationRemapNamespace namespace;
  final Object? openWebUiDatabase;
  final Object? openWebUiApi;
  final Object? openWebUiAuthSessionEpoch;

  bool matches(
    String? previousId,
    String? nextId, {
    ActiveConversationRemapNamespace? namespace,
  }) =>
      previousId == fromId &&
      nextId == toId &&
      (namespace == null || this.namespace == namespace);

  bool matchesOpenWebUiContext({
    required Object? database,
    required Object? api,
    required Object? authSessionEpoch,
  }) =>
      namespace == ActiveConversationRemapNamespace.openWebUi &&
      identical(openWebUiDatabase, database) &&
      identical(openWebUiApi, api) &&
      identical(openWebUiAuthSessionEpoch, authSessionEpoch);
}

final activeConversationInPlaceRemapProvider =
    NotifierProvider<
      ActiveConversationInPlaceRemapNotifier,
      ActiveConversationInPlaceRemap?
    >(ActiveConversationInPlaceRemapNotifier.new);

class ActiveConversationInPlaceRemapNotifier
    extends Notifier<ActiveConversationInPlaceRemap?> {
  @override
  ActiveConversationInPlaceRemap? build() => null;

  void mark({
    required String fromId,
    required String toId,
    ActiveConversationRemapNamespace namespace =
        ActiveConversationRemapNamespace.openWebUi,
  }) {
    Object? database;
    Object? api;
    Object? authSessionEpoch;
    if (namespace == ActiveConversationRemapNamespace.openWebUi) {
      // Remapping the durable row has already happened by the time this
      // navigation marker is emitted. A temporarily failing context provider
      // must not poison the remap stream or leave the UI on the deleted local
      // id. Capture what is available; the later exact-context check fails
      // closed when any captured component cannot be reproduced.
      try {
        database = ref.read(appDatabaseProvider);
      } catch (_) {}
      try {
        api = ref.read(apiServiceProvider);
      } catch (_) {}
      try {
        authSessionEpoch = ref.read(openWebUiAuthSessionEpochProvider);
      } catch (_) {}
    }
    state = ActiveConversationInPlaceRemap(
      fromId: fromId,
      toId: toId,
      namespace: namespace,
      openWebUiDatabase: database,
      openWebUiApi: api,
      openWebUiAuthSessionEpoch: authSessionEpoch,
    );
  }
}

bool isActiveConversationInPlaceRemap(
  dynamic ref,
  String? previousId,
  String? nextId,
) {
  try {
    if (previousId == null || nextId == null) return false;
    final previousIdentity = ChatStorageIdentity.parse(previousId);
    final nextIdentity = ChatStorageIdentity.parse(nextId);
    if (previousIdentity.storage != null &&
        nextIdentity.storage != null &&
        previousIdentity.storage != nextIdentity.storage) {
      return false;
    }
    final active = ref.read(activeConversationProvider) as Conversation?;
    if (active == null || !conversationMatchesScopedId(active, nextId)) {
      return false;
    }
    final namespace = _activeConversationRemapNamespaceFor(active);
    final remap = ref.read(activeConversationInPlaceRemapProvider);
    if (remap?.matches(
          previousIdentity.rawId,
          nextIdentity.rawId,
          namespace: namespace,
        ) !=
        true) {
      return false;
    }
    if (namespace != ActiveConversationRemapNamespace.openWebUi) return true;
    return remap!.matchesOpenWebUiContext(
      database: ref.read(appDatabaseProvider),
      api: ref.read(apiServiceProvider),
      authSessionEpoch: ref.read(openWebUiAuthSessionEpochProvider),
    );
  } catch (_) {
    return false;
  }
}

class ActiveConversationNotifier extends Notifier<Conversation?> {
  @override
  Conversation? build() => null;

  void set(Conversation? conversation) {
    final previous = state;
    final selectionChanged = previous == null
        ? conversation != null
        : conversation == null ||
              !isSameStoredConversation(previous, conversation);
    if (selectionChanged) {
      ref.read(hermesSessionNavigationEpochProvider.notifier).bump();
    }
    state = conversation;
  }

  void remapIdInPlace({required String fromId, required String toId}) {
    final current = state;
    if (current == null || current.id != fromId) return;
    final namespace = _activeConversationRemapNamespaceFor(current);
    ref
        .read(activeConversationInPlaceRemapProvider.notifier)
        .mark(fromId: fromId, toId: toId, namespace: namespace);
    state = inheritNativeHermesConversationProvenance(
      current,
      current.copyWith(id: toId),
    );
  }

  void clear() {
    ref.read(hermesSessionNavigationEpochProvider.notifier).bump();
    state = null;
  }
}

ActiveConversationRemapNamespace _activeConversationRemapNamespaceFor(
  Conversation conversation,
) {
  final storage = chatStorageKindOf(conversation);
  // Storage ownership and the transport used by the latest turn are separate.
  // A direct/Hermes turn inside a server-owned chat still needs the exact
  // OpenWebUI database/API remap fence.
  if (storage == ChatStorageKind.openWebUi) {
    return ActiveConversationRemapNamespace.openWebUi;
  }
  if (isNativeHermesConversation(conversation)) {
    return ActiveConversationRemapNamespace.hermes;
  }
  if (conversation.metadata['backend'] == 'direct' ||
      storage == ChatStorageKind.directLocal) {
    return ActiveConversationRemapNamespace.direct;
  }
  return ActiveConversationRemapNamespace.openWebUi;
}

// Provider to load full conversation with messages
@riverpod
Future<Conversation> loadConversation(Ref ref, String conversationId) {
  final keepAliveLink = ref.keepAlive();
  return _loadConversation(
    ref,
    conversationId,
  ).whenComplete(keepAliveLink.close);
}

Future<Conversation> _loadConversation(Ref ref, String conversationId) async {
  final identity = ChatStorageIdentity.parse(conversationId);
  final rawConversationId = identity.rawId;
  // Preserve database provenance from the selected summary when possible.
  // Prefixing makes locally-created ids collision-resistant, while the marker
  // handles imported or legacy rows whose ids do collide.
  Conversation? summary;
  final active = ref.read(activeConversationProvider);
  final activeConfirmsOpenWebUiOwnership =
      identity.storage == null &&
      chatStorageKindOf(active) == ChatStorageKind.openWebUi;
  if (active != null &&
      (identity.storage != null || activeConfirmsOpenWebUiOwnership) &&
      conversationMatchesScopedId(active, conversationId)) {
    // Legacy callers still pass raw OpenWebUI ids. An explicitly annotated
    // active summary can restore that ownership while the merged list loads;
    // a Direct-local or unannotated active row is never trusted for this.
    summary = active;
  } else {
    final conversations = ref.read(conversationsProvider).asData?.value;
    if (conversations != null) {
      final index = _conversationIndexForSelection(
        conversations,
        conversationId,
      );
      if (index >= 0) {
        summary = conversations[index];
      }
    }
  }
  final preferredStorage =
      identity.storage ??
      (rawConversationId.startsWith('direct-local:')
          ? ChatStorageKind.directLocal
          : null) ??
      chatStorageKindOf(summary);

  final openWebUiOwnership = captureOpenWebUiConversationRead(ref);
  final repository = ref.read(chatDatabaseRepositoryProvider);
  LocatedConversation? located;
  try {
    located = await repository.loadConversation(
      rawConversationId,
      preferred: preferredStorage,
      locationIsCurrent: (location) =>
          location.storage != ChatStorageKind.openWebUi ||
          (openWebUiOwnership != null &&
              identical(location.database, openWebUiOwnership.database) &&
              openWebUiConversationReadIsCurrent(ref, openWebUiOwnership)),
      offload: (envelope) => ref
          .read(workerManagerProvider)
          .schedule(
            parseFullConversationModelWorker,
            envelope,
            debugLabel: 'db.assembleConversation',
          ),
    );
  } catch (error, stackTrace) {
    DebugLogger.error(
      'load-failed',
      scope: 'conversation/cache',
      error: error,
      stackTrace: stackTrace,
      data: {
        'id': conversationId,
        'storage': preferredStorage?.name ?? 'unknown',
      },
    );
    // Only an explicitly OpenWebUI-owned summary may use the network fallback.
    // Unknown provenance can mean the same raw id exists in both stores; in
    // that case fetching OpenWebUI would silently cross the storage boundary.
    if (preferredStorage != ChatStorageKind.openWebUi) {
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
  if (located != null) {
    if (located.location.storage == ChatStorageKind.openWebUi &&
        (openWebUiOwnership == null ||
            !identical(
              located.location.database,
              openWebUiOwnership.database,
            ) ||
            !openWebUiConversationReadIsCurrent(ref, openWebUiOwnership))) {
      throw OpenWebUiConversationOwnershipException(
        OpenWebUiConversationOwnershipFailureReason.changedWhileLoading,
      );
    }
    final local = withChatStorageProvenance(
      located.conversation,
      located.location.storage,
    );
    DebugLogger.log(
      'load-local-ok',
      scope: 'conversation',
      data: {
        'id': conversationId,
        'messages': local.messages.length,
        'storage': located.location.storage.name,
      },
    );
    if (located.location.storage == ChatStorageKind.openWebUi) {
      schedulePullChatNow(
        ref,
        rawConversationId,
        ownership: openWebUiOwnership,
      );
    }
    return local;
  }

  if (preferredStorage == ChatStorageKind.directLocal) {
    throw StateError('On-device conversation is unavailable');
  }

  if (openWebUiOwnership == null ||
      !openWebUiConversationReadIsCurrent(ref, openWebUiOwnership)) {
    throw OpenWebUiConversationOwnershipException(
      OpenWebUiConversationOwnershipFailureReason.unavailable,
    );
  }
  final api = openWebUiOwnership.api;
  if (api == null) {
    throw Exception('No API service available');
  }

  DebugLogger.log(
    'load-start',
    scope: 'conversation',
    data: {'id': conversationId},
  );
  final fullConversation = await api.getConversation(rawConversationId);
  if (!openWebUiConversationReadIsCurrent(ref, openWebUiOwnership)) {
    throw OpenWebUiConversationOwnershipException(
      OpenWebUiConversationOwnershipFailureReason.changedWhileFetching,
    );
  }
  DebugLogger.log(
    'load-ok',
    scope: 'conversation',
    data: {'messages': fullConversation.messages.length},
  );
  // Materialize the local row so the next open is DB-first.
  schedulePullChatNow(ref, rawConversationId, ownership: openWebUiOwnership);

  return withChatStorageProvenance(fullConversation, ChatStorageKind.openWebUi);
}

// Provider to automatically load and set the default model from user settings or OpenWebUI
@Riverpod(keepAlive: true)
Future<Model?> defaultModel(Ref ref) async {
  Model? resolved;
  while (true) {
    final reviewerAtStart = ref.read(reviewerModeProvider);
    final selectedAtStart = ref.read(selectedModelProvider);
    final manualAtStart = ref.read(isManualModelSelectionProvider);
    final candidate = await _resolveDefaultModel(ref);
    if (!ref.mounted) return null;

    if (ref.read(reviewerModeProvider) != reviewerAtStart) {
      final latestSelected = ref.read(selectedModelProvider);
      final latestManual = ref.read(isManualModelSelectionProvider);
      final hasNewManualSelection =
          latestSelected != null &&
          latestManual &&
          (!manualAtStart || !identical(latestSelected, selectedAtStart));
      if (hasNewManualSelection) {
        resolved = latestSelected;
        break;
      }
      // The mode may change after the resolver's final internal checkpoint but
      // before this provider resumes its await. Loop once more so the cached
      // value and dependency watches belong to the current reviewer universe.
      continue;
    }
    resolved = candidate;
    break;
  }

  // Register reactive dependencies only after async resolution settles. A
  // later input change invalidates the cached result, while a change during an
  // in-flight one-shot `.future` read cannot cancel and orphan that read.
  ref.watch(preferredBackendProvider);
  ref.watch(hermesConfigProvider);
  ref.watch(apiServiceProvider);
  ref.watch(_modelAuthReadinessProvider);
  ref.watch(reviewerModeProvider);
  return resolved;
}

Future<Model?> _resolveDefaultModel(Ref ref) async {
  DebugLogger.log('provider-called', scope: 'models/default');

  final storage = ref.read(optimizedStorageServiceProvider);
  // This provider is commonly consumed through a one-shot `.future` read.
  // Snapshot mutable inputs instead of subscribing across awaits: invalidating
  // an in-flight build can otherwise orphan the caller's future. SelectedModel
  // owns reconciliation, and the post-await checks below reject stale
  // snapshots.
  final preferredBackend = ref.read(preferredBackendProvider);
  final hermesConfig = ref.read(hermesConfigProvider);
  final reviewerMode = ref.read(reviewerModeProvider);
  final selectedAtResolutionStart = ref.read(selectedModelProvider);
  final manualAtResolutionStart = ref.read(isManualModelSelectionProvider);

  bool isGenuinelyNewManualSelection(
    Model? latestSelected,
    bool latestManual,
  ) =>
      latestSelected != null &&
      latestManual &&
      (!manualAtResolutionStart ||
          !identical(latestSelected, selectedAtResolutionStart));

  Future<Model?>? reviewerRedirectAfterAwait() {
    if (ref.read(reviewerModeProvider) == reviewerMode) return null;
    final latestSelected = ref.read(selectedModelProvider);
    final latestManual = ref.read(isManualModelSelectionProvider);
    if (isGenuinelyNewManualSelection(latestSelected, latestManual)) {
      return Future<Model?>.value(latestSelected);
    }
    // Re-enter from the current reviewer state instead of caching an automatic
    // selection from the backend universe that owned the completed await.
    return _resolveDefaultModel(ref);
  }

  if (reviewerMode) {
    DebugLogger.log('reviewer-mode', scope: 'models/default');
    // Check if a model is manually selected
    final currentSelected = selectedAtResolutionStart;
    final isManualSelection = manualAtResolutionStart;

    if (currentSelected != null && isManualSelection) {
      DebugLogger.log(
        'manual',
        scope: 'models/default',
        data: {
          'backend': _modelBackendForDiagnostics(currentSelected),
          'source': 'user',
        },
      );
      return currentSelected;
    }

    // Get demo models and select the first one
    final models = await ref.read(modelsProvider.future);
    if (!ref.mounted) return null;
    final reviewerRedirect = reviewerRedirectAfterAwait();
    if (reviewerRedirect != null) return reviewerRedirect;
    final latestSelected = ref.read(selectedModelProvider);
    final latestManual = ref.read(isManualModelSelectionProvider);
    if (isGenuinelyNewManualSelection(latestSelected, latestManual)) {
      return latestSelected;
    }
    if (!identical(latestSelected, currentSelected) ||
        latestManual != isManualSelection) {
      return _resolveDefaultModel(ref);
    }
    if (models.isNotEmpty) {
      final defaultModel = models.first;
      if (!isManualSelection) {
        ref.read(selectedModelProvider.notifier).set(defaultModel);
        DebugLogger.log(
          'auto-select',
          scope: 'models/default',
          data: {
            'backend': _modelBackendForDiagnostics(defaultModel),
            'source': 'reviewer',
          },
        );
      }
      return defaultModel;
    }
    DebugLogger.warning('no-demo-models', scope: 'models/default');
    return null;
  }

  final api = ref.read(apiServiceProvider);
  var modelAuth = ref.read(_modelAuthReadinessProvider);
  final selectedBeforeAuthSettles = ref.read(selectedModelProvider);
  final authBuildFuture =
      !modelAuth.authenticated &&
          modelAuth.loading &&
          selectedBeforeAuthSettles == null
      ? ref.read(authStateManagerProvider.future)
      : null;
  if (authBuildFuture != null) {
    // A cold-start chat may ask for its default before the initial secure
    // storage read resolves. If this invocation completes with null, there may
    // be no remaining listener to retry when auth settles. Wait for that first
    // AuthStateManager build; inner token refreshes already have AsyncData and
    // return immediately.
    final settledAuth = await authBuildFuture;
    if (!ref.mounted) return null;
    final reviewerRedirect = reviewerRedirectAfterAwait();
    if (reviewerRedirect != null) return reviewerRedirect;
    modelAuth = (
      authenticated: settledAuth.isAuthenticated,
      loading:
          settledAuth.isLoading ||
          settledAuth.status == AuthStatus.initial ||
          settledAuth.status == AuthStatus.loading,
      status: settledAuth.status,
    );
  }
  if (!modelAuth.authenticated) {
    if (!_shouldUseAccountlessModelSelection(
      isAuthenticated: false,
      isAuthLoading: modelAuth.loading,
      authStatus: modelAuth.status,
      preferredBackend: preferredBackend,
      hasApiService: api != null,
    )) {
      // Authentication hydration/revalidation is not logout. Keep the current
      // model and avoid protected OpenWebUI calls until auth settles.
      return ref.read(selectedModelProvider);
    }

    final currentSelected = ref.read(selectedModelProvider);
    final configuredDefaultId =
        currentSelected != null && ref.read(isManualModelSelectionProvider)
        ? null
        : ref.read(appSettingsProvider).defaultModel;
    final Model? standalone;
    if (preferredBackend == PreferredBackend.hermes) {
      standalone = hermesConfig.isUsable
          ? (currentSelected != null && isHermesModel(currentSelected)
                ? currentSelected
                : hermesSyntheticModel())
          : null;
    } else if (preferredBackend == PreferredBackend.direct) {
      final discovery = await ref.read(directModelDiscoveryProvider.future);
      if (!ref.mounted) return null;
      final reviewerRedirect = reviewerRedirectAfterAwait();
      if (reviewerRedirect != null) return reviewerRedirect;
      final registry = ref.read(directModelRegistryProvider);
      standalone = _accountlessSelection(
        models: discovery.models.where(
          (model) => registry.resolve(model) != null,
        ),
        current: currentSelected,
        preferredBackend: preferredBackend,
        preferredModelId: configuredDefaultId,
      );
    } else {
      final models = await ref.read(modelsProvider.future);
      if (!ref.mounted) return null;
      final reviewerRedirect = reviewerRedirectAfterAwait();
      if (reviewerRedirect != null) return reviewerRedirect;
      standalone = _accountlessSelection(
        models: models,
        current: currentSelected,
        preferredBackend: preferredBackend,
        preferredModelId: configuredDefaultId,
      );
    }
    // Provider initialization may not synchronously mutate another provider.
    // The remote/default paths already cross an async boundary; keep the
    // locally minted Hermes fast path under the same Riverpod contract.
    await Future<void>.delayed(Duration.zero);
    if (!ref.mounted) return null;
    final reviewerRedirect = reviewerRedirectAfterAwait();
    if (reviewerRedirect != null) return reviewerRedirect;
    final latestSelected = ref.read(selectedModelProvider);
    final latestAuth = ref.read(_modelAuthReadinessProvider);
    final preferenceIsCurrent =
        ref.read(preferredBackendProvider) == preferredBackend;
    final authStillAllowsAccountless = _shouldUseAccountlessModelSelection(
      isAuthenticated: latestAuth.authenticated,
      isAuthLoading: latestAuth.loading,
      authStatus: latestAuth.status,
      preferredBackend: preferredBackend,
      hasApiService: ref.read(apiServiceProvider) != null,
    );
    final hermesSnapshotIsCurrent =
        preferredBackend != PreferredBackend.hermes ||
        ref.read(hermesConfigProvider).isUsable;
    final directBindingIsCurrent =
        standalone == null ||
        !isLocallyMintedDirectModel(standalone) ||
        ref.read(directModelRegistryProvider).resolve(standalone) != null;
    if (!preferenceIsCurrent ||
        !authStillAllowsAccountless ||
        !hermesSnapshotIsCurrent ||
        !directBindingIsCurrent ||
        !identical(latestSelected, currentSelected)) {
      return latestSelected;
    }
    if (!identical(currentSelected, standalone)) {
      if (currentSelected?.id != standalone?.id) {
        ref.read(isManualModelSelectionProvider.notifier).set(false);
      }
      ref.read(selectedModelProvider.notifier).set(standalone);
    }
    if (standalone != null) return standalone;
    DebugLogger.warning('no-accountless-model', scope: 'models/default');
    return null;
  }

  // Accountless Direct/Hermes selection is independent from the optional
  // OpenWebUI server. Authenticated work captures a point-in-time ownership
  // token below; startup/account listeners invalidate this provider when a
  // fresh resolution is required, so no server dependency needs to be watched
  // across the authentication await above.
  final authenticatedTokenSnapshot = ref.read(authTokenProvider3);
  final apiSnapshot = api;
  final authenticatedOwnershipSnapshot = api == null
      ? null
      : captureOpenWebUiCacheOwnership(
          ref,
          api: api,
          requireAuthenticated: false,
        );

  bool authenticatedResolutionIsCurrent(Model? selectionSnapshot) {
    if (!ref.mounted) return false;
    final latestAuth = ref.read(_modelAuthReadinessProvider);
    final ownershipIsCurrent = apiSnapshot == null
        ? authenticatedOwnershipSnapshot == null
        : authenticatedOwnershipSnapshot != null &&
              openWebUiCacheOwnershipIsCurrent(
                ref,
                authenticatedOwnershipSnapshot,
              );
    return latestAuth.authenticated &&
        ownershipIsCurrent &&
        ref.read(authTokenProvider3) == authenticatedTokenSnapshot &&
        identical(ref.read(apiServiceProvider), apiSnapshot) &&
        ref.read(preferredBackendProvider) == preferredBackend &&
        identical(ref.read(selectedModelProvider), selectionSnapshot);
  }

  if (api == null) {
    final manuallySelected = ref.read(selectedModelProvider);
    if (ref.read(isManualModelSelectionProvider) &&
        manuallySelected != null &&
        _matchesPreferredBackend(manuallySelected, preferredBackend) &&
        (isHermesModel(manuallySelected) ||
            ref.read(directModelRegistryProvider).resolve(manuallySelected) !=
                null)) {
      return manuallySelected;
    }

    final selectionSnapshot = ref.read(selectedModelProvider);
    final models = await ref.read(modelsProvider.future);
    if (!ref.mounted) return null;
    final reviewerRedirect = reviewerRedirectAfterAwait();
    if (reviewerRedirect != null) return reviewerRedirect;
    if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
      return ref.read(selectedModelProvider);
    }
    final standalone =
        _modelForPreferredBackend(models, preferredBackend) ??
        models.firstOrNull;
    if (standalone != null && !ref.read(isManualModelSelectionProvider)) {
      ref.read(selectedModelProvider.notifier).set(standalone);
      return standalone;
    }
    DebugLogger.warning('no-api', scope: 'models/default');
    return null;
  }

  DebugLogger.log('api-available', scope: 'models/default');

  try {
    // Respect manual selection if present
    if (ref.read(isManualModelSelectionProvider)) {
      final current = ref.read(selectedModelProvider);
      if (current != null && !current.isHidden) return current;
      ref.read(isManualModelSelectionProvider.notifier).set(false);
      ref.read(selectedModelProvider.notifier).clear();
    }
    final selectionSnapshot = ref.read(selectedModelProvider);

    // 1) Priority: app-local default model preference.
    final settingsDefaultId = ref.read(appSettingsProvider).defaultModel;
    final storedDefaultId =
        settingsDefaultId ??
        await SettingsService.getDefaultModel().catchError((_) => null);
    if (!ref.mounted) return null;
    var reviewerRedirect = reviewerRedirectAfterAwait();
    if (reviewerRedirect != null) return reviewerRedirect;
    if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
      return ref.read(selectedModelProvider);
    }

    if (storedDefaultId != null && storedDefaultId.isNotEmpty) {
      final availableModels = await ref.read(modelsProvider.future);
      if (!ref.mounted) return null;
      reviewerRedirect = reviewerRedirectAfterAwait();
      if (reviewerRedirect != null) return reviewerRedirect;
      if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
        return ref.read(selectedModelProvider);
      }
      final availableMatch =
          ref
              .read(directModelRegistryProvider)
              .resolveOpenWebUiWireModel(availableModels, storedDefaultId) ??
          availableModels
              .where((model) => model.id == storedDefaultId)
              .firstOrNull;
      if (availableMatch != null && !ref.read(isManualModelSelectionProvider)) {
        ref.read(selectedModelProvider.notifier).set(availableMatch);
        if (!isLocallyMintedDirectModel(availableMatch) &&
            !isHermesModel(availableMatch)) {
          unawaited(
            storage.saveLocalDefaultModel(availableMatch).onError((
              error,
              stack,
            ) {
              DebugLogger.error(
                'Failed to save default model to cache',
                scope: 'models/default',
                error: error,
                stackTrace: stack,
              );
            }),
          );
        }
        DebugLogger.log(
          'settings-default',
          scope: 'models/default',
          data: {
            'backend': _modelBackendForDiagnostics(availableMatch),
            'source': 'available',
          },
        );
        return availableMatch;
      }
      final cachedMatch = await selectCachedModel(storage, storedDefaultId);
      if (!ref.mounted) return null;
      reviewerRedirect = reviewerRedirectAfterAwait();
      if (reviewerRedirect != null) return reviewerRedirect;
      if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
        return ref.read(selectedModelProvider);
      }
      if (cachedMatch != null && !ref.read(isManualModelSelectionProvider)) {
        ref.read(selectedModelProvider.notifier).set(cachedMatch);
        unawaited(
          storage.saveLocalDefaultModel(cachedMatch).catchError((_) {}),
        );
        DebugLogger.log(
          'settings-default',
          scope: 'models/default',
          data: {
            'backend': _modelBackendForDiagnostics(cachedMatch),
            'source': 'settings',
          },
        );
        return cachedMatch;
      }
    }

    // Onboarding into a direct backend should not be silently replaced by an
    // Open WebUI server default merely because both are configured.
    if (preferredBackend == PreferredBackend.direct) {
      final availableModels = await ref.read(modelsProvider.future);
      if (!ref.mounted) return null;
      reviewerRedirect = reviewerRedirectAfterAwait();
      if (reviewerRedirect != null) return reviewerRedirect;
      if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
        return ref.read(selectedModelProvider);
      }
      final preferred = _modelForPreferredBackend(
        availableModels,
        preferredBackend,
      );
      if (preferred != null && !ref.read(isManualModelSelectionProvider)) {
        ref.read(selectedModelProvider.notifier).set(preferred);
        return preferred;
      }
    }

    // 2) Fallback: cached resolved default model (offline/fast startup).
    try {
      final cached = await storage.getLocalDefaultModel();
      if (!ref.mounted) return null;
      reviewerRedirect = reviewerRedirectAfterAwait();
      if (reviewerRedirect != null) return reviewerRedirect;
      if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
        return ref.read(selectedModelProvider);
      }
      if (cached != null && !ref.read(isManualModelSelectionProvider)) {
        final cachedMatch = await selectCachedModel(storage, cached.id);
        if (!ref.mounted) return null;
        reviewerRedirect = reviewerRedirectAfterAwait();
        if (reviewerRedirect != null) return reviewerRedirect;
        if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
          return ref.read(selectedModelProvider);
        }
        if (cachedMatch == null) {
          await storage.saveLocalDefaultModel(null);
          if (!ref.mounted) return null;
          reviewerRedirect = reviewerRedirectAfterAwait();
          if (reviewerRedirect != null) return reviewerRedirect;
          if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
            return ref.read(selectedModelProvider);
          }
        } else {
          ref.read(selectedModelProvider.notifier).set(cachedMatch);
          DebugLogger.log(
            'cached-default',
            scope: 'models/default',
            data: {
              'backend': _modelBackendForDiagnostics(cachedMatch),
              'source': 'cache',
            },
          );
          return cachedMatch;
        }
      }
    } catch (_) {
      if (!ref.mounted) return null;
      reviewerRedirect = reviewerRedirectAfterAwait();
      if (reviewerRedirect != null) return reviewerRedirect;
      if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
        return ref.read(selectedModelProvider);
      }
    }

    // 3) Fallback: server-provided automatic resolution when no app-local
    // preference exists.
    try {
      final serverDefault = await api.getDefaultModel();
      if (!ref.mounted) return null;
      reviewerRedirect = reviewerRedirectAfterAwait();
      if (reviewerRedirect != null) return reviewerRedirect;
      if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
        return ref.read(selectedModelProvider);
      }
      if (serverDefault != null && serverDefault.isNotEmpty) {
        final availableModels = await ref.read(modelsProvider.future);
        if (!ref.mounted) return null;
        reviewerRedirect = reviewerRedirectAfterAwait();
        if (reviewerRedirect != null) return reviewerRedirect;
        if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
          return ref.read(selectedModelProvider);
        }
        Model? resolved = ref
            .read(directModelRegistryProvider)
            .resolveOpenWebUiWireModel(availableModels, serverDefault);
        if (resolved == null) {
          final models = await api.getModels();
          if (!ref.mounted) return null;
          reviewerRedirect = reviewerRedirectAfterAwait();
          if (reviewerRedirect != null) return reviewerRedirect;
          if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
            return ref.read(selectedModelProvider);
          }
          resolved = resolveSafeRemoteDefaultModel(models, serverDefault);
        }

        if (resolved != null && !ref.read(isManualModelSelectionProvider)) {
          ref.read(selectedModelProvider.notifier).set(resolved);
          if (!isLocallyMintedDirectModel(resolved) &&
              !isHermesModel(resolved)) {
            unawaited(
              storage.saveLocalDefaultModel(resolved).onError((error, stack) {
                DebugLogger.error(
                  'Failed to save default model to cache',
                  scope: 'models/default',
                  error: error,
                  stackTrace: stack,
                );
              }),
            );
          }
          DebugLogger.log(
            'server-default',
            scope: 'models/default',
            data: {
              'backend': _modelBackendForDiagnostics(resolved),
              'source': 'server',
            },
          );
          return resolved;
        }
      }
    } catch (_) {
      if (!ref.mounted) return null;
      reviewerRedirect = reviewerRedirectAfterAwait();
      if (reviewerRedirect != null) return reviewerRedirect;
    }

    // 4) Fallback: fetch models and pick first available
    DebugLogger.log('fallback-path', scope: 'models/default');
    final models = await ref.read(modelsProvider.future);
    if (!ref.mounted) return null;
    reviewerRedirect = reviewerRedirectAfterAwait();
    if (reviewerRedirect != null) return reviewerRedirect;
    if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
      return ref.read(selectedModelProvider);
    }
    DebugLogger.log(
      'models-loaded',
      scope: 'models/default',
      data: {'count': models.length},
    );
    if (models.isEmpty) {
      DebugLogger.warning('no-models', scope: 'models/default');
      return null;
    }
    final selectedModel =
        _modelForPreferredBackend(models, preferredBackend) ?? models.first;
    if (!ref.read(isManualModelSelectionProvider)) {
      ref.read(selectedModelProvider.notifier).set(selectedModel);
      if (!isLocallyMintedDirectModel(selectedModel) &&
          !isHermesModel(selectedModel)) {
        unawaited(
          storage.saveLocalDefaultModel(selectedModel).onError((error, stack) {
            DebugLogger.error(
              'Failed to save default model to cache',
              scope: 'models/default',
              error: error,
              stackTrace: stack,
            );
          }),
        );
      }
      DebugLogger.log(
        'fallback-selected',
        scope: 'models/default',
        data: {
          'backend': _modelBackendForDiagnostics(selectedModel),
          'source': 'fallback',
        },
      );
    } else {
      DebugLogger.log('skip-manual-override', scope: 'models/default');
    }
    return selectedModel;
  } catch (e) {
    if (!ref.mounted) return null;
    final reviewerRedirect = reviewerRedirectAfterAwait();
    if (reviewerRedirect != null) return reviewerRedirect;
    DebugLogger.error('set-default-failed', scope: 'models/default', error: e);
    return null;
  }
}

Model? _modelForPreferredBackend(
  Iterable<Model> models,
  PreferredBackend preferredBackend,
) {
  return switch (preferredBackend) {
    PreferredBackend.direct =>
      models.where(isLocallyMintedDirectModel).firstOrNull,
    PreferredBackend.hermes => models.where(isHermesModel).firstOrNull,
    PreferredBackend.owui || PreferredBackend.unset => null,
  };
}

Model? _accountlessSelection({
  required Iterable<Model> models,
  required Model? current,
  required PreferredBackend preferredBackend,
  String? preferredModelId,
}) {
  final available = models.toList(growable: false);

  final preferredMatch = preferredModelId == null || preferredModelId.isEmpty
      ? null
      : available
            .where(
              (model) =>
                  model.id == preferredModelId &&
                  _matchesPreferredBackend(model, preferredBackend),
            )
            .firstOrNull;
  if (preferredMatch != null) return preferredMatch;

  final currentMatch = current == null
      ? null
      : available.where((model) => model.id == current.id).firstOrNull;
  if (currentMatch != null &&
      _matchesPreferredBackend(currentMatch, preferredBackend)) {
    return currentMatch;
  }
  return _modelForPreferredBackend(available, preferredBackend) ??
      switch (preferredBackend) {
        PreferredBackend.owui ||
        PreferredBackend.unset => available.firstOrNull,
        PreferredBackend.direct || PreferredBackend.hermes => null,
      };
}

bool _matchesPreferredBackend(Model model, PreferredBackend preferredBackend) =>
    switch (preferredBackend) {
      PreferredBackend.direct => isLocallyMintedDirectModel(model),
      PreferredBackend.hermes => isHermesModel(model),
      PreferredBackend.owui || PreferredBackend.unset =>
        isLocallyMintedDirectModel(model) || isHermesModel(model),
    };

bool _shouldUseAccountlessModelSelection({
  required bool isAuthenticated,
  required bool isAuthLoading,
  required AuthStatus authStatus,
  required PreferredBackend preferredBackend,
  required bool hasApiService,
}) {
  if (isAuthenticated || isAuthLoading) return false;
  return switch (authStatus) {
    AuthStatus.unauthenticated ||
    AuthStatus.tokenExpired ||
    AuthStatus.credentialError => true,
    AuthStatus.error || AuthStatus.initial || AuthStatus.loading =>
      preferredBackend == PreferredBackend.direct ||
          preferredBackend == PreferredBackend.hermes ||
          !hasApiService,
    AuthStatus.authenticated => false,
  };
}

/// Resolves a server-provided default only after removing identities reserved
/// for Conduit's locally minted Hermes transport.
@visibleForTesting
Model? resolveSafeRemoteDefaultModel(
  List<Model> remoteModels,
  String? serverDefault,
) {
  final models = sanitizeRemoteHermesModels(
    sanitizeRemoteDirectModels(remoteModels),
  );
  if (models.isEmpty) return null;

  if (serverDefault != null && serverDefault.isNotEmpty) {
    for (final model in models) {
      if (model.id == serverDefault) return model;
    }
    final byName = models.where((m) => m.name == serverDefault).toList();
    if (byName.length == 1) return byName.first;
  }
  return models.first;
}

// Search query provider
@Riverpod(keepAlive: true)
class SearchQuery extends _$SearchQuery {
  @override
  String build() => '';

  void set(String query) => state = query;
}

/// Offline full-text search over the synced Drift history (CDT-RFC-001 Phase 4).
///
/// Runs ranked FTS5 search via [SearchDao.search] and maps the hits to the same
/// list-summary [Conversation] shape the server search returns, so callers can
/// treat online and offline results identically. Returns `[]` when there is no
/// active database (no server / reviewer mode) or before the index is built
/// (the DAO short-circuits on the `fts_built` gate). Results are already bm25
/// ascending (most relevant first); order is preserved.
Future<List<Conversation>> _offlineSearch(
  Ref ref,
  String query, {
  ChatStorageKind? storage,
}) async {
  try {
    final repository = ref.read(chatDatabaseRepositoryProvider);
    final hits = storage == null
        ? await repository.searchMergedChats(query, limit: 50)
        : await repository.searchChatsInStorage(
            query,
            storage: storage,
            limit: 50,
          );
    return hits
        .map((located) {
          return withChatStorageProvenance(
            conversationFromSearchHit(located.hit),
            located.storage,
          );
        })
        .toList(growable: false);
  } catch (e) {
    DebugLogger.error('offline-search-failed', scope: 'search', error: e);
    return const [];
  }
}

// Server-side search provider for chats, with an offline FTS5 fallback.
@riverpod
Future<List<Conversation>> serverSearch(Ref ref, String query) async {
  final trimmedQuery = query.trim();
  if (trimmedQuery.isEmpty) {
    // Return empty list for empty query instead of all conversations
    return [];
  }

  if (ref.watch(reviewerModeProvider)) {
    final conversations =
        ref.watch(conversationsProvider).asData?.value ??
        const <Conversation>[];
    final lowerQuery = trimmedQuery.toLowerCase();
    return conversations
        .where((conversation) {
          return conversation.title.toLowerCase().contains(lowerQuery) ||
              conversation.messages.any(
                (message) => message.content.toLowerCase().contains(lowerQuery),
              );
        })
        .toList(growable: false);
  }

  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    // Offline: serve ranked results straight from the local
    // FTS index over synced history (CDT-RFC-001 Phase 4 acceptance).
    DebugLogger.log('offline-search', scope: 'search');
    return _offlineSearch(ref, trimmedQuery);
  }

  try {
    DebugLogger.log(
      'server-search',
      scope: 'search',
      data: {'length': trimmedQuery.length},
    );

    // Use the new server-side search API
    final localResultsFuture = _offlineSearch(
      ref,
      trimmedQuery,
      storage: ChatStorageKind.directLocal,
    );
    final chatHits = await api.searchChats(
      query: trimmedQuery,
      archived: false, // Only search non-archived conversations
      limit: 50,
      sortBy: 'updated_at',
      sortOrder: 'desc',
    );
    // Server search results are explicitly scoped before they are merged with
    // the independent on-device index. Equal raw ids are valid across stores.
    final List<Conversation> conversations = chatHits
        .map(
          (conversation) => withChatStorageProvenance(
            conversation,
            ChatStorageKind.openWebUi,
          ),
        )
        .toList();

    // Perform message-level search and merge chat hits
    try {
      final messageHits = await api.searchMessages(
        query: trimmedQuery,
        limit: 100,
      );

      // Build a set of conversation IDs already present from chat search
      final existingIds = conversations.map(conversationScopedId).toSet();

      // Extract chat ids from message hits (supporting multiple key casings)
      final messageChatIds = <String>{};
      for (final hit in messageHits) {
        final chatId =
            (hit['chat_id'] ?? hit['chatId'] ?? hit['chatID']) as String?;
        if (chatId != null && chatId.isNotEmpty) {
          messageChatIds.add(chatId);
        }
      }

      // Determine which chat ids we still need to fetch
      final idsToFetch = messageChatIds
          .where(
            (id) => !existingIds.contains(
              ChatStorageIdentity(
                rawId: id,
                storage: ChatStorageKind.openWebUi,
              ).scopedId,
            ),
          )
          .toList();

      // Fetch conversations for those ids in parallel (cap to avoid overload)
      const maxFetch = 50;
      final fetchList = idsToFetch.take(maxFetch).toList();
      if (fetchList.isNotEmpty) {
        DebugLogger.log(
          'fetch-from-messages',
          scope: 'search',
          data: {'count': fetchList.length},
        );
        final fetched = await Future.wait(
          fetchList.map((id) async {
            try {
              return await api.getConversation(id);
            } catch (_) {
              return null;
            }
          }),
        );

        // Merge fetched conversations
        for (final conv in fetched) {
          if (conv != null) {
            final scoped = withChatStorageProvenance(
              conv,
              ChatStorageKind.openWebUi,
            );
            if (existingIds.add(conversationScopedId(scoped))) {
              conversations.add(scoped);
            }
          }
        }

        // Optional: sort by updated date desc to keep results consistent
        conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      }
    } catch (e) {
      DebugLogger.error('message-search-failed', scope: 'search', error: e);
    }

    // Server search cannot see chats intentionally kept in the dedicated
    // direct-local database. Merge ranked local results after the remote
    // response, preserving remote ordering and avoiding duplicate server rows.
    final existingIds = conversations.map(conversationScopedId).toSet();
    final localResults = await localResultsFuture;
    for (final local in localResults) {
      if (existingIds.add(conversationScopedId(local))) {
        conversations.add(local);
      }
    }

    DebugLogger.log(
      'server-results',
      scope: 'search',
      data: {'count': conversations.length},
    );
    return conversations;
  } catch (e) {
    DebugLogger.error('server-search-failed', scope: 'search', error: e);

    // Fallback to the offline FTS index when the server search fails. This is a
    // ranked search across ALL synced history (not just the in-memory page),
    // matching the offline path (CDT-RFC-001 Phase 4).
    DebugLogger.log('fallback-offline', scope: 'search');
    return _offlineSearch(ref, trimmedQuery);
  }
}

final filteredConversationsProvider = Provider<List<Conversation>>((ref) {
  final conversations = ref.watch(conversationsProvider);
  final query = ref.watch(searchQueryProvider);

  // Use server-side search when there's a query
  if (query.trim().isNotEmpty) {
    final searchResults = ref.watch(serverSearchProvider(query));
    return searchResults.maybeWhen(
      data: (results) => results,
      loading: () {
        // While server search is loading, show local filtered results
        return conversations.maybeWhen(
          data: (convs) => convs.where((conv) {
            return !conv.archived &&
                (conv.title.toLowerCase().contains(query.toLowerCase()) ||
                    conv.messages.any(
                      (msg) => msg.content.toLowerCase().contains(
                        query.toLowerCase(),
                      ),
                    ));
          }).toList(),
          orElse: () => [],
        );
      },
      error: (_, stackTrace) {
        // On error, fallback to local search
        return conversations.maybeWhen(
          data: (convs) => convs.where((conv) {
            return !conv.archived &&
                (conv.title.toLowerCase().contains(query.toLowerCase()) ||
                    conv.messages.any(
                      (msg) => msg.content.toLowerCase().contains(
                        query.toLowerCase(),
                      ),
                    ));
          }).toList(),
          orElse: () => [],
        );
      },
      orElse: () => [],
    );
  }

  // When no search query, show all non-archived conversations
  return conversations.maybeWhen(
    data: (convs) {
      if (ref.watch(reviewerModeProvider)) {
        return convs; // Already filtered above for demo
      }
      // Filter out archived conversations (they should be in a separate view)
      final filtered = convs.where((conv) => !conv.archived).toList();

      // Sort: pinned conversations first, then by updated date
      filtered.sort((a, b) {
        // Pinned conversations come first
        if (a.pinned && !b.pinned) return -1;
        if (!a.pinned && b.pinned) return 1;

        // Within same pin status, sort by updated date (newest first)
        return b.updatedAt.compareTo(a.updatedAt);
      });

      return filtered;
    },
    orElse: () => [],
  );
});

// Provider for archived conversations
final archivedConversationsProvider = Provider<List<Conversation>>((ref) {
  final conversations = ref.watch(conversationsProvider);

  return conversations.maybeWhen(
    data: (convs) {
      if (ref.watch(reviewerModeProvider)) {
        return convs.where((c) => c.archived).toList();
      }
      // Only show archived conversations
      final archived = convs.where((conv) => conv.archived).toList();

      // Sort by updated date (newest first)
      archived.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

      return archived;
    },
    orElse: () => [],
  );
});

// Reviewer mode provider (persisted)
@Riverpod(keepAlive: true)
class ReviewerMode extends _$ReviewerMode {
  // Notifier instances survive invalidation, so build() can run more than once.
  late OptimizedStorageService _storage;
  int _loadGeneration = 0;

  @override
  bool build() {
    final storage = ref.watch(optimizedStorageServiceProvider);
    _storage = storage;
    final generation = ++_loadGeneration;
    Future.microtask(() => _load(storage, generation));
    return false;
  }

  Future<void> _load(OptimizedStorageService storage, int generation) async {
    final enabled = await storage.getReviewerMode();
    if (!ref.mounted || generation != _loadGeneration) {
      return;
    }
    state = enabled;
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    await _storage.setReviewerMode(enabled);
  }

  Future<void> toggle() => setEnabled(!state);
}

// User Settings providers
@Riverpod(keepAlive: true)
Future<UserSettings> userSettings(Ref ref) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    // Return default settings if no API
    return const UserSettings();
  }

  try {
    final settingsData = await api.getUserSettings();
    return UserSettings.fromJson(settingsData);
  } catch (e) {
    DebugLogger.error('user-settings-failed', scope: 'settings', error: e);
    // Return default settings on error
    return const UserSettings();
  }
}

final rawUserSettingsProvider = FutureProvider<Map<String, dynamic>>((
  ref,
) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    return const <String, dynamic>{};
  }

  try {
    return await api.getUserSettings();
  } catch (e) {
    DebugLogger.error('raw-user-settings-failed', scope: 'settings', error: e);
    return const <String, dynamic>{};
  }
});

@Riverpod(keepAlive: true)
class PersonalizationSettings extends _$PersonalizationSettings {
  int _pinnedModelsWriteGeneration = 0;
  String? _settingsServerId;
  ServerUserSettings? _settingsSnapshot;
  // Server is mirrored into local notification prefs once per server (on first
  // load / server switch). Re-applying on every settings reload could clobber a
  // just-made local toggle whose write-through hasn't reached the server yet.
  String? _notificationPrefsAppliedServerId;

  @override
  Future<ServerUserSettings> build() async {
    ref.watch(activeServerProvider.select((s) => s.asData?.value?.id));
    final apiAlive = ref.watch(apiServiceProvider.select((a) => a != null));
    if (!apiAlive) {
      return _localPinnedModelSettings();
    }
    return _loadSettings();
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_loadSettings);
  }

  Future<ServerUserSettings> setSystemPrompt(String? systemPrompt) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      throw StateError('No API service available');
    }

    final serverId = api.serverConfig.id;
    final updated = await api.updateUserSystemPrompt(systemPrompt);
    if (!ref.mounted) {
      return updated;
    }
    if (!_isCurrentServer(serverId)) {
      return _currentSettingsForActiveServerOrDefault();
    }

    _settingsServerId = serverId;
    _settingsSnapshot = updated;
    state = AsyncData(updated);
    ref.invalidate(rawUserSettingsProvider);
    ref.invalidate(userSettingsProvider);
    return updated;
  }

  Future<ServerUserSettings> setMemoryEnabled(bool enabled) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      throw StateError('No API service available');
    }

    final serverId = api.serverConfig.id;
    final updated = await api.updateUserMemoryEnabled(enabled);
    if (!ref.mounted) {
      return updated;
    }
    if (!_isCurrentServer(serverId)) {
      return _currentSettingsForActiveServerOrDefault();
    }

    _settingsServerId = serverId;
    _settingsSnapshot = updated;
    state = AsyncData(updated);
    ref.invalidate(rawUserSettingsProvider);
    ref.invalidate(userSettingsProvider);
    return updated;
  }

  Future<ServerUserSettings> setReasoningEffort(String? effort) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      throw StateError('No API service available');
    }

    final serverId = api.serverConfig.id;
    final updated = await api.updateUserReasoningEffort(effort);
    if (!ref.mounted) return updated;
    if (!_isCurrentServer(serverId)) {
      return _currentSettingsForActiveServerOrDefault();
    }

    _settingsServerId = serverId;
    _settingsSnapshot = updated;
    state = AsyncData(updated);
    ref.invalidate(rawUserSettingsProvider);
    ref.invalidate(userSettingsProvider);
    return updated;
  }

  Future<ServerUserSettings> setPinnedModels(List<String> modelIds) async {
    final sanitized = SettingsService.sanitizePinnedModels(modelIds);
    final api = ref.read(apiServiceProvider);
    final serverId = api?.serverConfig.id;
    final current =
        _currentSettingsForServer(serverId) ?? const ServerUserSettings();
    final optimistic = current.copyWith(pinnedModelIds: sanitized);
    final writeGeneration = ++_pinnedModelsWriteGeneration;

    _settingsServerId = serverId;
    _settingsSnapshot = optimistic;
    state = AsyncData(optimistic);
    await ref.read(appSettingsProvider.notifier).setPinnedModels(sanitized);

    if (api == null) {
      return optimistic;
    }

    try {
      final updated = await api.updateUserPinnedModels(sanitized);
      if (!ref.mounted) {
        return updated;
      }
      if (!_isCurrentServer(serverId)) {
        return _currentSettingsForActiveServerOrDefault();
      }
      if (writeGeneration != _pinnedModelsWriteGeneration) {
        return state.asData?.value ?? updated;
      }

      _settingsServerId = serverId;
      _settingsSnapshot = updated;
      state = AsyncData(updated);
      _cachePinnedModelsLocally(updated.pinnedModelIds);
      ref.invalidate(rawUserSettingsProvider);
      ref.invalidate(userSettingsProvider);
      return updated;
    } catch (error, stackTrace) {
      if (!_isCurrentServer(serverId)) {
        return _currentSettingsForActiveServerOrDefault();
      }
      if (writeGeneration != _pinnedModelsWriteGeneration) {
        return state.asData?.value ?? optimistic;
      }
      DebugLogger.error(
        'server-pinned-models-update-failed',
        scope: 'settings',
        error: error,
        stackTrace: stackTrace,
      );
      return optimistic;
    }
  }

  Future<ServerUserSettings> togglePinnedModel(String modelId) {
    final trimmed = modelId.trim();
    if (trimmed.isEmpty) {
      return Future.value(state.asData?.value ?? const ServerUserSettings());
    }

    final api = ref.read(apiServiceProvider);
    final currentSettings = _currentSettingsForServer(api?.serverConfig.id);
    if (api != null && currentSettings == null) {
      return Future.value(_currentSettingsForActiveServerOrDefault());
    }

    final currentPinned = currentSettings?.pinnedModelIds;
    final existing = api == null
        ? currentPinned ?? ref.read(appSettingsProvider).pinnedModels
        : currentPinned ?? const <String>[];
    final updated = existing.contains(trimmed)
        ? existing.where((id) => id != trimmed).toList(growable: false)
        : SettingsService.sanitizePinnedModels([...existing, trimmed]);
    return setPinnedModels(updated);
  }

  Future<ServerUserSettings> _loadSettings() async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      _settingsServerId = null;
      final localSettings = _localPinnedModelSettings();
      _settingsSnapshot = localSettings;
      return localSettings;
    }
    final serverId = api.serverConfig.id;
    final readGeneration = _pinnedModelsWriteGeneration;
    final settings = await api.getServerUserSettingsModel();
    if (!ref.mounted) {
      return settings;
    }
    if (!_isCurrentServer(serverId)) {
      return _currentSettingsForActiveServerOrDefault();
    }
    // Server is authoritative for the Open WebUI-aligned notification prefs;
    // mirror them into local settings for cross-device parity (no-ops nulls).
    // Only once per server so a fresh local toggle isn't overwritten by a
    // settings reload that raced the write-through.
    if (_notificationPrefsAppliedServerId != serverId) {
      // Lock the flag only after a successful mirror so a failed apply retries
      // on a later reload instead of staying out of sync for the session.
      unawaited(
        ref
            .read(appSettingsProvider.notifier)
            .applyServerNotificationPrefs(
              enabled: settings.notificationEnabled,
              sound: settings.notificationSound,
              soundAlways: settings.notificationSoundAlways,
            )
            .then(
              (_) => _notificationPrefsAppliedServerId = serverId,
              onError: (Object e, StackTrace st) {
                DebugLogger.error(
                  'failed to mirror server notification prefs',
                  error: e,
                  stackTrace: st,
                  scope: 'notifications/settings',
                );
              },
            ),
      );
    }
    if (readGeneration != _pinnedModelsWriteGeneration) {
      final merged = _settingsWithCurrentPinnedModels(settings, serverId);
      _settingsServerId = serverId;
      _settingsSnapshot = merged;
      return merged;
    }

    _settingsServerId = serverId;
    _settingsSnapshot = settings;
    _cachePinnedModelsLocally(settings.pinnedModelIds);
    return settings;
  }

  ServerUserSettings _settingsWithCurrentPinnedModels(
    ServerUserSettings settings,
    String? serverId,
  ) {
    final currentPinned = _currentSettingsForServer(serverId)?.pinnedModelIds;
    return settings.copyWith(
      pinnedModelIds: SettingsService.sanitizePinnedModels(
        currentPinned ?? const <String>[],
      ),
    );
  }

  ServerUserSettings? _currentSettingsForServer(String? serverId) {
    if (serverId != _settingsServerId) {
      return null;
    }
    final current = state.asData?.value;
    return current ?? _settingsSnapshot;
  }

  bool _isCurrentServer(String? serverId) {
    return serverId == _currentApiServerId();
  }

  String? _currentApiServerId() {
    return ref.read(apiServiceProvider)?.serverConfig.id;
  }

  ServerUserSettings _currentSettingsForActiveServerOrDefault() {
    return _currentSettingsForServer(_currentApiServerId()) ??
        const ServerUserSettings();
  }

  bool get canTogglePinnedModels {
    final api = ref.read(apiServiceProvider);
    return api == null ||
        _currentSettingsForServer(api.serverConfig.id) != null;
  }

  ServerUserSettings _localPinnedModelSettings() {
    return ServerUserSettings(
      pinnedModelIds: ref.read(appSettingsProvider).pinnedModels,
    );
  }

  void _cachePinnedModelsLocally(List<String> modelIds) {
    final local = ref.read(appSettingsProvider).pinnedModels;
    if (listEquals(local, modelIds)) {
      return;
    }

    unawaited(
      Future<void>.microtask(() async {
        if (!ref.mounted) {
          return;
        }
        await ref.read(appSettingsProvider.notifier).setPinnedModels(modelIds);
      }),
    );
  }
}

final effectivePinnedModelIdsProvider = Provider<List<String>>((ref) {
  final localPinnedModelIds = ref.watch(
    appSettingsProvider.select((settings) => settings.pinnedModels),
  );
  final apiAlive = ref.watch(apiServiceProvider.select((api) => api != null));
  if (!apiAlive) {
    return localPinnedModelIds;
  }

  final serverSettings = ref.watch(personalizationSettingsProvider);
  return serverSettings.maybeWhen(
    data: (settings) => settings.pinnedModelIds,
    orElse: () => localPinnedModelIds,
  );
});

final canTogglePinnedModelsProvider = Provider<bool>((ref) {
  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    return true;
  }

  ref.watch(personalizationSettingsProvider);
  return ref
      .read(personalizationSettingsProvider.notifier)
      .canTogglePinnedModels;
});

@Riverpod(keepAlive: true)
class UserMemories extends _$UserMemories {
  @override
  Future<List<ServerMemory>> build() async {
    ref.watch(activeServerProvider.select((s) => s.asData?.value?.id));
    final apiAlive = ref.watch(apiServiceProvider.select((a) => a != null));
    final api = ref.read(apiServiceProvider);
    if (!apiAlive || api == null) {
      return const <ServerMemory>[];
    }
    return _sortedMemories(await api.getMemories());
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_loadMemories);
  }

  Future<ServerMemory> add(String content) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      throw StateError('No API service available');
    }

    final memory = await api.createMemory(content: content);
    if (!ref.mounted) {
      return memory;
    }

    _replaceState([..._currentMemories(), memory]);
    return memory;
  }

  Future<ServerMemory> updateItem(String memoryId, String content) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      throw StateError('No API service available');
    }

    final updated = await api.updateMemory(
      memoryId: memoryId,
      content: content,
    );
    if (!ref.mounted) {
      return updated;
    }

    final current = _currentMemories();
    final next = _transformItemById(
      current,
      memoryId,
      (_) => updated,
      idOf: (memory) => memory.id,
    );
    _replaceState(next?.items ?? current);
    return updated;
  }

  Future<void> deleteItem(String memoryId) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      throw StateError('No API service available');
    }

    await api.deleteMemory(memoryId);
    if (!ref.mounted) {
      return;
    }

    _replaceState(
      _removeItemById(
        _currentMemories(),
        memoryId,
        idOf: (memory) => memory.id,
      ).items,
    );
  }

  Future<void> clearAll() async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      throw StateError('No API service available');
    }

    await api.clearAllMemories();
    if (!ref.mounted) {
      return;
    }

    state = const AsyncData(<ServerMemory>[]);
  }

  Future<List<ServerMemory>> _loadMemories() async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      return const <ServerMemory>[];
    }
    return _sortedMemories(await api.getMemories());
  }

  List<ServerMemory> _currentMemories() =>
      state.asData?.value ?? const <ServerMemory>[];

  void _replaceState(List<ServerMemory> memories) {
    state = AsyncData<List<ServerMemory>>(_sortedMemories(memories));
  }

  List<ServerMemory> _sortedMemories(List<ServerMemory> memories) {
    final sorted = [...memories];
    sorted.sort(
      (left, right) => right.updatedAtEpoch.compareTo(left.updatedAtEpoch),
    );
    return sorted;
  }
}

@Riverpod(keepAlive: true)
class AccountProfile extends _$AccountProfile {
  @override
  Future<AccountMetadata?> build() async {
    final api = ref.watch(apiServiceProvider);
    if (api == null) {
      return null;
    }
    return api.getAccountMetadata();
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_loadProfile);
  }

  Future<AccountMetadata> save({
    required String name,
    required String profileImageUrl,
    String? bio,
    String? gender,
    String? dateOfBirth,
    String? timezone,
  }) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      throw StateError('No API service available');
    }

    final updated = await api.updateAccountMetadata(
      name: name,
      profileImageUrl: profileImageUrl,
      bio: bio,
      gender: gender,
      dateOfBirth: dateOfBirth,
      timezone: timezone,
    );
    if (!ref.mounted) {
      return updated;
    }

    state = AsyncData(updated);
    await ref.read(authActionsProvider).refresh();
    ref.invalidate(currentUserProvider);
    return updated;
  }

  Future<void> updatePassword({
    required String password,
    required String newPassword,
  }) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      throw StateError('No API service available');
    }
    await api.updateAccountPassword(
      password: password,
      newPassword: newPassword,
    );
  }

  Future<AccountMetadata?> _loadProfile() async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      return null;
    }
    return api.getAccountMetadata();
  }
}

@Riverpod(keepAlive: true)
Future<ServerAboutInfo?> serverAboutInfo(Ref ref) async {
  ref.watch(activeServerProvider.select((s) => s.asData?.value?.id));
  final apiAlive = ref.watch(apiServiceProvider.select((a) => a != null));
  final api = ref.read(apiServiceProvider);
  if (!apiAlive || api == null) {
    return null;
  }
  return api.getServerAboutInfo();
}

/// Cached [PackageInfo] for About screens and native profile sheets.
final packageInfoProvider = FutureProvider<PackageInfo>((ref) async {
  return PackageInfo.fromPlatform();
});

// Conversation Suggestions provider
@Riverpod(keepAlive: true)
Future<List<String>> conversationSuggestions(Ref ref) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) return [];

  try {
    return await api.getSuggestions();
  } catch (e) {
    DebugLogger.error('suggestions-failed', scope: 'suggestions', error: e);
    return [];
  }
}

// Server features and permissions
@Riverpod(keepAlive: true)
Future<Map<String, dynamic>> userPermissions(Ref ref) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) return {};

  try {
    return await api.getUserPermissions();
  } catch (e) {
    DebugLogger.error('permissions-failed', scope: 'permissions', error: e);
    return {};
  }
}

bool _coerceFeatureFlag(dynamic value, {required bool fallback}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    switch (value.trim().toLowerCase()) {
      case 'true':
      case '1':
      case 'yes':
        return true;
      case 'false':
      case '0':
      case 'no':
        return false;
    }
  }
  return fallback;
}

bool _userCanUseFeature({
  required User? user,
  required Map<String, dynamic> permissions,
  required String featureKey,
}) {
  if (user?.role == 'admin') {
    return true;
  }

  final features = permissions['features'];
  if (features is Map) {
    return _coerceFeatureFlag(features[featureKey], fallback: true);
  }

  return true;
}

bool _modelSupportsFeature(Model? model, String featureKey) {
  final metadata = model?.metadata;
  final info = metadata?['info'];
  final infoMeta = info is Map ? info['meta'] : null;
  final rootMeta = metadata?['meta'];

  for (final capabilities in <dynamic>[
    if (infoMeta is Map) infoMeta['capabilities'],
    if (rootMeta is Map) rootMeta['capabilities'],
    model?.capabilities,
  ]) {
    if (capabilities is Map && capabilities.containsKey(featureKey)) {
      return _coerceFeatureFlag(capabilities[featureKey], fallback: true);
    }
  }

  return true;
}

final imageGenerationAvailableProvider = Provider<bool>((ref) {
  final perms = ref.watch(userPermissionsProvider);
  return perms.maybeWhen(
    data: (data) {
      final features = data['features'];
      if (features is Map<String, dynamic>) {
        final value = features['image_generation'];
        if (value is bool) return value;
        if (value is String) return value.toLowerCase() != 'false';
      }
      // No explicit permission — default to available. Open WebUI defaults
      // image_generation to true and the server will ignore the flag if the
      // feature is not configured.
      return true;
    },
    // Permissions unavailable (loading, error, older server) — assume available.
    orElse: () => true,
  );
});

final webSearchAvailableProvider = Provider<bool>((ref) {
  final selectedModel = ref.watch(selectedModelProvider);
  final directBinding = selectedModel == null
      ? null
      : ref.watch(directModelRegistryProvider).resolve(selectedModel);
  if (selectedModel != null && hasReservedDirectIdentity(selectedModel)) {
    // Device-owned direct models must never fall through to OpenWebUI
    // permissions. Ollama Cloud is currently the only direct transport with
    // a native, permission-aware web-search execution path.
    return directBinding?.source == DirectModelSource.device &&
        directBinding?.adapterKey == kOllamaAdapterKey &&
        selectedModel.capabilities?['ollama_cloud'] == true &&
        selectedModel.capabilities?['web_search'] == true;
  }

  final backendConfig = ref
      .watch(backendConfigProvider)
      .maybeWhen(data: (config) => config, orElse: () => null);
  if (backendConfig?.enableWebSearch == false) {
    return false;
  }

  if (!_modelSupportsFeature(selectedModel, 'web_search')) {
    return false;
  }

  final user = ref
      .watch(currentUserProvider)
      .maybeWhen(data: (value) => value, orElse: () => null);
  final perms = ref.watch(userPermissionsProvider);
  return perms.maybeWhen(
    data: (data) => _userCanUseFeature(
      user: user,
      permissions: data,
      featureKey: 'web_search',
    ),
    // Permissions unavailable (loading, error, older server) — assume available.
    orElse: () => true,
  );
});

/// Tracks whether the folders feature is enabled on the server.
/// When the server returns 403 for folders endpoint, this becomes false.
final foldersFeatureEnabledProvider =
    NotifierProvider<FoldersFeatureEnabledNotifier, bool>(
      FoldersFeatureEnabledNotifier.new,
    );

class FoldersFeatureEnabledNotifier extends Notifier<bool> {
  _FeatureAvailabilityScope? _scope;

  @override
  bool build() {
    _scope = _featureAvailabilityScope(ref);
    return _FeatureAvailabilityCache.read('folders', scope: _scope) ?? true;
  }

  void setEnabled(bool enabled) {
    state = enabled;
    _FeatureAvailabilityCache.write('folders', enabled, scope: _scope);
  }
}

/// Tracks whether the notes feature is enabled on the server.
/// Set to false when the server returns 401 or 403 for the notes endpoint.
final notesFeatureEnabledProvider =
    NotifierProvider<NotesFeatureEnabledNotifier, bool>(
      NotesFeatureEnabledNotifier.new,
    );

class NotesFeatureEnabledNotifier extends Notifier<bool> {
  _FeatureAvailabilityScope? _scope;

  @override
  bool build() {
    _scope = _featureAvailabilityScope(ref);
    return _FeatureAvailabilityCache.read('notes', scope: _scope) ?? true;
  }

  void setEnabled(bool enabled) {
    state = enabled;
    _FeatureAvailabilityCache.write('notes', enabled, scope: _scope);
  }
}

/// Tracks whether the Channels feature is enabled on the server.
/// Set to false when the server returns 401 or 403 for the channels endpoint.
final channelsFeatureEnabledProvider =
    NotifierProvider<ChannelsFeatureEnabledNotifier, bool>(
      ChannelsFeatureEnabledNotifier.new,
    );

class ChannelsFeatureEnabledNotifier extends Notifier<bool> {
  _FeatureAvailabilityScope? _scope;

  @override
  bool build() {
    _scope = _featureAvailabilityScope(ref);
    return _FeatureAvailabilityCache.read('channels', scope: _scope) ?? true;
  }

  void setEnabled(bool enabled) {
    state = enabled;
    _FeatureAvailabilityCache.write('channels', enabled, scope: _scope);
  }
}

/// Tracks whether the Terminal feature has any available servers on the active
/// server, cached per server/user. The terminal tab's visibility is otherwise
/// derived live from [terminalAvailableServersProvider]; this cache lets the tab
/// reflect the last-known state when offline (loading/error) instead of
/// optimistically defaulting to visible — matching notes/channels behavior so a
/// server with terminal disabled doesn't surface the tab offline. The live
/// derivation lives in `terminalTabVisibleProvider` (terminal feature), which
/// writes back here via [setEnabled] whenever the server list resolves.
final terminalFeatureEnabledProvider =
    NotifierProvider<TerminalFeatureEnabledNotifier, bool>(
      TerminalFeatureEnabledNotifier.new,
    );

class TerminalFeatureEnabledNotifier extends Notifier<bool> {
  _FeatureAvailabilityScope? _scope;

  @override
  bool build() {
    _scope = _featureAvailabilityScope(ref);
    return _FeatureAvailabilityCache.read('terminal', scope: _scope) ?? true;
  }

  void setEnabled(bool enabled) {
    state = enabled;
    _FeatureAvailabilityCache.write('terminal', enabled, scope: _scope);
  }
}

_FeatureAvailabilityScope? _featureAvailabilityScope(Ref ref) {
  final activeServerId = ref.watch(
    activeServerProvider.select((value) => value.asData?.value?.id),
  );
  final serverId = activeServerId ?? _FeatureAvailabilityCache.activeServerId();
  if (serverId == null) return null;

  final userId = ref.watch(currentUserProvider2.select((user) => user?.id));
  final tokenUserId = _featureAvailabilityTokenUserId(
    ref.watch(authTokenProvider3),
  );
  if (userId != null && userId.isNotEmpty) {
    return _FeatureAvailabilityScope(
      serverId: serverId,
      userId: userId,
      fallbackUserId: tokenUserId,
    );
  }

  if (tokenUserId == null) return null;
  return _FeatureAvailabilityScope(serverId: serverId, userId: tokenUserId);
}

String? _featureAvailabilityTokenUserId(String? token) {
  final trimmed = token?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final digest = sha256.convert(utf8.encode(trimmed)).toString();
  return '__token_${digest.substring(0, 24)}';
}

final class _FeatureAvailabilityScope {
  const _FeatureAvailabilityScope({
    required this.serverId,
    required this.userId,
    this.fallbackUserId,
  });

  final String serverId;
  final String userId;
  final String? fallbackUserId;

  String get cacheKey => '$serverId::$userId';

  String? get fallbackCacheKey {
    final fallback = fallbackUserId;
    if (fallback == null || fallback == userId) return null;
    return '$serverId::$fallback';
  }
}

final class _FeatureAvailabilityCache {
  const _FeatureAvailabilityCache._();

  // The nested flag map is stored in shared_preferences as a JSON string. It's
  // read per-feature per-build, so keep the decoded map cached and only re-parse
  // when the underlying string actually changes (e.g. a write here, or an
  // external clear). Keyed by the raw string so a clearAll invalidates it.
  //
  // INVARIANT: [_cachedMap] is treated as READ-ONLY. Reads return it directly
  // (no copy); writes build a fresh deep copy, mutate that, then replace the
  // cache — so a reader can never observe (or corrupt) a half-mutated map and
  // there is no shared-nested-map hazard.
  static String? _cachedRaw;
  static Map<String, dynamic> _cachedMap = const <String, dynamic>{};

  static bool? read(String featureKey, {_FeatureAvailabilityScope? scope}) {
    if (!PreferencesStore.isReady) return null;
    final resolvedScope = scope;
    if (resolvedScope == null) return null;

    final flags = _flags();
    final value = _readFeature(flags, resolvedScope.cacheKey, featureKey);
    if (value != null) return value;

    final fallbackCacheKey = resolvedScope.fallbackCacheKey;
    if (fallbackCacheKey == null) return null;
    final fallbackValue = _readFeature(flags, fallbackCacheKey, featureKey);
    if (fallbackValue == null) return null;
    // Backfill the primary scope so the next read hits directly.
    _writeFeature({resolvedScope.cacheKey}, featureKey, fallbackValue);
    return fallbackValue;
  }

  static void write(
    String featureKey,
    bool enabled, {
    _FeatureAvailabilityScope? scope,
  }) {
    if (!PreferencesStore.isReady) return;
    final resolvedScope = scope;
    if (resolvedScope == null) return;
    _writeFeature(
      {resolvedScope.cacheKey, ?resolvedScope.fallbackCacheKey},
      featureKey,
      enabled,
    );
  }

  static String? activeServerId() {
    if (!PreferencesStore.isReady) return null;
    final value = PreferencesStore.getString(PreferenceKeys.activeServerId);
    if (value == null || value.isEmpty) return null;
    return value;
  }

  /// Read-only decoded flag map (cached by raw string). Callers MUST NOT mutate
  /// the returned map or its nested maps.
  static Map<String, dynamic> _flags() {
    final raw = PreferencesStore.getString(
      PreferenceKeys.serverFeatureAvailability,
    );
    if (raw == null || raw.isEmpty) {
      _cachedRaw = raw;
      _cachedMap = const <String, dynamic>{};
      return _cachedMap;
    }
    if (raw != _cachedRaw) {
      try {
        final decoded = jsonDecode(raw);
        _cachedMap = decoded is Map
            ? decoded.map((key, value) => MapEntry(key.toString(), value))
            : const <String, dynamic>{};
      } catch (_) {
        _cachedMap = const <String, dynamic>{};
      }
      _cachedRaw = raw;
    }
    return _cachedMap;
  }

  static bool? _readFeature(
    Map<String, dynamic> flags,
    String cacheKey,
    String featureKey,
  ) {
    final server = flags[cacheKey];
    if (server is! Map) return null;
    final value = server[featureKey];
    return value is bool ? value : null;
  }

  /// Sets [featureKey] = [enabled] for each of [cacheKeys] and persists. Builds
  /// ONE deep copy of the cached map, mutates it, then replaces the cache — no
  /// redundant per-key reads and no shared-nested-map aliasing.
  static void _writeFeature(
    Set<String> cacheKeys,
    String featureKey,
    bool enabled,
  ) {
    final flags = _deepCopyFlags(_flags());
    for (final cacheKey in cacheKeys) {
      final existing = flags[cacheKey];
      final serverFlags = existing is Map
          ? Map<String, dynamic>.from(existing)
          : <String, dynamic>{};
      serverFlags[featureKey] = enabled;
      flags[cacheKey] = serverFlags;
    }

    final encoded = jsonEncode(flags);
    _cachedRaw = encoded;
    _cachedMap = flags;
    unawaited(
      PreferencesStore.put(
        PreferenceKeys.serverFeatureAvailability,
        encoded,
      ).catchError((Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'feature-cache-write-failed',
          scope: 'features/cache',
          error: error,
          stackTrace: stackTrace,
          data: {'feature': featureKey},
        );
      }),
    );
  }

  static Map<String, dynamic> _deepCopyFlags(Map<String, dynamic> source) {
    return source.map(
      (key, value) => MapEntry(
        key,
        value is Map ? Map<String, dynamic>.from(value) : value,
      ),
    );
  }
}

// Folders provider — Drift-backed read path (CDT-RFC-001 Phase 1). Renders
// from `FoldersDao.watchFolders()`; server-confirmed mutations land in memory
// and in the database in the same call so the next emission agrees.
// `foldersFeatureEnabledProvider` is now set by the SyncEngine from
// PullResult.
@Riverpod(keepAlive: true)
class Folders extends _$Folders {
  @override
  Future<List<Folder>> build() async {
    if (!ref.watch(isAuthenticatedProvider2)) {
      DebugLogger.log('skip-unauthed', scope: 'folders');
      return const [];
    }

    final db = ref.watch(appDatabaseProvider);
    if (db == null) {
      return const [];
    }

    final completer = Completer<List<Folder>>();
    final subscription = db.foldersDao.watchFolders().listen(
      (rows) {
        final folders = _sort([for (final row in rows) folderFromRow(row)]);
        if (!completer.isCompleted) {
          completer.complete(folders);
          return;
        }
        if (ref.mounted) {
          state = AsyncData<List<Folder>>(folders);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'watch-failed',
          scope: 'folders',
          error: error,
          stackTrace: stackTrace,
        );
        if (!completer.isCompleted) {
          completer.complete(const <Folder>[]);
        }
      },
    );
    ref.onDispose(subscription.cancel);
    return completer.future;
  }

  Future<void> refresh({bool forceFresh = false}) async {
    await ref
        .read(syncEngineProvider.notifier)
        .requestPull(reason: 'folders-refresh');
  }

  Future<void> warmIfNeeded() async {
    await ref
        .read(syncEngineProvider.notifier)
        .requestPull(reason: 'folders-warm');
  }

  void upsertFolder(Folder folder) {
    _replaceState(
      _upsertItemById(
        state.asData?.value ?? const <Folder>[],
        folder,
        idOf: (item) => item.id,
      ),
    );
    _persistFolder(folder);
  }

  /// Applies a server-confirmed folder upsert.
  void upsertFolderFromRemote(Folder folder) => upsertFolder(folder);

  void updateFolder(String id, Folder Function(Folder folder) transform) {
    final current = state.asData?.value;
    final update = current == null
        ? null
        : _transformItemById(current, id, transform, idOf: (f) => f.id);
    if (update == null) {
      _persistFolderTransform(id, transform);
      _requestReconcilePull(
        action: current == null ? 'update-cold' : 'update-missing',
      );
      return;
    }
    _replaceState(update.items);
    _persistFolder(update.item);
  }

  /// Applies a server-confirmed folder update.
  void updateFolderFromRemote(
    String id,
    Folder Function(Folder folder) transform,
  ) {
    updateFolder(id, transform);
  }

  void removeFolder(String id) {
    final current = state.asData?.value;
    if (current != null) {
      final removal = _removeItemById(current, id, idOf: (f) => f.id);
      if (removal.didRemove) {
        _replaceState(removal.items);
      }
    }
    final db = ref.read(appDatabaseProvider);
    if (db == null) return;
    unawaited(
      db.foldersDao.hardDelete(id).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        DebugLogger.error(
          'row-delete-failed',
          scope: 'folders',
          error: error,
          stackTrace: stackTrace,
          data: {'id': id},
        );
      }),
    );
  }

  /// Applies a server-confirmed folder deletion.
  void removeFolderFromRemote(String id) => removeFolder(id);

  void _persistFolder(Folder folder) {
    final db = ref.read(appDatabaseProvider);
    if (db == null) return;
    unawaited(
      db.foldersDao.upsertServerFolder(_rawFolder(folder)).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        DebugLogger.error(
          'row-upsert-failed',
          scope: 'folders',
          error: error,
          stackTrace: stackTrace,
          data: {'id': folder.id},
        );
      }),
    );
  }

  void _persistFolderTransform(
    String id,
    Folder Function(Folder folder) transform,
  ) {
    final db = ref.read(appDatabaseProvider);
    if (db == null) return;
    unawaited(
      (() async {
        final row = await db.foldersDao.getFolder(id);
        if (row == null) return;
        await db.foldersDao.upsertServerFolder(
          _rawFolder(transform(folderFromRow(row))),
        );
      })().catchError((Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'row-transform-failed',
          scope: 'folders',
          error: error,
          stackTrace: stackTrace,
          data: {'id': id},
        );
      }),
    );
  }

  void _requestReconcilePull({required String action}) {
    _submitReconcilePull(
      ref,
      reason: 'folders-reconcile',
      scope: 'folders',
      action: action,
    );
  }

  /// `FoldersDao.upsertServerFolder`-shaped raw map (timestamps as server
  /// epoch seconds; everything else rides in rawExtra verbatim).
  static Map<String, dynamic> _rawFolder(Folder folder) {
    final raw = folder.toJson();
    final createdAt = folder.createdAt;
    final updatedAt = folder.updatedAt;
    raw['created_at'] = createdAt == null ? 0 : _epochSecondsOf(createdAt);
    raw['updated_at'] = updatedAt == null ? 0 : _epochSecondsOf(updatedAt);
    return raw;
  }

  List<Folder> _sort(List<Folder> input) {
    final sorted = [...input];
    sorted.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return List<Folder>.unmodifiable(sorted);
  }

  void _replaceState(List<Folder> folders) {
    state = AsyncData<List<Folder>>(_sort(folders));
  }
}

// Files provider
@Riverpod(keepAlive: true)
class UserFiles extends _$UserFiles {
  int _loadGeneration = 0;

  @override
  Future<List<FileInfo>> build() async {
    if (!ref.watch(isAuthenticatedProvider2)) {
      DebugLogger.log('skip-unauthed', scope: 'files');
      return const [];
    }
    final api = ref.watch(apiServiceProvider);
    if (api == null) return const [];
    return _load(api);
  }

  Future<void> refresh() async {
    if (!ref.read(isAuthenticatedProvider2)) {
      state = const AsyncData<List<FileInfo>>([]);
      return;
    }
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      state = const AsyncData<List<FileInfo>>([]);
      return;
    }
    final result = await AsyncValue.guard(() => _load(api));
    if (!ref.mounted) return;
    state = result;
  }

  void upsert(FileInfo file) {
    if (!state.hasValue) {
      return;
    }

    final current = state.requireValue;
    final updated = _upsertItemById(current, file, idOf: (item) => item.id);
    _replaceState(updated);
  }

  void remove(String id) {
    final current = state.asData?.value;
    if (current == null) return;
    final removal = _removeItemById(current, id, idOf: (file) => file.id);
    _replaceState(removal.items);
  }

  Future<List<FileInfo>> _load(ApiService api) async {
    try {
      final loadGeneration = ++_loadGeneration;
      final firstPage = await api.getUserFilesPage(page: 1);
      final initialFiles = _sort(firstPage.items);

      final shouldLoadMore =
          firstPage.isPaginated &&
          firstPage.items.isNotEmpty &&
          (firstPage.total == null ||
              firstPage.items.length < firstPage.total!);

      if (shouldLoadMore) {
        unawaited(
          Future<void>.delayed(Duration.zero, () {
            return _loadRemainingPages(
              api,
              loadGeneration: loadGeneration,
              initialFiles: initialFiles,
              total: firstPage.total,
            );
          }),
        );
      }

      return initialFiles;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'files-failed',
        scope: 'files',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  List<FileInfo> _sort(List<FileInfo> input) {
    final sorted = [...input];
    sorted.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List<FileInfo>.unmodifiable(sorted);
  }

  void _replaceState(List<FileInfo> files) {
    state = AsyncData<List<FileInfo>>(_sort(files));
  }

  Future<void> _loadRemainingPages(
    ApiService api, {
    required int loadGeneration,
    required List<FileInfo> initialFiles,
    required int? total,
  }) async {
    if (!_isCurrentLoad(loadGeneration)) {
      return;
    }

    var page = 2;
    var totalCount = total;
    var loadedFiles = initialFiles;

    try {
      while (true) {
        final pageResult = await api.getUserFilesPage(page: page);
        if (!_isCurrentLoad(loadGeneration)) {
          return;
        }
        if (pageResult.items.isEmpty) {
          return;
        }

        loadedFiles = _mergeFiles(loadedFiles, pageResult.items);
        totalCount ??= pageResult.total;

        final currentFiles = state.asData?.value ?? initialFiles;
        _replaceState(_mergeFiles(currentFiles, pageResult.items));

        if (!pageResult.isPaginated) {
          return;
        }
        if (totalCount != null && loadedFiles.length >= totalCount) {
          return;
        }

        page += 1;
      }
    } catch (error, stackTrace) {
      if (!_isCurrentLoad(loadGeneration)) {
        return;
      }
      DebugLogger.error(
        'files-page-load-failed',
        scope: 'files',
        error: error,
        stackTrace: stackTrace,
        data: {'generation': loadGeneration, 'page': page},
      );
    }
  }

  bool _isCurrentLoad(int loadGeneration) =>
      ref.mounted && _loadGeneration == loadGeneration;

  List<FileInfo> _mergeFiles(
    List<FileInfo> current,
    Iterable<FileInfo> incoming,
  ) {
    final merged = <String, FileInfo>{
      for (final file in current) file.id: file,
    };
    for (final file in incoming) {
      merged[file.id] = file;
    }
    return merged.values.toList(growable: false);
  }
}

@riverpod
Future<List<FileInfo>> searchUserFiles(Ref ref, String query) async {
  if (!ref.watch(isAuthenticatedProvider2)) {
    return const [];
  }

  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    return const [];
  }

  final trimmedQuery = query.trim();
  if (trimmedQuery.isEmpty) {
    return const [];
  }

  try {
    const pageSize = 100;
    final files = <FileInfo>[];
    var offset = 0;

    while (true) {
      final page = await api.searchFiles(
        query: trimmedQuery,
        limit: pageSize,
        offset: offset,
      );
      if (page.isEmpty) {
        break;
      }

      files.addAll(page);
      if (page.length < pageSize) {
        break;
      }

      offset += page.length;
    }

    final deduped = <String, FileInfo>{for (final file in files) file.id: file};
    final sorted = deduped.values.toList(growable: false)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List<FileInfo>.unmodifiable(sorted);
  } catch (error, stackTrace) {
    DebugLogger.error(
      'files-search-failed',
      scope: 'files/search',
      error: error,
      stackTrace: stackTrace,
      data: {'query': trimmedQuery},
    );
    rethrow;
  }
}

// File content provider
@riverpod
Future<String> fileContent(Ref ref, String fileId) async {
  // Protected: require authentication
  if (!ref.read(isAuthenticatedProvider2)) {
    DebugLogger.log('skip-unauthed', scope: 'files/content');
    throw Exception('Not authenticated');
  }
  final api = ref.watch(apiServiceProvider);
  if (api == null) throw Exception('No API service available');

  try {
    return await api.getFileContent(fileId);
  } catch (e) {
    DebugLogger.error(
      'file-content-failed',
      scope: 'files',
      error: e,
      data: {'fileId': fileId},
    );
    throw Exception('Failed to load file content: $e');
  }
}

// Knowledge Base providers
@Riverpod(keepAlive: true)
class KnowledgeBases extends _$KnowledgeBases {
  @override
  Future<List<KnowledgeBase>> build() async {
    if (!ref.watch(isAuthenticatedProvider2)) {
      DebugLogger.log('skip-unauthed', scope: 'knowledge');
      return const [];
    }
    final api = ref.watch(apiServiceProvider);
    if (api == null) return const [];
    return _load(api);
  }

  Future<void> refresh() async {
    if (!ref.read(isAuthenticatedProvider2)) {
      state = const AsyncData<List<KnowledgeBase>>([]);
      return;
    }
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      state = const AsyncData<List<KnowledgeBase>>([]);
      return;
    }
    final result = await AsyncValue.guard(() => _load(api));
    if (!ref.mounted) return;
    state = result;
  }

  void upsert(KnowledgeBase knowledgeBase) {
    final current = state.asData?.value ?? const <KnowledgeBase>[];
    final updated = _upsertItemById(
      current,
      knowledgeBase,
      idOf: (item) => item.id,
    );
    _replaceState(updated);
  }

  void remove(String id) {
    final current = state.asData?.value;
    if (current == null) return;
    final removal = _removeItemById(
      current,
      id,
      idOf: (knowledgeBase) => knowledgeBase.id,
    );
    _replaceState(removal.items);
  }

  Future<List<KnowledgeBase>> _load(ApiService api) async {
    try {
      final knowledgeBases = await api.getKnowledgeBases();
      return _sort(knowledgeBases);
    } catch (e, stackTrace) {
      DebugLogger.error(
        'knowledge-bases-failed',
        scope: 'knowledge',
        error: e,
        stackTrace: stackTrace,
      );
      return const [];
    }
  }

  List<KnowledgeBase> _sort(List<KnowledgeBase> input) {
    final sorted = [...input];
    sorted.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List<KnowledgeBase>.unmodifiable(sorted);
  }

  void _replaceState(List<KnowledgeBase> knowledgeBases) {
    state = AsyncData<List<KnowledgeBase>>(_sort(knowledgeBases));
  }
}

@riverpod
Future<List<KnowledgeBaseItem>> knowledgeBaseItems(Ref ref, String kbId) async {
  // Protected: require authentication
  if (!ref.read(isAuthenticatedProvider2)) {
    DebugLogger.log('skip-unauthed', scope: 'knowledge/items');
    return [];
  }
  final api = ref.watch(apiServiceProvider);
  if (api == null) return [];

  try {
    return await api.getKnowledgeBaseItems(kbId);
  } catch (e) {
    DebugLogger.error('knowledge-items-failed', scope: 'knowledge', error: e);
    return [];
  }
}

// Audio providers
@Riverpod(keepAlive: true)
Future<List<String>> availableVoices(Ref ref) async {
  // Protected: require authentication
  if (!ref.read(isAuthenticatedProvider2)) {
    DebugLogger.log('skip-unauthed', scope: 'voices');
    return [];
  }
  final config = await ref.watch(backendConfigProvider.future);
  if (config == null) return [];

  return config.ttsVoices
      .map((voice) => voice.name.isNotEmpty ? voice.name : voice.id)
      .where((name) => name.isNotEmpty)
      .toList(growable: false);
}

// Image Generation providers
@Riverpod(keepAlive: true)
Future<List<Map<String, dynamic>>> imageModels(Ref ref) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) return [];

  try {
    return await api.getImageModels();
  } catch (e) {
    DebugLogger.error('image-models-failed', scope: 'image-models', error: e);
    return [];
  }
}

/// Helper function to select cached model based on settings and available models.
/// Used by both chat page and defaultModel provider to ensure consistent behavior.
/// Returns a cached model if available, otherwise returns null.
Future<Model?> selectCachedModel(
  OptimizedStorageService storage,
  String? desiredModelId,
) async {
  try {
    final cachedModels = sanitizeRemoteHermesModels(
      sanitizeRemoteDirectModels(await storage.getLocalModels()),
    ).where((model) => !model.isHidden).toList();
    if (cachedModels.isEmpty) return null;

    Model? match;
    if (desiredModelId != null && desiredModelId.isNotEmpty) {
      try {
        match = cachedModels.firstWhere(
          (model) =>
              model.id == desiredModelId ||
              model.name.trim() == desiredModelId.trim(),
        );
      } catch (_) {
        match = null;
      }
    }

    return match ?? cachedModels.first;
  } catch (error, stackTrace) {
    DebugLogger.error(
      'cache-select-failed',
      scope: 'models/cache',
      error: error,
      stackTrace: stackTrace,
    );
    return null;
  }
}

// ---------------------------------------------------------------------------
// Active chats tracking (mirrors OpenWebUI Sidebar.svelte activeChatIds)
// ---------------------------------------------------------------------------

/// Tracks the set of chat IDs that have an active background task running.
///
/// Updated via `chat:active` socket events emitted by the backend when a
/// chat processing task starts (`active: true`) or completes (`active: false`).
@Riverpod(keepAlive: true)
class ActiveChatIds extends _$ActiveChatIds {
  @override
  Set<String> build() => const <String>{};

  // Monotonic activation tokens so a delayed, conditional clear can detect that
  // a chat was (re)activated after the clear was scheduled and skip itself.
  int _seq = 0;
  final Map<String, int> _activationToken = {};

  /// Mark a chat as active (background task running).
  void setActive(String chatId) {
    _activationToken[chatId] = ++_seq;
    if (state.contains(chatId)) return;
    state = {...state, chatId};
  }

  /// Mark a chat as inactive (background task completed).
  void setInactive(String chatId) {
    _activationToken.remove(chatId);
    if (!state.contains(chatId)) return;
    state = {...state}..remove(chatId);
  }

  /// The current activation token for [chatId], or null if not active. Capture
  /// this before an async task-registry check, then pass it to
  /// [setInactiveIfUnchanged] so a racing [setActive] cannot be clobbered.
  int? activationToken(String chatId) => _activationToken[chatId];

  /// Clear [chatId] only if it has not been (re)activated since [token] was
  /// captured — guards an async optimistic clear against a racing setActive
  /// (e.g. a new stream starting for the same chat before the lookup resolves).
  void setInactiveIfUnchanged(String chatId, int? token) {
    if (_activationToken[chatId] != token) return;
    setInactive(chatId);
  }

  /// Bulk-initialize from a server response.
  void setAll(Set<String> chatIds) {
    _seq++;
    _activationToken
      ..clear()
      ..addEntries([for (final id in chatIds) MapEntry(id, _seq)]);
    state = chatIds;
  }
}

/// Keeps [activeChatIdsProvider] correct beyond the locally-streaming chat.
///
/// OpenWebUI's sidebar both bulk-fetches active chats on load and listens for
/// `chat:active` events for any chat. This provider mirrors that: it
/// bulk-fetches on cold open + socket reconnect (`setAll`) and registers a
/// GLOBAL `chat:active` handler so generations started by other sessions/
/// devices also light up the sidebar spinner.
@Riverpod(keepAlive: true)
class ActiveChatsSync extends _$ActiveChatsSync {
  SocketEventSubscription? _globalActiveSub;
  StreamSubscription<void>? _reconnectSub;
  SocketService? _boundSocket;
  ApiService? _boundApi;
  Object? _boundAuthSessionEpoch;
  int _bindingGeneration = 0;
  bool _initialFetchDone = false;

  @override
  void build() {
    ref.onDispose(() {
      _bindingGeneration++;
      _globalActiveSub?.dispose();
      _globalActiveSub = null;
      _reconnectSub?.cancel();
      _reconnectSub = null;
    });

    _boundApi = ref.read(apiServiceProvider);
    _boundAuthSessionEpoch = ref.read(openWebUiAuthSessionEpochProvider);
    _bindSocket(ref.read(socketServiceProvider));
    ref.listen<SocketService?>(socketServiceProvider, (prev, next) {
      _bindSocket(next);
    });
    ref.listen<ApiService?>(apiServiceProvider, (prev, next) {
      if (identical(prev, next)) return;
      _boundApi = next;
      _bindSocket(ref.read(socketServiceProvider), force: true);
      ref.read(activeChatIdsProvider.notifier).setAll(const <String>{});
    });
    ref.listen<Object>(openWebUiAuthSessionEpochProvider, (prev, next) {
      if (identical(prev, next)) return;
      _boundAuthSessionEpoch = next;
      _boundApi = ref.read(apiServiceProvider);
      _bindSocket(ref.read(socketServiceProvider), force: true);
      ref.read(activeChatIdsProvider.notifier).setAll(const <String>{});
    });

    // Cold-open population: refresh once the conversation list first resolves.
    ref.listen<AsyncValue<List<Conversation>>>(conversationsProvider, (
      prev,
      next,
    ) {
      final convos = next.asData?.value;
      if (convos == null || convos.isEmpty || _initialFetchDone) {
        return;
      }
      _initialFetchDone = true;
      unawaited(_refresh(convos.map((c) => c.id).toList()));
    }, fireImmediately: true);
  }

  void _bindSocket(SocketService? socket, {bool force = false}) {
    final api = _boundApi;
    if (socket != null &&
        (api == null || socket.serverConfig.id != api.serverConfig.id)) {
      // During an async server switch socketServiceProvider intentionally
      // exposes the retiring service as a connectivity fallback. Never bind
      // that A socket to B's API/global active-chat state.
      socket = null;
    }
    if (!force && identical(socket, _boundSocket)) {
      return;
    }
    final generation = ++_bindingGeneration;
    final authSessionEpoch = _boundAuthSessionEpoch;
    _boundSocket = socket;
    _globalActiveSub?.dispose();
    _globalActiveSub = null;
    _reconnectSub?.cancel();
    _reconnectSub = null;
    if (socket == null) {
      // Logout / session teardown: the socket the spinners were derived from is
      // gone. Drop the whole set so a stale `generating` indicator cannot
      // survive into the next session (the new socket re-arms the cold-open
      // fetch below to repopulate authoritative state).
      ref.read(activeChatIdsProvider.notifier).setAll(const <String>{});
      _initialFetchDone = false;
      return;
    }

    // A new socket means a (re)connection or a fresh session (e.g. after
    // logout/login). Re-arm the one-shot cold-open fetch so the conversations
    // listener bulk-fetches active chats again for the new session instead of
    // skipping it because the flag stayed true from the previous one.
    _initialFetchDone = false;

    // All selectors null => `_shouldDeliver` treats this as a wildcard handler.
    // requireFocus:false so background generations on other chats still update
    // the badge.
    _globalActiveSub = socket.addChatEventHandler(
      requireFocus: false,
      handler: (map, _) {
        if (generation != _bindingGeneration ||
            !identical(socket, _boundSocket) ||
            !identical(socket, ref.read(socketServiceProvider)) ||
            !identical(_boundApi, ref.read(apiServiceProvider)) ||
            !identical(
              authSessionEpoch,
              ref.read(openWebUiAuthSessionEpochProvider),
            )) {
          return;
        }
        _handleChatActiveEvent(map);
      },
    );

    // Redis task state may have changed while disconnected: refresh on connect.
    _reconnectSub = socket.onReconnect.listen((_) {
      if (generation != _bindingGeneration ||
          !identical(socket, _boundSocket) ||
          !identical(socket, ref.read(socketServiceProvider)) ||
          !identical(_boundApi, ref.read(apiServiceProvider)) ||
          !identical(
            authSessionEpoch,
            ref.read(openWebUiAuthSessionEpochProvider),
          )) {
        return;
      }
      final convos = ref.read(conversationsProvider).asData?.value;
      if (convos == null || convos.isEmpty) {
        return;
      }
      unawaited(_refresh(convos.map((c) => c.id).toList()));
    });
  }

  void _handleChatActiveEvent(Map<String, dynamic> map) {
    final data = map['data'];
    if (data is! Map || data['type'] != 'chat:active') {
      return;
    }
    final payload = data['data'];
    final active = payload is Map ? payload['active'] : null;
    if (active is! bool) {
      return;
    }
    final chatId = _extractActiveChatId(map);
    if (chatId == null || chatId.isEmpty) {
      return;
    }
    final notifier = ref.read(activeChatIdsProvider.notifier);
    if (active) {
      notifier.setActive(chatId);
    } else {
      notifier.setInactive(chatId);
    }
  }

  String? _extractActiveChatId(Map<String, dynamic> map) {
    final direct = map['chat_id'] ?? map['chatId'];
    if (direct != null) {
      return direct.toString();
    }
    final data = map['data'];
    if (data is Map) {
      final outer = data['chat_id'] ?? data['chatId'];
      if (outer != null) {
        return outer.toString();
      }
      final inner = data['data'];
      if (inner is Map) {
        final nested = inner['chat_id'] ?? inner['chatId'];
        if (nested != null) {
          return nested.toString();
        }
      }
    }
    return null;
  }

  Future<void> _refresh(List<String> chatIds) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      return;
    }
    final ids = chatIds
        .where((id) => id.isNotEmpty && !isTemporaryChat(id))
        .toList();
    if (ids.isEmpty) {
      return;
    }
    final socket = _boundSocket;
    final generation = _bindingGeneration;
    final authSessionEpoch = _boundAuthSessionEpoch;
    try {
      final active = await api.checkActiveChats(ids);
      if (generation != _bindingGeneration ||
          !identical(api, ref.read(apiServiceProvider)) ||
          !identical(socket, _boundSocket) ||
          !identical(socket, ref.read(socketServiceProvider)) ||
          !identical(
            authSessionEpoch,
            ref.read(openWebUiAuthSessionEpochProvider),
          )) {
        return;
      }
      ref.read(activeChatIdsProvider.notifier).setAll(active);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'active-chats refresh failed',
        scope: 'chat/active-sync',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

/// Resolves socket transport availability from backend configuration.
///
/// Used by both the sync [socketTransportOptionsProvider] and the
/// [BackendConfigNotifier] to ensure consistent resolution logic.
SocketTransportAvailability _resolveTransportAvailability(
  BackendConfig config,
) {
  if (config.websocketOnly) {
    return const SocketTransportAvailability(
      allowPolling: false,
      allowWebsocketOnly: true,
    );
  }

  if (config.pollingOnly) {
    return const SocketTransportAvailability(
      allowPolling: true,
      allowWebsocketOnly: false,
    );
  }

  return const SocketTransportAvailability(
    allowPolling: true,
    allowWebsocketOnly: true,
  );
}
