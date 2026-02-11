import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
// Types are used through app_providers.dart
import '../providers/app_providers.dart';
import '../models/user.dart';
import '../services/optimized_storage_service.dart';
import 'token_validator.dart';
import 'auth_cache_manager.dart';
import 'webview_cookie_helper.dart';
import '../utils/debug_logger.dart';
import '../utils/user_avatar_utils.dart';

part 'auth_state_manager.g.dart';

/// Comprehensive auth state representation
@immutable
class AuthState {
  const AuthState({
    required this.status,
    this.token,
    this.user,
    this.error,
    this.isLoading = false,
  });

  final AuthStatus status;
  final String? token;
  final User? user;
  final String? error;
  final bool isLoading;

  bool get isAuthenticated =>
      status == AuthStatus.authenticated && token != null;
  bool get hasValidToken => token != null && token!.isNotEmpty;
  bool get needsLogin =>
      status == AuthStatus.unauthenticated || status == AuthStatus.tokenExpired;

  AuthState copyWith({
    AuthStatus? status,
    String? token,
    User? user,
    String? error,
    bool? isLoading,
    bool clearToken = false,
    bool clearUser = false,
    bool clearError = false,
  }) {
    return AuthState(
      status: status ?? this.status,
      token: clearToken ? null : (token ?? this.token),
      user: clearUser ? null : (user ?? this.user),
      error: clearError ? null : (error ?? this.error),
      isLoading: isLoading ?? this.isLoading,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AuthState &&
        other.status == status &&
        other.token == token &&
        other.user == user &&
        other.error == error &&
        other.isLoading == isLoading;
  }

  @override
  int get hashCode => Object.hash(status, token, user, error, isLoading);

  @override
  String toString() =>
      'AuthState(status: $status, hasToken: ${token != null}, hasUser: ${user != null}, error: $error, isLoading: $isLoading)';
}

enum AuthStatus {
  initial,
  loading,
  authenticated,
  unauthenticated,
  tokenExpired,
  error,
  credentialError, // Invalid credentials - need re-login
}

/// Unified auth state manager - single source of truth for all auth operations
@Riverpod(keepAlive: true)
class AuthStateManager extends _$AuthStateManager {
  final AuthCacheManager _cacheManager = AuthCacheManager();
  Future<bool>? _silentLoginFuture;

  // Prevent infinite retry loops
  int _retryCount = 0;
  static const int _maxRetries = 3;
  DateTime? _lastRetryTime;

  AuthState get _current =>
      state.asData?.value ?? const AuthState(status: AuthStatus.initial);

  void _set(AuthState next, {bool cache = false}) {
    final storage = ref.read(optimizedStorageServiceProvider);
    if (next.user != null && next.isAuthenticated) {
      // Persist user and avatar asynchronously without blocking state update
      unawaited(_persistUserWithAvatar(next, storage));
    } else if (!next.isAuthenticated) {
      unawaited(
        storage.saveLocalUser(null).onError((error, stack) {
          DebugLogger.error(
            'Failed to clear local user on logout',
            scope: 'auth/persistence',
            error: error,
            stackTrace: stack,
          );
        }),
      );
      unawaited(
        storage.saveLocalUserAvatar(null).onError((error, stack) {
          DebugLogger.error(
            'Failed to clear local user avatar on logout',
            scope: 'auth/persistence',
            error: error,
            stackTrace: stack,
          );
        }),
      );
    }
    state = AsyncValue.data(next);
    if (cache) {
      _cacheManager.cacheAuthState(next);
    }
  }

  Future<void> _persistUserWithAvatar(
    AuthState authState,
    OptimizedStorageService storage,
  ) async {
    try {
      final api = ref.read(apiServiceProvider);
      final user = authState.user!;
      final resolvedAvatar = resolveUserProfileImageUrl(
        api,
        deriveUserProfileImage(user),
      );
      final userWithAvatar =
          resolvedAvatar != null && resolvedAvatar != user.profileImage
          ? user.copyWith(profileImage: resolvedAvatar)
          : user;
      await storage.saveLocalUser(userWithAvatar);
      if (resolvedAvatar != null) {
        await storage.saveLocalUserAvatar(resolvedAvatar);
      }
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to persist user with avatar',
        scope: 'auth/persistence',
        error: error,
        stackTrace: stack,
      );
    }
  }

  void _update(
    AuthState Function(AuthState current) transform, {
    bool cache = false,
  }) {
    final next = transform(_current);
    _set(next, cache: cache);
  }

  @override
  Future<AuthState> build() async {
    await _initialize();
    return _current;
  }

  /// Initialize auth state from storage
  Future<void> _initialize() async {
    _update(
      (current) =>
          current.copyWith(status: AuthStatus.loading, isLoading: true),
    );

    try {
      final storage = ref.read(optimizedStorageServiceProvider);

      // On cold start, secure storage (iOS Keychain) can be slow or
      // transiently fail. Retry a few times before giving up to avoid
      // incorrectly showing the sign-in page.
      String? token;
      const maxAttempts = 3;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        token = await storage.getAuthToken();
        if (token != null) break;

        // Only retry if this might be a cold start issue
        if (attempt < maxAttempts) {
          DebugLogger.auth(
            'Token read returned null, retrying ($attempt/$maxAttempts)',
          );
          // Exponential backoff: 50ms, 100ms
          await Future.delayed(Duration(milliseconds: 50 * attempt));
        }
      }

      if (token != null && token.isNotEmpty) {
        DebugLogger.auth('Found stored token during initialization');

        // Check if stored token is an API key - force logout if so
        if (TokenValidator.isApiKey(token)) {
          DebugLogger.auth('Detected API key token, forcing logout');
          await storage.deleteAuthToken();
          await storage.deleteSavedCredentials();
          _update(
            (current) => current.copyWith(
              status: AuthStatus.credentialError,
              error: 'apiKeyNoLongerSupported',
              isLoading: false,
              clearToken: true,
            ),
          );
          return;
        }

        // Fast path: trust token format to avoid blocking startup on network
        final formatOk = _isValidTokenFormat(token);
        if (formatOk) {
          // Network readiness gate: Wait for API to be reachable before
          // transitioning to authenticated state. This prevents race conditions
          // on cold starts with Cloudflare tunnels where the tunnel connection
          // may not be established yet.
          final apiReady = await _waitForApiReadiness();
          if (!apiReady) {
            DebugLogger.auth(
              'API not reachable on cold start - keeping loading state',
            );
            // Keep loading state and retry via silent login if we have creds
            final hasCreds = await storage.hasCredentials();
            if (hasCreds) {
              DebugLogger.auth(
                'Has credentials - attempting silent login after API ready',
              );
              // Schedule a delayed retry that will wait for network.
              // Allow time for network stack to stabilize after initial failure.
              unawaited(
                Future.delayed(const Duration(milliseconds: 500), () async {
                  if (!ref.mounted) return;
                  try {
                    final retryReady = await _waitForApiReadiness(
                      timeout: const Duration(seconds: 10),
                    );
                    if (!ref.mounted) return;
                    if (retryReady) {
                      await _performSilentLogin();
                    } else {
                      _update(
                        (current) => current.copyWith(
                          status: AuthStatus.error,
                          error: 'Unable to connect to server',
                          isLoading: false,
                        ),
                      );
                    }
                  } catch (e, stack) {
                    if (!ref.mounted) return;
                    DebugLogger.error(
                      'delayed-retry-failed',
                      scope: 'auth/state',
                      error: e,
                      stackTrace: stack,
                    );
                    _update(
                      (current) => current.copyWith(
                        status: AuthStatus.error,
                        error: 'Connection retry failed',
                        isLoading: false,
                      ),
                    );
                  }
                }),
              );
              return;
            }
            // No credentials - show error
            _update(
              (current) => current.copyWith(
                status: AuthStatus.error,
                error: 'Unable to connect to server',
                isLoading: false,
              ),
            );
            return;
          }

          _update(
            (current) => current.copyWith(
              status: AuthStatus.authenticated,
              token: token,
              isLoading: false,
              clearError: true,
            ),
            cache: true,
          );

          try {
            final cachedUser = await storage.getLocalUser();
            if (cachedUser != null) {
              // Restore cached avatar as well
              final cachedAvatar = await storage.getLocalUserAvatar();
              final userWithAvatar =
                  cachedAvatar != null &&
                      cachedAvatar.isNotEmpty &&
                      cachedUser.profileImage != cachedAvatar
                  ? cachedUser.copyWith(profileImage: cachedAvatar)
                  : cachedUser;
              _update(
                (current) => current.copyWith(user: userWithAvatar),
                cache: true,
              );
              DebugLogger.auth('Restored user from cache');
            }
          } catch (_) {}

          // Update API service with token and kick off dependent background work
          _updateApiServiceToken(token);
          _preloadDefaultModel();
          _loadUserData();
          _prefetchConversations();

          // Background server validation; if it fails, invalidate token gracefully
          final validToken = token; // Capture non-null token for closure
          Future.microtask(() async {
            try {
              final ok = await _validateToken(validToken);
              DebugLogger.auth('Deferred token validation result: $ok');
              if (!ok) {
                await onTokenInvalidated();
              }
            } catch (_) {}
          });
        } else {
          // Token format invalid; clear and require login
          DebugLogger.auth('Token format invalid, deleting token');
          await storage.deleteAuthToken();
          _update(
            (current) => current.copyWith(
              status: AuthStatus.unauthenticated,
              isLoading: false,
              clearToken: true,
              clearError: true,
            ),
          );
        }
      } else {
        // No token found after retries. Check if we have saved credentials
        // and attempt silent login immediately to avoid showing sign-in page.
        final hasCreds = await storage.hasCredentials();
        if (hasCreds) {
          DebugLogger.auth(
            'No token but credentials exist - attempting silent login',
          );
          // Keep loading state while we attempt silent login
          // This prevents the router from redirecting to sign-in
          await _performSilentLogin();
          // _performSilentLogin() updates state appropriately on both success
          // and failure (e.g., AuthStatus.error for network issues), so we
          // return here to preserve that state.
          return;
        }
        // No credentials - set to unauthenticated
        DebugLogger.auth('No token or credentials found');
        _update(
          (current) => current.copyWith(
            status: AuthStatus.unauthenticated,
            isLoading: false,
            clearToken: true,
            clearError: true,
          ),
        );
      }
    } catch (e) {
      DebugLogger.error('auth-init-failed', scope: 'auth/state', error: e);
      _update(
        (current) => current.copyWith(
          status: AuthStatus.error,
          error: 'Failed to initialize auth: $e',
          isLoading: false,
        ),
      );
    }
  }

  /// Perform login with JWT token.
  ///
  /// Note: API keys (sk-...) are not supported for streaming.
  ///
  /// [authType] specifies the source of the token for credential storage:
  /// - 'token': Manual JWT entry (default)
  /// - 'sso': Token obtained via SSO/OAuth flow
  Future<bool> loginWithApiKey(
    String apiKey, {
    bool rememberCredentials = false,
    String authType = 'token',
  }) async {
    _update(
      (current) => current.copyWith(
        status: AuthStatus.loading,
        isLoading: true,
        clearError: true,
      ),
    );

    try {
      // Validate token is not empty
      if (apiKey.trim().isEmpty) {
        throw Exception('Token cannot be empty');
      }

      final tokenStr = apiKey.trim();

      // Reject API keys - they don't support streaming
      if (TokenValidator.isApiKey(tokenStr)) {
        throw Exception('apiKeyNotSupported');
      }

      // Ensure API service is available
      await _ensureApiServiceAvailable();
      final api = ref.read(apiServiceProvider);
      if (api == null) {
        throw Exception('No server connection available');
      }

      // Validate token format
      if (!_isValidTokenFormat(tokenStr)) {
        throw Exception('Invalid token format');
      }

      // Update API service with the API key
      _updateApiServiceToken(tokenStr);

      // Validate by attempting to fetch user info
      try {
        await api.getCurrentUser(); // Just validate, don't store user data yet

        // Save token to storage
        final storage = ref.read(optimizedStorageServiceProvider);
        await storage.saveAuthToken(tokenStr);

        // Save JWT token if requested
        if (rememberCredentials) {
          final activeServer = await ref.read(activeServerProvider.future);
          if (activeServer != null) {
            // Store JWT as a special credential type
            await storage.saveCredentials(
              serverId: activeServer.id,
              username: 'jwt_user', // Special username to indicate JWT auth
              password: tokenStr, // Store JWT in password field
              authType: authType, // 'token' for manual entry, 'sso' for OAuth
            );
          }
        }

        // Update state (without user data initially)
        _update(
          (current) => current.copyWith(
            status: AuthStatus.authenticated,
            token: tokenStr,
            isLoading: false,
            clearError: true,
          ),
          cache: true,
        );

        // Update API service with token and kick off dependent background work
        _updateApiServiceToken(tokenStr);
        _preloadDefaultModel();

        // Load user data in background (consistent with credentials method)
        _loadUserData();
        _prefetchConversations();

        DebugLogger.auth('JWT token login successful');
        return true;
      } catch (e) {
        // If user fetch fails, the token might be invalid
        throw Exception('Invalid token or insufficient permissions');
      }
    } catch (e, stack) {
      DebugLogger.error(
        'api-key-login-failed',
        scope: 'auth/state',
        error: e,
        stackTrace: stack,
      );
      _update(
        (current) => current.copyWith(
          status: AuthStatus.error,
          error: e.toString(),
          isLoading: false,
          clearToken: true,
        ),
      );
      rethrow;
    }
  }

  /// Perform login with credentials
  Future<bool> login(
    String username,
    String password, {
    bool rememberCredentials = false,
  }) async {
    _update(
      (current) => current.copyWith(
        status: AuthStatus.loading,
        isLoading: true,
        clearError: true,
      ),
    );

    try {
      // Ensure API service is available (active server/provider rebuild race)
      await _ensureApiServiceAvailable();
      final api = ref.read(apiServiceProvider);
      if (api == null) {
        throw Exception('No server connection available');
      }

      // Perform login API call
      final response = await api.login(username, password);

      // Extract and validate token
      final token = response['token'] ?? response['access_token'];
      if (token == null || token.toString().trim().isEmpty) {
        throw Exception('No authentication token received');
      }

      final tokenStr = token.toString();
      if (!_isValidTokenFormat(tokenStr)) {
        throw Exception('Invalid authentication token format');
      }

      // Save token to storage
      final storage = ref.read(optimizedStorageServiceProvider);
      await storage.saveAuthToken(tokenStr);

      // Save credentials if requested
      if (rememberCredentials) {
        final activeServer = await ref.read(activeServerProvider.future);
        if (activeServer != null) {
          await storage.saveCredentials(
            serverId: activeServer.id,
            username: username,
            password: password,
          );
        }
      }

      // Update state and API service
      _update(
        (current) => current.copyWith(
          status: AuthStatus.authenticated,
          token: tokenStr,
          isLoading: false,
          clearError: true,
        ),
        cache: true,
      );

      _updateApiServiceToken(tokenStr);
      _preloadDefaultModel();

      // Load user data in background
      _loadUserData();
      _prefetchConversations();

      DebugLogger.auth('Login successful');
      return true;
    } catch (e, stack) {
      DebugLogger.error(
        'login-failed',
        scope: 'auth/state',
        error: e,
        stackTrace: stack,
      );
      _update(
        (current) => current.copyWith(
          status: AuthStatus.error,
          error: e.toString(),
          isLoading: false,
          clearToken: true,
        ),
      );
      rethrow;
    }
  }

  /// Perform login with LDAP credentials.
  ///
  /// LDAP uses username (not email) for authentication.
  /// The server must have LDAP enabled, otherwise this will throw an error.
  Future<bool> ldapLogin(
    String username,
    String password, {
    bool rememberCredentials = false,
  }) async {
    _update(
      (current) => current.copyWith(
        status: AuthStatus.loading,
        isLoading: true,
        clearError: true,
      ),
    );

    try {
      // Ensure API service is available
      await _ensureApiServiceAvailable();
      final api = ref.read(apiServiceProvider);
      if (api == null) {
        throw Exception('No server connection available');
      }

      // Perform LDAP login API call
      final response = await api.ldapLogin(username, password);

      // Check if notifier is still mounted after async call
      if (!ref.mounted) return false;

      // Extract and validate token
      final token = response['token'] ?? response['access_token'];
      if (token == null || token.toString().trim().isEmpty) {
        throw Exception('No authentication token received');
      }

      final tokenStr = token.toString();
      if (!_isValidTokenFormat(tokenStr)) {
        throw Exception('Invalid authentication token format');
      }

      // Save token to storage
      final storage = ref.read(optimizedStorageServiceProvider);
      await storage.saveAuthToken(tokenStr);

      if (!ref.mounted) return false;

      // Save JWT token for re-authentication if requested
      // We store the token (not the raw LDAP password) for security:
      // - JWT tokens can be revoked server-side
      // - Avoids storing the user's directory password
      // - Consistent with SSO token storage approach
      if (rememberCredentials) {
        final activeServer = await ref.read(activeServerProvider.future);
        if (!ref.mounted) return false;
        if (activeServer != null) {
          await storage.saveCredentials(
            serverId: activeServer.id,
            // Prefix with ldap: to preserve original username for debugging
            // while indicating this is token-based auth
            username: 'ldap:$username',
            password: tokenStr, // Store JWT token, not LDAP password
            authType: 'ldap', // Track that this originated from LDAP login
          );
        }
      }

      if (!ref.mounted) return false;

      // Update state and API service
      _update(
        (current) => current.copyWith(
          status: AuthStatus.authenticated,
          token: tokenStr,
          isLoading: false,
          clearError: true,
        ),
        cache: true,
      );

      _updateApiServiceToken(tokenStr);
      _preloadDefaultModel();

      // Load user data in background
      _loadUserData();
      _prefetchConversations();

      DebugLogger.auth('LDAP login successful');
      return true;
    } catch (e, stack) {
      DebugLogger.error(
        'ldap-login-failed',
        scope: 'auth/state',
        error: e,
        stackTrace: stack,
      );
      if (ref.mounted) {
        _update(
          (current) => current.copyWith(
            status: AuthStatus.error,
            error: e.toString(),
            isLoading: false,
            clearToken: true,
          ),
        );
      }
      rethrow;
    }
  }

  /// Wait briefly until the API service becomes available
  Future<void> _ensureApiServiceAvailable({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      final api = ref.read(apiServiceProvider);
      if (api != null) return;
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Wait for the API to be reachable (network readiness gate).
  ///
  /// On cold starts with Cloudflare tunnels or other proxy setups, the network
  /// connection may not be established immediately. This method performs a
  /// health check with retries to ensure we don't show the wrong screen due to
  /// a race condition between auth state initialization and network readiness.
  ///
  /// Returns true if the API is reachable within the timeout, false otherwise.
  Future<bool> _waitForApiReadiness({
    Duration timeout = const Duration(seconds: 3),
    Duration retryDelay = const Duration(milliseconds: 300),
  }) async {
    final stopwatch = Stopwatch()..start();

    // First ensure the API service provider is available
    await _ensureApiServiceAvailable(timeout: const Duration(seconds: 1));

    while (stopwatch.elapsed < timeout) {
      if (!ref.mounted) return false;

      final api = ref.read(apiServiceProvider);
      if (api == null) {
        await Future.delayed(retryDelay);
        continue;
      }

      try {
        // Use checkHealth which hits the /health endpoint
        final healthy = await api.checkHealth();
        if (healthy) {
          DebugLogger.auth(
            'API readiness confirmed in ${stopwatch.elapsedMilliseconds}ms',
          );
          return true;
        }
      } catch (e) {
        DebugLogger.auth(
          'API readiness check failed (${stopwatch.elapsedMilliseconds}ms): $e',
        );
      }

      // Wait before retrying
      if (stopwatch.elapsed + retryDelay < timeout) {
        await Future.delayed(retryDelay);
      } else {
        break;
      }
    }

    DebugLogger.auth(
      'API readiness timed out after ${stopwatch.elapsedMilliseconds}ms',
    );
    return false;
  }

  /// Perform silent auto-login with saved credentials
  Future<bool> silentLogin() async {
    // Coalesce concurrent calls (e.g., UI + interceptor retry)
    if (_silentLoginFuture != null) {
      return await _silentLoginFuture!;
    }
    final thisAttempt = _performSilentLogin();
    _silentLoginFuture = thisAttempt;
    try {
      return await thisAttempt;
    } finally {
      if (identical(_silentLoginFuture, thisAttempt)) {
        _silentLoginFuture = null;
      }
    }
  }

  Future<bool> _performSilentLogin() async {
    _update(
      (current) => current.copyWith(
        status: AuthStatus.loading,
        isLoading: true,
        clearError: true,
      ),
    );

    try {
      final storage = ref.read(optimizedStorageServiceProvider);
      final savedCredentials = await storage.getSavedCredentials();

      if (savedCredentials == null) {
        _update(
          (current) => current.copyWith(
            status: AuthStatus.unauthenticated,
            isLoading: false,
            clearError: true,
          ),
        );
        return false;
      }

      final serverId = savedCredentials['serverId']!;
      final username = savedCredentials['username']!;
      final password = savedCredentials['password']!;

      // Ensure the saved server still exists before switching
      final serverConfigs = await ref.read(serverConfigsProvider.future);
      final hasServer = serverConfigs.any((config) => config.id == serverId);

      if (!hasServer) {
        await storage.deleteSavedCredentials();
        await storage.setActiveServerId(null);
        ref.invalidate(serverConfigsProvider);
        ref.invalidate(activeServerProvider);

        _update(
          (current) => current.copyWith(
            status: AuthStatus.error,
            error:
                'Saved server configuration is no longer available. Please reconnect.',
            isLoading: false,
          ),
        );
        return false;
      }

      // Set active server once we know it exists
      await storage.setActiveServerId(serverId);
      ref.invalidate(activeServerProvider);

      // Wait for server connection
      final activeServer = await ref.read(activeServerProvider.future);
      if (activeServer == null) {
        await storage.setActiveServerId(null);
        _update(
          (current) => current.copyWith(
            status: AuthStatus.error,
            error: 'Server configuration not found',
            isLoading: false,
          ),
        );
        return false;
      }

      // Attempt login based on auth type
      final authType = savedCredentials['authType'] ?? 'credentials';

      // Handle JWT token-based authentication (includes legacy prefixes)
      // LDAP now also stores JWT tokens for re-auth (not raw passwords)
      if (username == 'api_key_user' ||
          username == 'jwt_user' ||
          username.startsWith('ldap:') ||
          authType == 'token' ||
          authType == 'sso' ||
          authType == 'ldap') {
        // This is a saved JWT token (manual entry, SSO, or LDAP-obtained)
        // For LDAP, we store the JWT token returned by the server, not the
        // original password, for security reasons
        return await loginWithApiKey(
          password, // This is the JWT token
          rememberCredentials: false,
          authType: authType,
        );
      } else {
        // Standard credentials login (default)
        return await login(username, password, rememberCredentials: false);
      }
    } catch (e, stack) {
      DebugLogger.error(
        'silent-login-failed',
        scope: 'auth/state',
        error: e,
        stackTrace: stack,
      );

      String errorMessage = e.toString();

      // Don't clear credentials on connection errors - only clear on actual auth failures
      // Check if this is a genuine auth failure vs network issue
      final isNetworkError =
          e.toString().contains('SocketException') ||
          e.toString().contains('Connection') ||
          e.toString().contains('timeout') ||
          e.toString().contains('NetworkImage');

      if (!isNetworkError &&
          (e.toString().contains('401') ||
              e.toString().contains('403') ||
              e.toString().contains('authentication') ||
              e.toString().contains('unauthorized'))) {
        // Only clear credentials if this is a real auth failure, not a network issue
        final storage = ref.read(optimizedStorageServiceProvider);
        try {
          DebugLogger.auth('Clearing invalid credentials after auth failure');
          await storage.deleteSavedCredentials();
        } catch (deleteError, deleteStack) {
          DebugLogger.error(
            'silent-login-credential-clear-failed',
            scope: 'auth/state',
            error: deleteError,
            stackTrace: deleteStack,
          );
          errorMessage =
              '$errorMessage. Also failed to clear saved '
              'credentials; please clear Conduit credentials from '
              'system settings.';
        }

        // Set credential error status to trigger login page
        _update(
          (current) => current.copyWith(
            status: AuthStatus.credentialError,
            error: errorMessage,
            isLoading: false,
            clearToken: true,
          ),
        );
        return false;
      } else if (isNetworkError) {
        DebugLogger.auth(
          'Silent login failed due to network error - keeping credentials',
        );
        errorMessage = 'Connection issue - please check your network';

        // Set general error status to trigger connection issue page
        _update(
          (current) => current.copyWith(
            status: AuthStatus.error,
            error: errorMessage,
            isLoading: false,
          ),
        );
        return false;
      }

      // Unknown error type - treat as connection issue but keep credentials
      if (errorMessage.trim().isEmpty) {
        errorMessage = 'Connection issue - please try again shortly';
      }
      DebugLogger.auth(
        'Silent login failed with unknown error - keeping credentials',
      );
      _update(
        (current) => current.copyWith(
          status: AuthStatus.error,
          error: errorMessage,
          isLoading: false,
        ),
      );
      return false;
    }
  }

  /// Reset retry counter (called when user manually retries)
  void resetRetryCounter() {
    _retryCount = 0;
    _lastRetryTime = null;
    DebugLogger.auth('Retry counter reset for manual retry');
  }

  /// Handle auth issues (called by API service)
  /// This shows connection issue page instead of logging out
  void onAuthIssue() {
    DebugLogger.auth('Auth issue detected - showing connection issue page');
    // Don't clear token or user data - just set error state
    // The router will show connection issue page
    _update(
      (current) => current.copyWith(
        status: AuthStatus.error,
        error: 'Connection issue - please check your connection',
        clearError: false,
      ),
    );
  }

  /// Handle token invalidation (called by API service for explicit token expiry)
  /// This is only used when we need to clear the token for re-login attempts
  Future<void> onTokenInvalidated() async {
    // Prevent infinite retry loops
    final now = DateTime.now();
    if (_lastRetryTime != null &&
        now.difference(_lastRetryTime!).inSeconds < 5) {
      _retryCount++;
      if (_retryCount >= _maxRetries) {
        DebugLogger.auth(
          'Max retry attempts reached - stopping silent re-login',
        );
        _update(
          (current) => current.copyWith(
            status: AuthStatus.error,
            error: 'Connection issue - please retry manually',
            clearError: false,
          ),
        );
        // Reset after 30 seconds to allow manual retry
        Future.delayed(const Duration(seconds: 30), () {
          _retryCount = 0;
          _lastRetryTime = null;
        });
        return;
      }
    } else {
      // Reset counter if enough time has passed
      _retryCount = 0;
    }
    _lastRetryTime = now;

    // Avoid spamming logs if multiple requests invalidate at once
    final reloginInProgress = _silentLoginFuture != null;
    if (!reloginInProgress) {
      DebugLogger.auth(
        'Auth token invalidated - attempting silent re-login (attempt ${_retryCount + 1}/$_maxRetries)',
      );
    }

    final storage = ref.read(optimizedStorageServiceProvider);
    try {
      await storage.deleteAuthToken();
      DebugLogger.auth('Cleared invalidated token from secure storage');
    } catch (e, stack) {
      DebugLogger.error(
        'token-delete-failed',
        scope: 'auth/state',
        error: e,
        stackTrace: stack,
      );
    }
    _updateApiServiceToken(null);

    _update(
      (current) => current.copyWith(
        status: AuthStatus.tokenExpired,
        error: 'Session expired - please sign in again',
        clearToken: true,
        clearUser: true,
        isLoading: false,
      ),
    );

    // Attempt silent re-login if credentials are available
    final hasCredentials = await storage.getSavedCredentials() != null;
    if (hasCredentials && !reloginInProgress) {
      DebugLogger.auth('Attempting silent re-login after token invalidation');
      final success = await silentLogin();
      if (success) {
        // Reset retry counter on success
        _retryCount = 0;
        _lastRetryTime = null;
      }
    }
  }

  /// Logout user and clear auth data while preserving server configuration.
  /// Server settings (URL, custom headers, self-signed cert) are kept so users
  /// can quickly re-login. Users can navigate to server connection page to
  /// change server settings if needed.
  Future<void> logout() async {
    _update(
      (current) =>
          current.copyWith(status: AuthStatus.loading, isLoading: true),
    );

    try {
      // Call server logout if possible
      final api = ref.read(apiServiceProvider);
      if (api != null) {
        try {
          await api.logout();
        } catch (e) {
          DebugLogger.warning(
            'server-logout-failed',
            scope: 'auth/state',
            data: {'error': e.toString()},
          );
        }
      }

      // Clear auth data but preserve server configs (URL, headers, cert settings)
      final storage = ref.read(optimizedStorageServiceProvider);
      await storage.clearAuthData();
      _updateApiServiceToken(null);

      // Clear all WebView data (cookies, localStorage, cache) to ensure
      // fresh SSO sessions on next login
      try {
        await WebViewCookieHelper.clearAllWebViewData();
      } catch (e) {
        DebugLogger.warning(
          'webview-data-clear-failed',
          scope: 'auth/state',
          data: {'error': e.toString()},
        );
      }

      // Keep active server ID so router redirects to sign-in page, not server
      // connection page. Users can navigate to server settings if they need to
      // change server configuration.

      // Note: toolsListProvider is NOT invalidated here because:
      // 1. clearAuthData() already deletes the tools cache from storage
      // 2. The provider has auth checks that prevent API calls when logged out
      // 3. When user logs back in, the provider will rebuild with fresh data

      // Clear auth cache manager
      _cacheManager.clearAuthCache();

      // Update state
      _update(
        (current) => current.copyWith(
          status: AuthStatus.unauthenticated,
          isLoading: false,
          clearToken: true,
          clearUser: true,
          clearError: true,
        ),
      );

      DebugLogger.auth(
        'Logout complete - auth data cleared, server config preserved for quick re-login',
      );
    } catch (e, stack) {
      DebugLogger.error(
        'logout-failed',
        scope: 'auth/state',
        error: e,
        stackTrace: stack,
      );
      // Even if logout fails, clear local state where possible
      final storage = ref.read(optimizedStorageServiceProvider);
      try {
        await storage.clearAuthData();
      } catch (clearError) {
        DebugLogger.error(
          'logout-clear-failed',
          scope: 'auth/state',
          error: clearError,
        );
      }
      // Keep active server ID for redirect to sign-in page
      _cacheManager.clearAuthCache();

      _update(
        (current) => current.copyWith(
          status: AuthStatus.unauthenticated,
          isLoading: false,
          clearToken: true,
          clearUser: true,
          error:
              'Logout error: $e. Some data may remain stored; '
              'please clear app data from your device settings if needed.',
        ),
      );
      _updateApiServiceToken(null);
    }
  }

  /// Preload the default model as soon as authentication succeeds.
  void _preloadDefaultModel() {
    Future.microtask(() async {
      if (!ref.mounted) return;
      try {
        await ref.read(defaultModelProvider.future);
        DebugLogger.auth('Default model preload requested');
      } catch (e) {
        if (!ref.mounted) return;
        DebugLogger.warning(
          'default-model-preload-failed',
          scope: 'auth/state',
          data: {'error': e.toString()},
        );
      }
    });
  }

  /// Prime the conversations list so navigation drawers show real data after login.
  void _prefetchConversations() {
    Future.microtask(() {
      if (!ref.mounted) return;
      try {
        refreshConversationsCache(ref, includeFolders: true);
        DebugLogger.auth('Conversations prefetch scheduled');
      } catch (e) {
        if (!ref.mounted) return;
        DebugLogger.warning(
          'conversation-prefetch-failed',
          scope: 'auth/state',
          data: {'error': e.toString()},
        );
      }
    });
  }

  /// Load user data in background with JWT extraction fallback
  Future<void> _loadUserData() async {
    try {
      // First try to extract user info from JWT token if available
      final current = _current;
      if (current.token != null) {
        final jwtUserInfo = TokenValidator.extractUserInfo(current.token!);
        if (jwtUserInfo != null) {
          final userFromJwt = _userFromJwtClaims(jwtUserInfo);
          if (userFromJwt != null) {
            DebugLogger.auth('Extracted user info from JWT token');
            _update((current) => current.copyWith(user: userFromJwt));
          }

          // Still try to load from server in background for complete data
          Future.microtask(() => _loadServerUserData());
          return;
        }
      }

      // Fall back to server data loading
      await _loadServerUserData();
    } catch (e) {
      DebugLogger.warning(
        'user-data-load-failed',
        scope: 'auth/state',
        data: {'error': e.toString()},
      );
      // Don't update state on user data load failure
    }
  }

  /// Load complete user data from server
  Future<void> _loadServerUserData() async {
    try {
      final api = ref.read(apiServiceProvider);
      final current = _current;
      if (api != null && current.isAuthenticated) {
        // Check if we already have user data from token validation
        if (current.user != null) {
          DebugLogger.auth('user-data-present-from-token', scope: 'auth/state');
          return;
        }

        final user = await api.getCurrentUser();
        _update((current) => current.copyWith(user: user));
        DebugLogger.auth('Loaded complete user data from server');
      }
    } catch (e) {
      DebugLogger.warning(
        'server-user-data-load-failed',
        scope: 'auth/state',
        data: {'error': e.toString()},
      );
      // Don't update state on server data load failure - keep JWT data if available
    }
  }

  /// Update API service with current token
  void _updateApiServiceToken(String? token) {
    final api = ref.read(apiServiceProvider);
    api?.updateAuthToken(token);
  }

  /// Validate token format using advanced validation
  bool _isValidTokenFormat(String token) {
    final result = TokenValidator.validateTokenFormat(token);
    return result.isValid;
  }

  /// Validate token with comprehensive validation (format + server)
  Future<bool> _validateToken(String token) async {
    // Check cache first
    final cachedResult = TokenValidationCache.getCachedResult(token);
    if (cachedResult != null) {
      DebugLogger.auth(
        'Using cached token validation result: ${cachedResult.isValid}',
      );
      return cachedResult.isValid;
    }

    // Fast format validation first
    final formatResult = TokenValidator.validateTokenFormat(token);
    if (!formatResult.isValid) {
      DebugLogger.warning(
        'token-format-invalid',
        scope: 'auth/state',
        data: {'message': formatResult.message},
      );
      TokenValidationCache.cacheResult(token, formatResult);
      return false;
    }

    // If format is valid but token is expiring soon, try server validation
    if (formatResult.isExpiringSoon) {
      DebugLogger.auth('token-expiring-soon', scope: 'auth/state');
    }

    // Server validation (async with timeout)
    try {
      final api = ref.read(apiServiceProvider);
      if (api == null) {
        DebugLogger.warning('token-validation-no-api', scope: 'auth/state');
        return formatResult.isValid; // Fall back to format validation
      }

      User? validationUser;
      final serverResult = await TokenValidator.validateTokenWithServer(
        token,
        () async {
          // Update API with token for validation
          api.updateAuthToken(token);
          // Try to fetch user data as validation
          validationUser = await api.getCurrentUser();
          return validationUser!;
        },
      );

      // Store the user data if validation was successful
      if (serverResult.isValid &&
          validationUser != null &&
          _current.isAuthenticated) {
        _update((current) => current.copyWith(user: validationUser));
        DebugLogger.auth('Cached user data from token validation');
      }

      TokenValidationCache.cacheResult(token, serverResult);

      DebugLogger.auth(
        'Server token validation: ${serverResult.isValid} - ${serverResult.message}',
      );
      return serverResult.isValid;
    } catch (e) {
      DebugLogger.warning(
        'token-validation-failed',
        scope: 'auth/state',
        data: {'error': e.toString()},
      );
      // On network error, fall back to format validation if it was valid
      return formatResult.isValid;
    }
  }

  /// Check if user has saved credentials (with caching)
  Future<bool> hasSavedCredentials() async {
    // Check cache first
    final cachedResult = _cacheManager.getCachedCredentialsExist();
    if (cachedResult != null) {
      return cachedResult;
    }

    try {
      final storage = ref.read(optimizedStorageServiceProvider);
      final hasCredentials = await storage.hasCredentials();

      // Cache the result
      _cacheManager.cacheCredentialsExist(hasCredentials);

      return hasCredentials;
    } catch (e) {
      return false;
    }
  }

  /// Refresh current auth state
  Future<void> refresh() async {
    // Clear cache before refresh to ensure fresh data
    _cacheManager.clearAuthCache();
    TokenValidationCache.clearCache();

    await _initialize();
  }

  /// Clean up expired caches (called periodically)
  void cleanupCaches() {
    _cacheManager.cleanExpiredCache();
    _cacheManager.optimizeCache();
  }

  /// Get performance statistics
  Map<String, dynamic> getPerformanceStats() {
    return {
      'authCache': _cacheManager.getCacheStats(),
      'tokenValidationCache': 'Managed by TokenValidationCache',
      'storageCache': 'Managed by OptimizedStorageService',
    };
  }

  User? _userFromJwtClaims(Map<String, dynamic> claims) {
    final id =
        (claims['sub'] ?? claims['username'] ?? claims['email'])
            ?.toString()
            .trim() ??
        '';
    final username =
        (claims['username'] ?? claims['name'])?.toString().trim() ?? '';
    final emailValue = claims['email'];
    final email = emailValue == null ? '' : emailValue.toString().trim();

    if (id.isEmpty && username.isEmpty && email.isEmpty) {
      return null;
    }

    String resolvedRole = 'user';
    final roles = claims['roles'];
    if (roles is List && roles.isNotEmpty) {
      resolvedRole = roles.first.toString();
    } else if (roles is String && roles.isNotEmpty) {
      resolvedRole = roles;
    }

    return User(
      id: id.isNotEmpty
          ? id
          : (username.isNotEmpty ? username : email.ifEmptyReturn('user')),
      username: username.ifEmptyReturn(
        email.ifEmptyReturn(id.ifEmptyReturn('user')),
      ),
      email: email,
      role: resolvedRole,
      isActive: true,
    );
  }
}

extension _StringFallbackExtension on String {
  String ifEmptyReturn(String fallback) => isEmpty ? fallback : this;
}
