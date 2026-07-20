import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';
import 'package:synchronized/synchronized.dart';

import '../models/backend_config.dart';
import '../models/model.dart';
import '../models/server_config.dart';
import '../models/user.dart';
import '../models/tool.dart';
import '../models/socket_transport_availability.dart';
import '../database/app_database.dart';
import '../persistence/hive_boxes.dart';
import '../persistence/persistence_keys.dart';
import '../persistence/preferences_store.dart';
import '../utils/debug_logger.dart';
import '../utils/json_normalization.dart';
import 'cache_manager.dart';
import 'secure_credential_storage.dart';
import 'worker_manager.dart';

typedef OptimizedStorageDatabaseResolver =
    FutureOr<OptimizedStorageDatabaseHandle?> Function();

typedef ServerConfigCandidateSnapshot = ({
  List<ServerConfig> configs,
  String? activeServerId,
  int transactionId,
});

/// Opaque pre-network ownership claim for an already-saved server.
///
/// The storage revision detects even A→B→A changes that leave equal values by
/// commit time. [requireActive] distinguishes foreground authentication (the
/// validated API client must remain the selected server) from a saved-login
/// flow that intentionally activates its credential owner at commit time.
typedef ServerSessionOwnershipSnapshot = ({
  int revision,
  ServerConfig serverConfig,
  bool requireActive,
});

typedef _StagedServerConfigCandidate = ({
  int transactionId,
  ServerConfig candidate,
  List<ServerConfig> baselineConfigs,
  String? baselineActiveServerId,
});

final class _StagedAuthAttemptSuperseded implements Exception {
  const _StagedAuthAttemptSuperseded();
}

/// Signals that a staged session could not be returned to a known durable
/// server/token pair after its forward commit had started.
///
/// Callers must treat durable ownership as indeterminate and clear in-memory
/// credentials rather than republishing either the previous or candidate
/// token. The underlying errors are retained for diagnostics but deliberately
/// omitted from [toString] so platform storage details are not exposed to UI.
final class ServerConfigSessionRollbackException implements Exception {
  const ServerConfigSessionRollbackException({
    required this.commitError,
    required this.rollbackError,
  });

  final Object commitError;
  final Object rollbackError;

  @override
  String toString() => 'Server config session rollback did not complete';
}

/// One operation-scoped database reference for structured cache access.
///
/// Production supplies a manager lifetime lease so a server switch cannot
/// close the executor between resolution and the asynchronous Drift query.
/// Tests and unmanaged callers may continue to use the legacy `database`
/// constructor argument, which creates a handle without a release callback.
final class OptimizedStorageDatabaseHandle {
  OptimizedStorageDatabaseHandle({required this.database, this.onRelease});

  final AppDatabase database;
  final Future<void> Function()? onRelease;
  bool _released = false;

  Future<void> release() {
    if (_released) return Future<void>.value();
    _released = true;
    return onRelease?.call() ?? Future<void>.value();
  }
}

/// Optimized storage service backed by Hive for non-sensitive data and
/// FlutterSecureStorage for credentials.
class OptimizedStorageService {
  OptimizedStorageService({
    required FlutterSecureStorage secureStorage,
    required HiveBoxes boxes,
    required WorkerManager workerManager,
    AppDatabase? Function()? database,
    OptimizedStorageDatabaseResolver? databaseAccess,
    CacheManager? cacheManager,
    Duration authTokenCacheTtl = const Duration(hours: 12),
    Duration serverIdCacheTtl = const Duration(days: 7),
    Duration serverConfigsCacheTtl = const Duration(days: 7),
    Duration credentialsFlagCacheTtl = const Duration(hours: 12),
  }) : _cachesBox = boxes.caches,
       _attachmentQueueBox = boxes.attachmentQueue,
       _metadataBox = boxes.metadata,
       assert(database == null || databaseAccess == null),
       _databaseAccess =
           databaseAccess ??
           (database == null
               ? null
               : () {
                   final resolved = database();
                   return resolved == null
                       ? null
                       : OptimizedStorageDatabaseHandle(database: resolved);
                 }),
       _secureCredentialStorage = SecureCredentialStorage(
         instance: secureStorage,
       ),
       _cacheManager = cacheManager ?? CacheManager(maxEntries: 64),
       _authTokenTtl = authTokenCacheTtl,
       _serverIdTtl = serverIdCacheTtl,
       _serverConfigsTtl = serverConfigsCacheTtl,
       _credentialsFlagTtl = credentialsFlagCacheTtl,
       _workerManager = workerManager;

  /// Resolves the active server's Drift database (PR-2: structured caches live
  /// in the per-server DB, not the Hive caches box). Null in reviewer mode / no
  /// active server / tests without a DB — callers fall back to defaults.
  final OptimizedStorageDatabaseResolver? _databaseAccess;

  Future<T?> _withDatabase<T>(
    Future<T> Function(AppDatabase database) operation, {
    String? expectedServerId,
  }) async {
    if (expectedServerId != null &&
        _rawStoredActiveServerId(bypassReadSuppression: true) !=
            expectedServerId) {
      return null;
    }
    final handle = await _databaseAccess?.call();
    if (handle == null) return null;
    try {
      return await operation(handle.database);
    } finally {
      await handle.release();
    }
  }

  Future<String?> _readCacheValue(String key) =>
      _withDatabase<String?>((database) => database.appCacheDao.getValue(key));

  Future<void> _writeCacheValue(String key, String value) async {
    await _withDatabase<void>(
      (database) => database.appCacheDao.setValue(
        key,
        value,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> _deleteCacheValue(String key) async {
    await _withDatabase<void>(
      (database) => database.appCacheDao.deleteKey(key),
    );
  }

  final Box<dynamic> _cachesBox;
  final Box<dynamic> _attachmentQueueBox;
  final Box<dynamic> _metadataBox;
  final SecureCredentialStorage _secureCredentialStorage;
  final WorkerManager _workerManager;
  final CacheManager _cacheManager;

  /// Serializes read-modify-write sequences over the auth token, saved
  /// credentials, and active server id so a stale background task's
  /// compare-and-write can't interleave with (and clobber) a newer login /
  /// server selection. All WRITES to those three keys take this lock; the
  /// compound `*IfMatches` / `restore*` helpers do their read AND write under a
  /// single hold via the private `_*Unlocked` bodies (the lock is NOT
  /// reentrant, so locked methods must call the unlocked bodies internally).
  final Lock _authStateLock = Lock();
  final Lock _serverConfigsLock = Lock();
  int _serverOwnershipRevision = 0;
  int _nextServerConfigCandidateTransactionId = 0;
  _StagedServerConfigCandidate? _stagedServerConfigCandidate;

  // These fail-closed read fences are intentionally independent of
  // [CacheManager]. A failed Keychain/preferences delete must not become
  // readable again because a cache entry expired, was evicted, or a caller
  // invoked [clearCache]. Each fence is lifted only after a checked write of
  // the corresponding category succeeds.
  bool _authTokenReadSuppressed = false;
  bool _savedCredentialsReadSuppressed = false;
  bool _serverConfigsReadSuppressed = false;
  bool _activeServerIdReadSuppressed = false;

  static const String _authTokenKey = 'auth_token_v3';
  static const String _activeServerIdKey = PreferenceKeys.activeServerId;
  static const String _serverConfigsCacheKey = 'server_configs_v1';
  static const String _themeModeKey = PreferenceKeys.themeMode;
  static const String _themePaletteKey = PreferenceKeys.themePalette;
  static const String _localeCodeKey = PreferenceKeys.localeCode;
  static const String _localConversationsKey = HiveStoreKeys.localConversations;
  static const String _localUserKey = HiveStoreKeys.localUser;
  static const String _localUserAvatarKey = HiveStoreKeys.localUserAvatar;
  static const String _localBackendConfigKey = HiveStoreKeys.localBackendConfig;
  static const String _localTransportOptionsKey =
      HiveStoreKeys.localTransportOptions;
  static const String _localToolsKey = HiveStoreKeys.localTools;
  static const String _localDefaultModelKey = HiveStoreKeys.localDefaultModel;
  static const String _localModelsKey = HiveStoreKeys.localModels;
  static const String _localFoldersKey = HiveStoreKeys.localFolders;
  static const String _reviewerModeKey = PreferenceKeys.reviewerMode;

  /// The Drift app-cache keys (everything moved off the Hive `caches` box in
  /// PR-2 except transport options, which live in shared_preferences).
  static const List<String> _allCacheKeys = [
    _localUserKey,
    _localUserAvatarKey,
    _localBackendConfigKey,
    _localToolsKey,
    _localDefaultModelKey,
    _localModelsKey,
  ];
  // Longer TTLs to reduce secure storage churn for OpenWebUI sessions.
  final Duration _authTokenTtl;
  final Duration _serverIdTtl;
  final Duration _serverConfigsTtl;
  final Duration _credentialsFlagTtl;

  Future<T> _retrySecureStorageRead<T>(
    Future<T> Function() read, {
    required String scope,
  }) async {
    try {
      return await read();
    } catch (error) {
      // iOS Keychain access can fail briefly while protected data is becoming
      // available. Retry once, but never turn either failure into a cacheable
      // "missing" value.
      DebugLogger.warning(
        'secure-read-retrying',
        scope: scope,
        data: {'errorType': error.runtimeType.toString()},
      );
    }
    return read();
  }

  // ---------------------------------------------------------------------------
  // Auth token APIs (secure storage + in-memory cache)
  // ---------------------------------------------------------------------------
  Future<void> saveAuthToken(String token) =>
      _authStateLock.synchronized(() => _saveAuthTokenUnlocked(token));

  /// Saves [token] only while its caller still owns the auth/session fence.
  ///
  /// The predicate is checked after acquiring [_authStateLock], which is also
  /// held by proxy session commit/rollback. A rollback-uncertainty callback can
  /// therefore poison the fence before a waiting normal login writes an
  /// old-origin token. A fence change during the platform write removes this
  /// operation's token before releasing the lock.
  Future<bool> saveAuthTokenIfCurrent(
    String token, {
    required bool Function() canCommit,
  }) {
    return _authStateLock.synchronized(() async {
      if (!canCommit()) return false;
      await _saveAuthTokenUnlocked(token);
      if (canCommit()) return true;
      await _deleteAuthTokenUnlocked();
      return false;
    });
  }

  Future<void> _saveAuthTokenUnlocked(String token) async {
    try {
      await _secureCredentialStorage.saveAuthToken(token);
      _authTokenReadSuppressed = false;
      _cacheManager.write(_authTokenKey, token, ttl: _authTokenTtl);
      DebugLogger.log(
        'Auth token saved and cached',
        scope: 'storage/optimized',
      );
    } catch (error) {
      DebugLogger.log(
        'Failed to save auth token: $error',
        scope: 'storage/optimized',
      );
      rethrow;
    }
  }

  Future<String?> getAuthToken() =>
      _authStateLock.synchronized(_getAuthTokenUnlocked);

  /// Reads the token without converting a Keychain failure into token absence.
  ///
  /// A confirmed missing token is cached immediately and does not trigger a
  /// retry. Transient platform failures are retried once, then propagated so
  /// bootstrap cannot publish a false signed-out state.
  Future<String?> getAuthTokenStrict() {
    return _authStateLock.synchronized(
      () => _retrySecureStorageRead(
        _getAuthTokenStrictUnlocked,
        scope: 'storage/optimized/auth-token',
      ),
    );
  }

  Future<String?> _getAuthTokenUnlocked() async {
    if (_authTokenReadSuppressed) return null;
    final (hit: hasCachedToken, value: cachedToken) = _cacheManager
        .lookup<String>(_authTokenKey);
    if (hasCachedToken) {
      DebugLogger.log('Using cached auth token', scope: 'storage/optimized');
      return cachedToken;
    }

    try {
      final token = await _retrySecureStorageRead(
        _secureCredentialStorage.getAuthTokenStrict,
        scope: 'storage/optimized/auth-token',
      );
      // A successful null read is authoritative and worth negative-caching on
      // the iOS hot path. Exceptions never reach this write.
      _cacheManager.write(_authTokenKey, token, ttl: _authTokenTtl);
      return token;
    } catch (error) {
      DebugLogger.log(
        'Failed to retrieve auth token: $error',
        scope: 'storage/optimized',
      );
      return null;
    }
  }

  Future<String?> _getAuthTokenStrictUnlocked({
    bool bypassReadSuppression = false,
  }) async {
    if (_authTokenReadSuppressed && !bypassReadSuppression) return null;
    if (!bypassReadSuppression) {
      final (hit: hasCachedToken, value: cachedToken) = _cacheManager
          .lookup<String>(_authTokenKey);
      if (hasCachedToken) return cachedToken;
    }

    final token = await _secureCredentialStorage.getAuthTokenStrict();
    if (!bypassReadSuppression) {
      _cacheManager.write(_authTokenKey, token, ttl: _authTokenTtl);
    }
    return token;
  }

  Future<void> deleteAuthToken() =>
      _authStateLock.synchronized(_deleteAuthTokenUnlocked);

  /// Compare-and-delete: deletes the stored auth token ONLY if it still equals
  /// [expected]. Read + conditional delete run under [_authStateLock], so a
  /// superseded login can roll back its own token write without clobbering a
  /// newer login's token. Returns true if it deleted.
  Future<bool> deleteAuthTokenIfMatches(String expected) {
    return _authStateLock.synchronized(() async {
      final current = await _retrySecureStorageRead(
        () => _getAuthTokenStrictUnlocked(bypassReadSuppression: true),
        scope: 'storage/optimized/token-compare-delete',
      );
      if (current != expected) return false;
      await _deleteAuthTokenUnlocked();
      return true;
    });
  }

  Future<void> _deleteAuthTokenUnlocked() async {
    // Fail closed in this process before crossing the platform boundary. A
    // Keychain delete error is still propagated, but no later notifier rebuild
    // may re-read and republish the retained bearer during recovery.
    _authTokenReadSuppressed = true;
    _cacheManager.write<String>(_authTokenKey, null, ttl: _authTokenTtl);
    try {
      await _secureCredentialStorage.deleteAuthToken();
      DebugLogger.log(
        'Auth token deleted and cache cleared',
        scope: 'storage/optimized',
      );
    } catch (error) {
      DebugLogger.error(
        'Failed to delete auth token',
        scope: 'storage/optimized',
        error: error,
      );
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Credential APIs (secure storage only)
  // ---------------------------------------------------------------------------
  Future<void> saveCredentials({
    required String serverId,
    required String username,
    required String password,
    String authType = 'credentials',
  }) {
    return _authStateLock.synchronized(
      () => _saveCredentialsUnlocked(
        serverId: serverId,
        username: username,
        password: password,
        authType: authType,
      ),
    );
  }

  Future<void> _saveCredentialsUnlocked({
    required String serverId,
    required String username,
    required String password,
    String authType = 'credentials',
  }) async {
    try {
      await _secureCredentialStorage.saveCredentials(
        serverId: serverId,
        username: username,
        password: password,
        authType: authType,
      );

      _savedCredentialsReadSuppressed = false;
      _cacheManager.write('has_credentials', true, ttl: _credentialsFlagTtl);

      DebugLogger.log(
        'Credentials saved via optimized storage',
        scope: 'storage/optimized',
      );
    } catch (error) {
      DebugLogger.log(
        'Failed to save credentials: $error',
        scope: 'storage/optimized',
      );
      rethrow;
    }
  }

  Future<Map<String, String>?> getSavedCredentials() =>
      _authStateLock.synchronized(_getSavedCredentialsUnlocked);

  /// Reads the credential snapshot without converting an exhausted secure
  /// storage failure into absence. A confirmed null is cached; failures retry
  /// once and then propagate so bootstrap cannot silently disable auto-login.
  Future<Map<String, String>?> getSavedCredentialsStrict() {
    return _authStateLock.synchronized(
      () => _retrySecureStorageRead(
        _getSavedCredentialsStrictUnlocked,
        scope: 'storage/optimized/credentials',
      ),
    );
  }

  Future<Map<String, String>?> _getSavedCredentialsUnlocked() async {
    if (_savedCredentialsReadSuppressed) return null;
    try {
      final credentials = await _retrySecureStorageRead(
        _getSavedCredentialsStrictUnlocked,
        scope: 'storage/optimized/credentials',
      );
      return credentials;
    } catch (error) {
      DebugLogger.log(
        'Failed to retrieve credentials: $error',
        scope: 'storage/optimized',
      );
      return null;
    }
  }

  Future<Map<String, String>?> _getSavedCredentialsStrictUnlocked({
    bool bypassReadSuppression = false,
  }) async {
    if (_savedCredentialsReadSuppressed && !bypassReadSuppression) return null;
    if (!bypassReadSuppression) {
      final (hit: hasCachedPresence, value: cachedPresence) = _cacheManager
          .lookup<bool>('has_credentials');
      if (hasCachedPresence && cachedPresence == false) return null;
    }
    final credentials = await _secureCredentialStorage.getSavedCredentials();
    if (!bypassReadSuppression) {
      _cacheManager.write(
        'has_credentials',
        credentials != null,
        ttl: _credentialsFlagTtl,
      );
    }
    return credentials;
  }

  Future<void> deleteSavedCredentials() =>
      _authStateLock.synchronized(_deleteSavedCredentialsUnlocked);

  Future<void> _deleteSavedCredentialsUnlocked() async {
    // Mirror token deletion's same-process fail-closed fence. The durable
    // caller-level suppression marker handles restart recovery if this write
    // cannot be removed from Keychain.
    _savedCredentialsReadSuppressed = true;
    _cacheManager.write('has_credentials', false, ttl: _credentialsFlagTtl);
    try {
      await _secureCredentialStorage.deleteSavedCredentials();
      DebugLogger.log(
        'Credentials deleted via optimized storage',
        scope: 'storage/optimized',
      );
    } catch (error) {
      DebugLogger.error(
        'Failed to delete credentials',
        scope: 'storage/optimized',
        error: error,
      );
      rethrow;
    }
  }

  /// Compare-and-delete: deletes the saved credentials ONLY if they still match
  /// [expected] (serverId/username/password). Read + conditional delete run
  /// under [_authStateLock], so a newer login that saved different credentials
  /// isn't clobbered. Returns true if it deleted.
  Future<bool> deleteSavedCredentialsIfMatches(Map<String, String> expected) {
    return _authStateLock.synchronized(() async {
      final current = await _retrySecureStorageRead(
        () => _getSavedCredentialsStrictUnlocked(bypassReadSuppression: true),
        scope: 'storage/optimized/credentials-compare-delete',
      );
      final matches =
          current != null &&
          current['serverId'] == expected['serverId'] &&
          current['username'] == expected['username'] &&
          current['password'] == expected['password'];
      if (!matches) return false;
      await _deleteSavedCredentialsUnlocked();
      return true;
    });
  }

  /// Clears an exact saved credential only while its server id is still absent.
  ///
  /// The missing-server check, credential comparison/delete, and dangling
  /// active-id cleanup share auth→config locks, so a concurrent config add
  /// cannot turn a stale provider observation into deletion of valid data.
  Future<bool> deleteSavedCredentialsIfMatchesAndServerMissing(
    Map<String, String> expected,
  ) {
    return _authStateLock.synchronized(
      () => _serverConfigsLock.synchronized(() async {
        final serverId = expected['serverId'];
        if (serverId == null) return false;
        final configs = await _getServerConfigsStrictUnlocked();
        if (configs.any((config) => config.id == serverId)) return false;

        final payload = await _secureCredentialStorage
            .getSavedCredentialsPayloadStrict();
        if (!_savedCredentialsPayloadMatches(payload, expected)) return false;

        await _deleteSavedCredentialsUnlocked();
        if (_rawStoredActiveServerId(bypassReadSuppression: true) == serverId) {
          await _writeActiveServerIdWithoutConfigSync(null);
        }
        return true;
      }),
    );
  }

  Future<bool> hasCredentials() async {
    if (_savedCredentialsReadSuppressed) return false;
    final (hit: hasCachedValue, value: hasCredentials) = _cacheManager
        .lookup<bool>('has_credentials');
    if (hasCachedValue) {
      return hasCredentials == true;
    }
    final credentials = await getSavedCredentials();
    return credentials != null;
  }

  // ---------------------------------------------------------------------------
  // Preference helpers (Hive-backed)
  // ---------------------------------------------------------------------------
  Future<void> saveServerConfigs(List<ServerConfig> configs) {
    return _authStateLock.synchronized(
      () => _serverConfigsLock.synchronized(() async {
        final currentConfigs = await _getServerConfigsStrictUnlocked();
        final sanitizedConfigs = configs
            .map(
              (config) => config.apiKey == null
                  ? config
                  : config.copyWith(apiKey: null),
            )
            .toList(growable: false);
        final rawActiveServerId = _rawStoredActiveServerId();
        final currentActiveId = _effectiveActiveServerId(
          configs: currentConfigs,
          rawActiveServerId: rawActiveServerId,
        );
        final nextActiveId = _effectiveActiveServerId(
          configs: sanitizedConfigs,
          rawActiveServerId: rawActiveServerId,
        );
        final currentActive = currentConfigs
            .where((config) => config.id == currentActiveId)
            .firstOrNull;
        final nextActive = sanitizedConfigs
            .where((config) => config.id == nextActiveId)
            .firstOrNull;
        // Session ownership follows the server identity (id, origin URL, mTLS
        // client identity), not per-request metadata. Editing custom headers
        // or the self-signed policy of the same server keeps the same account
        // session, and stripping a legacy persisted apiKey is a one-time
        // migration rather than an ownership change.
        final activeOwnershipChanged =
            currentActiveId != nextActiveId ||
            (currentActive != null &&
                nextActive != null &&
                !_hasSameServerSessionOwnershipIdentity(
                  currentActive,
                  nextActive,
                ));

        final credentialsPayload = await _secureCredentialStorage
            .getSavedCredentialsPayloadStrict();
        final credentialServerId = _savedCredentialsServerId(
          credentialsPayload,
        );
        var credentialOwnershipChanged = false;
        if (credentialsPayload != null) {
          final currentCredentialConfig = currentConfigs
              .where((config) => config.id == credentialServerId)
              .firstOrNull;
          final nextCredentialConfig = sanitizedConfigs
              .where((config) => config.id == credentialServerId)
              .firstOrNull;
          credentialOwnershipChanged =
              credentialServerId == null ||
              currentCredentialConfig == null ||
              nextCredentialConfig == null ||
              !_hasSameServerSessionOwnershipIdentity(
                currentCredentialConfig,
                nextCredentialConfig,
              );
        }

        // Security-owner changes are tokenless before the config payload can
        // point at the new origin. Metadata-only edits retain the session.
        if (activeOwnershipChanged) await _deleteAuthTokenUnlocked();
        if (credentialOwnershipChanged) {
          await _deleteSavedCredentialsUnlocked();
        }
        await _saveServerConfigsUnlocked(sanitizedConfigs);
        if (rawActiveServerId != nextActiveId) {
          await _writeActiveServerIdWithoutConfigSync(nextActiveId);
        }
        // A normal config edit supersedes any uncommitted auth candidate. The
        // candidate itself is only in memory, so there is nothing durable to
        // roll back and its later transaction-id claim must fail.
        _stagedServerConfigCandidate = null;
      }),
    );
  }

  String? _savedCredentialsServerId(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        final value = decoded['serverId']?.toString();
        return value == null || value.isEmpty ? null : value;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  ServerConfig _revokeServerConfigAuthArtifacts(ServerConfig config) {
    // Only Open WebUI *session* credentials are revoked here. The legacy
    // apiKey bearer and app-captured proxy session cookies (merged into a
    // Cookie custom header by the reverse-proxy flow) authenticate a signed-in
    // session and must not survive logout. Everything else on the config is a
    // connection prerequisite, not a session credential: user-configured
    // custom headers (Cloudflare Access service tokens, Authelia header
    // gates) and the mTLS client identity are required just to reach the
    // sign-in page, so scrubbing them would strand the user before re-login.
    // They are preserved exactly like the server URL.
    final hasCookieHeader = config.customHeaders.keys.any(
      (key) => key.toLowerCase() == 'cookie',
    );
    if (config.apiKey == null && !hasCookieHeader) return config;
    final sanitizedHeaders = hasCookieHeader
        ? Map<String, String>.fromEntries(
            config.customHeaders.entries.where(
              (entry) => entry.key.toLowerCase() != 'cookie',
            ),
          )
        : config.customHeaders;
    return config.copyWith(apiKey: null, customHeaders: sanitizedHeaders);
  }

  void _notifyRollbackUncertainSafely(void Function()? callback) {
    if (callback == null) return;
    try {
      callback();
    } catch (error) {
      // The transaction/rollback exception is authoritative. A UI poison
      // callback is advisory and must never replace that diagnostic.
      DebugLogger.warning(
        'rollback-uncertainty-callback-failed',
        scope: 'storage/optimized',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
  }

  /// Replaces the configured server for a fresh sign-in without ever pairing
  /// the prior server's bearer token with the new origin.
  ///
  /// Token deletion is the first durable write. Any crash or later storage
  /// failure therefore leaves either the old ownership or the new ownership
  /// without a Conduit bearer token. Explicit candidate custom headers remain
  /// available for this sign-in attempt; logout later revokes captured proxy
  /// Cookie headers while preserving user-configured connection headers.
  Future<bool> selectUnauthenticatedServerConfig(
    ServerConfig config, {
    required FutureOr<void> Function() publish,
    bool Function()? canCommit,
    void Function()? onRollbackUncertain,
  }) {
    return _authStateLock.synchronized(
      () => _serverConfigsLock.synchronized(() async {
        bool ownsAttempt() => canCommit?.call() ?? true;
        if (!ownsAttempt()) return false;

        final previousConfigs = List<ServerConfig>.unmodifiable(
          await _getServerConfigsStrictUnlocked(),
        );
        if (!ownsAttempt()) return false;
        final previousActiveServerId = _rawStoredActiveServerId();
        final previousToken = await _getAuthTokenStrictUnlocked();
        if (!ownsAttempt()) return false;
        final previousCredentialsReadSuppressed =
            _savedCredentialsReadSuppressed;
        final previousCredentialsPayload = previousCredentialsReadSuppressed
            ? null
            : await _secureCredentialStorage.getSavedCredentialsPayloadStrict();
        if (!ownsAttempt()) return false;

        final selected = config.copyWith(apiKey: null, isActive: true);
        final previousStage = _stagedServerConfigCandidate;
        var persistenceStarted = false;
        try {
          persistenceStarted = true;
          await _deleteAuthTokenUnlocked();
          if (!ownsAttempt()) throw const _StagedAuthAttemptSuperseded();

          await _deleteSavedCredentialsUnlocked();
          if (!ownsAttempt()) throw const _StagedAuthAttemptSuperseded();

          // The candidate's headers were explicitly supplied and already used
          // to verify this connection. Keep that exact candidate material long
          // enough to complete sign-in, while never merging baseline headers.
          await _saveServerConfigsUnlocked([selected]);
          if (!ownsAttempt()) throw const _StagedAuthAttemptSuperseded();

          await _writeActiveServerIdWithoutConfigSync(selected.id);
          if (!ownsAttempt()) throw const _StagedAuthAttemptSuperseded();

          _stagedServerConfigCandidate = null;
          try {
            await publish();
            if (!ownsAttempt()) throw const _StagedAuthAttemptSuperseded();
          } catch (_) {
            _stagedServerConfigCandidate = previousStage;
            rethrow;
          }
          return true;
        } on _StagedAuthAttemptSuperseded catch (commitError) {
          if (persistenceStarted) {
            try {
              await _restoreServerSessionUnlocked(
                configs: previousConfigs,
                activeServerId: previousActiveServerId,
                token: previousToken,
                restoreCredentials: true,
                credentialsPayload: previousCredentialsPayload,
                credentialsReadSuppressed: previousCredentialsReadSuppressed,
              );
              _stagedServerConfigCandidate = previousStage;
            } catch (rollbackError, rollbackStackTrace) {
              await _bestEffortFailClosedServerSessionRestoreUnlocked(
                configs: previousConfigs,
                activeServerId: previousActiveServerId,
              );
              _notifyRollbackUncertainSafely(onRollbackUncertain);
              Error.throwWithStackTrace(
                ServerConfigSessionRollbackException(
                  commitError: commitError,
                  rollbackError: rollbackError,
                ),
                rollbackStackTrace,
              );
            }
          }
          return false;
        } catch (commitError, commitStackTrace) {
          if (persistenceStarted) {
            try {
              if (commitError is ServerConfigSessionRollbackException) {
                await _restoreTokenlessSanitizedServerSessionUnlocked(
                  configs: previousConfigs,
                  activeServerId: previousActiveServerId,
                );
                _notifyRollbackUncertainSafely(onRollbackUncertain);
              } else {
                await _restoreServerSessionUnlocked(
                  configs: previousConfigs,
                  activeServerId: previousActiveServerId,
                  token: previousToken,
                  restoreCredentials: true,
                  credentialsPayload: previousCredentialsPayload,
                  credentialsReadSuppressed: previousCredentialsReadSuppressed,
                );
                _stagedServerConfigCandidate = previousStage;
              }
            } catch (rollbackError, rollbackStackTrace) {
              await _bestEffortFailClosedServerSessionRestoreUnlocked(
                configs: previousConfigs,
                activeServerId: previousActiveServerId,
              );
              _notifyRollbackUncertainSafely(onRollbackUncertain);
              Error.throwWithStackTrace(
                ServerConfigSessionRollbackException(
                  commitError: commitError,
                  rollbackError: rollbackError,
                ),
                rollbackStackTrace,
              );
            }
          }
          Error.throwWithStackTrace(commitError, commitStackTrace);
        }
      }),
    );
  }

  Future<void> _saveServerConfigsUnlocked(
    List<ServerConfig> configs, {
    bool authorizeReads = true,
  }) async {
    try {
      final jsonString = jsonEncode(configs.map((c) => c.toJson()).toList());
      await _secureCredentialStorage.saveServerConfigs(jsonString);
      if (authorizeReads) _serverConfigsReadSuppressed = false;
      _serverOwnershipRevision++;
      _cacheManager.invalidate(_activeServerIdKey);
      _cacheServerConfigs(configs);
      DebugLogger.log(
        'Server configs saved (${configs.length} entries)',
        scope: 'storage/optimized',
      );
    } catch (error) {
      DebugLogger.log(
        'Failed to save server configs: $error',
        scope: 'storage/optimized',
      );
      rethrow;
    }
  }

  /// Captures the exact server ownership that an API client will validate.
  ///
  /// Call this immediately before the network authentication request and pass
  /// the returned opaque snapshot to [commitExistingServerSession]. A null
  /// result means the API client's config is already absent, has changed
  /// security/transport identity, or (for foreground login) is no longer the
  /// selected server.
  Future<ServerSessionOwnershipSnapshot?> captureServerSessionOwnership({
    required ServerConfig validatedConfig,
    required bool requireActive,
  }) {
    return _authStateLock.synchronized(
      () => _serverConfigsLock.synchronized(() async {
        final configs = await _getServerConfigsStrictUnlocked();
        final storedConfig = configs
            .where((config) => config.id == validatedConfig.id)
            .firstOrNull;
        if (storedConfig == null ||
            !_hasSameServerAuthTransportIdentity(
              storedConfig,
              validatedConfig,
            )) {
          return null;
        }

        if (requireActive &&
            _effectiveActiveServerId(
                  configs: configs,
                  rawActiveServerId: _rawStoredActiveServerId(),
                ) !=
                storedConfig.id) {
          return null;
        }

        return (
          revision: _serverOwnershipRevision,
          serverConfig: storedConfig,
          requireActive: requireActive,
        );
      }),
    );
  }

  /// Captures the current stored identity for a saved credential's server id.
  ///
  /// Unlike a Riverpod config-list lookup, this read is serialized with config
  /// writers. A null result therefore proves the id was absent at this storage
  /// revision and is safe to use for value-matched stale-credential cleanup.
  Future<ServerSessionOwnershipSnapshot?> captureSavedServerSessionOwnership(
    String serverId,
  ) {
    return _authStateLock.synchronized(
      () => _serverConfigsLock.synchronized(() async {
        final configs = await _getServerConfigsStrictUnlocked();
        final storedConfig = configs
            .where((config) => config.id == serverId)
            .firstOrNull;
        if (storedConfig == null) return null;
        return (
          revision: _serverOwnershipRevision,
          serverConfig: storedConfig,
          requireActive: false,
        );
      }),
    );
  }

  /// Atomically commits a token for an already-saved, pre-network ownership
  /// snapshot and publishes the authenticated state while both storage locks
  /// remain held.
  ///
  /// The previous token is removed before any owner write and the new token is
  /// saved last. A crash at any earlier prefix is therefore tokenless. On any
  /// failure after mutation starts, rollback deletes the candidate token,
  /// restores the exact raw active id/config list/remembered credentials, and
  /// restores the previous token only after every ownership write succeeds.
  Future<bool> commitExistingServerSession({
    required ServerSessionOwnershipSnapshot ownership,
    required String token,
    required bool Function() canCommit,
    required FutureOr<void> Function() publish,
    Map<String, String>? rememberedCredentials,
    Map<String, String>? expectedSavedCredentials,
    void Function()? onRollbackUncertain,
  }) {
    return _authStateLock.synchronized(
      () => _serverConfigsLock.synchronized(() async {
        if (!canCommit() || _serverOwnershipRevision != ownership.revision) {
          return false;
        }

        final previousConfigs = List<ServerConfig>.unmodifiable(
          await _getServerConfigsStrictUnlocked(),
        );
        if (!canCommit() || _serverOwnershipRevision != ownership.revision) {
          return false;
        }

        final targetConfig = previousConfigs
            .where(
              (config) =>
                  config.id == ownership.serverConfig.id &&
                  _hasSameServerAuthTransportIdentity(
                    config,
                    ownership.serverConfig,
                  ),
            )
            .firstOrNull;
        if (targetConfig == null) return false;

        final previousActiveServerId = _rawStoredActiveServerId();
        if (ownership.requireActive &&
            _effectiveActiveServerId(
                  configs: previousConfigs,
                  rawActiveServerId: previousActiveServerId,
                ) !=
                targetConfig.id) {
          return false;
        }

        final previousToken = await _getAuthTokenStrictUnlocked();
        if (!canCommit() || _serverOwnershipRevision != ownership.revision) {
          return false;
        }

        // Every foreground session replaces the global credential owner. A
        // non-remembered login must therefore delete an older account's saved
        // secret; silent login is the sole path that retains an exact expected
        // payload. Snapshot unconditionally so any later failure can restore
        // the complete prior transaction.
        final previousCredentialsReadSuppressed =
            _savedCredentialsReadSuppressed;
        final previousCredentialsPayload = previousCredentialsReadSuppressed
            ? null
            : await _secureCredentialStorage.getSavedCredentialsPayloadStrict();
        if (expectedSavedCredentials != null &&
            !_savedCredentialsPayloadMatches(
              previousCredentialsPayload,
              expectedSavedCredentials,
            )) {
          return false;
        }
        if (!canCommit() || _serverOwnershipRevision != ownership.revision) {
          return false;
        }
        if (rememberedCredentials != null &&
            (rememberedCredentials['serverId'] != targetConfig.id ||
                rememberedCredentials['username'] == null ||
                rememberedCredentials['password'] == null)) {
          throw ArgumentError(
            'Remembered credentials must belong to the validated server',
          );
        }

        final committedConfigs = previousConfigs
            .map(
              (config) =>
                  config.copyWith(isActive: config.id == targetConfig.id),
            )
            .toList(growable: false);
        final configsNeedWrite = previousConfigs.any(
          (config) => config.isActive != (config.id == targetConfig.id),
        );
        final activeIdNeedsWrite = previousActiveServerId != targetConfig.id;
        final stagedBeforeCommit = _stagedServerConfigCandidate;
        var persistenceStarted = false;
        var configsWritten = false;
        var activeIdWritten = false;
        var credentialsWritten = false;
        try {
          persistenceStarted = true;
          await _deleteAuthTokenUnlocked();
          if (!canCommit()) throw const _StagedAuthAttemptSuperseded();

          if (configsNeedWrite) {
            configsWritten = true;
            await _saveServerConfigsUnlocked(committedConfigs);
            if (!canCommit()) throw const _StagedAuthAttemptSuperseded();
          }

          if (activeIdNeedsWrite) {
            activeIdWritten = true;
            await _writeActiveServerIdWithoutConfigSync(targetConfig.id);
            if (!canCommit()) throw const _StagedAuthAttemptSuperseded();
          }

          if (rememberedCredentials != null) {
            credentialsWritten = true;
            await _saveCredentialsUnlocked(
              serverId: targetConfig.id,
              username: rememberedCredentials['username']!,
              password: rememberedCredentials['password']!,
              authType: rememberedCredentials['authType'] ?? 'credentials',
            );
            if (!canCommit()) throw const _StagedAuthAttemptSuperseded();
          } else if (expectedSavedCredentials == null) {
            credentialsWritten = true;
            await _deleteSavedCredentialsUnlocked();
            if (!canCommit()) throw const _StagedAuthAttemptSuperseded();
          }

          await _saveAuthTokenUnlocked(token);
          if (!canCommit()) throw const _StagedAuthAttemptSuperseded();

          _stagedServerConfigCandidate = null;
          try {
            await publish();
            if (!canCommit()) throw const _StagedAuthAttemptSuperseded();
          } catch (_) {
            _stagedServerConfigCandidate = stagedBeforeCommit;
            rethrow;
          }
          return true;
        } on _StagedAuthAttemptSuperseded catch (commitError) {
          if (persistenceStarted) {
            try {
              await _restoreServerSessionUnlocked(
                configs: previousConfigs,
                activeServerId: previousActiveServerId,
                token: previousToken,
                restoreConfigs: configsWritten,
                restoreActiveServerId: activeIdWritten,
                restoreCredentials: credentialsWritten,
                credentialsPayload: previousCredentialsPayload,
                credentialsReadSuppressed: previousCredentialsReadSuppressed,
              );
            } catch (rollbackError, rollbackStackTrace) {
              await _bestEffortFailClosedServerSessionRestoreUnlocked(
                configs: previousConfigs,
                activeServerId: previousActiveServerId,
              );
              _notifyRollbackUncertainSafely(onRollbackUncertain);
              Error.throwWithStackTrace(
                ServerConfigSessionRollbackException(
                  commitError: commitError,
                  rollbackError: rollbackError,
                ),
                rollbackStackTrace,
              );
            }
          }
          return false;
        } catch (commitError, commitStackTrace) {
          if (persistenceStarted) {
            try {
              if (commitError is ServerConfigSessionRollbackException) {
                // The non-secret logout fence itself could not be restored.
                // Never resurrect a previous bearer, saved credential, or
                // proxy Cookie under a possibly-cleared fence.
                await _restoreTokenlessSanitizedServerSessionUnlocked(
                  configs: previousConfigs,
                  activeServerId: previousActiveServerId,
                  // Even when the forward commit did not touch configs, the
                  // baseline may contain the Cookie that the uncertain fence
                  // was suppressing. Force a sanitized durable rewrite.
                  restoreConfigs: true,
                  restoreActiveServerId: activeIdWritten,
                );
                _notifyRollbackUncertainSafely(onRollbackUncertain);
              } else {
                await _restoreServerSessionUnlocked(
                  configs: previousConfigs,
                  activeServerId: previousActiveServerId,
                  token: previousToken,
                  restoreConfigs: configsWritten,
                  restoreActiveServerId: activeIdWritten,
                  restoreCredentials: credentialsWritten,
                  credentialsPayload: previousCredentialsPayload,
                  credentialsReadSuppressed: previousCredentialsReadSuppressed,
                );
              }
            } catch (rollbackError, rollbackStackTrace) {
              await _bestEffortFailClosedServerSessionRestoreUnlocked(
                configs: previousConfigs,
                activeServerId: previousActiveServerId,
              );
              _notifyRollbackUncertainSafely(onRollbackUncertain);
              Error.throwWithStackTrace(
                ServerConfigSessionRollbackException(
                  commitError: commitError,
                  rollbackError: rollbackError,
                ),
                rollbackStackTrace,
              );
            }
          }
          Error.throwWithStackTrace(commitError, commitStackTrace);
        }
      }),
    );
  }

  /// Full transport identity used to pin a token commit to the exact stored
  /// config it was validated against (URL, headers, TLS policy, mTLS
  /// identity).
  ///
  /// The legacy `apiKey` field is deliberately excluded: it is stripped from
  /// every persisted config, so a config migrated from an older install would
  /// otherwise never match its own sanitized successor.
  bool _hasSameServerAuthTransportIdentity(
    ServerConfig stored,
    ServerConfig validated,
  ) {
    return stored.id == validated.id &&
        _normalizedServerIdentityUrl(stored.url) ==
            _normalizedServerIdentityUrl(validated.url) &&
        _sameStringMap(stored.customHeaders, validated.customHeaders) &&
        stored.allowSelfSignedCertificates ==
            validated.allowSelfSignedCertificates &&
        stored.mtlsCertificateChainPem == validated.mtlsCertificateChainPem &&
        stored.mtlsPrivateKeyPem == validated.mtlsPrivateKeyPem &&
        stored.mtlsPrivateKeyPassword == validated.mtlsPrivateKeyPassword;
  }

  /// Narrow identity used by [saveServerConfigs] to decide whether an edited
  /// config still owns the current session and saved credentials.
  ///
  /// A session belongs to a server account, identified by the config id, the
  /// normalized origin URL, and the mTLS client identity presented to that
  /// origin. Custom-header and self-signed-policy edits change per-request
  /// metadata for the same server and must not sign the user out, matching
  /// pre-hardening behavior. URL and mTLS identity changes still fence.
  bool _hasSameServerSessionOwnershipIdentity(
    ServerConfig stored,
    ServerConfig next,
  ) {
    return stored.id == next.id &&
        _normalizedServerIdentityUrl(stored.url) ==
            _normalizedServerIdentityUrl(next.url) &&
        stored.mtlsCertificateChainPem == next.mtlsCertificateChainPem &&
        stored.mtlsPrivateKeyPem == next.mtlsPrivateKeyPem &&
        stored.mtlsPrivateKeyPassword == next.mtlsPrivateKeyPassword;
  }

  String _normalizedServerIdentityUrl(String value) {
    final trimmed = value.trim();
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      return trimmed;
    }
    var path = parsed.path;
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (path == '/') path = '';
    return parsed
        .replace(
          scheme: parsed.scheme.toLowerCase(),
          host: parsed.host.toLowerCase(),
          path: path,
        )
        .toString();
  }

  bool _sameStringMap(Map<String, String> left, Map<String, String> right) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) || right[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  bool _savedCredentialsPayloadMatches(
    String? payload,
    Map<String, String> expected,
  ) {
    if (payload == null || payload.isEmpty) return false;
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } catch (_) {
      return false;
    }
    if (decoded is! Map<String, dynamic>) return false;
    for (final key in const ['serverId', 'username', 'password']) {
      if (decoded[key]?.toString() != expected[key]) return false;
    }
    if ((decoded['authType']?.toString() ?? 'credentials') !=
        (expected['authType'] ?? 'credentials')) {
      return false;
    }
    final expectedSavedAt = expected['savedAt'];
    if (expectedSavedAt != null &&
        expectedSavedAt.isNotEmpty &&
        decoded['savedAt']?.toString() != expectedSavedAt) {
      return false;
    }
    return true;
  }

  /// Atomically snapshots the current config/active owner and stages an
  /// authentication candidate in memory.
  ///
  /// Unlike [getServerConfigs], this operation does not convert a secure-store
  /// read failure into an empty list. Crucially, it does not overwrite the
  /// durable config payload: an app termination before commit therefore leaves
  /// the previous servers and session intact.
  Future<ServerConfigCandidateSnapshot> stageServerConfigCandidate(
    ServerConfig candidate,
  ) {
    return _authStateLock.synchronized(
      () => _serverConfigsLock.synchronized(() async {
        final currentConfigs = List<ServerConfig>.unmodifiable(
          await _getServerConfigsStrictUnlocked(),
        );
        final previousStage = _stagedServerConfigCandidate;
        final rawActiveServerId = _rawStoredActiveServerId();
        final baselineConfigs =
            previousStage?.baselineConfigs ?? currentConfigs;
        final baselineActiveServerId = previousStage != null
            ? previousStage.baselineActiveServerId
            : _effectiveActiveServerId(
                configs: baselineConfigs,
                rawActiveServerId: rawActiveServerId,
              );
        final transactionId = ++_nextServerConfigCandidateTransactionId;
        final stage = (
          transactionId: transactionId,
          candidate: candidate,
          baselineConfigs: baselineConfigs,
          baselineActiveServerId: baselineActiveServerId,
        );
        _stagedServerConfigCandidate = stage;
        return (
          configs: baselineConfigs,
          activeServerId: baselineActiveServerId,
          transactionId: transactionId,
        );
      }),
    );
  }

  /// Whether [config] is a provisional auth candidate that is not part of the
  /// durable baseline and therefore must not yet be exposed as active.
  ///
  /// Matching by id alone is unsafe: a candidate may intentionally replace a
  /// saved server while retaining its id. In that case the durable baseline row
  /// remains publishable until the candidate session commits.
  bool isUncommittedServerConfigCandidate(ServerConfig config) {
    final staged = _stagedServerConfigCandidate;
    if (staged == null || staged.candidate != config) return false;
    return !staged.baselineConfigs.contains(config);
  }

  /// Commits a staged proxy/trusted-header session and publishes it while the
  /// auth/config locks are still held.
  ///
  /// The durable ordering is intentionally crash-safe:
  ///
  /// 1. Remove the previous token.
  /// 2. Preserve prior configs and append the candidate as the active row.
  /// 3. Switch the active id.
  /// 4. Save the validated candidate token.
  ///
  /// A termination during steps 1-3 leaves no token, so startup is
  /// unauthenticated without ever pairing the candidate with the previous
  /// token. A termination after step 4 leaves a complete candidate session.
  /// The candidate JWT itself is never duplicated into ServerConfig.apiKey.
  Future<bool> commitServerConfigCandidateSession({
    required ServerConfig candidate,
    required int transactionId,
    required String token,
    required bool Function() canCommit,
    required FutureOr<void> Function() publish,
    void Function()? onRollbackUncertain,
  }) {
    return _authStateLock.synchronized(
      () => _serverConfigsLock.synchronized(() async {
        final staged = _stagedServerConfigCandidate;
        if (!_ownsStagedServerConfigCandidate(
              staged,
              candidate: candidate,
              transactionId: transactionId,
            ) ||
            !canCommit()) {
          return false;
        }

        final committedCandidate = candidate.copyWith(
          apiKey: null,
          isActive: true,
        );
        final committedConfigs = <ServerConfig>[
          for (final config in staged!.baselineConfigs)
            if (config.id != candidate.id) config.copyWith(isActive: false),
          committedCandidate,
        ];

        String? previousToken;
        String? previousCredentialsPayload;
        var previousCredentialsReadSuppressed = false;
        var persistenceStarted = false;
        try {
          // This strict snapshot occurs inside the auth lock and before the
          // first write. A transient Keychain failure must abort the commit,
          // never masquerade as a missing prior session during rollback.
          previousToken = await _getAuthTokenStrictUnlocked();
          if (!canCommit()) throw const _StagedAuthAttemptSuperseded();
          previousCredentialsReadSuppressed = _savedCredentialsReadSuppressed;
          previousCredentialsPayload = previousCredentialsReadSuppressed
              ? null
              : await _secureCredentialStorage
                    .getSavedCredentialsPayloadStrict();
          if (!canCommit()) throw const _StagedAuthAttemptSuperseded();

          persistenceStarted = true;
          // Never allow a crash window where the previous server's token is
          // paired with the newly-active candidate.
          await _deleteAuthTokenUnlocked();
          if (!canCommit()) throw const _StagedAuthAttemptSuperseded();

          // Proxy/trusted-header sessions cannot safely inherit a remembered
          // credential belonging to the previous account or server.
          await _deleteSavedCredentialsUnlocked();
          if (!canCommit()) throw const _StagedAuthAttemptSuperseded();

          await _saveServerConfigsUnlocked(committedConfigs);
          if (!canCommit()) throw const _StagedAuthAttemptSuperseded();

          await _writeActiveServerIdWithoutConfigSync(candidate.id);
          if (!canCommit()) throw const _StagedAuthAttemptSuperseded();

          await _saveAuthTokenUnlocked(token);
          if (!canCommit()) throw const _StagedAuthAttemptSuperseded();

          // Publication (including any checked non-secret session-fence write)
          // completes before either lock is released. A queued normal config
          // save therefore either won before this transaction (and invalidated
          // its marker) or runs after the authenticated state/config pair has
          // been published.
          _stagedServerConfigCandidate = null;
          try {
            await publish();
            if (!canCommit()) throw const _StagedAuthAttemptSuperseded();
          } catch (_) {
            // Let the outer rollback path retain ownership if synchronous
            // Riverpod publication unexpectedly fails.
            _stagedServerConfigCandidate = staged;
            rethrow;
          }
          return true;
        } on _StagedAuthAttemptSuperseded catch (commitError) {
          if (persistenceStarted) {
            try {
              await _restoreStagedServerConfigSessionUnlocked(
                staged: staged,
                previousToken: previousToken,
                previousCredentialsPayload: previousCredentialsPayload,
                previousCredentialsReadSuppressed:
                    previousCredentialsReadSuppressed,
              );
            } catch (rollbackError, rollbackStackTrace) {
              await _bestEffortFailClosedServerSessionRestoreUnlocked(
                configs: staged.baselineConfigs,
                activeServerId: staged.baselineActiveServerId,
              );
              _notifyRollbackUncertainSafely(onRollbackUncertain);
              Error.throwWithStackTrace(
                ServerConfigSessionRollbackException(
                  commitError: commitError,
                  rollbackError: rollbackError,
                ),
                rollbackStackTrace,
              );
            }
          }
          return false;
        } catch (commitError, commitStackTrace) {
          if (persistenceStarted) {
            try {
              if (commitError is ServerConfigSessionRollbackException) {
                await _restoreTokenlessSanitizedServerSessionUnlocked(
                  configs: staged.baselineConfigs,
                  activeServerId: staged.baselineActiveServerId,
                );
                _notifyRollbackUncertainSafely(onRollbackUncertain);
              } else {
                await _restoreStagedServerConfigSessionUnlocked(
                  staged: staged,
                  previousToken: previousToken,
                  previousCredentialsPayload: previousCredentialsPayload,
                  previousCredentialsReadSuppressed:
                      previousCredentialsReadSuppressed,
                );
              }
            } catch (rollbackError, rollbackStackTrace) {
              await _bestEffortFailClosedServerSessionRestoreUnlocked(
                configs: staged.baselineConfigs,
                activeServerId: staged.baselineActiveServerId,
              );
              _notifyRollbackUncertainSafely(onRollbackUncertain);
              Error.throwWithStackTrace(
                ServerConfigSessionRollbackException(
                  commitError: commitError,
                  rollbackError: rollbackError,
                ),
                rollbackStackTrace,
              );
            }
          }
          Error.throwWithStackTrace(commitError, commitStackTrace);
        } finally {
          // A rollback failure must not leave an in-memory publication fence
          // stranded. Durable uncertainty is communicated by the typed error.
          if (_stagedServerConfigCandidate?.transactionId == transactionId) {
            _stagedServerConfigCandidate = null;
          }
        }
      }),
    );
  }

  /// Discards an in-memory candidate if the caller still owns its transaction.
  Future<bool> discardServerConfigCandidate({
    required ServerConfig candidate,
    required int transactionId,
  }) {
    return _authStateLock.synchronized(
      () => _serverConfigsLock.synchronized(() {
        final staged = _stagedServerConfigCandidate;
        if (!_ownsStagedServerConfigCandidate(
          staged,
          candidate: candidate,
          transactionId: transactionId,
        )) {
          return false;
        }
        _stagedServerConfigCandidate = null;
        return true;
      }),
    );
  }

  bool _ownsStagedServerConfigCandidate(
    _StagedServerConfigCandidate? staged, {
    required ServerConfig candidate,
    required int transactionId,
  }) {
    return staged != null &&
        staged.transactionId == transactionId &&
        staged.candidate == candidate;
  }

  Future<void> _restoreStagedServerConfigSessionUnlocked({
    required _StagedServerConfigCandidate staged,
    required String? previousToken,
    required String? previousCredentialsPayload,
    required bool previousCredentialsReadSuppressed,
  }) {
    return _restoreServerSessionUnlocked(
      configs: staged.baselineConfigs,
      activeServerId: staged.baselineActiveServerId,
      token: previousToken,
      restoreCredentials: true,
      credentialsPayload: previousCredentialsPayload,
      credentialsReadSuppressed: previousCredentialsReadSuppressed,
    );
  }

  Future<void> _restoreServerSessionUnlocked({
    required List<ServerConfig> configs,
    required String? activeServerId,
    required String? token,
    bool restoreConfigs = true,
    bool restoreActiveServerId = true,
    bool restoreCredentials = false,
    String? credentialsPayload,
    bool credentialsReadSuppressed = false,
    bool tokenAlreadyDeleted = false,
  }) async {
    // Roll back in a crash-safe order. Until the prior config/id pair is fully
    // restored there must be no bearer token that could be sent to whichever
    // origin startup can resolve from a partially-restored snapshot.
    if (!tokenAlreadyDeleted) await _deleteAuthTokenUnlocked();

    Object? ownershipRestoreError;
    StackTrace? ownershipRestoreStackTrace;
    if (restoreActiveServerId) {
      try {
        await _writeActiveServerIdWithoutConfigSync(activeServerId);
      } catch (error, stackTrace) {
        ownershipRestoreError = error;
        ownershipRestoreStackTrace = stackTrace;
      }
    }
    if (restoreConfigs) {
      try {
        await _saveServerConfigsUnlocked(configs);
      } catch (error, stackTrace) {
        ownershipRestoreError ??= error;
        ownershipRestoreStackTrace ??= stackTrace;
      }
    }
    if (restoreCredentials) {
      try {
        if (credentialsReadSuppressed) {
          // The transaction began behind a same-process read fence. Never
          // resurrect a Keychain payload that the baseline deliberately made
          // unreadable; delete any candidate written by the failed commit and
          // retain the fence.
          await _deleteSavedCredentialsUnlocked();
        } else {
          await _secureCredentialStorage.restoreSavedCredentialsPayload(
            credentialsPayload,
          );
          _savedCredentialsReadSuppressed = false;
          _cacheManager.write(
            'has_credentials',
            credentialsPayload != null && credentialsPayload.isNotEmpty,
            ttl: _credentialsFlagTtl,
          );
        }
      } catch (error, stackTrace) {
        ownershipRestoreError ??= error;
        ownershipRestoreStackTrace ??= stackTrace;
      }
    }

    // Restoring a bearer token is safe only after both ownership keys are
    // known to be back at their baseline values. Otherwise remain explicitly
    // unauthenticated and let the caller surface recovery UI.
    if (ownershipRestoreError == null && token != null && token.isNotEmpty) {
      await _saveAuthTokenUnlocked(token);
    }
    if (ownershipRestoreError != null) {
      Error.throwWithStackTrace(
        ownershipRestoreError,
        ownershipRestoreStackTrace!,
      );
    }
  }

  /// Fail-closed rollback used only when the durable incomplete-logout fence
  /// cannot be restored. Deleting auth secrets is the first prefix; configs
  /// are then restored without legacy bearer fields or proxy cookies.
  Future<void> _restoreTokenlessSanitizedServerSessionUnlocked({
    required List<ServerConfig> configs,
    required String? activeServerId,
    bool restoreConfigs = true,
    bool restoreActiveServerId = true,
  }) async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> attempt(Future<void> Function() operation) async {
      try {
        await operation();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    // Each fail-closed mutation is independent. A broken Keychain delete must
    // not prevent the password delete or the durable proxy-cookie/legacy
    // bearer scrub.
    await attempt(_deleteAuthTokenUnlocked);
    await attempt(_deleteSavedCredentialsUnlocked);
    final sanitized = configs
        .map(_revokeServerConfigAuthArtifacts)
        .toList(growable: false);
    await attempt(
      () => _restoreServerSessionUnlocked(
        configs: sanitized,
        activeServerId: activeServerId,
        token: null,
        restoreConfigs: restoreConfigs,
        restoreActiveServerId: restoreActiveServerId,
        tokenAlreadyDeleted: true,
      ),
    );
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  /// A baseline rollback can itself fail after the candidate bearer has been
  /// removed. Make one independent best-effort pass to leave a durable,
  /// tokenless owner without remembered credentials or proxy cookies before
  /// surfacing the original typed rollback failure to the caller.
  ///
  /// The original rollback error remains the diagnostic source. Failure of
  /// this safety pass is logged by type only and must not hide that error or
  /// prevent the in-memory uncertainty fence from being published.
  Future<void> _bestEffortFailClosedServerSessionRestoreUnlocked({
    required List<ServerConfig> configs,
    required String? activeServerId,
  }) async {
    try {
      await _restoreTokenlessSanitizedServerSessionUnlocked(
        configs: configs,
        activeServerId: activeServerId,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'session-rollback-fail-closed-restore-incomplete',
        scope: 'storage/optimized',
        stackTrace: stackTrace,
        data: {'errorType': error.runtimeType.toString()},
      );
    }
  }

  String? _effectiveActiveServerId({
    required List<ServerConfig> configs,
    required String? rawActiveServerId,
  }) {
    if (rawActiveServerId != null &&
        configs.any((config) => config.id == rawActiveServerId)) {
      return rawActiveServerId;
    }

    for (final config in configs) {
      if (config.isActive) return config.id;
    }
    return configs.length == 1 ? configs.single.id : null;
  }

  Future<List<ServerConfig>> getServerConfigs() {
    return _serverConfigsLock.synchronized(() async {
      try {
        return await _getServerConfigsStrictRetryingUnlocked();
      } catch (error) {
        DebugLogger.log(
          'Failed to retrieve server configs: $error',
          scope: 'storage/optimized',
        );
        return const [];
      }
    });
  }

  /// Reads server configs without converting a Keychain failure into an empty
  /// list. Provider-facing callers use this so Riverpod publishes AsyncError
  /// and can recover on invalidation instead of retaining a false empty cache.
  Future<List<ServerConfig>> getServerConfigsStrict() =>
      _serverConfigsLock.synchronized(_getServerConfigsStrictRetryingUnlocked);

  Future<List<ServerConfig>> _getServerConfigsStrictRetryingUnlocked() {
    return _retrySecureStorageRead(
      _getServerConfigsStrictUnlocked,
      scope: 'storage/optimized/server-configs',
    );
  }

  Future<List<ServerConfig>> _getServerConfigsStrictUnlocked({
    bool bypassReadSuppression = false,
  }) async {
    if (_serverConfigsReadSuppressed && !bypassReadSuppression) {
      return const <ServerConfig>[];
    }
    if (!bypassReadSuppression) {
      final (hit: hasCachedConfigs, value: cachedConfigs) = _cacheManager
          .lookup<List<ServerConfig>>(_serverConfigsCacheKey);
      if (hasCachedConfigs && cachedConfigs != null) {
        return cachedConfigs;
      }
    }

    final jsonString = await _secureCredentialStorage.getServerConfigs();
    if (jsonString == null) {
      if (!bypassReadSuppression) {
        _cacheServerConfigs(const <ServerConfig>[]);
      }
      return const [];
    }
    if (jsonString.isEmpty) {
      throw const FormatException('Server configs payload was empty');
    }

    final decoded = jsonDecode(jsonString) as List<dynamic>;
    final configs = decoded
        .map((item) => ServerConfig.fromJson(item))
        .toList(growable: false);
    if (!bypassReadSuppression) _cacheServerConfigs(configs);
    return configs;
  }

  Future<List<ServerConfig>>
  _getServerConfigsStrictUnlockedBypassingSuppression() =>
      _getServerConfigsStrictUnlocked(bypassReadSuppression: true);

  Future<void> setActiveServerId(String? serverId) =>
      _authStateLock.synchronized(() => _setActiveServerIdUnlocked(serverId));

  Future<void> _setActiveServerIdUnlocked(String? serverId) async {
    await _serverConfigsLock.synchronized(() async {
      final configs = await _getServerConfigsStrictUnlocked();
      final previousActiveId = _effectiveActiveServerId(
        configs: configs,
        rawActiveServerId: _rawStoredActiveServerId(),
      );
      final updatedConfigs = configs
          .map((config) => config.copyWith(isActive: config.id == serverId))
          .toList(growable: false);
      final nextActiveId = _effectiveActiveServerId(
        configs: updatedConfigs,
        rawActiveServerId: serverId,
      );
      if (previousActiveId != nextActiveId) {
        await _deleteAuthTokenUnlocked();
      }
      await _writeActiveServerIdWithoutConfigSync(serverId);
      // A normal server selection supersedes an uncommitted auth candidate.
      _stagedServerConfigCandidate = null;
      if (configs.any((config) => config.isActive != (config.id == serverId))) {
        await _saveServerConfigsUnlocked(updatedConfigs);
      }
    });
  }

  Future<void> _writeActiveServerIdWithoutConfigSync(String? serverId) async {
    await PreferencesStore.putChecked(_activeServerIdKey, serverId);
    _activeServerIdReadSuppressed = false;
    _serverOwnershipRevision++;
    _cacheActiveServerId(serverId);
  }

  Future<String?> getActiveServerId() {
    return _authStateLock.synchronized(
      () => _serverConfigsLock.synchronized(() async {
        final activeServerIdState = _readActiveServerIdState();
        try {
          return await _resolveValidatedActiveServerIdUnlocked(
            rawServerId: activeServerIdState.rawServerId,
            cacheWhenUnchanged: !activeServerIdState.hasCachedId,
          );
        } catch (error) {
          // Preserve the raw preference and leave the active-id cache untouched.
          // A transient Keychain failure is not evidence that the selection is
          // invalid; the next lookup must be allowed to recover it.
          DebugLogger.log(
            'Failed to validate active server id: $error',
            scope: 'storage/optimized',
          );
          return null;
        }
      }),
    );
  }

  /// Compare-and-clear: clears the active server id ONLY if the RAW stored
  /// preference still equals [expectedId]. Compares the raw value (not
  /// [getActiveServerId], which validates against saved configs and returns null
  /// once the server is deleted — the very case this is used for), under
  /// [_authStateLock] so a concurrently-selected active server isn't clobbered.
  /// Returns true if it cleared.
  Future<bool> clearActiveServerIdIfMatches(String expectedId) {
    return _authStateLock.synchronized(() async {
      if (_rawStoredActiveServerId(bypassReadSuppression: true) != expectedId) {
        return false;
      }
      await _setActiveServerIdUnlocked(null);
      return true;
    });
  }

  /// The active-server id as stored in Hive, bypassing the in-memory cache and
  /// the saved-config validation in [getActiveServerId] (which returns null once
  /// the referenced server is deleted). Compare-and-clear/restore use this so a
  /// dangling preference for a removed server is still detected and cleared.
  String? _rawStoredActiveServerId({bool bypassReadSuppression = false}) {
    if (_activeServerIdReadSuppressed && !bypassReadSuppression) return null;
    return PreferencesStore.getString(_activeServerIdKey);
  }

  String? getThemeMode() {
    return PreferencesStore.getString(_themeModeKey);
  }

  Future<void> setThemeMode(String mode) async {
    await PreferencesStore.put(_themeModeKey, mode);
  }

  String? getThemePaletteId() {
    return PreferencesStore.getString(_themePaletteKey);
  }

  Future<void> setThemePaletteId(String paletteId) async {
    await PreferencesStore.put(_themePaletteKey, paletteId);
  }

  String? getLocaleCode() {
    return PreferencesStore.getString(_localeCodeKey);
  }

  Future<void> setLocaleCode(String? code) async {
    if (code == null || code.isEmpty) {
      await PreferencesStore.remove(_localeCodeKey);
    } else {
      await PreferencesStore.put(_localeCodeKey, code);
    }
  }

  Future<bool> getReviewerMode() async {
    return PreferencesStore.getBool(_reviewerModeKey) ?? false;
  }

  Future<void> setReviewerMode(bool enabled) async {
    await PreferencesStore.put(_reviewerModeKey, enabled);
  }

  Future<T> _readSafely<T>({
    required String errorMessage,
    required Future<T> Function() read,
    required T fallback,
  }) async {
    try {
      return await read();
    } catch (error, stackTrace) {
      _logStorageError(errorMessage, error, stackTrace);
      return fallback;
    }
  }

  Future<T?> _readNullableSafely<T>({
    required String errorMessage,
    required Future<T?> Function() read,
  }) async {
    try {
      return await read();
    } catch (error, stackTrace) {
      _logStorageError(errorMessage, error, stackTrace);
      return null;
    }
  }

  Future<void> _writeSafely({
    required String errorMessage,
    required Future<void> Function() write,
  }) async {
    try {
      await write();
    } catch (error, stackTrace) {
      _logStorageError(errorMessage, error, stackTrace);
    }
  }

  void _logStorageError(String message, Object error, StackTrace stackTrace) {
    DebugLogger.error(
      message,
      scope: 'storage/optimized',
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// CDT-RFC-001 §9.3: deletes the legacy Hive conversation/folder caches.
  /// The Drift database is the only conversation/folder read substrate in
  /// Phase 1; the SyncEngine calls this exactly once after the first
  /// fully-successful full pull (guarded by the `hive_cache_purged`
  /// sync_meta flag). Idempotent.
  Future<void> deleteLegacyConversationCaches() {
    return _writeSafely(
      errorMessage: 'Failed to delete legacy conversation caches',
      write: () async {
        await Future.wait([
          _cachesBox.delete(_localConversationsKey),
          _cachesBox.delete(_localFoldersKey),
        ]);
      },
    );
  }

  Future<User?> getLocalUser() {
    return _readNullableSafely(
      errorMessage: 'Failed to retrieve local user',
      read: () async {
        final stored = await _readCacheValue(_localUserKey);
        if (stored == null) return null;
        return _decodeJsonObject(stored, User.fromJson);
      },
    );
  }

  /// Reads the cached user and its separately-stored avatar from one database
  /// ownership snapshot. A server switch between those reads must never pair
  /// A's user with B's avatar.
  Future<User?> getLocalUserWithAvatar() {
    return _readNullableSafely(
      errorMessage: 'Failed to retrieve local user with avatar',
      read: () async {
        final cached = await _withDatabase<({String? user, String? avatar})>(
          (database) => database.transaction(() async {
            final user = await database.appCacheDao.getValue(_localUserKey);
            final avatar = await database.appCacheDao.getValue(
              _localUserAvatarKey,
            );
            return (user: user, avatar: avatar);
          }),
        );
        final storedUser = cached?.user;
        if (storedUser == null) return null;
        final user = _decodeJsonObject(storedUser, User.fromJson);
        if (user == null) return null;
        final avatar = cached?.avatar;
        if (avatar == null || avatar.isEmpty || user.profileImage == avatar) {
          return user;
        }
        return user.copyWith(profileImage: avatar);
      },
    );
  }

  Future<void> saveLocalUser(User? user) {
    return _authStateLock.synchronized(() => _saveLocalUserUnlocked(user));
  }

  Future<void> _saveLocalUserUnlocked(User? user) {
    return _writeSafely(
      errorMessage: 'Failed to save local user',
      write: () async {
        if (user == null) {
          await _withDatabase<void>(
            (database) => database.appCacheDao.deleteKeys(<String>[
              _localUserKey,
              _localUserAvatarKey,
            ]),
          );
          return;
        }
        await _writeCacheValue(_localUserKey, jsonEncode(user.toJson()));
      },
    );
  }

  /// Persists the user and avatar under one database lease and transaction.
  Future<void> saveLocalUserWithAvatar(User user, {String? avatarUrl}) {
    return _authStateLock.synchronized(
      () => _saveLocalUserWithAvatarUnlocked(user, avatarUrl: avatarUrl),
    );
  }

  Future<void> _saveLocalUserWithAvatarUnlocked(
    User user, {
    String? avatarUrl,
  }) {
    return _writeSafely(
      errorMessage: 'Failed to save local user with avatar',
      write: () async {
        final updatedAt = DateTime.now().millisecondsSinceEpoch;
        await _withDatabase<void>(
          (database) => database.transaction(() async {
            await database.appCacheDao.setValue(
              _localUserKey,
              jsonEncode(user.toJson()),
              updatedAt: updatedAt,
            );
            if (avatarUrl == null || avatarUrl.isEmpty) {
              await database.appCacheDao.deleteKey(_localUserAvatarKey);
            } else {
              await database.appCacheDao.setValue(
                _localUserAvatarKey,
                avatarUrl,
                updatedAt: updatedAt,
              );
            }
          }),
        );
      },
    );
  }

  Future<String?> getLocalUserAvatar() {
    return _readNullableSafely(
      errorMessage: 'Failed to retrieve local user avatar',
      read: () async {
        final stored = await _readCacheValue(_localUserAvatarKey);
        if (stored != null && stored.isNotEmpty) {
          return stored;
        }
        return null;
      },
    );
  }

  Future<void> saveLocalUserAvatar(String? avatarUrl) {
    return _authStateLock.synchronized(
      () => _saveLocalUserAvatarUnlocked(avatarUrl),
    );
  }

  Future<void> _saveLocalUserAvatarUnlocked(String? avatarUrl) {
    return _writeSafely(
      errorMessage: 'Failed to save local user avatar',
      write: () async {
        if (avatarUrl == null || avatarUrl.isEmpty) {
          await _deleteCacheValue(_localUserAvatarKey);
          return;
        }
        await _writeCacheValue(_localUserAvatarKey, avatarUrl);
      },
    );
  }

  Future<BackendConfig?> getLocalBackendConfig() {
    return _readNullableSafely(
      errorMessage: 'Failed to retrieve local backend config',
      read: () async {
        final stored = await _readCacheValue(_localBackendConfigKey);
        if (stored == null) return null;
        return _decodeJsonObject(stored, BackendConfig.fromJson);
      },
    );
  }

  Future<void> saveLocalBackendConfig(BackendConfig? config) {
    return _writeSafely(
      errorMessage: 'Failed to save local backend config',
      write: () async {
        if (config == null) {
          await _deleteCacheValue(_localBackendConfigKey);
          return;
        }
        await _writeCacheValue(
          _localBackendConfigKey,
          jsonEncode(normalizeJsonLikeValue(config.toJson())),
        );
      },
    );
  }

  // Transport options live in shared_preferences (not the Hive caches box) under
  // a per-server key, because they need a SYNCHRONOUS read at socket init and
  // must not churn the socket on cold start. The serverId is base64-encoded so
  // arbitrary characters can't break the key.
  static String _transportOptionsKey(String serverId) =>
      '${PreferenceKeys.transportOptionsPrefix}:'
      '${base64Url.encode(utf8.encode(serverId))}';

  SocketTransportAvailability? _readTransportOptionsForActiveServer() {
    final serverId = _rawStoredActiveServerId();
    if (serverId == null || serverId.isEmpty) return null;
    final raw = PreferencesStore.getString(_transportOptionsKey(serverId));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return _transportFromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  Future<SocketTransportAvailability?> getLocalTransportOptions() {
    return Future.value(_readTransportOptionsForActiveServer());
  }

  Future<void> saveLocalTransportOptions(SocketTransportAvailability? options) {
    return _writeSafely(
      errorMessage: 'Failed to save local transport options',
      write: () async {
        final serverId = _rawStoredActiveServerId();
        if (serverId == null || serverId.isEmpty) return;
        final key = _transportOptionsKey(serverId);
        if (options == null) {
          await PreferencesStore.remove(key);
          return;
        }
        await PreferencesStore.put(
          key,
          jsonEncode({
            'allowPolling': options.allowPolling,
            'allowWebsocketOnly': options.allowWebsocketOnly,
          }),
        );
      },
    );
  }

  SocketTransportAvailability? getLocalTransportOptionsSync() {
    return _readTransportOptionsForActiveServer();
  }

  /// Decodes a stored JSON-list cache value off the UI isolate (lists can be
  /// large, e.g. models). Empty when [stored] is null.
  Future<List<Map<String, dynamic>>> _decodeCacheJsonList(
    String? stored, {
    required String debugLabel,
  }) async {
    if (stored == null || stored.isEmpty) {
      return const <Map<String, dynamic>>[];
    }
    return _workerManager
        .schedule<Map<String, dynamic>, List<Map<String, dynamic>>>(
          _decodeStoredJsonListWorker,
          {'stored': stored},
          debugLabel: debugLabel,
        );
  }

  Future<void> _writeCacheJsonList<T>(
    String key,
    Iterable<T> items, {
    required Map<String, dynamic> Function(T item) toJson,
  }) async {
    final normalized = items
        .map((item) => normalizeJsonLikeMap(toJson(item)))
        .toList(growable: false);
    await _writeCacheValue(key, jsonEncode(normalized));
  }

  Future<List<Model>> getLocalModels() {
    return _readSafely(
      errorMessage: 'Failed to retrieve local models',
      fallback: List<Model>.empty(growable: false),
      read: () async {
        final parsed = await _decodeCacheJsonList(
          await _readCacheValue(_localModelsKey),
          debugLabel: 'decode_local_models',
        );
        return parsed.map(Model.fromJson).toList(growable: false);
      },
    );
  }

  Future<void> saveLocalModels(List<Model> models) {
    return _writeSafely(
      errorMessage: 'Failed to save local models',
      write: () => _writeCacheJsonList(
        _localModelsKey,
        models,
        toJson: (model) => model.toJson(),
      ),
    );
  }

  Future<List<Tool>> getLocalTools() {
    return _readSafely(
      errorMessage: 'Failed to retrieve local tools',
      fallback: List<Tool>.empty(growable: false),
      read: () async {
        final parsed = await _decodeCacheJsonList(
          await _readCacheValue(_localToolsKey),
          debugLabel: 'decode_local_tools',
        );
        return parsed.map(Tool.fromJson).toList(growable: false);
      },
    );
  }

  Future<void> saveLocalTools(List<Tool> tools) {
    return _writeSafely(
      errorMessage: 'Failed to save local tools',
      write: () => _writeCacheJsonList(
        _localToolsKey,
        tools,
        toJson: (tool) => tool.toJson(),
      ),
    );
  }

  Future<Model?> getLocalDefaultModel() {
    return _readNullableSafely(
      errorMessage: 'Failed to retrieve local default model',
      read: () async {
        final cached = await _withDatabase<({String? model, String? models})>(
          (database) => database.transaction(() async {
            final model = await database.appCacheDao.getValue(
              _localDefaultModelKey,
            );
            final models = await database.appCacheDao.getValue(_localModelsKey);
            return (model: model, models: models);
          }),
        );
        final stored = cached?.model;
        if (stored == null) return null;
        final parsedModel = _decodeJsonObject(stored, Model.fromJson);
        if (parsedModel == null) return null;

        final cachedModels = (await _decodeCacheJsonList(
          cached?.models,
          debugLabel: 'decode_local_models_for_default',
        )).map(Model.fromJson).toList(growable: false);
        final hasMatch = cachedModels.any(
          (model) =>
              model.id == parsedModel.id ||
              model.name.trim() == parsedModel.name.trim(),
        );
        if (cachedModels.isNotEmpty && !hasMatch) {
          return null;
        }
        return parsedModel;
      },
    );
  }

  Future<void> saveLocalDefaultModel(Model? model) {
    return _writeSafely(
      errorMessage: 'Failed to save local default model',
      write: () async {
        if (model == null) {
          await _deleteCacheValue(_localDefaultModelKey);
          return;
        }
        await _writeCacheValue(
          _localDefaultModelKey,
          jsonEncode(normalizeJsonLikeValue(model.toJson())),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Batch operations
  // ---------------------------------------------------------------------------
  Future<void> _clearUserScopedCacheEntries() async {
    // Capture the logical owner before any database resolution or query can
    // suspend. A concurrent server switch must not make cleanup that started
    // for A remove B's per-server transport preferences after the Drift work
    // settles.
    final initiatingServerId = _rawStoredActiveServerId();

    // Active store: the per-server Drift app cache.
    await _withDatabase<void>(
      (database) => database.appCacheDao.deleteKeys(<String>[
        _localUserKey,
        _localUserAvatarKey,
        _localBackendConfigKey,
        _localToolsKey,
        _localDefaultModelKey,
        _localModelsKey,
      ]),
    );
    // Transport options moved to shared_preferences (PR-1).
    if (initiatingServerId != null && initiatingServerId.isNotEmpty) {
      await PreferencesStore.remove(_transportOptionsKey(initiatingServerId));
    }
    // Legacy Hive caches-box cleanup for installs that predate the Drift cache.
    await Future.wait([
      _cachesBox.delete(_localUserKey),
      _cachesBox.delete(_localUserAvatarKey),
      _cachesBox.delete(_localBackendConfigKey),
      _cachesBox.delete(_localTransportOptionsKey),
      _cachesBox.delete(_localToolsKey),
      _cachesBox.delete(_localDefaultModelKey),
      _cachesBox.delete(_localModelsKey),
      _cachesBox.delete(_localConversationsKey),
      _cachesBox.delete(_localFoldersKey),
    ]);
  }

  /// Clear user-scoped cached data while preserving token and saved credentials.
  ///
  /// Used when an existing token is invalidated but saved credentials may still
  /// be used for a silent re-login.
  Future<void> clearUserScopedAuthData() async {
    await _authStateLock.synchronized(_clearUserScopedCacheEntries);
    DebugLogger.log(
      'User-scoped auth data cleared',
      scope: 'storage/optimized',
    );
  }

  /// Clear authentication-related data (tokens, credentials, user data).
  /// Connection settings remain available for quick re-login: the URL,
  /// self-signed-certificate policy, user-configured custom headers, and the
  /// mTLS client identity are prerequisites for reaching the sign-in page at
  /// all. Session credentials embedded in configs (the legacy apiKey bearer
  /// and captured proxy Cookie headers) are deliberately revoked.
  Future<void> clearAuthData() async {
    await _authStateLock.synchronized(_clearAuthDataUnlocked);

    DebugLogger.log(
      'Auth data cleared (non-auth server settings preserved)',
      scope: 'storage/optimized',
    );
  }

  /// Clears auth data only if [canClear] still owns the session after waiting
  /// for every earlier auth mutation. Checking under [_authStateLock] closes
  /// the race where a logout observes a loading login, then deletes the new
  /// token immediately after that login commits.
  Future<bool> clearAuthDataIf({required bool Function() canClear}) async {
    final cleared = await _authStateLock.synchronized(() async {
      if (!canClear()) return false;
      await _clearAuthDataUnlocked();
      return true;
    });
    if (cleared) {
      DebugLogger.log(
        'Auth data conditionally cleared',
        scope: 'storage/optimized',
      );
    }
    return cleared;
  }

  Future<void> _scrubServerConfigAuthArtifactsUnlocked() async {
    final configs = await _getServerConfigsStrictUnlockedBypassingSuppression();
    var changed = false;
    final sanitized = configs
        .map((config) {
          final revoked = _revokeServerConfigAuthArtifacts(config);
          if (revoked == config) return config;
          changed = true;
          return revoked;
        })
        .toList(growable: false);
    if (changed) {
      await _saveServerConfigsUnlocked(sanitized, authorizeReads: false);
    }
  }

  Future<void> _clearAuthDataUnlocked() async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> attempt(Future<void> Function() operation) async {
      try {
        await operation();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    await _serverConfigsLock.synchronized(() async {
      // Keep every fail-closed leg independent: platform storage can fail for
      // one key while the other secret and the sanitized owner remain writable.
      await attempt(_deleteAuthTokenUnlocked);
      await attempt(_deleteSavedCredentialsUnlocked);
      await attempt(_scrubServerConfigAuthArtifactsUnlocked);
      _stagedServerConfigCandidate = null;
    });
    await attempt(_clearUserScopedCacheEntries);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  Future<void> clearAll() async {
    try {
      await _authStateLock.synchronized(
        () => _serverConfigsLock.synchronized(() async {
          Object? firstError;
          StackTrace? firstStackTrace;

          Future<void> attempt(Future<void> Function() operation) async {
            try {
              await operation();
            } catch (error, stackTrace) {
              firstError ??= error;
              firstStackTrace ??= stackTrace;
            }
          }

          // Fence every pre-wipe ownership snapshot before the first await.
          _authTokenReadSuppressed = true;
          _savedCredentialsReadSuppressed = true;
          _serverConfigsReadSuppressed = true;
          _activeServerIdReadSuppressed = true;
          _serverOwnershipRevision++;
          _stagedServerConfigCandidate = null;

          // Keep every fail-closed mutation independent. An individual
          // Keychain failure must not prevent deletion of the other secret, a
          // durable proxy-Cookie/API-key scrub, or the later broad wipe.
          await attempt(_deleteAuthTokenUnlocked);
          await attempt(_deleteSavedCredentialsUnlocked);
          await attempt(_scrubServerConfigAuthArtifactsUnlocked);

          // PreferencesStore.clear removes activeServerId. Keep the initiating
          // owner stable until a deferred database open/retry has finished, or
          // the structured wipe can silently disappear halfway through.
          final initiatingServerId = _rawStoredActiveServerId(
            bypassReadSuppression: true,
          );

          try {
            await attempt(
              () => _withDatabase<void>(
                (database) => Future.wait([
                  database.appCacheDao.deleteKeys(_allCacheKeys),
                  database.attachmentQueueDao.clearAll(),
                ]),
                expectedServerId: initiatingServerId,
              ),
            );
            // Preserve the migration gate so a wipe doesn't re-import stale
            // Hive preferences on the next launch. This still runs after a
            // structured-store failure, but only after that operation settles.
            await attempt(
              () => PreferencesStore.clear(
                preserve: const {PreferenceKeys.hiveToPrefsMigrationV1},
              ),
            );
            await attempt(_secureCredentialStorage.clearAll);
            // Legacy Hive stores; structured active-server stores were handled
            // above while holding their database lifetime lease.
            await attempt(_cachesBox.clear);
            await attempt(_attachmentQueueBox.clear);
            await attempt(() async {
              // Preserve migration metadata.
              final migrationVersion =
                  _metadataBox.get(HiveStoreKeys.migrationVersion) as int?;
              await _metadataBox.clear();
              if (migrationVersion != null) {
                await _metadataBox.put(
                  HiveStoreKeys.migrationVersion,
                  migrationVersion,
                );
              }
            });
          } finally {
            // A partially successful platform wipe must never make retained
            // Keychain data readable again after cache invalidation. Install
            // an explicit signed-out fence after dropping every stale entry;
            // later authorized saves overwrite these negative values.
            _cacheManager.clear();
            _authTokenReadSuppressed = true;
            _savedCredentialsReadSuppressed = true;
            _serverConfigsReadSuppressed = true;
            _activeServerIdReadSuppressed = true;
            _cacheManager.write<String>(
              _authTokenKey,
              null,
              ttl: _authTokenTtl,
            );
            _cacheManager.write<bool>(
              'has_credentials',
              false,
              ttl: _credentialsFlagTtl,
            );
            // Server config custom headers can themselves be credentials.
            // Do not rehydrate a retained unsanitized Cookie/API-key payload
            // when both the targeted scrub and broad Keychain wipe fail.
            _cacheServerConfigs(const <ServerConfig>[]);
            _cacheActiveServerId(null);
          }
          if (firstError != null) {
            Error.throwWithStackTrace(firstError!, firstStackTrace!);
          }
        }),
      );

      DebugLogger.log('All storage cleared', scope: 'storage/optimized');
    } catch (error) {
      DebugLogger.log(
        'Failed to clear all storage: $error',
        scope: 'storage/optimized',
      );
      rethrow;
    }
  }

  Future<bool> isSecureStorageAvailable() async {
    return _secureCredentialStorage.isSecureStorageAvailable();
  }

  String? _normalizeServerId(String? serverId) {
    if (serverId == null || serverId.isEmpty) {
      return null;
    }
    return serverId;
  }

  ({bool hasCachedId, String? rawServerId}) _readActiveServerIdState() {
    if (_activeServerIdReadSuppressed) {
      return (hasCachedId: true, rawServerId: null);
    }
    final (hit: hasCachedId, value: cachedId) = _cacheManager.lookup<String>(
      _activeServerIdKey,
    );
    return (
      hasCachedId: hasCachedId,
      rawServerId: hasCachedId
          ? cachedId
          : PreferencesStore.getString(_activeServerIdKey),
    );
  }

  List<ServerConfig>? _readCachedServerConfigs() {
    if (_serverConfigsReadSuppressed) return const <ServerConfig>[];
    final (hit: hasCachedConfigs, value: cachedConfigs) = _cacheManager
        .lookup<List<ServerConfig>>(_serverConfigsCacheKey);
    return hasCachedConfigs ? cachedConfigs : null;
  }

  ({bool didValidate, String? serverId}) _validateServerIdAgainstConfigs(
    String? serverId,
    List<ServerConfig>? configs,
  ) {
    final normalizedServerId = _normalizeServerId(serverId);
    if (normalizedServerId == null) {
      return (didValidate: true, serverId: null);
    }
    if (configs == null) {
      return (didValidate: false, serverId: null);
    }

    final hasMatch = configs.any((config) => config.id == normalizedServerId);
    return (didValidate: true, serverId: hasMatch ? normalizedServerId : null);
  }

  String? _finalizeValidatedActiveServerId({
    required String? rawServerId,
    required ({bool didValidate, String? serverId}) validation,
    bool cacheWhenUnchanged = false,
  }) {
    if (!validation.didValidate) {
      return null;
    }

    final validatedServerId = validation.serverId;
    if (cacheWhenUnchanged || validatedServerId != rawServerId) {
      _cacheActiveServerId(validatedServerId);
    }
    return validatedServerId;
  }

  Future<String?> _resolveValidatedActiveServerIdUnlocked({
    required String? rawServerId,
    bool cacheWhenUnchanged = false,
  }) async {
    var validation = _validateServerIdAgainstConfigs(
      rawServerId,
      _readCachedServerConfigs(),
    );
    if (!validation.didValidate) {
      validation = _validateServerIdAgainstConfigs(
        rawServerId,
        await _getServerConfigsStrictRetryingUnlocked(),
      );
    }
    return _finalizeValidatedActiveServerId(
      rawServerId: rawServerId,
      validation: validation,
      cacheWhenUnchanged: cacheWhenUnchanged,
    );
  }

  T? _decodeJsonObject<T>(
    Object? stored,
    T? Function(Map<String, dynamic> json) fromJson,
  ) {
    final json = _decodeJsonMap(stored);
    if (json == null) {
      return null;
    }
    return fromJson(json);
  }

  Map<String, dynamic>? _decodeJsonMap(Object? stored) {
    if (stored is String) {
      final decoded = jsonDecode(stored);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return null;
    }
    if (stored is Map<String, dynamic>) {
      return stored;
    }
    if (stored is Map) {
      return Map<String, dynamic>.from(stored);
    }
    return null;
  }

  void _cacheServerConfigs(List<ServerConfig> configs) {
    _cacheManager.write('server_config_count', configs.length);
    _cacheManager.write(
      _serverConfigsCacheKey,
      List<ServerConfig>.unmodifiable(configs),
      ttl: _serverConfigsTtl,
    );
  }

  void _cacheActiveServerId(String? serverId) {
    _cacheManager.write(_activeServerIdKey, serverId, ttl: _serverIdTtl);
  }

  // ---------------------------------------------------------------------------
  // Cache helpers
  // ---------------------------------------------------------------------------
  void clearCache() {
    _cacheManager.clear();
    DebugLogger.log('Storage cache cleared', scope: 'storage/optimized');
  }

  SocketTransportAvailability? _transportFromJson(Map<String, dynamic> json) {
    try {
      return SocketTransportAvailability.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Legacy migration hooks (no-op)
  // ---------------------------------------------------------------------------
  Future<void> migrateFromLegacyStorage() async {
    try {
      DebugLogger.log(
        'Starting migration from legacy storage',
        scope: 'storage/optimized',
      );
      DebugLogger.log(
        'Legacy storage migration completed',
        scope: 'storage/optimized',
      );
    } catch (error) {
      DebugLogger.log(
        'Legacy storage migration failed: $error',
        scope: 'storage/optimized',
      );
    }
  }

  Map<String, dynamic> getStorageStats() {
    return _cacheManager.stats();
  }
}

List<Map<String, dynamic>> _decodeStoredJsonListWorker(
  Map<String, dynamic> payload,
) {
  final stored = payload['stored'];
  if (stored is String) {
    final decoded = jsonDecode(stored);
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    }
    return <Map<String, dynamic>>[];
  }

  if (stored is List) {
    return stored
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  return <Map<String, dynamic>>[];
}
