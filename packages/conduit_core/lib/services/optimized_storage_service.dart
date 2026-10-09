import 'dart:async';
import 'dart:convert';

import 'package:hive_ce/hive.dart';
import 'package:synchronized/synchronized.dart';
import 'package:conduit_core/conduit_core.dart';

import 'package:conduit_core/auth/openwebui_account_owner_marker.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/models/socket_transport_availability.dart';

import 'package:conduit_core/database/app_database.dart';

import '../persistence/hive_boxes.dart';
import '../persistence/persistence_keys.dart';
import '../persistence/preferences_store.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import '../utils/json_normalization.dart';
import 'cache_manager.dart';
import 'secure_credential_storage.dart';

import 'package:conduit_core/services/worker_manager.dart';

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

/// The registry as a transaction found it, and whether reads of it were
/// fenced then. A rollback puts back exactly this: rebuilding it from the
/// projected configs would lose what they do not carry, such as an
/// account's proven user and the ids of its server and routes.
typedef _RegistrySnapshot = ({
  OpenWebUiRegistry registry,
  bool readsSuppressed,
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

/// A saved sign-in, live for another account, that could not be filed
/// under that account.
final class _ForeignSignInNotFiled implements Exception {
  const _ForeignSignInNotFiled(this.error);

  final Object error;

  @override
  String toString() => 'Saved sign-in not filed under its account: $error';
}

/// What the vault slots a commit wrote or deleted held before it did, by
/// account id; null for a slot that was empty. A rollback puts back exactly
/// this, so an account that merely shared the commit's vault keeps its
/// session.
final class _VaultUndo {
  final Map<String, String?> tokens = <String, String?>{};
  final Map<String, String?> credentials = <String, String?>{};
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
/// SecureKeyValueStore for credentials.
class OptimizedStorageService {
  OptimizedStorageService({
    required SecureKeyValueStore secureStorage,
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

  /// Set once no read can migrate the one-server config list any more: a
  /// registry was found or written, or there was no list to move. Until then
  /// a config read may run the migration, which rewrites the saved sign-in,
  /// so it holds [_authStateLock] as well.
  bool _registryMigrationSettled = false;
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

  // What the last full wipe meant to leave stored, until a registry write
  // lands; see [_registryForWriteUnlocked]. Not a cache entry: it must not
  // expire while the old registry may still be stored.
  OpenWebUiRegistry? _registryLeftByWipe;

  static const String _authTokenKey = 'auth_token_v3';
  static const String _activeServerIdKey = PreferenceKeys.activeServerId;
  static const String _serverConfigsCacheKey = 'server_configs_v1';
  static const String _registryCacheKey = 'openwebui_registry_v1';
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

  /// Runs [write], and once more when it fails, as [_retrySecureStorageRead]
  /// does for a read. A second failure throws.
  Future<void> _retrySecureStorageWrite(
    Future<void> Function() write, {
    required String scope,
  }) async {
    try {
      return await write();
    } catch (error) {
      DebugLogger.warning(
        'secure-write-retrying',
        scope: scope,
        data: {'errorType': error.runtimeType.toString()},
      );
    }
    return write();
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

  // ---------------------------------------------------------------------
  // Per-server token vault
  // ---------------------------------------------------------------------

  /// Moves the session for [fromServerId] aside and takes up [toServerId]'s.
  ///
  /// One acquisition of [_authStateLock] for the whole exchange, not three.
  /// The steps are individually harmless and collectively not: a login that
  /// interleaved between the stash and the adopt would write a token for the
  /// old server that the adopt then overwrites, and the user would end up on
  /// the new server holding the old server's bearer.
  ///
  /// Returns whether [toServerId] has a session afterwards: a token, or a
  /// saved sign-in the caller can use silently. False means the caller must
  /// present a sign-in form, which is an honest outcome rather than a failure.
  Future<bool> switchActiveServer({
    String? fromServerId,
    required String toServerId,
  }) {
    return _authStateLock.synchronized(() async {
      // The caller read the active account before taking the lock. If another
      // account operation moved it since, the live session belongs to that
      // account, and filing it under [fromServerId] would hand one account's
      // bearer to another. A failed read refuses the switch too.
      //
      // The account the live session belongs to is the one storage treats as
      // active, which may be flagged active or the only one saved rather than
      // named by the active id. Checked against the stricter id, a caller
      // could pass none, skip the stash and lose that account's session.
      final (activeId, isSaved, configs) = await _serverConfigsLock
          .synchronized(() async {
            final configs = await _getServerConfigsStrictRetryingUnlocked();
            return (
              _effectiveActiveServerId(
                configs: configs,
                rawActiveServerId: _readActiveServerIdState().rawServerId,
              ),
              configs.any((config) => config.id == toServerId),
              configs,
            );
          });
      final callerIsCurrent =
          activeId == fromServerId ||
          // A first connection: the one saved server already counts as active
          // by storage's own fallback, which is the no-op case below.
          (fromServerId == null && activeId == toServerId);
      if (!callerIsCurrent) {
        throw StateError('The active account changed before the switch.');
      }
      // A switch queued behind a sign-out can name the account it removed.
      // Making that active would leave an active id that names nothing.
      if (!isSaved) {
        throw StateError('The account to switch to is not saved.');
      }
      final from = activeId;

      // Switching to the server already active must not disturb anything.
      // Without this the vault lookup below finds nothing -- correctly, since
      // this server's session is in the live slot, not the vault -- and the
      // "no session" branch deletes the very token that was live. Signing the
      // user out for re-selecting the server they are on is a quiet enough
      // failure that only a test asking for it would find it.
      if (from == toServerId) {
        // It may be active only by storage's fallback; name it, so the
        // stricter active id agrees. Its session is already the live one.
        if (_rawStoredActiveServerId() != toServerId) {
          await _setActiveServerIdUnlocked(toServerId);
        }
        final live = await _retrySecureStorageRead(
          () => _getAuthTokenStrictUnlocked(bypassReadSuppression: true),
          scope: 'storage/optimized/token-switch-noop',
        );
        if (live != null && live.isNotEmpty) return true;
        final credentials = _savedCredentialsReadSuppressed
            ? null
            : await _retrySecureStorageRead(
                _secureCredentialStorage.getSavedCredentialsPayloadStrict,
                scope: 'storage/optimized/credentials-switch-noop',
              );
        if (credentials != null && credentials.isNotEmpty) {
          if ((_savedCredentialsServerId(credentials) ?? toServerId) ==
              toServerId) {
            return true;
          }
          // A saved sign-in from before accounts existed can name another
          // account. It is not this one's session; filed under its own, it
          // is not lost when this one's is taken up below.
          await _fileForeignSavedCredentialsUnlocked(toServerId, configs);
        }
        // Nothing live, but the account may have been left active with its
        // session still in the vault, by a switch that failed part-way. Take
        // it up rather than leave it for the next switch away to drop.
        return _adoptVaultedSessionUnlocked(toServerId);
      }

      // Read what the next account has filed away before anything changes.
      // A vault that cannot be read then refuses the switch with both
      // accounts as they were, rather than leaving the next one active and
      // signed out with its session still filed away, for the next switch
      // away from it to drop.
      var vaulted = await _readVaultedSessionUnlocked(toServerId);
      if (from != null) {
        // Copy before clearing, so the worst case is a session in two places
        // rather than one lost to a crash mid-switch. The adopt below removes
        // the vault copy, reconciling it.
        final filed = await _stashLiveSessionUnlocked(from);
        // A saved sign-in from before accounts existed can name the next
        // account; the stash has just filed it there.
        if (filed != null && filed.owner == toServerId) {
          vaulted = (token: vaulted.token, credentials: filed.credentials);
        }
        // The live sign-in belongs to the account being left. Drop it before
        // the active id moves, so a crash here cannot leave it live under
        // the new account.
        await _deleteSavedCredentialsUnlocked();
      }

      await _setActiveServerIdUnlocked(toServerId);
      return _adoptVaultedSessionUnlocked(toServerId, vaulted: vaulted);
    });
  }

  /// Copies the live token and saved sign-in into the vault of the account
  /// they belong to, replacing whatever that vault held.
  ///
  /// A copy: the live slots are left for the caller to clear. Absent or
  /// fenced values are not copied (an entry would read as "signed in"), and
  /// any older vault copy is dropped instead, so the vault never holds a
  /// session the live slots had already given up. Returns the saved sign-in
  /// it filed, with the account it was filed under.
  Future<({String owner, String credentials})?> _stashLiveSessionUnlocked(
    String accountId,
  ) async {
    final token = _authTokenReadSuppressed
        ? null
        : await _retrySecureStorageRead(
            () => _getAuthTokenStrictUnlocked(bypassReadSuppression: true),
            scope: 'storage/optimized/token-stash',
          );
    if (token != null && token.isNotEmpty) {
      await _secureCredentialStorage.saveServerToken(accountId, token);
    } else {
      await _secureCredentialStorage.deleteServerToken(accountId);
    }

    final credentials = _savedCredentialsReadSuppressed
        ? null
        : await _retrySecureStorageRead(
            _secureCredentialStorage.getSavedCredentialsPayloadStrict,
            scope: 'storage/optimized/credentials-stash',
          );
    // A saved sign-in names its own account. Before accounts existed one
    // could outlive a server change; file it under that account, not this one.
    final credentialsOwner =
        _savedCredentialsServerId(credentials) ?? accountId;
    if (credentials != null && credentials.isNotEmpty) {
      await _secureCredentialStorage.saveServerCredentialsPayload(
        credentialsOwner,
        credentials,
      );
    }
    if (credentialsOwner != accountId ||
        credentials == null ||
        credentials.isEmpty) {
      await _secureCredentialStorage.deleteServerCredentials(accountId);
    }
    return credentials == null || credentials.isEmpty
        ? null
        : (owner: credentialsOwner, credentials: credentials);
  }

  /// [accountId]'s vaulted token and saved sign-in.
  Future<({String? token, String? credentials})> _readVaultedSessionUnlocked(
    String accountId,
  ) async => (
    token: await _retrySecureStorageRead(
      () => _secureCredentialStorage.getServerToken(accountId),
      scope: 'storage/optimized/token-adopt',
    ),
    credentials: await _retrySecureStorageRead(
      () => _secureCredentialStorage.getServerCredentialsPayload(accountId),
      scope: 'storage/optimized/credentials-adopt',
    ),
  );

  /// Moves [accountId]'s vaulted token and saved sign-in into the live slots,
  /// emptying them when it has none. Returns whether either was there.
  /// [vaulted] is what the vault held, when the caller read it already.
  Future<bool> _adoptVaultedSessionUnlocked(
    String accountId, {
    ({String? token, String? credentials})? vaulted,
  }) async {
    final (:token, :credentials) =
        vaulted ?? await _readVaultedSessionUnlocked(accountId);
    final hasToken = token != null && token.isNotEmpty;
    final hasCredentials = credentials != null && credentials.isNotEmpty;

    // The saved sign-in first. With the token taken up and the sign-in not,
    // the account would be signed in with its sign-in fenced, and the next
    // switch away would drop the copy still in its vault. Without the token,
    // choosing the account again takes up both.
    if (hasCredentials) {
      await _secureCredentialStorage.restoreSavedCredentialsPayload(
        credentials,
      );
      _savedCredentialsReadSuppressed = false;
      _cacheManager.write('has_credentials', true, ttl: _credentialsFlagTtl);
    } else {
      await _deleteSavedCredentialsUnlocked();
    }
    if (hasToken) {
      await _saveAuthTokenUnlocked(token);
    } else {
      await _deleteAuthTokenUnlocked();
    }

    // A session lives in exactly one place. A stale vault copy is how a
    // revoked session comes back.
    if (hasToken) await _secureCredentialStorage.deleteServerToken(accountId);
    if (hasCredentials) {
      await _secureCredentialStorage.deleteServerCredentials(accountId);
    }
    return hasToken || hasCredentials;
  }

  /// Drops [accountId]'s vaulted session, if any.
  Future<void> _deleteVaultedSessionUnlocked(String accountId) async {
    await _secureCredentialStorage.deleteServerToken(accountId);
    await _secureCredentialStorage.deleteServerCredentials(accountId);
  }

  /// Before a commit replaces the live slots for [targetAccountId], files
  /// what they hold for any other account in that account's vault, so signing
  /// in to one account never signs another out. Each vault slot it writes is
  /// recorded in [undo] first, for a rollback to restore.
  Future<void> _stashForeignSessionUnlocked({
    required String targetAccountId,
    required String? previousActiveId,
    required _VaultUndo undo,
  }) async {
    if (previousActiveId != null &&
        previousActiveId != targetAccountId &&
        !_authTokenReadSuppressed) {
      final token = await _retrySecureStorageRead(
        () => _getAuthTokenStrictUnlocked(bypassReadSuppression: true),
        scope: 'storage/optimized/token-stash',
      );
      if (token != null && token.isNotEmpty) {
        await _rememberVaultedTokenUnlocked(undo, previousActiveId);
        await _secureCredentialStorage.saveServerToken(previousActiveId, token);
      }
    }
    if (!_savedCredentialsReadSuppressed) {
      final payload = await _retrySecureStorageRead(
        _secureCredentialStorage.getSavedCredentialsPayloadStrict,
        scope: 'storage/optimized/credentials-stash',
      );
      final owner = _savedCredentialsServerId(payload) ?? previousActiveId;
      if (payload != null &&
          payload.isNotEmpty &&
          owner != null &&
          owner != targetAccountId) {
        await _rememberVaultedCredentialsUnlocked(undo, owner);
        await _secureCredentialStorage.saveServerCredentialsPayload(
          owner,
          payload,
        );
      }
    }
  }

  /// Before the live slots are emptied for [accountId], files a saved
  /// sign-in they hold for another saved account under that account, as a
  /// switch would. Before accounts existed one could outlive a server change,
  /// and the account it names is still signed in. Returns what it filed,
  /// with the account it was filed under.
  ///
  /// The vault slot it writes is recorded in [undo] first, when given.
  Future<({String owner, String credentials})?>
  _fileForeignSavedCredentialsUnlocked(
    String accountId,
    Iterable<ServerConfig> configs, {
    _VaultUndo? undo,
  }) async {
    if (_savedCredentialsReadSuppressed) return null;
    final payload = await _retrySecureStorageRead(
      _secureCredentialStorage.getSavedCredentialsPayloadStrict,
      scope: 'storage/optimized/credentials-stash',
    );
    final owner = _savedCredentialsServerId(payload);
    if (payload == null ||
        payload.isEmpty ||
        owner == null ||
        owner == accountId ||
        !configs.any((config) => config.id == owner)) {
      return null;
    }
    if (undo != null) await _rememberVaultedCredentialsUnlocked(undo, owner);
    try {
      await _secureCredentialStorage.saveServerCredentialsPayload(
        owner,
        payload,
      );
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(_ForeignSignInNotFiled(error), stackTrace);
    }
    return (owner: owner, credentials: payload);
  }

  /// Drops [accountId]'s vaulted session, recording it in [undo] first.
  Future<void> _deleteVaultedSessionUndoablyUnlocked(
    String accountId,
    _VaultUndo undo,
  ) async {
    await _rememberVaultedTokenUnlocked(undo, accountId);
    await _rememberVaultedCredentialsUnlocked(undo, accountId);
    await _deleteVaultedSessionUnlocked(accountId);
  }

  /// Records what [accountId]'s vaulted token is before the first change.
  /// A failed read throws: a slot that could not be read must not be
  /// restored as empty.
  Future<void> _rememberVaultedTokenUnlocked(
    _VaultUndo undo,
    String accountId,
  ) async {
    if (undo.tokens.containsKey(accountId)) return;
    undo.tokens[accountId] = await _retrySecureStorageRead(
      () => _secureCredentialStorage.getServerToken(accountId),
      scope: 'storage/optimized/vault-undo',
    );
  }

  Future<void> _rememberVaultedCredentialsUnlocked(
    _VaultUndo undo,
    String accountId,
  ) async {
    if (undo.credentials.containsKey(accountId)) return;
    undo.credentials[accountId] = await _retrySecureStorageRead(
      () => _secureCredentialStorage.getServerCredentialsPayload(accountId),
      scope: 'storage/optimized/vault-undo',
    );
  }

  /// Undoes a failed commit's vault writes and deletions. The live slots are
  /// restored by the rollback itself; a stash copy left behind would put one
  /// session in two places, and a deletion left standing would sign an
  /// account out for an attempt that never happened.
  Future<void> _restoreVaultUnlocked(_VaultUndo undo) async {
    Future<void> restore(Future<void> Function() write) async {
      try {
        await _retrySecureStorageWrite(
          write,
          scope: 'storage/optimized/vault-restore',
        );
      } catch (error, stackTrace) {
        // The live session was restored; only an account kept aside may now
        // read as signed out, as the account list then shows it. That is
        // not worth signing the user out of the live one, which the
        // rollback-uncertain path would.
        DebugLogger.error(
          'vault-restore-failed',
          scope: 'storage/optimized',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    for (final MapEntry(key: accountId, value: prior) in undo.tokens.entries) {
      await restore(
        () => prior == null || prior.isEmpty
            ? _secureCredentialStorage.deleteServerToken(accountId)
            : _secureCredentialStorage.saveServerToken(accountId, prior),
      );
    }
    for (final MapEntry(key: accountId, value: prior)
        in undo.credentials.entries) {
      await restore(
        () => prior == null || prior.isEmpty
            ? _secureCredentialStorage.deleteServerCredentials(accountId)
            : _secureCredentialStorage.saveServerCredentialsPayload(
                accountId,
                prior,
              ),
      );
    }
  }

  /// Empties the vault, tokens and saved sign-ins alike. Sign-out calls
  /// this; see [SecureCredentialStorage.deleteAllServerTokens].
  Future<void> clearTokenVault() => _authStateLock.synchronized(() async {
    await _secureCredentialStorage.deleteAllServerTokens();
    await _secureCredentialStorage.deleteAllServerCredentials();
  });

  /// Server ids holding a vaulted session, for the UI's "signed in" markers.
  Future<Set<String>> vaultedServerIds() =>
      _secureCredentialStorage.vaultedServerIds();

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
    return _authStateLock.synchronized(() async {
      await _settleRegistryMigrationUnlocked();
      return _retrySecureStorageRead(
        _getSavedCredentialsStrictUnlocked,
        scope: 'storage/optimized/credentials',
      );
    });
  }

  /// Runs the registry migration, when it is still due, before a saved
  /// sign-in is read. The migration moves a sign-in whose account collapsed
  /// into another; read before it, the sign-in names an account the
  /// migration then drops, and the silent sign-in started from it finds no
  /// server. Call with [_authStateLock] held and [_serverConfigsLock] not.
  Future<void> _settleRegistryMigrationUnlocked() async {
    if (_registryMigrationSettled) return;
    await _serverConfigsLock.synchronized(
      () => _retrySecureStorageRead(
        _registryForWriteUnlocked,
        scope: 'storage/optimized/server-configs',
      ),
    );
  }

  Future<Map<String, String>?> _getSavedCredentialsUnlocked() async {
    if (_savedCredentialsReadSuppressed) return null;
    try {
      await _settleRegistryMigrationUnlocked();
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
        // Judge ownership by what the save will store, not by what was passed:
        // accounts on one server share its endpoint, so an edit made through
        // one account moves every other account on that server too.
        final nextConfigs = (await _registryForWriteUnlocked())
            .mergeServerConfigs(sanitizedConfigs)
            .projectAll();
        final rawActiveServerId = _rawStoredActiveServerId();
        final currentActiveId = _effectiveActiveServerId(
          configs: currentConfigs,
          rawActiveServerId: rawActiveServerId,
        );
        final nextActiveId = _effectiveActiveServerId(
          configs: nextConfigs,
          rawActiveServerId: rawActiveServerId,
        );
        final currentActive = currentConfigs
            .where((config) => config.id == currentActiveId)
            .firstOrNull;
        final nextActive = nextConfigs
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
          final nextCredentialConfig = nextConfigs
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
        // The same holds for sessions kept aside, the active account's
        // included: a switch that failed part-way can leave its session in
        // the vault, where selecting it again takes that session up.
        await _dropVaultedSessionsOfMovedAccountsUnlocked(
          current: currentConfigs,
          next: nextConfigs,
        );
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

  /// Drops the session kept aside for each account in [current] whose
  /// server moves in [next] -- through its own edit or another account's on
  /// the same server -- or that [next] no longer has: it must not take its
  /// old bearer to the new origin. [next] is what the save will store, not
  /// what was passed to it, since accounts on one server share its endpoint.
  /// [skip] keeps its vault; [undo] records what went, for a rollback.
  Future<void> _dropVaultedSessionsOfMovedAccountsUnlocked({
    required List<ServerConfig> current,
    required List<ServerConfig> next,
    String? skip,
    _VaultUndo? undo,
  }) async {
    for (final account in current) {
      if (account.id == skip) continue;
      final moved = next
          .where((config) => config.id == account.id)
          .firstOrNull;
      if (moved != null &&
          _hasSameServerSessionOwnershipIdentity(account, moved)) {
        continue;
      }
      if (undo == null) {
        await _deleteVaultedSessionUnlocked(account.id);
      } else {
        await _deleteVaultedSessionUndoablyUnlocked(account.id, undo);
      }
    }
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

  /// What a sign-out that keeps server details keeps of [registry]: every
  /// server with all its routes in order, their URLs, labels and certificate
  /// policy, and every account, no longer proven to be anyone and without
  /// captured cookies. Custom headers and client identities are secrets and
  /// go. Built from the registry, not from its projections, which carry only
  /// the route each account is using.
  OpenWebUiRegistry _retainNonSecretServerDetails(OpenWebUiRegistry registry) {
    return OpenWebUiRegistry(
      servers: [
        for (final server in registry.servers)
          OpenWebUiServer(
            id: server.id,
            name: server.name,
            endpoints: [
              for (final endpoint in server.endpoints)
                OpenWebUiEndpoint(
                  id: endpoint.id,
                  url: endpoint.url,
                  label: endpoint.label,
                  allowSelfSignedCertificates:
                      endpoint.allowSelfSignedCertificates,
                ),
            ],
          ),
      ],
      accounts: [
        for (final account in registry.accounts)
          OpenWebUiAccount(
            id: account.id,
            serverId: account.serverId,
            isActive: account.isActive,
            lastConnected: account.lastConnected,
          ),
      ],
    );
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

  /// Makes [config] the active account for a fresh sign-in without ever
  /// pairing the prior account's bearer token with the new origin.
  ///
  /// Other saved accounts stay: the account being left keeps its session in
  /// its vault, so adding an account never signs another out. Only accounts
  /// with nothing behind them -- an earlier sign-in that was abandoned before
  /// it proved a user or saved a session -- are dropped, along with any
  /// session [config]'s own id still had vaulted, since it is being signed
  /// in to afresh.
  ///
  /// Token deletion is the first durable write after the stash. Any crash or
  /// later storage failure therefore leaves either the old ownership or the
  /// new ownership without a live bearer token. Explicit candidate custom
  /// headers remain available for this sign-in attempt; logout later revokes
  /// captured proxy Cookie headers while preserving user-configured
  /// connection headers.
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
        final previousRegistry = await _snapshotRegistryUnlocked();
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
        final previousActiveId = _effectiveActiveServerId(
          configs: previousConfigs,
          rawActiveServerId: previousActiveServerId,
        );
        final registry = await _registryForWriteUnlocked();
        final vaulted = await _secureCredentialStorage.vaultedServerIds();
        if (!ownsAttempt()) return false;
        final previousHasLiveSession =
            (previousToken != null && previousToken.isNotEmpty) ||
            (previousCredentialsPayload != null &&
                previousCredentialsPayload.isNotEmpty);
        // A saved sign-in from before accounts existed can name another
        // account than the active one; that account has it behind it.
        final liveSignInOwner = _savedCredentialsServerId(
          previousCredentialsPayload,
        );
        bool abandoned(ServerConfig candidate) =>
            registry.account(candidate.id)?.userId == null &&
            !vaulted.contains(candidate.id) &&
            candidate.id != liveSignInOwner &&
            (candidate.id != previousActiveId || !previousHasLiveSession);
        final nextConfigs = <ServerConfig>[
          for (final existing in previousConfigs)
            if (existing.id != selected.id && !abandoned(existing))
              existing.copyWith(isActive: false),
          selected,
        ];

        final previousStage = _stagedServerConfigCandidate;
        var persistenceStarted = false;
        final vaultUndo = _VaultUndo();
        try {
          persistenceStarted = true;
          // Even when re-selecting the active account: the saved sign-in
          // can be another account's, from before accounts existed. The
          // account's own session is not filed; it is signed in to afresh.
          await _stashForeignSessionUnlocked(
            targetAccountId: selected.id,
            previousActiveId: previousActiveId,
            undo: vaultUndo,
          );
          if (!ownsAttempt()) throw const _StagedAuthAttemptSuperseded();
          if (vaulted.contains(selected.id)) {
            await _deleteVaultedSessionUndoablyUnlocked(
              selected.id,
              vaultUndo,
            );
            if (!ownsAttempt()) throw const _StagedAuthAttemptSuperseded();
          }
          // Selecting an account with its server edited moves every account
          // on that server, the one just filed away included.
          await _dropVaultedSessionsOfMovedAccountsUnlocked(
            current: registry.projectAll(),
            next: registry.mergeServerConfigs(nextConfigs).projectAll(),
            skip: selected.id,
            undo: vaultUndo,
          );

          await _deleteAuthTokenUnlocked();
          if (!ownsAttempt()) throw const _StagedAuthAttemptSuperseded();

          await _deleteSavedCredentialsUnlocked();
          if (!ownsAttempt()) throw const _StagedAuthAttemptSuperseded();

          // The candidate's headers were explicitly supplied and already used
          // to verify this connection. Keep that exact candidate material long
          // enough to complete sign-in, while never merging baseline headers.
          await _saveServerConfigsUnlocked(nextConfigs);
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
            await _restoreVaultUnlocked(vaultUndo);
            try {
              await _restoreServerSessionUnlocked(
                registry: previousRegistry,
                activeServerId: previousActiveServerId,
                token: previousToken,
                restoreCredentials: true,
                credentialsPayload: previousCredentialsPayload,
                credentialsReadSuppressed: previousCredentialsReadSuppressed,
              );
              _stagedServerConfigCandidate = previousStage;
            } catch (rollbackError, rollbackStackTrace) {
              await _bestEffortFailClosedServerSessionRestoreUnlocked(
                registry: previousRegistry,
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
            await _restoreVaultUnlocked(vaultUndo);
            try {
              if (commitError is ServerConfigSessionRollbackException) {
                await _restoreTokenlessSanitizedServerSessionUnlocked(
                  registry: previousRegistry,
                  activeServerId: previousActiveServerId,
                );
                _notifyRollbackUncertainSafely(onRollbackUncertain);
              } else {
                await _restoreServerSessionUnlocked(
                  registry: previousRegistry,
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
                registry: previousRegistry,
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

  /// Saves [configs] as the complete account list.
  ///
  /// The registry is the stored form; [configs] are folded into it by
  /// [OpenWebUiRegistry.mergeServerConfigs], which keeps every account's
  /// server, its other endpoints and its proven user while applying the
  /// edits the configs carry.
  Future<void> _saveServerConfigsUnlocked(
    List<ServerConfig> configs, {
    bool authorizeReads = true,
  }) async {
    try {
      final base = await _registryForWriteUnlocked();
      await _saveRegistryUnlocked(
        base.mergeServerConfigs(configs),
        authorizeReads: authorizeReads,
      );
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
        final previousRegistry = await _snapshotRegistryUnlocked();
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

        // The live saved sign-in belongs to the committed account afterwards.
        // A non-remembered login deletes it; silent login is the sole path
        // that retains an exact expected payload. One left behind by another
        // account is filed in that account's vault first. Snapshot
        // unconditionally so any later failure can restore the complete prior
        // transaction.
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
        final vaultUndo = _VaultUndo();
        try {
          persistenceStarted = true;
          await _stashForeignSessionUnlocked(
            targetAccountId: targetConfig.id,
            previousActiveId: _effectiveActiveServerId(
              configs: previousConfigs,
              rawActiveServerId: previousActiveServerId,
            ),
            undo: vaultUndo,
          );
          if (!canCommit()) throw const _StagedAuthAttemptSuperseded();

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
            await _restoreVaultUnlocked(vaultUndo);
            try {
              await _restoreServerSessionUnlocked(
                registry: previousRegistry,
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
                registry: previousRegistry,
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
            await _restoreVaultUnlocked(vaultUndo);
            try {
              if (commitError is ServerConfigSessionRollbackException) {
                // The non-secret logout fence itself could not be restored.
                // Never resurrect a previous bearer, saved credential, or
                // proxy Cookie under a possibly-cleared fence.
                await _restoreTokenlessSanitizedServerSessionUnlocked(
                  registry: previousRegistry,
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
                  registry: previousRegistry,
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
                registry: previousRegistry,
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

  String _normalizedServerIdentityUrl(String value) =>
      openWebUiServerIdentityUrl(value);

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

        late final _RegistrySnapshot previousRegistry;
        String? previousToken;
        String? previousCredentialsPayload;
        var previousCredentialsReadSuppressed = false;
        var persistenceStarted = false;
        final vaultUndo = _VaultUndo();
        try {
          // This strict snapshot occurs inside the auth lock and before the
          // first write. A transient Keychain failure must abort the commit,
          // never masquerade as a missing prior session during rollback.
          previousRegistry = await _snapshotRegistryUnlocked();
          previousToken = await _getAuthTokenStrictUnlocked();
          if (!canCommit()) throw const _StagedAuthAttemptSuperseded();
          previousCredentialsReadSuppressed = _savedCredentialsReadSuppressed;
          previousCredentialsPayload = previousCredentialsReadSuppressed
              ? null
              : await _secureCredentialStorage
                    .getSavedCredentialsPayloadStrict();
          if (!canCommit()) throw const _StagedAuthAttemptSuperseded();

          persistenceStarted = true;
          // The previous account stays signed in: its session moves to its
          // vault before the live slots are handed to the candidate.
          await _stashForeignSessionUnlocked(
            targetAccountId: candidate.id,
            previousActiveId: staged.baselineActiveServerId,
            undo: vaultUndo,
          );
          if (!canCommit()) throw const _StagedAuthAttemptSuperseded();
          // A candidate can keep a saved account's id with its server moved,
          // which moves every account on that server.
          await _dropVaultedSessionsOfMovedAccountsUnlocked(
            current: previousRegistry.registry.projectAll(),
            next: previousRegistry.registry
                .mergeServerConfigs(committedConfigs)
                .projectAll(),
            undo: vaultUndo,
          );

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
            await _restoreVaultUnlocked(vaultUndo);
            try {
              await _restoreStagedServerConfigSessionUnlocked(
                staged: staged,
                previousRegistry: previousRegistry,
                previousToken: previousToken,
                previousCredentialsPayload: previousCredentialsPayload,
                previousCredentialsReadSuppressed:
                    previousCredentialsReadSuppressed,
              );
            } catch (rollbackError, rollbackStackTrace) {
              await _bestEffortFailClosedServerSessionRestoreUnlocked(
                registry: previousRegistry,
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
            await _restoreVaultUnlocked(vaultUndo);
            try {
              if (commitError is ServerConfigSessionRollbackException) {
                await _restoreTokenlessSanitizedServerSessionUnlocked(
                  registry: previousRegistry,
                  activeServerId: staged.baselineActiveServerId,
                );
                _notifyRollbackUncertainSafely(onRollbackUncertain);
              } else {
                await _restoreStagedServerConfigSessionUnlocked(
                  staged: staged,
                  previousRegistry: previousRegistry,
                  previousToken: previousToken,
                  previousCredentialsPayload: previousCredentialsPayload,
                  previousCredentialsReadSuppressed:
                      previousCredentialsReadSuppressed,
                );
              }
            } catch (rollbackError, rollbackStackTrace) {
              await _bestEffortFailClosedServerSessionRestoreUnlocked(
                registry: previousRegistry,
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
    required _RegistrySnapshot previousRegistry,
    required String? previousToken,
    required String? previousCredentialsPayload,
    required bool previousCredentialsReadSuppressed,
  }) {
    return _restoreServerSessionUnlocked(
      registry: previousRegistry,
      activeServerId: staged.baselineActiveServerId,
      token: previousToken,
      restoreCredentials: true,
      credentialsPayload: previousCredentialsPayload,
      credentialsReadSuppressed: previousCredentialsReadSuppressed,
    );
  }

  Future<void> _restoreServerSessionUnlocked({
    required _RegistrySnapshot registry,
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
        await _restoreRegistryUnlocked(registry);
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
  /// cannot be restored. Deleting auth secrets is the first prefix; the
  /// registry is then restored without the proxy cookies its accounts
  /// captured (it never stores a legacy bearer).
  Future<void> _restoreTokenlessSanitizedServerSessionUnlocked({
    required _RegistrySnapshot registry,
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
    final sanitized = (
      registry: registry.registry.withoutCapturedHeaders(),
      readsSuppressed: registry.readsSuppressed,
    );
    await attempt(
      () => _restoreServerSessionUnlocked(
        registry: sanitized,
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
    required _RegistrySnapshot registry,
    required String? activeServerId,
  }) async {
    try {
      await _restoreTokenlessSanitizedServerSessionUnlocked(
        registry: registry,
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

  /// The account storage treats as active as reads see it, the way
  /// [_setActiveServerIdUnlocked] decides whose live session a change ends.
  /// A failed read propagates.
  Future<String?> _effectiveActiveServerIdUnlocked() async =>
      _effectiveActiveServerId(
        configs: await _getServerConfigsStrictRetryingUnlocked(),
        rawActiveServerId: _readActiveServerIdState().rawServerId,
      );

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

  // ---------------------------------------------------------------------------
  // Accounts
  // ---------------------------------------------------------------------------

  /// The saved servers and accounts. Strict: a Keychain failure propagates
  /// rather than reading as "nothing saved".
  Future<OpenWebUiRegistry> getOpenWebUiRegistryStrict() =>
      _synchronizedServerConfigsRead(
        () => _retrySecureStorageRead(
          _getRegistryStrictUnlocked,
          scope: 'storage/optimized/registry',
        ),
      );

  /// Records that [accountId] is [userId]'s account, once a sign-in to it
  /// has been proved. Not an ownership change; see [_saveRegistryUnlocked].
  Future<void> bindAccountUser(String accountId, String userId) {
    final normalized = userId.trim();
    if (normalized.isEmpty) return Future<void>.value();
    // Its read can run the migration too.
    return _synchronizedServerConfigsRead(() async {
      final registry = await _registryForWriteUnlocked();
      final account = registry.account(accountId);
      if (account == null || account.userId == normalized) return;
      await _saveRegistryUnlocked(
        registry.withAccount(account.copyWith(userId: normalized)),
        authorizeReads: !_serverConfigsReadSuppressed,
        ownershipChanged: false,
      );
    });
  }

  /// The token vaulted for [accountId], an account that is not active, so it
  /// can be revoked on the server when signing out of that account.
  Future<String?> vaultedTokenFor(String accountId) =>
      _authStateLock.synchronized(
        () => _retrySecureStorageRead(
          () => _secureCredentialStorage.getServerToken(accountId),
          scope: 'storage/optimized/token-vault-read',
        ),
      );

  /// The tokens kept in the vault for [accountIds] (every account when
  /// null), each with the config of the server it was kept for.
  ///
  /// Read together, under the locks a server edit takes: an edit that moves
  /// an account drops its token, which must never go to where the edit
  /// points.
  Future<List<({ServerConfig config, String token})>> vaultedSessions({
    Set<String>? accountIds,
  }) {
    return _authStateLock.synchronized(
      () => _serverConfigsLock.synchronized(() async {
        final registry = await _retrySecureStorageRead(
          _getRegistryStrictUnlocked,
          scope: 'storage/optimized/registry',
        );
        final sessions = <({ServerConfig config, String token})>[];
        for (final account in registry.accounts) {
          if (accountIds != null && !accountIds.contains(account.id)) continue;
          final config = registry.project(account.id);
          if (config == null) continue;
          final token = await _retrySecureStorageRead(
            () => _secureCredentialStorage.getServerToken(account.id),
            scope: 'storage/optimized/token-vault-read',
          );
          if (token != null && token.isNotEmpty) {
            sessions.add((config: config, token: token));
          }
        }
        return sessions;
      }),
    );
  }

  /// Ids of accounts holding a session somewhere: the active one when its
  /// live slots do, and every account with something vaulted.
  Future<Set<String>> accountIdsWithSession() {
    return _authStateLock.synchronized(
      () => _serverConfigsLock.synchronized(() async {
        final configs = await _getServerConfigsStrictUnlocked(
          bypassReadSuppression: true,
        );
        final active = _effectiveActiveServerId(
          configs: configs,
          rawActiveServerId: _rawStoredActiveServerId(
            bypassReadSuppression: true,
          ),
        );
        return _accountIdsWithSessionUnlocked(active);
      }),
    );
  }

  /// [accountIdsWithSession], with [active] the account the live slots
  /// belong to.
  Future<Set<String>> _accountIdsWithSessionUnlocked(String? active) async {
    final ids = await _secureCredentialStorage.vaultedServerIds();
    if (active != null) {
      final token = _authTokenReadSuppressed
          ? null
          : await _getAuthTokenStrictUnlocked(bypassReadSuppression: true);
      final credentials = _savedCredentialsReadSuppressed
          ? null
          : await _secureCredentialStorage.getSavedCredentialsPayloadStrict();
      if (token?.isNotEmpty ?? false) ids.add(active);
      // A saved sign-in names its own account. From before accounts
      // existed, that can be another one than the active.
      if (credentials?.isNotEmpty ?? false) {
        ids.add(_savedCredentialsServerId(credentials) ?? active);
      }
    }
    return ids;
  }

  /// Forgets [accountId]: its live or vaulted session and saved sign-in, its
  /// record, and its server once no account is left on it.
  ///
  /// When it is the active account, [thenActivate] becomes active and takes
  /// up its vaulted session; without one the active id is cleared. Returns
  /// whether the newly active account has a session to restore. Purging the
  /// account's local data is the caller's job, after this returns.
  Future<bool> removeAccount(String accountId, {String? thenActivate}) async =>
      await _removeAccount(accountId, thenActivate: thenActivate) ?? false;

  /// Forgets [accountId] as [removeAccount] does, unless it is the active
  /// account: then it changes nothing and returns false.
  ///
  /// Deciding that under the same locks as the removal is what keeps a
  /// switch to it from landing in between, after which its live session
  /// would be deleted with nobody told.
  Future<bool> removeInactiveAccount(String accountId) async =>
      await _removeAccount(accountId, onlyIfInactive: true) != null;

  /// Forgets [accountId] as [removeAccount] does, handing over to
  /// [thenActivate], only while it is the active account and has never
  /// signed in: no user proven for it, and no live, saved or vaulted
  /// session. Otherwise it changes nothing and returns null.
  ///
  /// Deciding that under the same locks as the removal, which a sign-in
  /// commits under too, is what keeps a sign-in from landing in between,
  /// after which its session would be deleted with the account. Returns
  /// whether [thenActivate] has a session to restore.
  Future<bool?> removePendingAccount(
    String accountId, {
    required String thenActivate,
  }) => _removeAccount(
    accountId,
    thenActivate: thenActivate,
    onlyIfPending: true,
  );

  /// Null when [onlyIfInactive] or [onlyIfPending] declined.
  Future<bool?> _removeAccount(
    String accountId, {
    String? thenActivate,
    bool onlyIfInactive = false,
    bool onlyIfPending = false,
  }) {
    return _authStateLock.synchronized(
      () => _serverConfigsLock.synchronized(() async {
        final configs = await _getServerConfigsStrictUnlocked(
          bypassReadSuppression: true,
        );
        final rawActive = _rawStoredActiveServerId(bypassReadSuppression: true);
        final wasActive =
            _effectiveActiveServerId(
              configs: configs,
              rawActiveServerId: rawActive,
            ) ==
            accountId;
        if (wasActive && onlyIfInactive) return null;
        if (onlyIfPending) {
          if (!wasActive) return null;
          // The account to hand over to must be another one, and may have
          // been removed meanwhile.
          if (thenActivate == accountId ||
              !configs.any((config) => config.id == thenActivate)) {
            return null;
          }
          final registry = await _getRegistryStrictUnlocked(
            bypassReadSuppression: true,
          );
          if (registry.account(accountId)?.userId != null) return null;
          final withSession = await _accountIdsWithSessionUnlocked(accountId);
          if (withSession.contains(accountId)) return null;
        }
        // One removed since the caller chose it is none: an active id that
        // named it would name no account.
        final next =
            thenActivate != null &&
                thenActivate != accountId &&
                configs.any((config) => config.id == thenActivate)
            ? thenActivate
            : null;
        // Read before anything changes: once this account is gone, a read
        // that fails could not be retried from it. So is what a failure
        // part-way puts back.
        var nextSession = wasActive && next != null
            ? await _readVaultedSessionUnlocked(next)
            : null;
        final previousRegistry = await _snapshotRegistryUnlocked();
        final previousToken = wasActive && !_authTokenReadSuppressed
            ? await _retrySecureStorageRead(
                () => _getAuthTokenStrictUnlocked(bypassReadSuppression: true),
                scope: 'storage/optimized/removal-undo',
              )
            : null;
        final previousCredentialsReadSuppressed =
            _savedCredentialsReadSuppressed;
        final previousCredentialsPayload = previousCredentialsReadSuppressed
            ? null
            : await _retrySecureStorageRead(
                _secureCredentialStorage.getSavedCredentialsPayloadStrict,
                scope: 'storage/optimized/removal-undo',
              );
        final vaultUndo = _VaultUndo();
        if (next != null && nextSession != null) {
          // Taken up below, and filed to first when the live sign-in is its.
          vaultUndo.tokens[next] = nextSession.token;
          vaultUndo.credentials[next] = nextSession.credentials;
        }

        var liveCredentialsChanged = false;
        var registryWritten = false;
        var activeIdWritten = false;
        try {
          if (wasActive) {
            final filed = await _fileForeignSavedCredentialsUnlocked(
              accountId,
              configs,
              undo: vaultUndo,
            );
            if (nextSession != null && filed?.owner == next) {
              // Filed under the account taking over, which takes it up.
              nextSession = (
                token: nextSession.token,
                credentials: filed!.credentials,
              );
            }
            liveCredentialsChanged = true;
            await _deleteAuthTokenUnlocked();
            await _deleteSavedCredentialsUnlocked();
          } else if (_savedCredentialsServerId(previousCredentialsPayload) ==
              accountId) {
            // From before accounts existed: this account's sign-in, live
            // while another is active. It goes with the account.
            liveCredentialsChanged = true;
            await _deleteSavedCredentialsUnlocked();
          }
          await _deleteVaultedSessionUndoablyUnlocked(accountId, vaultUndo);
          _stagedServerConfigCandidate = null;

          final remaining = [
            for (final config in configs)
              if (config.id != accountId)
                config.copyWith(
                  // Removing an inactive account leaves the active one active.
                  isActive: wasActive ? config.id == next : config.isActive,
                ),
          ];
          if (remaining.length != configs.length || wasActive) {
            registryWritten = true;
            await _saveServerConfigsUnlocked(remaining);
          }
          if (!wasActive) return false;
          activeIdWritten = true;
          await _writeActiveServerIdWithoutConfigSync(next);
          if (next == null) return false;
          return await _adoptVaultedSessionUnlocked(next, vaulted: nextSession);
        } catch (error, stackTrace) {
          // Nothing of the removal stays: the account keeps its record, its
          // sessions and, when it was active, the live slots.
          await _restoreVaultUnlocked(vaultUndo);
          try {
            await _restoreServerSessionUnlocked(
              registry: previousRegistry,
              activeServerId: rawActive,
              token: previousToken,
              restoreConfigs: registryWritten,
              restoreActiveServerId: activeIdWritten,
              restoreCredentials: liveCredentialsChanged,
              credentialsPayload: previousCredentialsPayload,
              credentialsReadSuppressed: previousCredentialsReadSuppressed,
              // An inactive account's removal leaves the live token alone.
              tokenAlreadyDeleted: !wasActive,
            );
          } catch (rollbackError, rollbackStackTrace) {
            await _bestEffortFailClosedServerSessionRestoreUnlocked(
              registry: previousRegistry,
              activeServerId: rawActive,
            );
            Error.throwWithStackTrace(
              ServerConfigSessionRollbackException(
                commitError: error,
                rollbackError: rollbackError,
              ),
              rollbackStackTrace,
            );
          }
          Error.throwWithStackTrace(error, stackTrace);
        }
      }),
    );
  }

  /// Hands the active account's live session to [targetAccountId], an
  /// existing account of the same user on the same server, and removes the
  /// active account.
  ///
  /// Signing in again as someone who already has an account here should land
  /// in that account, with its local data, rather than in a duplicate. The
  /// live token and saved sign-in stay where they are; only the account they
  /// belong to changes, so any older session vaulted for the target is
  /// superseded and dropped.
  ///
  /// Returns whether it merged. It declines -- changing nothing -- unless
  /// [expectedSourceAccountId] is still active and the target is another
  /// account on its server; a failure part-way puts back what it changed.
  /// When that cannot be put back either, the live session is ended and a
  /// [ServerConfigSessionRollbackException] thrown.
  Future<bool> mergeActiveAccountInto(
    String targetAccountId, {
    required String expectedSourceAccountId,
    String? expectedToken,
  }) {
    return _authStateLock.synchronized(
      () => _serverConfigsLock.synchronized(() async {
        // The session checked to be the target's user, and no newer one
        // committed since: a merge moves the live session to the target. A
        // token read that fails is not a changed token, so it propagates;
        // one fenced off by a sign-out is none, and the merge declines.
        if (expectedToken != null &&
            await _retrySecureStorageRead(
                  _getAuthTokenStrictUnlocked,
                  scope: 'storage/optimized/token-compare-merge',
                ) !=
                expectedToken) {
          return false;
        }
        final previousRegistry = await _snapshotRegistryUnlocked();
        final registry = previousRegistry.registry;
        final rawActiveId = _rawStoredActiveServerId(
          bypassReadSuppression: true,
        );
        final activeId = _effectiveActiveServerId(
          configs: registry.projectAll(),
          rawActiveServerId: rawActiveId,
        );
        if (activeId != expectedSourceAccountId) return false;
        final source = activeId == null ? null : registry.account(activeId);
        final target = registry.account(targetAccountId);
        if (source == null ||
            target == null ||
            source.id == target.id ||
            source.serverId != target.serverId) {
          return false;
        }

        final vaultUndo = _VaultUndo();
        String? rewrittenCredentialsFrom;
        var registryWritten = false;
        try {
          await _deleteVaultedSessionUndoablyUnlocked(target.id, vaultUndo);
          // The source goes, and what was kept aside under its id with it,
          // as when an account is removed: left, nothing would reach it.
          await _deleteVaultedSessionUndoablyUnlocked(source.id, vaultUndo);
          final payload = _savedCredentialsReadSuppressed
              ? null
              : await _secureCredentialStorage
                    .getSavedCredentialsPayloadStrict();
          if (payload != null &&
              payload.isNotEmpty &&
              _savedCredentialsServerId(payload) == source.id) {
            final decoded = jsonDecode(payload) as Map<String, dynamic>;
            decoded['serverId'] = target.id;
            rewrittenCredentialsFrom = payload;
            await _secureCredentialStorage.restoreSavedCredentialsPayload(
              jsonEncode(decoded),
            );
          }

          final merged = target.copyWith(
            isActive: true,
            userId: target.userId ?? source.userId,
            capturedHeaders: {
              ...target.capturedHeaders,
              ...source.capturedHeaders,
            },
          );
          await _saveRegistryUnlocked(
            OpenWebUiRegistry(
              servers: registry.servers,
              accounts: [
                for (final account in registry.accounts)
                  if (account.id == target.id)
                    merged
                  else if (account.id != source.id)
                    account.copyWith(isActive: false),
              ],
            ),
          );
          registryWritten = true;
          await _writeActiveServerIdWithoutConfigSync(target.id);
        } catch (error, stackTrace) {
          // Whose the live session is cannot be told any more. End it rather
          // than leave it with an account it may not belong to.
          Future<Never> endLiveSession(
            Object rollbackError,
            StackTrace rollbackStackTrace,
          ) async {
            for (final delete in [
              _deleteAuthTokenUnlocked,
              _deleteSavedCredentialsUnlocked,
            ]) {
              try {
                await delete();
              } catch (_) {}
            }
            await _restoreVaultUnlocked(vaultUndo);
            Error.throwWithStackTrace(
              ServerConfigSessionRollbackException(
                commitError: error,
                rollbackError: rollbackError,
              ),
              rollbackStackTrace,
            );
          }

          // The source stays the active account with its session; the target
          // keeps the one it had. The accounts and the active id go back
          // first: the live session belongs to whichever account they name.
          if (registryWritten) {
            try {
              await _restoreRegistryUnlocked(previousRegistry);
              // A failed write can still have changed the id read back.
              if (_rawStoredActiveServerId(bypassReadSuppression: true) !=
                  rawActiveId) {
                await _writeActiveServerIdWithoutConfigSync(rawActiveId);
              }
            } catch (rollbackError, rollbackStackTrace) {
              await endLiveSession(rollbackError, rollbackStackTrace);
            }
          }
          final original = rewrittenCredentialsFrom;
          if (original != null) {
            // Left naming the target, the saved sign-in would be filed under
            // it the next time the source's session moves.
            try {
              await _retrySecureStorageWrite(
                () => _secureCredentialStorage.restoreSavedCredentialsPayload(
                  original,
                ),
                scope: 'storage/optimized/merge-rollback',
              );
            } catch (rollbackError, rollbackStackTrace) {
              await endLiveSession(rollbackError, rollbackStackTrace);
            }
          }
          await _restoreVaultUnlocked(vaultUndo);
          Error.throwWithStackTrace(error, stackTrace);
        }
        _stagedServerConfigCandidate = null;
        return true;
      }),
    );
  }

  /// Runs a config read under [_serverConfigsLock], and under
  /// [_authStateLock] first while it could still run the migration: the
  /// migration moves the saved sign-in, and a sign-in saved or deleted
  /// between its read and that write would be overwritten or come back.
  Future<T> _synchronizedServerConfigsRead<T>(Future<T> Function() read) {
    if (_registryMigrationSettled) {
      return _serverConfigsLock.synchronized(read);
    }
    return _authStateLock.synchronized(
      () => _serverConfigsLock.synchronized(read),
    );
  }

  Future<List<ServerConfig>> getServerConfigs() {
    return _synchronizedServerConfigsRead(() async {
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
      _synchronizedServerConfigsRead(_getServerConfigsStrictRetryingUnlocked);

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

    final registry = await _getRegistryStrictUnlocked(
      bypassReadSuppression: bypassReadSuppression,
    );
    return registry.projectAll();
  }

  Future<OpenWebUiRegistry> _getRegistryStrictUnlocked({
    bool bypassReadSuppression = false,
  }) async {
    if (_serverConfigsReadSuppressed && !bypassReadSuppression) {
      return OpenWebUiRegistry.empty;
    }
    if (!bypassReadSuppression) {
      final (hit: hasCachedRegistry, value: cachedRegistry) = _cacheManager
          .lookup<OpenWebUiRegistry>(_registryCacheKey);
      if (hasCachedRegistry && cachedRegistry != null) return cachedRegistry;
    }
    final registry = await _readRegistryFromStorageUnlocked();
    if (!bypassReadSuppression) _cacheRegistry(registry);
    return registry;
  }

  /// The registry a config write folds into: the last one written by this
  /// process, or the stored one. Read fences do not apply; a write must build
  /// on what is durable, not on what reads are currently allowed to see.
  ///
  /// After a full wipe it is the registry the wipe meant to leave -- empty,
  /// or the server details it kept -- even when the platform delete failed
  /// and the old one is still stored. Until a registry write lands, a write
  /// builds on that, however long it takes, so it cannot bring back the
  /// accounts, routes or cookies the wipe was removing.
  Future<OpenWebUiRegistry> _registryForWriteUnlocked() async {
    final leftByWipe = _registryLeftByWipe;
    if (leftByWipe != null) return leftByWipe;
    final (hit: hasCachedRegistry, value: cachedRegistry) = _cacheManager
        .lookup<OpenWebUiRegistry>(_registryCacheKey);
    if (hasCachedRegistry && cachedRegistry != null) return cachedRegistry;
    return _readRegistryFromStorageUnlocked();
  }

  Future<_RegistrySnapshot> _snapshotRegistryUnlocked() async => (
    registry: await _registryForWriteUnlocked(),
    readsSuppressed: _serverConfigsReadSuppressed,
  );

  /// Writes [snapshot] back as it was taken. Reads fenced then stay fenced,
  /// whatever the transaction being undone did to the fence.
  Future<void> _restoreRegistryUnlocked(_RegistrySnapshot snapshot) async {
    await _saveRegistryUnlocked(snapshot.registry, authorizeReads: false);
    _serverConfigsReadSuppressed = snapshot.readsSuppressed;
  }

  Future<void> _saveRegistryUnlocked(
    OpenWebUiRegistry registry, {
    bool authorizeReads = true,
    bool ownershipChanged = true,
  }) async {
    await _secureCredentialStorage.saveOpenWebUiRegistry(registry.encode());
    _registryLeftByWipe = null;
    _registryMigrationSettled = true;
    if (authorizeReads) _serverConfigsReadSuppressed = false;
    // Recording facts about an account (which user it proved to be) changes
    // no transport or session owner, and must not fail a sign-in that
    // snapshotted ownership a moment earlier.
    if (ownershipChanged) _serverOwnershipRevision++;
    _cacheManager.invalidate(_activeServerIdKey);
    _cacheRegistry(registry);
  }

  Future<OpenWebUiRegistry> _readRegistryFromStorageUnlocked() async {
    final stored = await _secureCredentialStorage.getOpenWebUiRegistry();
    if (stored != null) {
      _registryMigrationSettled = true;
      if (stored.isEmpty) {
        throw const FormatException('Open WebUI registry payload was empty');
      }
      return OpenWebUiRegistry.decode(stored);
    }

    final legacy = await _secureCredentialStorage.getServerConfigs();
    if (legacy == null) {
      // Nothing writes the old list any more, so none can appear later.
      _registryMigrationSettled = true;
      return OpenWebUiRegistry.empty;
    }
    if (legacy.isEmpty) {
      throw const FormatException('Server configs payload was empty');
    }
    final decoded = jsonDecode(legacy) as List<dynamic>;
    final configs = decoded
        .map((item) => ServerConfig.fromJson(item))
        .toList(growable: false);
    final registry = await _migrateLegacyServerConfigsUnlocked(configs);
    _registryMigrationSettled = true;
    return registry;
  }

  /// Replaces the one-server config list with the registry, once.
  ///
  /// Every read happens before the first write, and any failure propagates
  /// before anything is written: a Keychain that is still locked at launch
  /// must not turn into "no servers". The registry is written and read back
  /// before the legacy list is deleted, so a crash at any point leaves one of
  /// the two intact, and the registry wins whenever it exists. One-way: an
  /// older build afterwards finds no saved server and asks to sign in.
  ///
  /// It can rewrite the saved sign-in, so it runs with both locks held; see
  /// [_synchronizedServerConfigsRead].
  Future<OpenWebUiRegistry> _migrateLegacyServerConfigsUnlocked(
    List<ServerConfig> configs,
  ) async {
    final activeId = _effectiveActiveServerId(
      configs: configs,
      rawActiveServerId: _rawStoredActiveServerId(bypassReadSuppression: true),
    );
    final credentials = await _secureCredentialStorage
        .getSavedCredentialsPayloadStrict();
    final credentialOwner = _savedCredentialsServerId(credentials);
    final vaulted = await _secureCredentialStorage.vaultedServerIds();
    const markers = PreferencesOpenWebUiAccountOwnerMarkerStore();
    final collapsedInto = <String, String>{};
    final registry = OpenWebUiRegistry.fromLegacyServerConfigs(
      configs,
      priority: <String>[?activeId, ?credentialOwner, ...vaulted],
      userIdFor: (accountId) => markers.read(accountId)?.userId,
      onCollapsed: (droppedId, keptId) => collapsedInto[droppedId] = keptId,
    );

    // The saved sign-in may name an account that collapsed into another of
    // the same user; it follows that account, or a silent sign-in would find
    // its owner gone and drop it. Before the registry write, so a crash
    // reruns the migration with the sign-in already owned by a kept account.
    final credentialHeir = collapsedInto[credentialOwner];
    if (credentials != null && credentialHeir != null) {
      final decoded = jsonDecode(credentials) as Map<String, dynamic>;
      await _secureCredentialStorage.restoreSavedCredentialsPayload(
        jsonEncode(<String, dynamic>{...decoded, 'serverId': credentialHeir}),
      );
    }

    final encoded = registry.encode();
    await _secureCredentialStorage.saveOpenWebUiRegistry(encoded);
    final written = await _secureCredentialStorage.getOpenWebUiRegistry();
    if (written != encoded) {
      try {
        await _secureCredentialStorage.deleteOpenWebUiRegistry();
      } catch (_) {}
      throw StateError('Open WebUI registry could not be verified');
    }
    try {
      await _secureCredentialStorage.deleteLegacyServerConfigs();
    } catch (error) {
      // The registry is authoritative from here on; the stale list is never
      // read again while it exists.
      DebugLogger.warning(
        'legacy-server-configs-delete-failed',
        scope: 'storage/optimized/registry',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
    DebugLogger.info(
      'registry-migrated',
      scope: 'storage/optimized/registry',
      data: {
        'legacyConfigs': configs.length,
        'accounts': registry.accounts.length,
        'servers': registry.servers.length,
      },
    );
    return registry;
  }

  Future<List<ServerConfig>>
  _getServerConfigsStrictUnlockedBypassingSuppression() =>
      _getServerConfigsStrictUnlocked(bypassReadSuppression: true);

  Future<void> setActiveServerId(String? serverId) =>
      _authStateLock.synchronized(() => _setActiveServerIdUnlocked(serverId));

  /// Keeps [accountId] as the active account id when it is active only as
  /// storage counts it -- flagged active, or the only account saved -- with
  /// no id kept for it. Settings scoped to an account read the kept id, so
  /// until then they would be the device's, while the account's own copy of
  /// them went stale. Changes nothing else, and nothing when another
  /// account is active.
  Future<void> recordEffectiveActiveAccount(String accountId) =>
      _authStateLock.synchronized(
        () => _serverConfigsLock.synchronized(() async {
          final raw = _rawStoredActiveServerId(bypassReadSuppression: true);
          if (raw == accountId) return;
          final effective = _effectiveActiveServerId(
            configs: await _getServerConfigsStrictUnlocked(),
            rawActiveServerId: raw,
          );
          if (effective != accountId) return;
          await _writeActiveServerIdWithoutConfigSync(accountId);
        }),
      );

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

  Future<void> _writeActiveServerIdWithoutConfigSync(
    String? serverId, {
    bool bypassAppDataClearBarrier = false,
  }) async {
    await PreferencesStore.putChecked(
      _activeServerIdKey,
      serverId,
      bypassAppDataClearBarrier: bypassAppDataClearBarrier,
    );
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

  /// The account the live session belongs to: the one [getActiveServerId]
  /// names, or failing that the one flagged active, or the only one saved.
  /// Account changes compare against this, as storage itself does; the
  /// stricter id can be null while an account is active. Null when nothing
  /// is active; throws when it cannot be read.
  Future<String?> getEffectiveActiveServerId() {
    // Not caught: a failed read must not pass for no account at all, which
    // callers would act on.
    return _authStateLock.synchronized(
      () => _serverConfigsLock.synchronized(_effectiveActiveServerIdUnlocked),
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

  /// Like [clearAuthDataIf], for the active account alone.
  ///
  /// Its live token and saved sign-in go, along with anything vaulted under
  /// its id and its captured proxy cookies. Every other account stays signed
  /// in: their sessions are in the vault, untouched.
  Future<bool> clearActiveAccountAuthDataIf({
    required bool Function() canClear,
  }) async {
    final cleared = await _authStateLock.synchronized(() async {
      if (!canClear()) return false;
      await _clearActiveAccountAuthDataUnlocked();
      return true;
    });
    if (cleared) {
      DebugLogger.log(
        'Active account auth data conditionally cleared',
        scope: 'storage/optimized',
      );
    }
    return cleared;
  }

  Future<void> _clearActiveAccountAuthDataUnlocked() async {
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
      Future<(List<ServerConfig>, String?)> activeAccount() async {
        final configs =
            await _getServerConfigsStrictUnlockedBypassingSuppression();
        return (
          configs,
          _effectiveActiveServerId(
            configs: configs,
            rawActiveServerId: _rawStoredActiveServerId(
              bypassReadSuppression: true,
            ),
          ),
        );
      }

      // A saved sign-in the live slots hold for another account is filed
      // under it first, so that account is not signed out with this one.
      // One that could not be filed stays where it is: it is not this
      // account's to delete, and the next commit files it.
      var foreignSignInKept = false;
      await attempt(() async {
        final (configs, activeId) = await activeAccount();
        if (activeId == null) return;
        try {
          await _fileForeignSavedCredentialsUnlocked(activeId, configs);
        } on _ForeignSignInNotFiled {
          foreignSignInKept = true;
          rethrow;
        }
      });
      await attempt(_deleteAuthTokenUnlocked);
      if (!foreignSignInKept) await attempt(_deleteSavedCredentialsUnlocked);
      // Like every step here, a failed read is recorded and the rest still
      // runs: the staged candidate and the cached user data go regardless.
      await attempt(() async {
        final (configs, activeId) = await activeAccount();
        if (activeId == null) return;
        await attempt(() => _deleteVaultedSessionUnlocked(activeId));
        await attempt(() async {
          var changed = false;
          final sanitized = [
            for (final config in configs)
              if (config.id == activeId)
                () {
                  final revoked = _revokeServerConfigAuthArtifacts(config);
                  changed = revoked != config;
                  return revoked;
                }()
              else
                config,
          ];
          if (changed) {
            await _saveServerConfigsUnlocked(sanitized, authorizeReads: false);
          }
        });
      });
      _stagedServerConfigCandidate = null;
    });
    await attempt(_clearUserScopedCacheEntries);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  Future<void> _scrubServerConfigAuthArtifactsUnlocked() async {
    // After a wipe whose delete failed, the old registry is still stored,
    // cookies and all. What the wipe meant to leave goes over it: a copy
    // with only its secrets taken out would keep what the wipe removed.
    final leftByWipe = _registryLeftByWipe;
    if (leftByWipe != null) {
      await _saveRegistryUnlocked(leftByWipe, authorizeReads: false);
      return;
    }
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
      // The vault too, and not only the active token: leaving another
      // server's session in the keychain would make "sign out" untrue, and
      // switching back would silently resurrect a session the user believed
      // they had ended. `_clearAllUnlocked` gets this for free through
      // `clearAll`, which wipes the whole store; this path is selective and
      // has to say so.
      await attempt(_secureCredentialStorage.deleteAllServerTokens);
      await attempt(_secureCredentialStorage.deleteAllServerCredentials);
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
        () => _serverConfigsLock.synchronized(
          () => _clearAllUnlocked(
            preserveServerDetails: false,
            preserveLogoutFence: false,
          ),
        ),
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

  /// Clears all app data if [canClear] still owns the authenticated session.
  ///
  /// When [preserveServerDetails] is true, only sanitized Open WebUI
  /// connection settings are restored after the broad wipe. Authentication
  /// artifacts, app preferences, Direct profiles, and Hermes credentials are
  /// always removed.
  Future<bool> clearAllIf({
    required bool Function() canClear,
    required bool preserveServerDetails,
  }) async {
    try {
      final cleared = await _authStateLock.synchronized(
        () => _serverConfigsLock.synchronized(() async {
          if (!canClear()) return false;
          await _clearAllUnlocked(
            preserveServerDetails: preserveServerDetails,
            preserveLogoutFence: true,
          );
          return true;
        }),
      );
      if (cleared) {
        DebugLogger.log(
          preserveServerDetails
              ? 'All storage cleared; server details restored'
              : 'All storage cleared',
          scope: 'storage/optimized',
        );
      }
      return cleared;
    } catch (error) {
      DebugLogger.log(
        'Failed to clear all storage: $error',
        scope: 'storage/optimized',
      );
      rethrow;
    }
  }

  Future<void> _clearAllUnlocked({
    required bool preserveServerDetails,
    required bool preserveLogoutFence,
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

    final initiatingServerId = _rawStoredActiveServerId(
      bypassReadSuppression: true,
    );
    var retainedRegistry = OpenWebUiRegistry.empty;
    String? retainedActiveServerId;
    if (preserveServerDetails) {
      await attempt(() async {
        // After an earlier wipe whose delete failed, what it meant to leave,
        // not the old registry still stored.
        retainedRegistry = _retainNonSecretServerDetails(
          _registryLeftByWipe ??
              await _getRegistryStrictUnlocked(bypassReadSuppression: true),
        );
        retainedActiveServerId = _effectiveActiveServerId(
          configs: retainedRegistry.projectAll(),
          rawActiveServerId: initiatingServerId,
        );
      });
    }

    // Fence every pre-wipe ownership snapshot before the first mutation.
    _authTokenReadSuppressed = true;
    _savedCredentialsReadSuppressed = true;
    _serverConfigsReadSuppressed = true;
    _activeServerIdReadSuppressed = true;
    _serverOwnershipRevision++;
    _stagedServerConfigCandidate = null;

    // Keep every fail-closed mutation independent. An individual Keychain
    // failure must not prevent the later broad wipe.
    await attempt(_deleteAuthTokenUnlocked);
    await attempt(_deleteSavedCredentialsUnlocked);
    await attempt(_scrubServerConfigAuthArtifactsUnlocked);

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
      await attempt(
        () => PreferencesStore.clear(
          preserve: {
            PreferenceKeys.hiveToPrefsMigrationV1,
            if (preserveLogoutFence) PreferenceKeys.incompleteLogoutFence,
          },
        ),
      );
      await attempt(_secureCredentialStorage.clearAll);
      await attempt(_cachesBox.clear);
      await attempt(_attachmentQueueBox.clear);
      await attempt(() async {
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
      // A partially successful platform wipe must never expose stale secure
      // data again during this process.
      _cacheManager.clear();
      _authTokenReadSuppressed = true;
      _savedCredentialsReadSuppressed = true;
      _serverConfigsReadSuppressed = true;
      _activeServerIdReadSuppressed = true;
      _cacheManager.write<String>(_authTokenKey, null, ttl: _authTokenTtl);
      _cacheManager.write<bool>(
        'has_credentials',
        false,
        ttl: _credentialsFlagTtl,
      );
      _cacheRegistry(OpenWebUiRegistry.empty);
      _registryLeftByWipe = retainedRegistry;
      _cacheActiveServerId(null);
    }

    if (preserveServerDetails) {
      var configsRestored = false;
      var activeIdRestored = false;
      await attempt(() async {
        await _saveRegistryUnlocked(retainedRegistry, authorizeReads: false);
        configsRestored = true;
      });
      await attempt(() async {
        // The sign-out wipe holds the preference write barrier; this restore
        // is part of that wipe, like the keys PreferencesStore.clear keeps.
        await _writeActiveServerIdWithoutConfigSync(
          retainedActiveServerId,
          bypassAppDataClearBarrier: true,
        );
        activeIdRestored = true;
      });
      if (configsRestored && activeIdRestored) {
        _serverConfigsReadSuppressed = false;
        _activeServerIdReadSuppressed = false;
        _cacheActiveServerId(retainedActiveServerId);
      } else {
        _serverConfigsReadSuppressed = true;
        _activeServerIdReadSuppressed = true;
      }
    }

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
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

  void _cacheRegistry(OpenWebUiRegistry registry) {
    final configs = registry.projectAll();
    _cacheManager.write('server_config_count', configs.length);
    _cacheManager.write(_registryCacheKey, registry, ttl: _serverConfigsTtl);
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
