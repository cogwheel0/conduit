import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';
import '../utils/debug_logger.dart';

/// Enhanced secure credential storage with platform-specific optimizations
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

  /// Get Android-specific secure storage options
  AndroidOptions _getAndroidOptions() {
    return const AndroidOptions(
      // Keep legacy Android storage readable until a storageNamespace migration
      // can move both encrypted data and wrapped keys.
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
        'deviceId': await _getDeviceFingerprint(),
        'version': '2.1', // Version for migration purposes
      };

      final encryptedData = await _encryptData(jsonEncode(credentials));
      await _secureStorage.write(key: _credentialsKey, value: encryptedData);

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
      final encryptedData = await _secureStorage.read(key: _credentialsKey);
      if (encryptedData == null || encryptedData.isEmpty) {
        return null;
      }

      final jsonString = await _decryptData(encryptedData);
      final decoded = jsonDecode(jsonString);

      if (decoded is! Map<String, dynamic>) {
        DebugLogger.warning('invalid-format', scope: 'credentials');
        await deleteSavedCredentials();
        return null;
      }

      // Validate device fingerprint for additional security, but be more lenient
      final savedDeviceId = decoded['deviceId']?.toString();
      if (savedDeviceId != null) {
        final currentDeviceId = await _getDeviceFingerprint();

        if (savedDeviceId != currentDeviceId) {
          DebugLogger.info(
            'fingerprint-mismatch-allowed',
            scope: 'credentials',
            data: {'previous': savedDeviceId, 'current': currentDeviceId},
          );
          // Don't clear credentials immediately - allow the user to continue
          // They can re-login if needed, which will update the fingerprint
        }
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
      final encryptedToken = await _encryptData(token);
      await _secureStorage.write(key: _authTokenKey, value: encryptedToken);
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
      final encryptedToken = await _secureStorage.read(key: _authTokenKey);
      if (encryptedToken == null) return null;

      return await _decryptData(encryptedToken);
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

  /// Save server configurations securely
  Future<void> saveServerConfigs(String configsJson) async {
    try {
      final encryptedConfigs = await _encryptData(configsJson);
      await _secureStorage.write(
        key: _serverConfigsKey,
        value: encryptedConfigs,
      );
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
      final encryptedConfigs = await _secureStorage.read(
        key: _serverConfigsKey,
      );
      if (encryptedConfigs == null) return null;

      return await _decryptData(encryptedConfigs);
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

  /// Encrypt data using additional layer of encryption
  Future<String> _encryptData(String data) async {
    try {
      // For now, return the data as-is since FlutterSecureStorage already provides encryption
      // In a more advanced implementation, you could add an additional layer of AES encryption
      return data;
    } catch (e) {
      DebugLogger.error(
        'encrypt-failed',
        scope: 'credentials/crypto',
        error: e,
      );
      rethrow;
    }
  }

  /// Decrypt data
  Future<String> _decryptData(String encryptedData) async {
    try {
      // For now, return the data as-is since FlutterSecureStorage handles decryption
      // This matches the encryption method above
      return encryptedData;
    } catch (e) {
      DebugLogger.error(
        'decrypt-failed',
        scope: 'credentials/crypto',
        error: e,
      );
      rethrow;
    }
  }

  /// Generate a device fingerprint for additional security
  Future<String> _getDeviceFingerprint() async {
    try {
      // Create a more stable device fingerprint
      final platformInfo = {
        'platform': Platform.operatingSystem,
        // Use only major version to avoid fingerprint changes on minor updates
        'majorVersion': Platform.operatingSystemVersion.split('.').first,
        'isPhysicalDevice': true, // In a real implementation, you'd detect this
        // Add a static component to ensure consistency
        'appId': 'conduit_app_v1',
      };

      final fingerprintData = jsonEncode(platformInfo);
      final bytes = utf8.encode(fingerprintData);
      final digest = sha256.convert(bytes);

      return digest.toString();
    } catch (e) {
      DebugLogger.warning(
        'fingerprint-failed',
        scope: 'credentials',
        data: {'error': e.toString()},
      );
      // Return a consistent fallback fingerprint
      return 'stable_fallback_device_id';
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
