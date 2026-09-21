import 'package:conduit_core/services/cache_manager.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_core/auth/auth_state_manager.dart';

/// Comprehensive caching manager for auth-related operations.
///
/// Delegates to the shared [CacheManager] to keep TTL and eviction behavior
/// consistent across the app.
class AuthCacheManager {
  static final AuthCacheManager _instance = AuthCacheManager._internal();
  factory AuthCacheManager() => _instance;
  AuthCacheManager._internal();

  static const Duration _shortCache = Duration(minutes: 2);
  static const Duration _mediumCache = Duration(minutes: 5);
  static const Duration _longCache = Duration(minutes: 15);

  static const String _userDataKey = 'user_data';
  static const String _serverConnectionKey = 'server_connection';
  static const String _credentialsExistKey = 'credentials_exist';
  static const String _serverConfigsKey = 'server_configs';
  static const String _authStatusKey = 'auth_status';

  final CacheManager _cache = CacheManager(
    defaultTtl: _mediumCache,
    maxEntries: 32,
  );

  void cacheUserData(dynamic userData) {
    _cache.write<dynamic>(_userDataKey, userData, ttl: _mediumCache);
    DebugLogger.storage('User data cached');
  }

  dynamic getCachedUserData() {
    final (hit: hit, value: user) = _cache.lookup<dynamic>(_userDataKey);
    if (hit) {
      DebugLogger.storage('Using cached user data');
    }
    return user;
  }

  void cacheServerConnection(bool isConnected) {
    _cache.write<bool>(_serverConnectionKey, isConnected, ttl: _shortCache);
  }

  bool? getCachedServerConnection() {
    final (hit: hit, value: connection) = _cache.lookup<bool>(
      _serverConnectionKey,
    );
    return hit ? connection : null;
  }

  void cacheCredentialsExist(bool exist) {
    _cache.write<bool>(_credentialsExistKey, exist, ttl: _mediumCache);
  }

  bool? getCachedCredentialsExist() {
    final (hit: hit, value: hasCreds) = _cache.lookup<bool>(
      _credentialsExistKey,
    );
    return hit ? hasCreds : null;
  }

  void cacheServerConfigs(List<dynamic> configs) {
    _cache.write<List<dynamic>>(_serverConfigsKey, configs, ttl: _longCache);
  }

  List<dynamic>? getCachedServerConfigs() {
    final (hit: hit, value: configs) = _cache.lookup<List<dynamic>>(
      _serverConfigsKey,
    );
    return hit ? configs : null;
  }

  void clearCacheEntry(String key) {
    _cache.invalidate(key);
    DebugLogger.storage('Cache entry cleared: $key');
  }

  void clearAuthCache() {
    _cache.clear();
    DebugLogger.storage(
      'All auth cache cleared (including server configs and custom headers)',
    );
  }

  void cleanExpiredCache() {
    final stats = _cache.stats();
    final entries = stats['entries'];
    if (entries is! Map<String, dynamic>) return;

    var expiredCount = 0;
    entries.forEach((key, value) {
      if (value is! Map) return;
      final ageSeconds = value['ageSeconds'];
      final ttlSeconds = value['ttlSeconds'];
      if (ageSeconds is num && ttlSeconds is num && ageSeconds > ttlSeconds) {
        _cache.invalidate(key);
        expiredCount++;
      }
    });

    if (expiredCount > 0) {
      DebugLogger.storage('Cleaned $expiredCount expired auth cache entries');
    }
  }

  Map<String, dynamic> getCacheStats() => _cache.stats();

  void optimizeCache() {
    // CacheManager enforces maxEntries using LRU; no extra work needed.
  }

  void cacheAuthState(AuthState authState) {
    if (authState.user != null) {
      cacheUserData(authState.user);
    }
    if (authState.status == AuthStatus.authenticated) {
      _cache.write<AuthStatus>(
        _authStatusKey,
        authState.status,
        ttl: _shortCache,
      );
    }
  }

  AuthStatus? getCachedAuthStatus() {
    final (hit: hit, value: status) = _cache.lookup<AuthStatus>(_authStatusKey);
    return hit ? status : null;
  }
}
