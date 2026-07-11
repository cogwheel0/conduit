import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../utils/debug_logger.dart';

/// Secure credential storage with platform-specific options.
///
/// Values are protected by the platform keychain/keystore via
/// FlutterSecureStorage; no additional app-level encryption is applied.
class SecureCredentialStorage {
  late final FlutterSecureStorage _secureStorage;

  SecureCredentialStorage({FlutterSecureStorage? instance}) {
    _secureStorage =
        instance ??
        FlutterSecureStorage(
          aOptions: _getAndroidOptions(),
          iOptions: _getIOSOptions(),
        );
  }

  static const String _credentialsKey = 'user_credentials_v2';
  static const String _serverConfigsKey = 'server_configs_v2';
  static const String _authTokenKey = 'auth_token_v2';
  static const String _hermesApiKeyKey = 'hermes_api_key_v1';
  static const String _hermesSessionKeyKey = 'hermes_session_key_v1';
  static const String _directConnectionProfilesKey =
      'direct_connection_profiles_v1';

  /// Get Android-specific secure storage options
  AndroidOptions _getAndroidOptions() {
    return const AndroidOptions(
      // Keep legacy Android storage readable until a storageNamespace migration
      // can move both stored data and wrapped keys.
      // ignore: deprecated_member_use
      sharedPreferencesName: 'conduit_secure_prefs',
      preferencesKeyPrefix: 'conduit_',
      // Avoid auto-wipe on transient errors; handle gracefully in code
      resetOnError: false,
    );
  }

  /// Get iOS-specific secure storage options
  IOSOptions _getIOSOptions() {
    return const IOSOptions(
      accountName: 'conduit_secure_storage',
      synchronizable: false,
    );
  }

  /// Save user credentials securely.
  ///
  /// [authType] identifies the authentication method:
  /// - 'credentials': Standard email/password login (default)
  /// - 'ldap': LDAP directory authentication
  /// - 'token': Manual JWT token entry
  /// - 'sso': JWT token obtained via SSO/OAuth flow
  Future<void> saveCredentials({
    required String serverId,
    required String username,
    required String password,
    String authType = 'credentials',
  }) async {
    try {
      // First check if secure storage is available
      final isAvailable = await isSecureStorageAvailable();
      if (!isAvailable) {
        throw Exception('Secure storage is not available on this device');
      }

      final credentials = {
        'serverId': serverId,
        'username': username,
        'password': password,
        'authType': authType,
        'savedAt': DateTime.now().toIso8601String(),
        'version': '2.1', // Version for migration purposes
      };

      final payload = jsonEncode(credentials);
      await _secureStorage.write(key: _credentialsKey, value: payload);

      // Verify the save was successful by attempting to read it back
      final verifyData = await _secureStorage.read(key: _credentialsKey);
      if (verifyData == null || verifyData.isEmpty) {
        throw Exception(
          'Failed to verify credential save - storage returned null',
        );
      }

      DebugLogger.storage(
        'save-ok',
        scope: 'credentials',
        data: {'version': '2.1'},
      );
    } catch (e) {
      DebugLogger.error('save-failed', scope: 'credentials', error: e);
      rethrow;
    }
  }

  /// Retrieve saved credentials
  Future<Map<String, String>?> getSavedCredentials() async {
    try {
      final storedData = await _secureStorage.read(key: _credentialsKey);
      if (storedData == null || storedData.isEmpty) {
        return null;
      }

      final jsonString = storedData;
      final decoded = jsonDecode(jsonString);

      if (decoded is! Map<String, dynamic>) {
        DebugLogger.warning('invalid-format', scope: 'credentials');
        await deleteSavedCredentials();
        return null;
      }

      // Validate required fields
      if (!decoded.containsKey('serverId') ||
          !decoded.containsKey('username') ||
          !decoded.containsKey('password')) {
        DebugLogger.warning('missing-fields', scope: 'credentials');
        await deleteSavedCredentials();
        return null;
      }

      // Check if credentials are too old (optional expiration)
      final savedAt = decoded['savedAt']?.toString();
      if (savedAt != null) {
        try {
          final savedTime = DateTime.parse(savedAt);
          final now = DateTime.now();
          final daysSinceCreated = now.difference(savedTime).inDays;

          // Warn if credentials are very old (but don't delete them)
          if (daysSinceCreated > 90) {
            DebugLogger.info(
              'credentials-old',
              scope: 'credentials',
              data: {'ageDays': daysSinceCreated},
            );
          }
        } catch (e) {
          DebugLogger.warning(
            'savedat-parse-failed',
            scope: 'credentials',
            data: {'raw': savedAt, 'error': e.toString()},
          );
        }
      }

      return {
        'serverId': decoded['serverId']?.toString() ?? '',
        'username': decoded['username']?.toString() ?? '',
        'password': decoded['password']?.toString() ?? '',
        'savedAt': decoded['savedAt']?.toString() ?? '',
        'authType': decoded['authType']?.toString() ?? 'credentials',
      };
    } catch (e) {
      DebugLogger.error('read-failed', scope: 'credentials', error: e);
      // Don't delete credentials on retrieval errors - they might be recoverable
      return null;
    }
  }

  /// Delete saved credentials
  Future<void> deleteSavedCredentials() async {
    try {
      await _secureStorage.delete(key: _credentialsKey);
      DebugLogger.storage('delete-ok', scope: 'credentials');
    } catch (e) {
      DebugLogger.error('delete-failed', scope: 'credentials', error: e);
      rethrow;
    }
  }

  /// Save auth token securely
  Future<void> saveAuthToken(String token) async {
    try {
      await _secureStorage.write(key: _authTokenKey, value: token);
    } catch (e) {
      DebugLogger.error(
        'save-token-failed',
        scope: 'credentials/token',
        error: e,
      );
      rethrow;
    }
  }

  /// Get auth token
  Future<String?> getAuthToken() async {
    try {
      final storedToken = await _secureStorage.read(key: _authTokenKey);
      if (storedToken == null) return null;

      return storedToken;
    } catch (e) {
      DebugLogger.error(
        'read-token-failed',
        scope: 'credentials/token',
        error: e,
      );
      return null;
    }
  }

  /// Delete auth token
  Future<void> deleteAuthToken() async {
    try {
      await _secureStorage.delete(key: _authTokenKey);
    } catch (e) {
      DebugLogger.error(
        'delete-token-failed',
        scope: 'credentials/token',
        error: e,
      );
      rethrow;
    }
  }

  /// Save the Hermes Agent API key (bearer token for the direct Hermes backend).
  Future<void> saveHermesApiKey(String apiKey) async {
    try {
      await _secureStorage.write(key: _hermesApiKeyKey, value: apiKey);
    } catch (e) {
      DebugLogger.error('save-failed', scope: 'hermes/api-key', error: e);
      rethrow;
    }
  }

  /// Get the Hermes Agent API key, or null when none is stored.
  Future<String?> getHermesApiKey() =>
      _readHermesSecret(_hermesApiKeyKey, scope: 'hermes/api-key');

  Future<String?> _readHermesSecret(String key, {required String scope}) async {
    try {
      return await _secureStorage.read(key: key);
    } catch (error) {
      // Keychain/keystore access can fail transiently while the platform is
      // unlocking. Retry once rather than treating a configured backend as if
      // its secret were absent for the remainder of this app session.
      DebugLogger.warning(
        'read-retrying',
        scope: scope,
        data: {'error': error.toString()},
      );
    }

    try {
      return await _secureStorage.read(key: key);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'read-failed',
        scope: scope,
        error: error,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Delete the Hermes Agent API key.
  Future<void> deleteHermesApiKey() async {
    try {
      await _secureStorage.delete(key: _hermesApiKeyKey);
    } catch (e) {
      DebugLogger.error('delete-failed', scope: 'hermes/api-key', error: e);
      rethrow;
    }
  }

  /// Save the Hermes long-term memory session key (`X-Hermes-Session-Key`).
  Future<void> saveHermesSessionKey(String sessionKey) async {
    try {
      await _secureStorage.write(key: _hermesSessionKeyKey, value: sessionKey);
    } catch (e) {
      DebugLogger.error('save-failed', scope: 'hermes/session-key', error: e);
      rethrow;
    }
  }

  /// Get the Hermes long-term memory session key, or null when none is stored.
  Future<String?> getHermesSessionKey() =>
      _readHermesSecret(_hermesSessionKeyKey, scope: 'hermes/session-key');

  /// Delete the Hermes long-term memory session key.
  Future<void> deleteHermesSessionKey() async {
    try {
      await _secureStorage.delete(key: _hermesSessionKeyKey);
    } catch (e) {
      DebugLogger.error('delete-failed', scope: 'hermes/session-key', error: e);
      rethrow;
    }
  }

  /// Persists the complete versioned direct-connection document securely.
  ///
  /// Profiles include API keys, custom headers, and optional mTLS material, so
  /// their serialized representation must never be placed in preferences.
  Future<void> saveDirectConnectionProfiles(String profilesJson) async {
    try {
      await _secureStorage.write(
        key: _directConnectionProfilesKey,
        value: profilesJson,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'save-failed',
        scope: 'direct-connections/profiles',
        error: error,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Reads the versioned direct-connection document from secure storage.
  /// Storage failures are surfaced rather than being confused with no config.
  Future<String?> getDirectConnectionProfiles() async {
    try {
      return await _secureStorage.read(key: _directConnectionProfilesKey);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'read-failed',
        scope: 'direct-connections/profiles',
        error: error,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> deleteDirectConnectionProfiles() async {
    try {
      await _secureStorage.delete(key: _directConnectionProfilesKey);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'delete-failed',
        scope: 'direct-connections/profiles',
        error: error,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Save server configurations securely
  Future<void> saveServerConfigs(String configsJson) async {
    try {
      await _secureStorage.write(key: _serverConfigsKey, value: configsJson);
    } catch (e) {
      DebugLogger.error(
        'save-configs-failed',
        scope: 'credentials/server-configs',
        error: e,
      );
      rethrow;
    }
  }

  /// Get server configurations
  Future<String?> getServerConfigs() async {
    try {
      final storedConfigs = await _secureStorage.read(key: _serverConfigsKey);
      if (storedConfigs == null) return null;

      return storedConfigs;
    } catch (e) {
      DebugLogger.error(
        'read-configs-failed',
        scope: 'credentials/server-configs',
        error: e,
      );
      rethrow;
    }
  }

  /// Check if secure storage is available
  Future<bool> isSecureStorageAvailable() async {
    try {
      // Test write and read
      const testKey = 'test_availability';
      const testValue = 'test';

      await _secureStorage.write(key: testKey, value: testValue);
      final result = await _secureStorage.read(key: testKey);
      await _secureStorage.delete(key: testKey);

      return result == testValue;
    } catch (e) {
      DebugLogger.warning(
        'storage-unavailable',
        scope: 'credentials/health',
        data: {'error': e.toString()},
      );
      return false;
    }
  }

  /// Clear all secure data including credentials, tokens, and server configurations
  /// (which contain custom headers)
  Future<void> clearAll() async {
    try {
      await _secureStorage.deleteAll();
      DebugLogger.storage(
        'clear-ok (all secure data including server configs with custom headers)',
        scope: 'credentials',
      );
    } catch (e) {
      DebugLogger.error('clear-failed', scope: 'credentials', error: e);
    }
  }

  /// Migrate from old storage format if needed.
  ///
  /// Preserves the [authType] if present in old credentials.
  Future<void> migrateFromOldStorage(
    Map<String, String>? oldCredentials,
  ) async {
    if (oldCredentials == null) return;

    try {
      await saveCredentials(
        serverId: oldCredentials['serverId'] ?? '',
        username: oldCredentials['username'] ?? '',
        password: oldCredentials['password'] ?? '',
        authType: oldCredentials['authType'] ?? 'credentials',
      );
      DebugLogger.storage('migrate-ok', scope: 'credentials');
    } catch (e) {
      DebugLogger.error('migrate-failed', scope: 'credentials', error: e);
    }
  }
}
