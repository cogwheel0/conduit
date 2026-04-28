import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';

import '../models/backend_config.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/file_info.dart';
import '../models/folder.dart';
import '../models/model.dart';
import '../models/server_config.dart';
import '../models/user.dart';
import '../models/tool.dart';
import '../models/socket_transport_availability.dart';
import '../persistence/conversation_store.dart';
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
    required ConversationStore conversationStore,
  }) : _preferencesBox = boxes.preferences,
       _cachesBox = boxes.caches,
       _attachmentQueueBox = boxes.attachmentQueue,
       _metadataBox = boxes.metadata,
       _secureCredentialStorage = SecureCredentialStorage(
         instance: secureStorage,
       ),
       _workerManager = workerManager,
       _conversationStore = conversationStore;

  final Box<dynamic> _preferencesBox;
  final Box<dynamic> _cachesBox;
  final Box<dynamic> _attachmentQueueBox;
  final Box<dynamic> _metadataBox;
  final SecureCredentialStorage _secureCredentialStorage;
  final WorkerManager _workerManager;
  final ConversationStore _conversationStore;
  final CacheManager _cacheManager = CacheManager(maxEntries: 64);

  static const String _authTokenKey = 'auth_token_v3';
  static const String _activeServerIdKey = PreferenceKeys.activeServerId;
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

  // Per-entity cache key prefixes (in _cachesBox / _preferencesBox).
  // Per-conversation Hive blobs (chat_history_*) were retired in Phase 3a
  // — conversations now live as rows in SQLite via [ConversationStore].
  static const String _cachedFileInfoPrefix = 'file_info_';
  static const String _draftPrefix = 'draft_';
  // Longer TTLs to reduce secure storage churn for OpenWebUI sessions.
  static const Duration _authTokenTtl = Duration(hours: 12);
  static const Duration _serverIdTtl = Duration(days: 7);
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
      _cacheManager.write('server_config_count', configs.length);
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
    try {
      final jsonString = await _secureCredentialStorage.getServerConfigs();
      if (jsonString == null || jsonString.isEmpty) {
        _cacheManager.write('server_config_count', 0);
        return const [];
      }

      final decoded = jsonDecode(jsonString) as List<dynamic>;
      final configs = decoded
          .map((item) => ServerConfig.fromJson(item))
          .toList();
      _cacheManager.write('server_config_count', configs.length);
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
    _cacheManager.write(_activeServerIdKey, serverId, ttl: _serverIdTtl);
    await _syncActiveServerConfigFlags(serverId);
  }

  Future<String?> getActiveServerId() async {
    final (hit: hasCachedId, value: cachedId) = _cacheManager.lookup<String>(
      _activeServerIdKey,
    );
    if (hasCachedId) {
      return cachedId;
    }
    final serverId = _preferencesBox.get(_activeServerIdKey) as String?;
    _cacheManager.write(_activeServerIdKey, serverId, ttl: _serverIdTtl);
    return serverId;
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

  Future<List<Conversation>> getLocalConversations() async {
    try {
      return await _conversationStore.getAllSummaries();
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to retrieve local conversations',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
      return const [];
    }
  }

  Future<void> saveLocalConversations(List<Conversation> conversations) async {
    try {
      await _conversationStore.upsertConversations(conversations);
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to save local conversations',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
  }

  /// Persist [conversations] as the canonical full set, pruning any cached
  /// conversations whose ids are missing from the new list. Use when the
  /// caller has just fetched the full server snapshot — this is what makes
  /// web-side deletes propagate into the mobile drawer.
  Future<void> replaceLocalConversations(
    List<Conversation> conversations,
  ) async {
    try {
      await _conversationStore.replaceAllConversations(conversations);
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to replace local conversations',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Per-conversation cache — backed by SQLite via [ConversationStore]
  // (Phase 3a). The four methods below delegate so chat_providers and the
  // drawer don't need to know the storage backing changed.
  // ---------------------------------------------------------------------------
  Future<Conversation?> getCachedConversation(String id) async {
    if (id.isEmpty) return null;
    try {
      return await _conversationStore.getConversation(id);
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to read cached conversation',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
      return null;
    }
  }

  Future<void> cacheConversation(Conversation conversation) async {
    if (conversation.id.isEmpty) return;
    try {
      await _conversationStore.upsertConversation(conversation);
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to cache conversation',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
  }

  /// Synchronous read of the user's cached system prompt. Returns null when
  /// nothing has been cached yet (first launch or after a sign-out). Used by
  /// the chat send hot path so we don't have to await `getUserSettings`
  /// before kicking off the stream — local-first means the first token
  /// shouldn't be gated on a settings round-trip.
  String? getCachedUserSystemPrompt() {
    try {
      final stored = _cachesBox.get(HiveStoreKeys.cachedUserSystemPrompt);
      if (stored is String && stored.isNotEmpty) return stored;
    } catch (_) {}
    return null;
  }

  /// Persists the user's system prompt for synchronous reads via
  /// [getCachedUserSystemPrompt]. Pass null/empty to clear.
  Future<void> setCachedUserSystemPrompt(String? prompt) async {
    try {
      if (prompt == null || prompt.trim().isEmpty) {
        await _cachesBox.delete(HiveStoreKeys.cachedUserSystemPrompt);
      } else {
        await _cachesBox.put(
          HiveStoreKeys.cachedUserSystemPrompt,
          prompt.trim(),
        );
      }
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to cache user system prompt',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
  }

  /// Persist a single message under [scaffold.id], scaffolding the
  /// conversation row if it does not yet exist (Phase 3b — granular
  /// streaming writes from the chat send path).
  Future<void> persistMessageEnsuringConversation({
    required Conversation scaffold,
    required ChatMessage message,
  }) async {
    if (scaffold.id.isEmpty) return;
    try {
      await _conversationStore.upsertMessageEnsuringConversation(
        scaffold: scaffold,
        message: message,
      );
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to persist message',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
  }

  /// Update a single existing message in place. The conversation is
  /// resolved from the message's row.
  Future<void> persistUpdatedMessage(ChatMessage message) async {
    try {
      await _conversationStore.updateMessage(message);
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to persist message update',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
  }

  /// Remove a single message row.
  Future<void> persistMessageDeletion(
    String conversationId,
    String messageId,
  ) async {
    if (conversationId.isEmpty || messageId.isEmpty) return;
    try {
      await _conversationStore.deleteMessage(conversationId, messageId);
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to persist message deletion',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
  }

  Future<void> clearCachedConversation(String id) async {
    if (id.isEmpty) return;
    try {
      await _conversationStore.deleteConversation(id);
    } catch (_) {}
  }

  Future<void> clearAllCachedConversations() async {
    try {
      await _conversationStore.deleteAll();
    } catch (_) {}
  }

  /// Phase 4b — local full-text search over cached conversations and
  /// messages. Returns immediately without any network round-trip;
  /// callers are responsible for merging with server results if desired.
  Future<List<Conversation>> searchConversationsLocal(
    String query, {
    int limit = 50,
  }) async {
    try {
      return await _conversationStore.searchConversations(query, limit: limit);
    } catch (error, stack) {
      DebugLogger.error(
        'Local conversation search failed',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
      return const [];
    }
  }

  // ---------------------------------------------------------------------------
  // Per-file-info cache (Phase 2.1 — eliminate per-send getFileInfo round-trip).
  // ---------------------------------------------------------------------------
  String _fileInfoCacheKey(String fileId) => '$_cachedFileInfoPrefix$fileId';

  Future<FileInfo?> getCachedFileInfo(String fileId) async {
    if (fileId.isEmpty) return null;
    try {
      final stored = _cachesBox.get(_fileInfoCacheKey(fileId));
      if (stored == null) return null;
      Map<String, dynamic>? json;
      if (stored is String && stored.isNotEmpty) {
        final decoded = jsonDecode(stored);
        if (decoded is Map<String, dynamic>) {
          json = decoded;
        } else if (decoded is Map) {
          json = Map<String, dynamic>.from(decoded);
        }
      } else if (stored is Map) {
        json = Map<String, dynamic>.from(stored);
      }
      return json == null ? null : FileInfo.fromJson(json);
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to read cached file info',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
      return null;
    }
  }

  Future<void> cacheFileInfo(FileInfo info) async {
    if (info.id.isEmpty) return;
    try {
      final serialized = jsonEncode(info.toJson());
      await _cachesBox.put(_fileInfoCacheKey(info.id), serialized);
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to cache file info',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
  }

  Future<void> clearAllCachedFileInfo() async {
    try {
      final keys = _cachesBox.keys
          .whereType<String>()
          .where((k) => k.startsWith(_cachedFileInfoPrefix))
          .toList(growable: false);
      if (keys.isEmpty) return;
      await _cachesBox.deleteAll(keys);
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Composer drafts (Phase 2.6 — never lose typing across app restarts or
  // conversation switches). Keyed by conversation id, or 'new' for an
  // unstarted chat.
  // ---------------------------------------------------------------------------
  String _draftKey(String chatKey) =>
      '$_draftPrefix${chatKey.isEmpty ? 'new' : chatKey}';

  Future<String?> getDraft(String chatKey) async {
    try {
      final stored = _preferencesBox.get(_draftKey(chatKey));
      if (stored is String && stored.isNotEmpty) {
        return stored;
      }
    } catch (_) {}
    return null;
  }

  Future<void> saveDraft(String chatKey, String text) async {
    try {
      if (text.isEmpty) {
        await _preferencesBox.delete(_draftKey(chatKey));
        return;
      }
      await _preferencesBox.put(_draftKey(chatKey), text);
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to save draft',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
  }

  Future<void> clearDraft(String chatKey) async {
    try {
      await _preferencesBox.delete(_draftKey(chatKey));
    } catch (_) {}
  }

  Future<void> clearAllDrafts() async {
    try {
      final keys = _preferencesBox.keys
          .whereType<String>()
          .where((k) => k.startsWith(_draftPrefix))
          .toList(growable: false);
      if (keys.isEmpty) return;
      await _preferencesBox.deleteAll(keys);
    } catch (_) {}
  }

  Future<List<Folder>> getLocalFolders() async {
    try {
      final stored = _cachesBox.get(_localFoldersKey);
      if (stored == null) {
        return const [];
      }
      final parsed = await _workerManager
          .schedule<Map<String, dynamic>, List<Map<String, dynamic>>>(
            _decodeStoredJsonListWorker,
            {'stored': stored},
            debugLabel: 'decode_local_folders',
          );
      return parsed.map(Folder.fromJson).toList(growable: false);
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to retrieve local folders',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
      return const [];
    }
  }

  Future<void> saveLocalFolders(List<Folder> folders) async {
    try {
      final jsonReady = folders.map((folder) => folder.toJson()).toList();
      final serialized = await _workerManager
          .schedule<Map<String, dynamic>, String>(_encodeJsonListWorker, {
            'items': jsonReady,
          }, debugLabel: 'encode_local_folders');
      await _cachesBox.put(_localFoldersKey, serialized);
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to save local folders',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
  }

  Future<User?> getLocalUser() async {
    try {
      final stored = _cachesBox.get(_localUserKey);
      if (stored == null) return null;
      if (stored is String) {
        final decoded = jsonDecode(stored);
        if (decoded is Map<String, dynamic>) {
          return User.fromJson(decoded);
        }
      } else if (stored is Map<String, dynamic>) {
        return User.fromJson(stored);
      }
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to retrieve local user',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
    return null;
  }

  Future<void> saveLocalUser(User? user) async {
    try {
      if (user == null) {
        await _cachesBox.delete(_localUserKey);
        await _cachesBox.delete(_localUserAvatarKey);
        return;
      }
      final serialized = jsonEncode(user.toJson());
      await _cachesBox.put(_localUserKey, serialized);
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to save local user',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
  }

  Future<String?> getLocalUserAvatar() async {
    try {
      final stored = _cachesBox.get(_localUserAvatarKey);
      if (stored is String && stored.isNotEmpty) {
        return stored;
      }
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to retrieve local user avatar',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
    return null;
  }

  Future<void> saveLocalUserAvatar(String? avatarUrl) async {
    try {
      if (avatarUrl == null || avatarUrl.isEmpty) {
        await _cachesBox.delete(_localUserAvatarKey);
        return;
      }
      await _cachesBox.put(_localUserAvatarKey, avatarUrl);
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to save local user avatar',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
  }

  Future<BackendConfig?> getLocalBackendConfig() async {
    try {
      final stored = _cachesBox.get(_localBackendConfigKey);
      if (stored == null) return null;
      final activeServerId = await getActiveServerId();
      final (payload, ownerServerId) = _unwrapServerScoped(stored);
      if (!_matchesActiveServer(activeServerId, ownerServerId)) {
        return null;
      }
      if (payload is String) {
        final decoded = jsonDecode(payload);
        if (decoded is Map<String, dynamic>) {
          return BackendConfig.fromJson(decoded);
        }
      } else if (payload is Map) {
        return BackendConfig.fromJson(Map<String, dynamic>.from(payload));
      }
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to retrieve local backend config',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
    return null;
  }

  Future<void> saveLocalBackendConfig(BackendConfig? config) async {
    try {
      if (config == null) {
        await _cachesBox.delete(_localBackendConfigKey);
        return;
      }
      final serialized = jsonEncode(config.toJson());
      await _cachesBox.put(
        _localBackendConfigKey,
        _wrapServerScoped(serialized),
      );
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to save local backend config',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
  }

  Future<SocketTransportAvailability?> getLocalTransportOptions() async {
    try {
      final stored = _cachesBox.get(_localTransportOptionsKey);
      if (stored == null) return null;
      final activeServerId = await getActiveServerId();
      final (payload, ownerServerId) = _unwrapServerScoped(stored);
      if (!_matchesActiveServer(activeServerId, ownerServerId)) {
        return null;
      }
      if (payload is String) {
        final decoded = jsonDecode(payload);
        if (decoded is Map<String, dynamic>) {
          return _transportFromJson(decoded);
        }
      } else if (payload is Map) {
        return _transportFromJson(Map<String, dynamic>.from(payload));
      }
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to retrieve local transport options',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
    return null;
  }

  Future<void> saveLocalTransportOptions(
    SocketTransportAvailability? options,
  ) async {
    try {
      if (options == null) {
        await _cachesBox.delete(_localTransportOptionsKey);
        return;
      }
      final json = {
        'allowPolling': options.allowPolling,
        'allowWebsocketOnly': options.allowWebsocketOnly,
      };
      await _cachesBox.put(
        _localTransportOptionsKey,
        _wrapServerScoped(jsonEncode(json)),
      );
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to save local transport options',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
  }

  SocketTransportAvailability? getLocalTransportOptionsSync() {
    try {
      final stored = _cachesBox.get(_localTransportOptionsKey);
      if (stored == null) return null;
      final (payload, ownerServerId) = _unwrapServerScoped(stored);
      if (!_matchesActiveServer(_readActiveServerIdSync(), ownerServerId)) {
        return null;
      }
      if (payload is String) {
        final decoded = jsonDecode(payload);
        if (decoded is Map<String, dynamic>) {
          return _transportFromJson(decoded);
        }
      } else if (payload is Map) {
        return _transportFromJson(Map<String, dynamic>.from(payload));
      }
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to retrieve local transport options sync',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
    return null;
  }

  Future<List<Model>> getLocalModels() async {
    try {
      final stored = _cachesBox.get(_localModelsKey);
      if (stored == null) {
        return const [];
      }
      final activeServerId = await getActiveServerId();
      final (payload, ownerServerId) = _unwrapServerScoped(stored);
      if (!_matchesActiveServer(activeServerId, ownerServerId)) {
        return const [];
      }
      if (payload == null) return const [];
      final parsed = await _workerManager
          .schedule<Map<String, dynamic>, List<Map<String, dynamic>>>(
            _decodeStoredJsonListWorker,
            {'stored': payload},
            debugLabel: 'decode_local_models',
          );
      return parsed.map(Model.fromJson).toList(growable: false);
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to retrieve local models',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
      return const [];
    }
  }

  Future<void> saveLocalModels(List<Model> models) async {
    try {
      final jsonReady = models.map((model) => model.toJson()).toList();
      final serialized = await _workerManager
          .schedule<Map<String, dynamic>, String>(_encodeJsonListWorker, {
            'items': jsonReady,
          }, debugLabel: 'encode_local_models');
      await _cachesBox.put(_localModelsKey, _wrapServerScoped(serialized));
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to save local models',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
  }

  Future<List<Tool>> getLocalTools() async {
    try {
      final stored = _cachesBox.get(_localToolsKey);
      if (stored == null) return const [];
      final activeServerId = await getActiveServerId();
      final (payload, ownerServerId) = _unwrapServerScoped(stored);
      if (!_matchesActiveServer(activeServerId, ownerServerId)) {
        return const [];
      }
      if (payload == null) return const [];
      final parsed = await _workerManager
          .schedule<Map<String, dynamic>, List<Map<String, dynamic>>>(
            _decodeStoredJsonListWorker,
            {'stored': payload},
            debugLabel: 'decode_local_tools',
          );
      return parsed.map(Tool.fromJson).toList(growable: false);
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to retrieve local tools',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
      return const [];
    }
  }

  Future<void> saveLocalTools(List<Tool> tools) async {
    try {
      final jsonReady = tools.map((tool) => tool.toJson()).toList();
      final serialized = await _workerManager
          .schedule<Map<String, dynamic>, String>(_encodeJsonListWorker, {
            'items': jsonReady,
          }, debugLabel: 'encode_local_tools');
      await _cachesBox.put(_localToolsKey, _wrapServerScoped(serialized));
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to save local tools',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
  }

  Future<Model?> getLocalDefaultModel() async {
    try {
      final stored = _cachesBox.get(_localDefaultModelKey);
      if (stored == null) return null;
      final activeServerId = await getActiveServerId();
      final (payload, ownerServerId) = _unwrapServerScoped(stored);
      if (!_matchesActiveServer(activeServerId, ownerServerId)) {
        return null;
      }
      Model? parsed;
      if (payload is String) {
        final decoded = jsonDecode(payload);
        if (decoded is Map<String, dynamic>) {
          parsed = Model.fromJson(decoded);
        }
      } else if (payload is Map) {
        parsed = Model.fromJson(Map<String, dynamic>.from(payload));
      }
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
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to retrieve local default model',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
    return null;
  }

  Future<void> saveLocalDefaultModel(Model? model) async {
    try {
      if (model == null) {
        await _cachesBox.delete(_localDefaultModelKey);
        return;
      }
      final serialized = jsonEncode(model.toJson());
      await _cachesBox.put(
        _localDefaultModelKey,
        _wrapServerScoped(serialized),
      );
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to save local default model',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
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
      clearAllCachedConversations(),
      clearAllCachedFileInfo(),
      clearAllDrafts(),
      // Note: Server configs are NOT cleared - they persist across logouts
      // so users can quickly re-login without re-entering server details
    ]);

    _cacheManager.invalidateMatching(
      (key) => key.contains('auth') || key.contains('credentials'),
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
  (Object?, String?) _unwrapServerScoped(Object? stored) {
    if (stored is Map && stored.containsKey('data')) {
      final serverId = stored['serverId'];
      return (stored['data'], serverId is String ? serverId : null);
    }
    return (stored, null);
  }

  Map<String, Object?> _wrapServerScoped(Object data) {
    return {'data': data, 'serverId': _readActiveServerIdSync()};
  }

  bool _matchesActiveServer(String? activeServerId, String? ownerServerId) {
    if (ownerServerId == null || ownerServerId.isEmpty) {
      return activeServerId == null;
    }
    return activeServerId == ownerServerId;
  }

  String? _readActiveServerIdSync() {
    final (hit: hasCachedId, value: cachedId) = _cacheManager.lookup<String>(
      _activeServerIdKey,
    );
    if (hasCachedId) {
      return cachedId;
    }
    return _preferencesBox.get(_activeServerIdKey) as String?;
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
