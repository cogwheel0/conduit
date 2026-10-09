import 'dart:convert';

import 'package:conduit_core/conduit_core.dart';

import 'dart:math';

import 'package:conduit_core/utils/debug_logger.dart';

/// Secure credential storage with platform-specific options.
///
/// Values are protected by the platform keychain/keystore via
/// SecureKeyValueStore; no additional app-level encryption is applied.
class SecureCredentialStorage {
  /// [instance] is required. It used to default to a
  /// `FlutterSecureStorage` configured here, which quietly made this class a
  /// second place platform options had to be kept in step; they now live
  /// once, in `FlutterSecureKeyValueStore`.
  SecureCredentialStorage({required SecureKeyValueStore instance})
    : _secureStorage = instance;

  final SecureKeyValueStore _secureStorage;

  static const String _credentialsKey = 'user_credentials_v2';

  /// The one-server layout's config list. Read once, to build the registry,
  /// then deleted.
  static const String _serverConfigsKey = 'server_configs_v2';
  static const String _openWebUiRegistryKey = 'openwebui_registry_v1';
  static const String _authTokenKey = 'auth_token_v2';
  static const String _hermesApiKeyKey = 'hermes_api_key_v1';
  static const String _hermesSessionKeyKey = 'hermes_session_key_v1';
  static const String _hermesDesktopCredentialsKey =
      'hermes_desktop_credentials_v1';
  static const String _directConnectionProfilesKey =
      'direct_connection_profiles_v1';
  static const String _directMcpServersKey = 'direct_mcp_servers_v1';
  static const String _openWebUiDirectIdentityKey =
      'openwebui_direct_identity_key_v1';
  // Released once drained: a retained completed tail would keep its creating
  // zone alive, and strands later callers if that zone stops running (as a
  // finished fake-async widget test does).
  static Future<void>? _openWebUiDirectIdentityKeyQueue;
  static bool _openWebUiDirectIdentityWritesBlocked = false;

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
        scope: 'credentials/storage',
        data: {'version': '2.1'},
      );
    } catch (e) {
      DebugLogger.error('save-failed', scope: 'credentials/storage', error: e);
      rethrow;
    }
  }

  /// Retrieve saved credentials
  Future<Map<String, String>?> getSavedCredentials() async {
    final String? storedData;
    try {
      storedData = await _secureStorage.read(key: _credentialsKey);
    } catch (error, stackTrace) {
      // A Keychain/keystore read failure is not proof that credentials are
      // absent. Propagate it so the optimized storage layer can retry without
      // negative-caching a transient platform failure.
      DebugLogger.error(
        'read-failed',
        scope: 'credentials/storage',
        error: error,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }

    if (storedData == null || storedData.isEmpty) {
      return null;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(storedData);
    } catch (error) {
      // Parsing failures are distinct from platform read failures. Preserve the
      // payload here: a future app version may still be able to recover it.
      // FormatException messages may quote the malformed JSON, including
      // credential values, so only record its non-sensitive runtime type.
      DebugLogger.error(
        'decode-failed',
        scope: 'credentials/storage',
        data: {'errorType': error.runtimeType.toString()},
      );
      return null;
    }

    if (decoded is! Map<String, dynamic>) {
      DebugLogger.warning('invalid-format', scope: 'credentials/storage');
      await deleteSavedCredentials();
      return null;
    }

    // Do not coerce malformed JSON values into apparently usable credentials.
    // Password content is intentionally not trimmed: spaces and control
    // characters can be legitimate password bytes, but the value must exist.
    final serverId = decoded['serverId'];
    final username = decoded['username'];
    final password = decoded['password'];
    if (serverId is! String ||
        serverId.trim().isEmpty ||
        username is! String ||
        username.trim().isEmpty ||
        password is! String ||
        password.isEmpty) {
      DebugLogger.warning(
        'invalid-required-fields',
        scope: 'credentials/storage',
      );
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
            scope: 'credentials/storage',
            data: {'ageDays': daysSinceCreated},
          );
        }
      } catch (error) {
        DebugLogger.warning(
          'savedat-parse-failed',
          scope: 'credentials/storage',
          data: {
            'errorType': error.runtimeType.toString(),
            'valueLength': savedAt.length,
          },
        );
      }
    }

    return {
      'serverId': serverId,
      'username': username,
      'password': password,
      'savedAt': decoded['savedAt']?.toString() ?? '',
      'authType': decoded['authType']?.toString() ?? 'credentials',
    };
  }

  /// Returns the exact versioned credential payload without converting a
  /// Keychain/keystore read failure into an absent value.
  ///
  /// Auth-session transactions use this to restore the prior credential bytes
  /// if a later ownership/token write fails. The public parsed read remains
  /// intentionally forgiving for normal bootstrap behavior.
  Future<String?> getSavedCredentialsPayloadStrict() =>
      _secureStorage.read(key: _credentialsKey);

  /// Restores an exact payload captured by
  /// [getSavedCredentialsPayloadStrict], or removes it when none existed.
  Future<void> restoreSavedCredentialsPayload(String? payload) {
    if (payload == null) {
      return _secureStorage.delete(key: _credentialsKey);
    }
    return _secureStorage.write(key: _credentialsKey, value: payload);
  }

  /// Delete saved credentials
  Future<void> deleteSavedCredentials() async {
    try {
      await _secureStorage.delete(key: _credentialsKey);
      DebugLogger.storage('delete-ok', scope: 'credentials/storage');
    } catch (e) {
      DebugLogger.error(
        'delete-failed',
        scope: 'credentials/storage',
        error: e,
      );
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

  /// Read the auth token without converting a Keychain/keystore failure into
  /// an absent token.
  ///
  /// Transactional callers use this before changing any durable auth state so
  /// a transient platform read failure cannot be mistaken for a legitimate
  /// null snapshot and erase an existing session during rollback.
  Future<String?> getAuthTokenStrict() =>
      _secureStorage.read(key: _authTokenKey);

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

  // ---------------------------------------------------------------------
  // Per-server token vault
  // ---------------------------------------------------------------------
  //
  // [_authTokenKey] above is the *active* session, and the whole ownership
  // machinery in OptimizedStorageService and AuthStateManager is built around
  // there being exactly one. That stays true. The vault is where a token goes
  // while its server is not the active one, so switching servers does not
  // have to mean signing in again.
  //
  // Deliberately additive rather than a re-keying of the active token: the
  // revocation markers, the incomplete-logout fence and the rollback
  // arbitration all reason about "the token", and giving that phrase a
  // parameter would touch every one of them.

  static const String _serverTokenPrefix = 'auth_token_server_v1:';

  static String _serverTokenKey(String serverId) =>
      '$_serverTokenPrefix$serverId';

  /// Stores [token] against [serverId] for later reuse.
  Future<void> saveServerToken(String serverId, String token) async {
    try {
      await _secureStorage.write(key: _serverTokenKey(serverId), value: token);
    } catch (e) {
      DebugLogger.error(
        'save-server-token-failed',
        scope: 'credentials/token',
        error: e,
      );
      rethrow;
    }
  }

  /// Reads the vaulted token for [serverId].
  ///
  /// Strict, like [getAuthTokenStrict]: a platform read failure must not be
  /// mistaken for "that server has no session", which would silently demand a
  /// fresh sign-in for a server that is in fact still signed in.
  Future<String?> getServerToken(String serverId) =>
      _secureStorage.read(key: _serverTokenKey(serverId));

  Future<void> deleteServerToken(String serverId) async {
    try {
      await _secureStorage.delete(key: _serverTokenKey(serverId));
    } catch (e) {
      DebugLogger.error(
        'delete-server-token-failed',
        scope: 'credentials/token',
        error: e,
      );
      rethrow;
    }
  }

  /// Empties the vault.
  ///
  /// Sign-out has to call this. Clearing only the active token would leave
  /// every other server's session sitting in the keychain, so "sign out"
  /// would not be true -- and switching back afterwards would silently
  /// resurrect a session the user believed they had ended.
  Future<void> deleteAllServerTokens() async {
    try {
      final all = await _secureStorage.readAll();
      for (final key in all.keys) {
        if (key.startsWith(_serverTokenPrefix)) {
          await _secureStorage.delete(key: key);
        }
      }
    } catch (e) {
      DebugLogger.error(
        'delete-server-tokens-failed',
        scope: 'credentials/token',
        error: e,
      );
      rethrow;
    }
  }

  /// Server ids that currently hold a vaulted token or vaulted credentials.
  Future<Set<String>> vaultedServerIds() async {
    final all = await _secureStorage.readAll();
    return <String>{
      for (final key in all.keys)
        if (key.startsWith(_serverTokenPrefix))
          key.substring(_serverTokenPrefix.length)
        else if (key.startsWith(_serverCredentialsPrefix))
          key.substring(_serverCredentialsPrefix.length),
    };
  }

  // The saved sign-in of an account that is not the active one. Like the
  // token vault, it sits beside the single live slot ([_credentialsKey]) so
  // the arbitration built around "the saved credentials" keeps one meaning:
  // the live slot always belongs to the active account, and a switch moves
  // the payload between the two, byte for byte.
  static const String _serverCredentialsPrefix = 'user_credentials_server_v1:';

  static String _serverCredentialsKey(String serverId) =>
      '$_serverCredentialsPrefix$serverId';

  Future<void> saveServerCredentialsPayload(
    String serverId,
    String payload,
  ) async {
    try {
      await _secureStorage.write(
        key: _serverCredentialsKey(serverId),
        value: payload,
      );
    } catch (e) {
      DebugLogger.error(
        'save-server-credentials-failed',
        scope: 'credentials/storage',
        error: e,
      );
      rethrow;
    }
  }

  /// Strict: a platform failure is not "this account has no saved sign-in".
  Future<String?> getServerCredentialsPayload(String serverId) =>
      _secureStorage.read(key: _serverCredentialsKey(serverId));

  Future<void> deleteServerCredentials(String serverId) =>
      _secureStorage.delete(key: _serverCredentialsKey(serverId));

  Future<void> deleteAllServerCredentials() async {
    final all = await _secureStorage.readAll();
    for (final key in all.keys) {
      if (key.startsWith(_serverCredentialsPrefix)) {
        await _secureStorage.delete(key: key);
      }
    }
  }

  /// Hermes secrets are scoped to one saved connection:
  /// `hermes_api_key_v1:<connectionId>` and so on. The unscoped keys belong to
  /// the single connection stored before saved connections existed and are
  /// only read to migrate them.
  static String _hermesSecretKey(HermesSecretKind kind, String connectionId) {
    if (!_hermesConnectionIdPattern.hasMatch(connectionId)) {
      throw ArgumentError.value(connectionId, 'connectionId', 'Invalid id');
    }
    return '${_legacyHermesSecretKey(kind)}:$connectionId';
  }

  static final RegExp _hermesConnectionIdPattern = RegExp(
    r'^[A-Za-z0-9_-]{1,64}$',
  );

  static String _legacyHermesSecretKey(HermesSecretKind kind) =>
      switch (kind) {
        HermesSecretKind.apiKey => _hermesApiKeyKey,
        HermesSecretKind.sessionKey => _hermesSessionKeyKey,
        HermesSecretKind.desktopCredentials => _hermesDesktopCredentialsKey,
      };

  static String _hermesSecretScope(HermesSecretKind kind) => switch (kind) {
    HermesSecretKind.apiKey => 'hermes/api-key',
    HermesSecretKind.sessionKey => 'hermes/session-key',
    HermesSecretKind.desktopCredentials => 'hermes/desktop-credentials',
  };

  /// Reads one connection's secret, or null when none is stored. A thrown
  /// keychain failure is not reported as a missing secret.
  Future<String?> readHermesSecret(
    HermesSecretKind kind,
    String connectionId,
  ) => _readHermesSecret(
    _hermesSecretKey(kind, connectionId),
    scope: _hermesSecretScope(kind),
  );

  /// Writes one connection's secret. Callers own validation of Desktop
  /// credential JSON; this class deliberately never logs a payload.
  Future<void> writeHermesSecret(
    HermesSecretKind kind,
    String connectionId,
    String value,
  ) async {
    try {
      await _secureStorage.write(
        key: _hermesSecretKey(kind, connectionId),
        value: value,
      );
    } catch (e) {
      DebugLogger.error(
        'save-failed',
        scope: _hermesSecretScope(kind),
        error: e,
      );
      rethrow;
    }
  }

  Future<void> deleteHermesSecret(
    HermesSecretKind kind,
    String connectionId,
  ) async {
    try {
      await _secureStorage.delete(key: _hermesSecretKey(kind, connectionId));
    } catch (e) {
      DebugLogger.error(
        'delete-failed',
        scope: _hermesSecretScope(kind),
        error: e,
      );
      rethrow;
    }
  }

  /// Removes every secret saved for one Hermes connection. Attempts each key
  /// and rethrows the first failure afterwards.
  Future<void> deleteHermesConnectionSecrets(String connectionId) async {
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final kind in HermesSecretKind.values) {
      try {
        await deleteHermesSecret(kind, connectionId);
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  /// Reads a secret stored before saved connections existed.
  Future<String?> readLegacyHermesSecret(HermesSecretKind kind) =>
      _readHermesSecret(
        _legacyHermesSecretKey(kind),
        scope: _hermesSecretScope(kind),
      );

  Future<void> deleteLegacyHermesSecret(HermesSecretKind kind) async {
    try {
      await _secureStorage.delete(key: _legacyHermesSecretKey(kind));
    } catch (e) {
      DebugLogger.error(
        'legacy-delete-failed',
        scope: _hermesSecretScope(kind),
        error: e,
      );
      rethrow;
    }
  }

  /// Save a connection's Hermes Agent API key (its bearer token).
  Future<void> saveHermesApiKey(String connectionId, String apiKey) =>
      writeHermesSecret(HermesSecretKind.apiKey, connectionId, apiKey);

  /// Get a connection's Hermes Agent API key, or null when none is stored.
  Future<String?> getHermesApiKey(String connectionId) =>
      readHermesSecret(HermesSecretKind.apiKey, connectionId);

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

  /// Delete a connection's Hermes Agent API key.
  Future<void> deleteHermesApiKey(String connectionId) =>
      deleteHermesSecret(HermesSecretKind.apiKey, connectionId);

  /// Save a connection's long-term memory session key
  /// (`X-Hermes-Session-Key`).
  Future<void> saveHermesSessionKey(String connectionId, String sessionKey) =>
      writeHermesSecret(HermesSecretKind.sessionKey, connectionId, sessionKey);

  /// Get a connection's long-term memory session key, or null when none is
  /// stored.
  Future<String?> getHermesSessionKey(String connectionId) =>
      readHermesSecret(HermesSecretKind.sessionKey, connectionId);

  /// Delete a connection's long-term memory session key.
  Future<void> deleteHermesSessionKey(String connectionId) =>
      deleteHermesSecret(HermesSecretKind.sessionKey, connectionId);

  /// Persists a connection's versioned Desktop Gateway credential document.
  Future<void> saveHermesDesktopCredentials(
    String connectionId,
    String value,
  ) => writeHermesSecret(
    HermesSecretKind.desktopCredentials,
    connectionId,
    value,
  );

  Future<String?> getHermesDesktopCredentials(String connectionId) =>
      readHermesSecret(HermesSecretKind.desktopCredentials, connectionId);

  Future<void> deleteHermesDesktopCredentials(String connectionId) =>
      deleteHermesSecret(HermesSecretKind.desktopCredentials, connectionId);

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

  /// Persists the complete MCP server document without logging its payload.
  Future<void> saveDirectMcpServers(String serversJson) async {
    try {
      await _secureStorage.write(key: _directMcpServersKey, value: serversJson);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'save-failed',
        scope: 'direct-connections/mcp/storage',
        error: error,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<String?> getDirectMcpServers() async {
    try {
      return await _secureStorage.read(key: _directMcpServersKey);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'read-failed',
        scope: 'direct-connections/mcp/storage',
        error: error,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> deleteDirectMcpServers() async {
    try {
      await _secureStorage.delete(key: _directMcpServersKey);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'delete-failed',
        scope: 'direct-connections/mcp/storage',
        error: error,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Returns the durable device secret used for domain-separated Direct
  /// identity authentication, creating it when needed.
  Future<List<int>> getOrCreateOpenWebUiDirectIdentityKey() {
    if (_openWebUiDirectIdentityWritesBlocked) {
      return Future<List<int>>.error(
        StateError(
          'Direct identity changes are unavailable while signing out.',
        ),
      );
    }
    final previous = _openWebUiDirectIdentityKeyQueue ?? Future<void>.value();
    final result = previous.then<List<int>>(
      (_) => _loadOrCreateOpenWebUiDirectIdentityKeyIfAllowed(),
      onError: (Object _, StackTrace _) =>
          _loadOrCreateOpenWebUiDirectIdentityKeyIfAllowed(),
    );
    late final Future<void> tail;
    tail = result
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          if (identical(_openWebUiDirectIdentityKeyQueue, tail)) {
            _openWebUiDirectIdentityKeyQueue = null;
          }
        });
    _openWebUiDirectIdentityKeyQueue = tail;
    return result;
  }

  Future<List<int>> _loadOrCreateOpenWebUiDirectIdentityKeyIfAllowed() {
    if (_openWebUiDirectIdentityWritesBlocked) {
      return Future<List<int>>.error(
        StateError(
          'Direct identity changes are unavailable while signing out.',
        ),
      );
    }
    return _loadOrCreateOpenWebUiDirectIdentityKey();
  }

  static Future<void> blockDirectIdentityWritesForAppDataClear() async {
    _openWebUiDirectIdentityWritesBlocked = true;
    await _openWebUiDirectIdentityKeyQueue;
  }

  static void resumeDirectIdentityWritesAfterAppDataClear() {
    _openWebUiDirectIdentityWritesBlocked = false;
  }

  Future<List<int>> _loadOrCreateOpenWebUiDirectIdentityKey() async {
    List<int>? decodeKey(String? raw) {
      if (raw == null || raw.isEmpty) return null;
      try {
        final decoded = base64Url.decode(raw);
        return decoded.length >= 32 ? decoded : null;
      } catch (_) {
        return null;
      }
    }

    final existing = decodeKey(
      await _secureStorage.read(key: _openWebUiDirectIdentityKey),
    );
    if (existing != null) return List<int>.unmodifiable(existing);

    final random = Random.secure();
    final generated = List<int>.generate(
      32,
      (_) => random.nextInt(256),
      growable: false,
    );
    await _secureStorage.write(
      key: _openWebUiDirectIdentityKey,
      value: base64UrlEncode(generated),
    );
    // Read back to verify that secure persistence accepted the generated key.
    final persisted = decodeKey(
      await _secureStorage.read(key: _openWebUiDirectIdentityKey),
    );
    if (persisted == null) {
      throw StateError(
        'Open WebUI direct identity key could not be persisted.',
      );
    }
    return List<int>.unmodifiable(persisted);
  }

  /// Persists the saved Open WebUI servers and accounts. The document holds
  /// custom headers, captured proxy cookies and mTLS keys, so it never goes
  /// to preferences.
  Future<void> saveOpenWebUiRegistry(String registryJson) async {
    try {
      await _secureStorage.write(
        key: _openWebUiRegistryKey,
        value: registryJson,
      );
    } catch (e) {
      DebugLogger.error(
        'save-registry-failed',
        scope: 'credentials/server-configs',
        error: e,
      );
      rethrow;
    }
  }

  /// Reads the Open WebUI registry. A platform failure propagates: it is not
  /// evidence that no server is saved.
  Future<String?> getOpenWebUiRegistry() async {
    try {
      return await _secureStorage.read(key: _openWebUiRegistryKey);
    } catch (e) {
      DebugLogger.error(
        'read-registry-failed',
        scope: 'credentials/server-configs',
        error: e,
      );
      rethrow;
    }
  }

  Future<void> deleteOpenWebUiRegistry() =>
      _secureStorage.delete(key: _openWebUiRegistryKey);

  /// Removes the one-server config list once the registry has replaced it.
  Future<void> deleteLegacyServerConfigs() =>
      _secureStorage.delete(key: _serverConfigsKey);

  /// Get the one-server layout's config list, if it is still stored.
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
      rethrow;
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

/// The secrets one saved Hermes connection can hold.
enum HermesSecretKind { apiKey, sessionKey, desktopCredentials }
