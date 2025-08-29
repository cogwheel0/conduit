import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'secure_credential_storage.dart';
import '../models/server_config.dart';
import '../models/conversation.dart';

/// Optimized storage service with single secure storage implementation
/// Eliminates dual storage overhead and improves performance
class OptimizedStorageService {
  final SharedPreferences _prefs;
  final SecureCredentialStorage _secureCredentialStorage;

  OptimizedStorageService({
    required FlutterSecureStorage secureStorage,
    required SharedPreferences prefs,
  }) : _prefs = prefs,
       _secureCredentialStorage = SecureCredentialStorage();

  // Optimized key names with versioning
  static const String _authTokenKey = 'auth_token_v3';
  static const String _activeServerIdKey = 'active_server_id';
  static const String _rememberCredentialsKey = 'remember_credentials';
  static const String _themeModeKey = 'theme_mode';
  static const String _localeCodeKey = 'locale_code_v1';
  static const String _ttsLanguageKey = 'tts_language_v1';
  static const String _localConversationsKey = 'local_conversations';
  static const String _onboardingSeenKey = 'onboarding_seen_v1';
  static const String _reviewerModeKey = 'reviewer_mode_v1';

  // Cache for frequently accessed data
  final Map<String, dynamic> _cache = {};
  static const Duration _cacheTimeout = Duration(minutes: 5);
  final Map<String, DateTime> _cacheTimestamps = {};

  /// Auth Token Management (Optimized with caching)
  Future<void> saveAuthToken(String token) async {
    try {
      await _secureCredentialStorage.saveAuthToken(token);
      _cache[_authTokenKey] = token;
      _cacheTimestamps[_authTokenKey] = DateTime.now();
      debugPrint('DEBUG: Auth token saved and cached');
    } catch (e) {
      debugPrint('ERROR: Failed to save auth token: $e');
      rethrow;
    }
  }

  Future<String?> getAuthToken() async {
    // Check cache first
    if (_isCacheValid(_authTokenKey)) {
      final cachedToken = _cache[_authTokenKey] as String?;
      if (cachedToken != null) {
        debugPrint('DEBUG: Using cached auth token');
        return cachedToken;
      }
    }

    try {
      final token = await _secureCredentialStorage.getAuthToken();
      if (token != null) {
        _cache[_authTokenKey] = token;
        _cacheTimestamps[_authTokenKey] = DateTime.now();
      }
      return token;
    } catch (e) {
      debugPrint('ERROR: Failed to retrieve auth token: $e');
      return null;
    }
  }

  Future<void> deleteAuthToken() async {
    try {
      await _secureCredentialStorage.deleteAuthToken();
      _cache.remove(_authTokenKey);
      _cacheTimestamps.remove(_authTokenKey);
      debugPrint('DEBUG: Auth token deleted and cache cleared');
    } catch (e) {
      debugPrint('ERROR: Failed to delete auth token: $e');
    }
  }

  /// Credential Management (Single storage implementation)
  Future<void> saveCredentials({
    required String serverId,
    required String username,
    required String password,
  }) async {
    try {
      await _secureCredentialStorage.saveCredentials(
        serverId: serverId,
        username: username,
        password: password,
      );

      // Cache the fact that credentials exist (not the credentials themselves)
      _cache['has_credentials'] = true;
      _cacheTimestamps['has_credentials'] = DateTime.now();

      debugPrint('DEBUG: Credentials saved via optimized storage');
    } catch (e) {
      debugPrint('ERROR: Failed to save credentials: $e');
      rethrow;
    }
  }

  Future<Map<String, String>?> getSavedCredentials() async {
    try {
      // Use single storage implementation - no fallback needed
      final credentials = await _secureCredentialStorage.getSavedCredentials();

      // Update cache flag
      _cache['has_credentials'] = credentials != null;
      _cacheTimestamps['has_credentials'] = DateTime.now();

      return credentials;
    } catch (e) {
      debugPrint('ERROR: Failed to retrieve credentials: $e');
      return null;
    }
  }

  Future<void> deleteSavedCredentials() async {
    try {
      await _secureCredentialStorage.deleteSavedCredentials();
      _cache.remove('has_credentials');
      _cacheTimestamps.remove('has_credentials');
      debugPrint('DEBUG: Credentials deleted via optimized storage');
    } catch (e) {
      debugPrint('ERROR: Failed to delete credentials: $e');
    }
  }

  /// Quick check if credentials exist (uses cache)
  Future<bool> hasCredentials() async {
    if (_isCacheValid('has_credentials')) {
      return _cache['has_credentials'] == true;
    }

    final credentials = await getSavedCredentials();
    return credentials != null;
  }

  /// Remember Credentials Flag
  Future<void> setRememberCredentials(bool remember) async {
    await _prefs.setBool(_rememberCredentialsKey, remember);
  }

  bool getRememberCredentials() {
    return _prefs.getBool(_rememberCredentialsKey) ?? false;
  }

  /// Server Configuration (Optimized)
  Future<void> saveServerConfigs(List<ServerConfig> configs) async {
    try {
      final jsonString = jsonEncode(configs.map((c) => c.toJson()).toList());
      await _secureCredentialStorage.saveServerConfigs(jsonString);

      // Cache config count for quick checks
      _cache['server_config_count'] = configs.length;
      _cacheTimestamps['server_config_count'] = DateTime.now();

      debugPrint('DEBUG: Server configs saved (${configs.length} configs)');
    } catch (e) {
      debugPrint('ERROR: Failed to save server configs: $e');
      rethrow;
    }
  }

  Future<List<ServerConfig>> getServerConfigs() async {
    try {
      final jsonString = await _secureCredentialStorage.getServerConfigs();
      if (jsonString == null || jsonString.isEmpty) {
        _cache['server_config_count'] = 0;
        _cacheTimestamps['server_config_count'] = DateTime.now();
        return [];
      }

      final decoded = jsonDecode(jsonString) as List<dynamic>;
      final configs = decoded
          .map((item) => ServerConfig.fromJson(item))
          .toList();

      // Update cache
      _cache['server_config_count'] = configs.length;
      _cacheTimestamps['server_config_count'] = DateTime.now();

      return configs;
    } catch (e) {
      debugPrint('ERROR: Failed to retrieve server configs: $e');
      return [];
    }
  }

  /// Active Server Management
  Future<void> setActiveServerId(String? serverId) async {
    if (serverId != null) {
      await _prefs.setString(_activeServerIdKey, serverId);
    } else {
      await _prefs.remove(_activeServerIdKey);
    }

    // Update cache
    _cache[_activeServerIdKey] = serverId;
    _cacheTimestamps[_activeServerIdKey] = DateTime.now();
  }

  Future<String?> getActiveServerId() async {
    // Check cache first
    if (_isCacheValid(_activeServerIdKey)) {
      return _cache[_activeServerIdKey] as String?;
    }

    final serverId = _prefs.getString(_activeServerIdKey);
    _cache[_activeServerIdKey] = serverId;
    _cacheTimestamps[_activeServerIdKey] = DateTime.now();

    return serverId;
  }

  /// Theme Management
  String? getThemeMode() {
    return _prefs.getString(_themeModeKey);
  }

  Future<void> setThemeMode(String mode) async {
    await _prefs.setString(_themeModeKey, mode);
  }

  /// Locale Management
  String? getLocaleCode() {
    // Returns a locale code like 'en', 'de', 'fr', 'it'. Null means system.
    return _prefs.getString(_localeCodeKey);
  }

  Future<void> setLocaleCode(String? code) async {
    if (code == null || code.isEmpty) {
      await _prefs.remove(_localeCodeKey);
    } else {
      await _prefs.setString(_localeCodeKey, code);
    }
  }

  /// TTS Language Management
  String? getTTSLanguage() {
    // Returns a language code like 'en-US', 'es-ES', 'de-DE', 'fr-FR', 'it-IT'. Null means system.
    return _prefs.getString(_ttsLanguageKey);
  }

  Future<void> setTTSLanguage(String? languageCode) async {
    if (languageCode == null || languageCode.isEmpty) {
      await _prefs.remove(_ttsLanguageKey);
    } else {
      await _prefs.setString(_ttsLanguageKey, languageCode);
    }
  }

  /// Onboarding
  Future<bool> getOnboardingSeen() async {
    return _prefs.getBool(_onboardingSeenKey) ?? false;
  }

  Future<void> setOnboardingSeen(bool seen) async {
    await _prefs.setBool(_onboardingSeenKey, seen);
  }

  /// Reviewer mode (persisted)
  Future<bool> getReviewerMode() async {
    return _prefs.getBool(_reviewerModeKey) ?? false;
  }

  Future<void> setReviewerMode(bool enabled) async {
    await _prefs.setBool(_reviewerModeKey, enabled);
  }

  /// Local Conversations (Optimized with compression)
  Future<List<Conversation>> getLocalConversations() async {
    try {
      final jsonString = _prefs.getString(_localConversationsKey);
      if (jsonString == null || jsonString.isEmpty) return [];

      final decoded = jsonDecode(jsonString) as List<dynamic>;
      return decoded.map((item) => Conversation.fromJson(item)).toList();
    } catch (e) {
      debugPrint('ERROR: Failed to retrieve local conversations: $e');
      return [];
    }
  }

  Future<void> saveLocalConversations(List<Conversation> conversations) async {
    try {
      // Only save essential data to reduce storage size
      final lightweightConversations = conversations
          .map(
            (conv) => {
              'id': conv.id,
              'title': conv.title,
              'updatedAt': conv.updatedAt.toIso8601String(),
              'messageCount': conv.messages.length,
              // Don't save full message content locally
            },
          )
          .toList();

      final jsonString = jsonEncode(lightweightConversations);
      await _prefs.setString(_localConversationsKey, jsonString);

      debugPrint(
        'DEBUG: Saved ${conversations.length} local conversations (lightweight)',
      );
    } catch (e) {
      debugPrint('ERROR: Failed to save local conversations: $e');
    }
  }

  /// Batch Operations for Performance
  Future<void> clearAuthData() async {
    try {
      // Clear auth-related data in batch
      await Future.wait([
        deleteAuthToken(),
        deleteSavedCredentials(),
        _prefs.remove(_rememberCredentialsKey),
        _prefs.remove(_activeServerIdKey),
      ]);

      // Clear related cache entries
      _cache.removeWhere(
        (key, value) =>
            key.contains('auth') ||
            key.contains('credentials') ||
            key.contains('server'),
      );
      _cacheTimestamps.removeWhere(
        (key, value) =>
            key.contains('auth') ||
            key.contains('credentials') ||
            key.contains('server'),
      );

      debugPrint('DEBUG: Auth data cleared in batch operation');
    } catch (e) {
      debugPrint('ERROR: Failed to clear auth data: $e');
    }
  }

  Future<void> clearAll() async {
    try {
      await Future.wait([_secureCredentialStorage.clearAll(), _prefs.clear()]);

      _cache.clear();
      _cacheTimestamps.clear();

      debugPrint('DEBUG: All storage cleared');
    } catch (e) {
      debugPrint('ERROR: Failed to clear all storage: $e');
    }
  }

  /// Storage Health Check
  Future<bool> isSecureStorageAvailable() async {
    return await _secureCredentialStorage.isSecureStorageAvailable();
  }

  /// Cache Management Utilities
  bool _isCacheValid(String key) {
    final timestamp = _cacheTimestamps[key];
    if (timestamp == null) return false;

    return DateTime.now().difference(timestamp) < _cacheTimeout;
  }

  void clearCache() {
    _cache.clear();
    _cacheTimestamps.clear();
    debugPrint('DEBUG: Storage cache cleared');
  }

  /// Migration from old storage service (one-time operation)
  Future<void> migrateFromLegacyStorage() async {
    try {
      debugPrint('DEBUG: Starting migration from legacy storage');

      // This would be called once during app upgrade
      // Implementation would depend on the specific migration needs
      // For now, the SecureCredentialStorage already handles legacy migration

      debugPrint('DEBUG: Legacy storage migration completed');
    } catch (e) {
      debugPrint('ERROR: Legacy storage migration failed: $e');
    }
  }

  /// Performance Monitoring
  Map<String, dynamic> getStorageStats() {
    return {
      'cacheSize': _cache.length,
      'cachedKeys': _cache.keys.toList(),
      'lastAccess': _cacheTimestamps.entries
          .map((e) => '${e.key}: ${e.value}')
          .toList(),
    };
  }
}
