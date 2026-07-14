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
       _workerManager = workerManager;

  /// Resolves the active server's Drift database (PR-2: structured caches live
  /// in the per-server DB, not the Hive caches box). Null in reviewer mode / no
  /// active server / tests without a DB — callers fall back to defaults.
  final OptimizedStorageDatabaseResolver? _databaseAccess;

  Future<T?> _withDatabase<T>(
    Future<T> Function(AppDatabase database) operation,
  ) async {
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
  final CacheManager _cacheManager = CacheManager(maxEntries: 64);

  /// Serializes read-modify-write sequences over the auth token, saved
  /// credentials, and active server id so a stale background task's
  /// compare-and-write can't interleave with (and clobber) a newer login /
  /// server selection. All WRITES to those three keys take this lock; the
  /// compound `*IfMatches` / `restore*` helpers do their read AND write under a
  /// single hold via the private `_*Unlocked` bodies (the lock is NOT
  /// reentrant, so locked methods must call the unlocked bodies internally).
  final Lock _authStateLock = Lock();

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
  static const Duration _authTokenTtl = Duration(hours: 12);
  static const Duration _serverIdTtl = Duration(days: 7);
  static const Duration _serverConfigsTtl = Duration(days: 7);
  static const Duration _credentialsFlagTtl = Duration(hours: 12);

  // ---------------------------------------------------------------------------
  // Auth token APIs (secure storage + in-memory cache)
  // ---------------------------------------------------------------------------
  Future<void> saveAuthToken(String token) =>
      _authStateLock.synchronized(() => _saveAuthTokenUnlocked(token));

  Future<void> _saveAuthTokenUnlocked(String token) async {
    try {
      await _secureCredentialStorage.saveAuthToken(token);
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

  Future<String?> getAuthToken() async {
    final (hit: hasCachedToken, value: cachedToken) = _cacheManager
        .lookup<String>(_authTokenKey);
    if (hasCachedToken) {
      DebugLogger.log('Using cached auth token', scope: 'storage/optimized');
      return cachedToken;
    }

    try {
      final token = await _secureCredentialStorage.getAuthToken();
      if (token != null) {
        _cacheManager.write(_authTokenKey, token, ttl: _authTokenTtl);
      }
      return token;
    } catch (error) {
      DebugLogger.log(
        'Failed to retrieve auth token: $error',
        scope: 'storage/optimized',
      );
      return null;
    }
  }

  Future<void> deleteAuthToken() =>
      _authStateLock.synchronized(_deleteAuthTokenUnlocked);

  /// Compare-and-delete: deletes the stored auth token ONLY if it still equals
  /// [expected]. Read + conditional delete run under [_authStateLock], so a
  /// superseded login can roll back its own token write without clobbering a
  /// newer login's token. Returns true if it deleted.
  Future<bool> deleteAuthTokenIfMatches(String expected) {
    return _authStateLock.synchronized(() async {
      final current = await getAuthToken();
      if (current != expected) return false;
      await _deleteAuthTokenUnlocked();
      return true;
    });
  }

  Future<void> _deleteAuthTokenUnlocked() async {
    try {
      await _secureCredentialStorage.deleteAuthToken();
      _cacheManager.invalidate(_authTokenKey);
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

  Future<Map<String, String>?> getSavedCredentials() async {
    try {
      final credentials = await _secureCredentialStorage.getSavedCredentials();
      _cacheManager.write(
        'has_credentials',
        credentials != null,
        ttl: _credentialsFlagTtl,
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

  Future<void> deleteSavedCredentials() =>
      _authStateLock.synchronized(_deleteSavedCredentialsUnlocked);

  Future<void> _deleteSavedCredentialsUnlocked() async {
    try {
      await _secureCredentialStorage.deleteSavedCredentials();
      _cacheManager.invalidate('has_credentials');
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
      final current = await getSavedCredentials();
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

  Future<bool> hasCredentials() async {
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
  Future<void> saveServerConfigs(List<ServerConfig> configs) async {
    try {
      final jsonString = jsonEncode(configs.map((c) => c.toJson()).toList());
      await _secureCredentialStorage.saveServerConfigs(jsonString);
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

  Future<List<ServerConfig>> getServerConfigs() async {
    final (hit: hasCachedConfigs, value: cachedConfigs) = _cacheManager
        .lookup<List<ServerConfig>>(_serverConfigsCacheKey);
    if (hasCachedConfigs && cachedConfigs != null) {
      return cachedConfigs;
    }

    try {
      final jsonString = await _secureCredentialStorage.getServerConfigs();
      if (jsonString == null) {
        _cacheServerConfigs(const <ServerConfig>[]);
        return const [];
      }
      if (jsonString.isEmpty) {
        throw const FormatException('Server configs payload was empty');
      }

      final decoded = jsonDecode(jsonString) as List<dynamic>;
      final configs = decoded
          .map((item) => ServerConfig.fromJson(item))
          .toList(growable: false);
      _cacheServerConfigs(configs);
      return configs;
    } catch (error) {
      DebugLogger.log(
        'Failed to retrieve server configs: $error',
        scope: 'storage/optimized',
      );
      return const [];
    }
  }

  Future<void> setActiveServerId(String? serverId) =>
      _authStateLock.synchronized(() => _setActiveServerIdUnlocked(serverId));

  Future<void> _setActiveServerIdUnlocked(String? serverId) async {
    if (serverId != null) {
      await PreferencesStore.put(_activeServerIdKey, serverId);
    } else {
      await PreferencesStore.remove(_activeServerIdKey);
    }
    _cacheActiveServerId(serverId);
    await _syncActiveServerConfigFlags(serverId);
  }

  Future<String?> getActiveServerId() async {
    final activeServerIdState = _readActiveServerIdState();
    return _resolveValidatedActiveServerId(
      rawServerId: activeServerIdState.rawServerId,
      cacheWhenUnchanged: !activeServerIdState.hasCachedId,
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
      if (_rawStoredActiveServerId() != expectedId) return false;
      await _setActiveServerIdUnlocked(null);
      return true;
    });
  }

  /// The active-server id as stored in Hive, bypassing the in-memory cache and
  /// the saved-config validation in [getActiveServerId] (which returns null once
  /// the referenced server is deleted). Compare-and-clear/restore use this so a
  /// dangling preference for a removed server is still detected and cleared.
  String? _rawStoredActiveServerId() =>
      PreferencesStore.getString(_activeServerIdKey);

  /// Atomically undoes a stale silent-login's persistence: under
  /// [_authStateLock], restores the auth token and active server to their
  /// pre-attempt values — but only the entries that still hold the stale
  /// values, so a newer login that already wrote a fresh token / server isn't
  /// overwritten. [replacementToken] is the token to restore when the stored
  /// token still equals [staleToken] (null/empty → delete it).
  Future<void> restoreActiveServerAndTokenIfStale({
    required String staleServerId,
    required String? previousServerId,
    required String staleToken,
    required String? replacementToken,
  }) {
    return _authStateLock.synchronized(() async {
      final currentToken = await getAuthToken();
      if (currentToken == staleToken) {
        if (replacementToken != null &&
            replacementToken.isNotEmpty &&
            replacementToken != staleToken) {
          await _saveAuthTokenUnlocked(replacementToken);
        } else if (replacementToken == null || replacementToken.isEmpty) {
          await _deleteAuthTokenUnlocked();
        }
      }

      if (_rawStoredActiveServerId() == staleServerId) {
        await _setActiveServerIdUnlocked(previousServerId);
      }
    });
  }

  Future<void> _syncActiveServerConfigFlags(String? serverId) async {
    final configs = await getServerConfigs();
    if (configs.isEmpty) {
      return;
    }

    var didChange = false;
    final updatedConfigs = configs
        .map((config) {
          final shouldBeActive = serverId != null && config.id == serverId;
          if (config.isActive == shouldBeActive) {
            return config;
          }

          didChange = true;
          return config.copyWith(isActive: shouldBeActive);
        })
        .toList(growable: false);

    if (!didChange) {
      return;
    }

    await saveServerConfigs(updatedConfigs);
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
    await _clearUserScopedCacheEntries();
    DebugLogger.log(
      'User-scoped auth data cleared',
      scope: 'storage/optimized',
    );
  }

  /// Clear authentication-related data (tokens, credentials, user data).
  /// Server configurations (URL, custom headers, self-signed cert settings)
  /// are preserved to allow quick re-login.
  Future<void> clearAuthData() async {
    await Future.wait([
      deleteAuthToken(),
      deleteSavedCredentials(),
      _clearUserScopedCacheEntries(),
      // Note: Server configs are NOT cleared - they persist across logouts
      // so users can quickly re-login without re-entering server details
    ]);

    _cacheManager.invalidateMatching(
      (key) =>
          key.contains('auth') ||
          key.contains('credentials') ||
          key == _serverConfigsCacheKey,
    );

    DebugLogger.log(
      'Auth data cleared (server configs preserved for quick re-login)',
      scope: 'storage/optimized',
    );
  }

  Future<void> clearAll() async {
    try {
      await Future.wait([
        _withDatabase<void>(
          (database) => Future.wait([
            database.appCacheDao.deleteKeys(_allCacheKeys),
            database.attachmentQueueDao.clearAll(),
          ]),
        ),
        _secureCredentialStorage.clearAll(),
        // Preserve the migration gate so a wipe doesn't re-import stale Hive
        // preferences on the next launch.
        PreferencesStore.clear(
          preserve: const {PreferenceKeys.hiveToPrefsMigrationV1},
        ),
        // Legacy Hive stores; structured active-server stores were cleared
        // above while holding their database lifetime lease.
        _cachesBox.clear(),
        _attachmentQueueBox.clear(),
      ]);

      _cacheManager.clear();

      // Preserve migration metadata
      final migrationVersion =
          _metadataBox.get(HiveStoreKeys.migrationVersion) as int?;
      await _metadataBox.clear();
      if (migrationVersion != null) {
        await _metadataBox.put(
          HiveStoreKeys.migrationVersion,
          migrationVersion,
        );
      }

      DebugLogger.log('All storage cleared', scope: 'storage/optimized');
    } catch (error) {
      DebugLogger.log(
        'Failed to clear all storage: $error',
        scope: 'storage/optimized',
      );
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

  Future<String?> _resolveValidatedActiveServerId({
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
        await getServerConfigs(),
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
