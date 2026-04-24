import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
// Types are used through app_providers.dart
import '../providers/app_providers.dart';
import '../../features/tools/providers/tools_providers.dart';
import '../models/user.dart';
import '../services/optimized_storage_service.dart';
import 'token_validator.dart';
import 'auth_cache_manager.dart';
import 'webview_cookie_helper.dart';
import '../services/connectivity_service.dart';
import '../utils/debug_logger.dart';
import '../utils/startup_timeline.dart';
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
    this.serverReachable = true,
  });

  final AuthStatus status;
  final String? token;
  final User? user;
  final String? error;
  final bool isLoading;

  /// Whether the configured Open WebUI server has been reached recently.
  ///
  /// On cold start the local-first path renders the UI from cached state
  /// before the readiness probe completes — this flag goes false if the
  /// background `/health` check fails so the chat shell can show a
  /// non-blocking reconnect banner without flipping out of `authenticated`.
  final bool serverReachable;

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
    bool? serverReachable,
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
      serverReachable: serverReachable ?? this.serverReachable,
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
        other.isLoading == isLoading &&
        other.serverReachable == serverReachable;
  }

  @override
  int get hashCode =>
      Object.hash(status, token, user, error, isLoading, serverReachable);

  @override
  String toString() =>
      'AuthState(status: $status, hasToken: ${token != null}, hasUser: ${user != null}, error: $error, isLoading: $isLoading, serverReachable: $serverReachable)';
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
    // Phase 2.4: re-probe server reachability whenever connectivity flips
    // back online. This pairs with the TaskQueue's connectivity drain so the
    // reconnect banner clears as soon as the server is reachable again.
    ref.listen<ConnectivityStatus>(connectivityStatusProvider, (prev, next) {
      if (next == ConnectivityStatus.online &&
          prev != ConnectivityStatus.online) {
        final state = _current;
        if (state.isAuthenticated && !state.serverReachable) {
          unawaited(probeServerReachability());
        }
      }
    });
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
          // Local-first path: transition to authenticated immediately using
          // the cached user (if any) so the chat UI can render in the same
          // frame. The /health probe runs in the background and only flips
          // `serverReachable` to false on failure — never demotes status.
          User? cachedUser;
          try {
            cachedUser = await storage.getLocalUser();
            if (cachedUser != null) {
              final cachedAvatar = await storage.getLocalUserAvatar();
              if (cachedAvatar != null &&
                  cachedAvatar.isNotEmpty &&
                  cachedUser.profileImage != cachedAvatar) {
                cachedUser = cachedUser.copyWith(profileImage: cachedAvatar);
              }
              DebugLogger.auth('Restored user from cache');
            }
          } catch (_) {
            cachedUser = null;
          }

          _update(
            (current) => current.copyWith(
              status: AuthStatus.authenticated,
              token: token,
              user: cachedUser,
              isLoading: false,
              serverReachable: true,
              clearError: true,
            ),
            cache: true,
          );

          StartupTimeline.instant('auth_state_resolved');

          // Update API service with token and kick off dependent background work
          _updateApiServiceToken(token);
          _preloadDefaultModel();
          _loadUserData();
          _prefetchConversations();

          // Background server reachability probe. On failure we set
          // serverReachable=false so the chat shell can show a non-blocking
          // reconnect banner. We do NOT demote status — the cached UI stays
          // usable, and outbound sends will queue via TaskQueue with retry.
          final validToken = token; // Capture non-null token for closure
          unawaited(_probeReachabilityAndValidate(validToken));
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

  /// Background reachability probe + deferred token validation. Used after
  /// the local-first cold-start path sets `authenticated` from cache; never
  /// demotes status, only updates `serverReachable` and (on definitive
  /// server-side rejection) calls [onTokenInvalidated].
  Future<void> _probeReachabilityAndValidate(String token) async {
    try {
      final ready = await _waitForApiReadiness();
      if (!ref.mounted) return;
      _update((current) => current.copyWith(serverReachable: ready));
      if (!ready) {
        DebugLogger.auth(
          'Server unreachable after cold-start probe — banner will surface',
        );
        return;
      }
      try {
        final ok = await _validateToken(token);
        DebugLogger.auth('Deferred token validation result: $ok');
        if (!ok && ref.mounted) {
          await onTokenInvalidated();
        }
      } catch (_) {}
    } catch (e, stack) {
      DebugLogger.warning(
        'reachability-probe-failed',
        scope: 'auth/state',
        data: {'error': e.toString()},
      );
      // Surface as unreachable; user can manually retry from the banner.
      if (ref.mounted) {
        _update((current) => current.copyWith(serverReachable: false));
      }
      // Stack is captured for debug builds; rethrow swallowed intentionally.
      assert(() {
        debugPrintStack(stackTrace: stack);
        return true;
      }());
    }
  }

  /// Manually re-probe server reachability. Called by the reconnect banner
  /// retry action and by connectivity-online transitions (Phase 2.4 wiring).
  Future<bool> probeServerReachability() async {
    final ready = await _waitForApiReadiness(
      timeout: const Duration(seconds: 5),
    );
    if (ref.mounted) {
      _update((current) => current.copyWith(serverReachable: ready));
    }
    return ready;
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

      // Clear auth cache manager
      _cacheManager.clearAuthCache();

      // Invalidate all keepAlive providers that hold user-specific data.
      // Without this, stale data remains in memory after sign out.
      ref.invalidate(conversationsProvider);
      ref.invalidate(activeConversationProvider);
      ref.invalidate(foldersProvider);
      ref.invalidate(modelsProvider);
      ref.invalidate(selectedModelProvider);
      ref.invalidate(currentUserProvider);
      ref.invalidate(userSettingsProvider);
      ref.invalidate(userPermissionsProvider);
      ref.invalidate(toolsListProvider);
      ref.invalidate(selectedToolIdsProvider);
      ref.invalidate(selectedTerminalIdProvider);
      ref.invalidate(selectedFilterIdsProvider);
      ref.invalidate(knowledgeBasesProvider);
      ref.invalidate(availableVoicesProvider);
      ref.invalidate(imageModelsProvider);
      ref.invalidate(defaultModelProvider);
      ref.invalidate(backendConfigProvider);
      ref.invalidate(socketServiceManagerProvider);

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

/// Whether the configured Open WebUI server has been reachable via the
/// background `/health` probe. Watched by the chat shell's reconnect banner
/// so it can surface a non-blocking "Reconnecting…" hint without blocking
/// the UI on cold start.
@Riverpod(keepAlive: true)
bool serverReachable(Ref ref) {
  final state = ref.watch(authStateManagerProvider).asData?.value;
  // Default to true so we never flash a banner before the first probe lands.
  return state?.serverReachable ?? true;
}
