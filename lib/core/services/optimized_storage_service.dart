import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';

import '../models/backend_config.dart';
import '../models/conversation.dart';
import '../models/folder.dart';
import '../models/model.dart';
import '../models/server_config.dart';
import '../models/user.dart';
import '../models/tool.dart';
import '../models/socket_transport_availability.dart';
import '../persistence/hive_boxes.dart';
import '../persistence/persistence_keys.dart';
import '../utils/debug_logger.dart';
import 'cache_manager.dart';
import 'secure_credential_storage.dart';
import 'worker_manager.dart';

/// Optimized storage service backed by Hive for non-sensitive data and
/// FlutterSecureStorage for credentials.
class OptimizedStorageService {
  OptimizedStorageService({
    required FlutterSecureStorage secureStorage,
    required HiveBoxes boxes,
    required WorkerManager workerManager,
  }) : _preferencesBox = boxes.preferences,
       _cachesBox = boxes.caches,
       _attachmentQueueBox = boxes.attachmentQueue,
       _metadataBox = boxes.metadata,
       _secureCredentialStorage = SecureCredentialStorage(
         instance: secureStorage,
       ),
       _workerManager = workerManager;

  final Box<dynamic> _preferencesBox;
  final Box<dynamic> _cachesBox;
  final Box<dynamic> _attachmentQueueBox;
  final Box<dynamic> _metadataBox;
  final SecureCredentialStorage _secureCredentialStorage;
  final WorkerManager _workerManager;
  final CacheManager _cacheManager = CacheManager(maxEntries: 64);

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
  // Longer TTLs to reduce secure storage churn for OpenWebUI sessions.
  static const Duration _authTokenTtl = Duration(hours: 12);
  static const Duration _serverIdTtl = Duration(days: 7);
  static const Duration _serverConfigsTtl = Duration(days: 7);
  static const Duration _credentialsFlagTtl = Duration(hours: 12);

  // ---------------------------------------------------------------------------
  // Auth token APIs (secure storage + in-memory cache)
  // ---------------------------------------------------------------------------
  Future<void> saveAuthToken(String token) async {
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

  Future<void> deleteAuthToken() async {
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

  Future<void> deleteSavedCredentials() async {
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

  Future<void> setActiveServerId(String? serverId) async {
    if (serverId != null) {
      await _preferencesBox.put(_activeServerIdKey, serverId);
    } else {
      await _preferencesBox.delete(_activeServerIdKey);
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
    return _preferencesBox.get(_themeModeKey) as String?;
  }

  Future<void> setThemeMode(String mode) async {
    await _preferencesBox.put(_themeModeKey, mode);
  }

  String? getThemePaletteId() {
    return _preferencesBox.get(_themePaletteKey) as String?;
  }

  Future<void> setThemePaletteId(String paletteId) async {
    await _preferencesBox.put(_themePaletteKey, paletteId);
  }

  String? getLocaleCode() {
    return _preferencesBox.get(_localeCodeKey) as String?;
  }

  Future<void> setLocaleCode(String? code) async {
    if (code == null || code.isEmpty) {
      await _preferencesBox.delete(_localeCodeKey);
    } else {
      await _preferencesBox.put(_localeCodeKey, code);
    }
  }

  Future<bool> getReviewerMode() async {
    return (_preferencesBox.get(_reviewerModeKey) as bool?) ?? false;
  }

  Future<void> setReviewerMode(bool enabled) async {
    await _preferencesBox.put(_reviewerModeKey, enabled);
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

  T? _readNullableSafelySync<T>({
    required String errorMessage,
    required T? Function() read,
  }) {
    try {
      return read();
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

  Future<List<Conversation>> getLocalConversations() {
    return _readSafely(
      errorMessage: 'Failed to retrieve local conversations',
      fallback: List<Conversation>.empty(growable: false),
      read: () => _readServerScopedJsonList(
        key: _localConversationsKey,
        decodeDebugLabel: 'decode_local_conversations',
        fromJson: Conversation.fromJson,
        allowLegacyPayload: true,
        migrateLegacy: true,
      ),
    );
  }

  Future<void> saveLocalConversations(List<Conversation> conversations) {
    return _writeSafely(
      errorMessage: 'Failed to save local conversations',
      write: () => _saveServerScopedJsonList(
        _localConversationsKey,
        items: conversations,
        toJson: (conversation) => conversation.toJson(),
        encodeDebugLabel: 'encode_local_conversations',
      ),
    );
  }

  Future<List<Folder>> getLocalFolders() {
    return _readSafely(
      errorMessage: 'Failed to retrieve local folders',
      fallback: List<Folder>.empty(growable: false),
      read: () => _readServerScopedJsonList(
        key: _localFoldersKey,
        decodeDebugLabel: 'decode_local_folders',
        fromJson: Folder.fromJson,
        allowLegacyPayload: true,
        migrateLegacy: true,
      ),
    );
  }

  Future<void> saveLocalFolders(List<Folder> folders) {
    return _writeSafely(
      errorMessage: 'Failed to save local folders',
      write: () => _saveServerScopedJsonList(
        _localFoldersKey,
        items: folders,
        toJson: (folder) => folder.toJson(),
        encodeDebugLabel: 'encode_local_folders',
      ),
    );
  }

  Future<User?> getLocalUser() {
    return _readNullableSafely(
      errorMessage: 'Failed to retrieve local user',
      read: () async {
        final stored = _cachesBox.get(_localUserKey);
        if (stored == null) return null;
        return _decodeJsonObject(stored, User.fromJson);
      },
    );
  }

  Future<void> saveLocalUser(User? user) {
    return _writeSafely(
      errorMessage: 'Failed to save local user',
      write: () async {
        if (user == null) {
          await _cachesBox.delete(_localUserKey);
          await _cachesBox.delete(_localUserAvatarKey);
          return;
        }
        final serialized = jsonEncode(user.toJson());
        await _cachesBox.put(_localUserKey, serialized);
      },
    );
  }

  Future<String?> getLocalUserAvatar() {
    return _readNullableSafely(
      errorMessage: 'Failed to retrieve local user avatar',
      read: () async {
        final stored = _cachesBox.get(_localUserAvatarKey);
        if (stored is String && stored.isNotEmpty) {
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
          await _cachesBox.delete(_localUserAvatarKey);
          return;
        }
        await _cachesBox.put(_localUserAvatarKey, avatarUrl);
      },
    );
  }

  Future<BackendConfig?> getLocalBackendConfig() {
    return _readNullableSafely(
      errorMessage: 'Failed to retrieve local backend config',
      read: () => _readServerScopedJsonObject(
        key: _localBackendConfigKey,
        fromJson: BackendConfig.fromJson,
      ),
    );
  }

  Future<void> saveLocalBackendConfig(BackendConfig? config) {
    return _writeSafely(
      errorMessage: 'Failed to save local backend config',
      write: () async {
        if (config == null) {
          await _cachesBox.delete(_localBackendConfigKey);
          return;
        }
        await _saveServerScopedJsonObject(
          _localBackendConfigKey,
          config,
          toJson: (value) => value.toJson(),
        );
      },
    );
  }

  Future<SocketTransportAvailability?> getLocalTransportOptions() {
    return _readNullableSafely(
      errorMessage: 'Failed to retrieve local transport options',
      read: () => _readServerScopedJsonObject(
        key: _localTransportOptionsKey,
        fromJson: _transportFromJson,
      ),
    );
  }

  Future<void> saveLocalTransportOptions(SocketTransportAvailability? options) {
    return _writeSafely(
      errorMessage: 'Failed to save local transport options',
      write: () async {
        if (options == null) {
          await _cachesBox.delete(_localTransportOptionsKey);
          return;
        }
        final json = {
          'allowPolling': options.allowPolling,
          'allowWebsocketOnly': options.allowWebsocketOnly,
        };
        await _saveServerScopedJsonObject(
          _localTransportOptionsKey,
          json,
          toJson: (value) => value,
        );
      },
    );
  }

  SocketTransportAvailability? getLocalTransportOptionsSync() {
    return _readNullableSafelySync(
      errorMessage: 'Failed to retrieve local transport options sync',
      read: () => _readValidatedServerScopedJsonObjectSync(
        _localTransportOptionsKey,
        fromJson: _transportFromJson,
      ),
    );
  }

  Future<List<Model>> getLocalModels() {
    return _readSafely(
      errorMessage: 'Failed to retrieve local models',
      fallback: List<Model>.empty(growable: false),
      read: () => _readServerScopedJsonList(
        key: _localModelsKey,
        decodeDebugLabel: 'decode_local_models',
        fromJson: Model.fromJson,
      ),
    );
  }

  Future<void> saveLocalModels(List<Model> models) {
    return _writeSafely(
      errorMessage: 'Failed to save local models',
      write: () => _saveServerScopedJsonList(
        _localModelsKey,
        items: models,
        toJson: (model) => model.toJson(),
        encodeDebugLabel: 'encode_local_models',
      ),
    );
  }

  Future<List<Tool>> getLocalTools() {
    return _readSafely(
      errorMessage: 'Failed to retrieve local tools',
      fallback: List<Tool>.empty(growable: false),
      read: () => _readServerScopedJsonList(
        key: _localToolsKey,
        decodeDebugLabel: 'decode_local_tools',
        fromJson: Tool.fromJson,
      ),
    );
  }

  Future<void> saveLocalTools(List<Tool> tools) {
    return _writeSafely(
      errorMessage: 'Failed to save local tools',
      write: () => _saveServerScopedJsonList(
        _localToolsKey,
        items: tools,
        toJson: (tool) => tool.toJson(),
        encodeDebugLabel: 'encode_local_tools',
      ),
    );
  }

  Future<Model?> getLocalDefaultModel() {
    return _readNullableSafely(
      errorMessage: 'Failed to retrieve local default model',
      read: () async {
        final parsed = await _readServerScopedJsonObject(
          key: _localDefaultModelKey,
          fromJson: Model.fromJson,
        );
        if (parsed == null) return null;

        final parsedModel = parsed;
        final cachedModels = await getLocalModels();
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
          await _cachesBox.delete(_localDefaultModelKey);
          return;
        }
        await _saveServerScopedJsonObject(
          _localDefaultModelKey,
          model,
          toJson: (value) => value.toJson(),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Batch operations
  // ---------------------------------------------------------------------------
  /// Clear authentication-related data (tokens, credentials, user data).
  /// Server configurations (URL, custom headers, self-signed cert settings)
  /// are preserved to allow quick re-login.
  Future<void> clearAuthData() async {
    await Future.wait([
      deleteAuthToken(),
      deleteSavedCredentials(),
      _cachesBox.delete(_localUserKey),
      _cachesBox.delete(_localUserAvatarKey),
      _cachesBox.delete(_localBackendConfigKey),
      _cachesBox.delete(_localTransportOptionsKey),
      _cachesBox.delete(_localToolsKey),
      _cachesBox.delete(_localDefaultModelKey),
      _cachesBox.delete(_localModelsKey),
      _cachesBox.delete(_localConversationsKey),
      _cachesBox.delete(_localFoldersKey),
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
        _secureCredentialStorage.clearAll(),
        _preferencesBox.clear(),
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

  // ---------------------------------------------------------------------------
  // Server scoping helpers
  // ---------------------------------------------------------------------------
  bool _isServerScopedPayload(Object? stored) =>
      stored is Map && stored.containsKey('data');

  (Object?, String?) _unwrapServerScoped(Object? stored) {
    if (_isServerScopedPayload(stored)) {
      final scoped = stored as Map<Object?, Object?>;
      final serverId = scoped['serverId'];
      return (scoped['data'], serverId is String ? serverId : null);
    }
    return (stored, null);
  }

  Future<Map<String, Object?>> _wrapServerScoped(Object data) async {
    return _wrapServerScopedForServerId(data, await getActiveServerId());
  }

  Map<String, Object?> _wrapServerScopedForServerId(
    Object? data,
    String? serverId,
  ) {
    return {'data': data, 'serverId': _normalizeServerId(serverId)};
  }

  Future<void> _maybeMigrateLegacyServerScopedCache({
    required String key,
    required Object? stored,
    required Object? payload,
    required String? activeServerId,
  }) async {
    if (_isServerScopedPayload(stored)) {
      return;
    }

    try {
      await _cachesBox.put(
        key,
        _wrapServerScopedForServerId(payload, activeServerId),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'Failed to migrate legacy server-scoped cache',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stackTrace,
        data: {'key': key, 'serverId': _normalizeServerId(activeServerId)},
      );
    }
  }

  Object? _resolveServerScopedPayload(
    Object? stored, {
    required String? activeServerId,
    bool allowLegacyPayload = false,
  }) {
    if (stored == null) {
      return null;
    }

    final isLegacyPayload = !_isServerScopedPayload(stored);
    final (payload, ownerServerId) = _unwrapServerScoped(stored);
    final shouldEnforceScope = !isLegacyPayload || !allowLegacyPayload;
    if (shouldEnforceScope &&
        !_matchesActiveServer(activeServerId, ownerServerId)) {
      return null;
    }
    return payload;
  }

  Future<Object?> _getServerScopedPayload({
    required String key,
    bool allowLegacyPayload = false,
    bool migrateLegacy = false,
  }) async {
    final stored = _cachesBox.get(key);
    final activeServerId = await getActiveServerId();
    final payload = _resolveServerScopedPayload(
      stored,
      activeServerId: activeServerId,
      allowLegacyPayload: allowLegacyPayload,
    );
    if (payload == null) {
      return null;
    }

    if (migrateLegacy) {
      await _maybeMigrateLegacyServerScopedCache(
        key: key,
        stored: stored,
        payload: payload,
        activeServerId: activeServerId,
      );
    }

    return payload;
  }

  Future<List<T>> _readServerScopedJsonList<T>({
    required String key,
    required String decodeDebugLabel,
    required T Function(Map<String, dynamic> json) fromJson,
    bool allowLegacyPayload = false,
    bool migrateLegacy = false,
  }) async {
    final payload = await _getServerScopedPayload(
      key: key,
      allowLegacyPayload: allowLegacyPayload,
      migrateLegacy: migrateLegacy,
    );
    if (payload == null) {
      return List<T>.empty(growable: false);
    }

    final parsed = await _workerManager
        .schedule<Map<String, dynamic>, List<Map<String, dynamic>>>(
          _decodeStoredJsonListWorker,
          {'stored': payload},
          debugLabel: decodeDebugLabel,
        );
    return parsed.map(fromJson).toList(growable: false);
  }

  Future<void> _saveServerScopedJsonList<T>(
    String key, {
    required Iterable<T> items,
    required Map<String, dynamic> Function(T item) toJson,
    required String encodeDebugLabel,
  }) async {
    final jsonReady = items.map(toJson).toList(growable: false);
    final serialized = await _workerManager
        .schedule<Map<String, dynamic>, String>(_encodeJsonListWorker, {
          'items': jsonReady,
        }, debugLabel: encodeDebugLabel);
    await _putServerScopedCacheValue(key, serialized);
  }

  Future<void> _putServerScopedCacheValue(String key, Object value) async {
    await _cachesBox.put(key, await _wrapServerScoped(value));
  }

  Future<void> _saveServerScopedJsonObject<T>(
    String key,
    T value, {
    required Object? Function(T value) toJson,
  }) async {
    await _putServerScopedCacheValue(key, jsonEncode(toJson(value)));
  }

  Future<T?> _readServerScopedJsonObject<T>({
    required String key,
    required T? Function(Map<String, dynamic> json) fromJson,
  }) async {
    final payload = await _getServerScopedPayload(key: key);
    if (payload == null) {
      return null;
    }
    return _decodeJsonObject(payload, fromJson);
  }

  bool _matchesActiveServer(String? activeServerId, String? ownerServerId) {
    final normalizedActive = _normalizeServerId(activeServerId);
    final normalizedOwner = _normalizeServerId(ownerServerId);
    if (normalizedOwner == null) {
      return normalizedActive == null;
    }
    return normalizedActive == normalizedOwner;
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
          : _preferencesBox.get(_activeServerIdKey) as String?,
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

  /// Validates the active server id using only synchronously available cache.
  ///
  /// If the server config cache has not been hydrated yet, return `null` so
  /// sync consumers fall back to safe defaults instead of trusting stale
  /// server-scoped cache entries from a removed server.
  String? _readValidatedActiveServerIdSync() {
    final activeServerIdState = _readActiveServerIdState();
    final validation = _validateServerIdAgainstConfigs(
      activeServerIdState.rawServerId,
      _readCachedServerConfigs(),
    );
    return _finalizeValidatedActiveServerId(
      rawServerId: activeServerIdState.rawServerId,
      validation: validation,
    );
  }

  Object? _getValidatedServerScopedPayloadSync(String key) {
    return _resolveServerScopedPayload(
      _cachesBox.get(key),
      activeServerId: _readValidatedActiveServerIdSync(),
    );
  }

  T? _readValidatedServerScopedJsonObjectSync<T>(
    String key, {
    required T? Function(Map<String, dynamic> json) fromJson,
  }) {
    final payload = _getValidatedServerScopedPayloadSync(key);
    if (payload == null) {
      return null;
    }
    return _decodeJsonObject(payload, fromJson);
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

String _encodeJsonListWorker(Map<String, dynamic> payload) {
  final raw = payload['items'] ?? payload['conversations'];
  if (raw is List) {
    return jsonEncode(raw);
  }
  if (raw is String) {
    // Already encoded.
    return raw;
  }
  return jsonEncode([]);
}
