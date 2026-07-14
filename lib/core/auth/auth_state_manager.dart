import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
// Types are used through app_providers.dart
import '../providers/app_providers.dart';
import '../models/user.dart';
import '../services/api_service.dart';
import '../services/optimized_storage_service.dart';
import '../services/worker_manager.dart';
import 'token_validator.dart';
import 'auth_cache_manager.dart';
import 'webview_cookie_helper.dart';
import '../utils/debug_logger.dart';
import '../utils/user_avatar_utils.dart';
import '../persistence/persistence_keys.dart';
import '../persistence/preferences_store.dart';
import 'openwebui_account_owner_marker.dart';

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

/// Whether the bootstrap silent-login path should fall back to
/// [AuthStatus.unauthenticated] after the background login resolves.
///
/// `_bootstrapSilentLogin` and `_performSilentLoginInBackground` deliberately
/// SHARE the pre-existing auth-attempt revision — neither calls
/// `_beginAuthAttempt()` up-front. A successful background login bumps the
/// revision lazily through its `claimCommit()`. So the fallback must fire ONLY
/// when the background login committed nothing ([committed] is false) AND no
/// newer auth attempt has started since bootstrap captured
/// [capturedRevision] (i.e. [currentRevision] is unchanged), while the app
/// still sits in the bootstrap [AuthStatus.loading] state with no token.
///
/// Any of the following must SUPPRESS the fallback so a stale bootstrap task
/// can't clobber newer state:
/// - a successful commit (its `claimCommit()` bumped the revision → unequal),
/// - a newer attempt (login / logout / token-invalidation bumped the revision),
/// - a session already published (status moved off `loading`),
/// - a token already restored ([hasValidToken]).
///
/// Extracted as a pure function so the revision-sharing contract has a dedicated
/// test; the private bootstrap path is otherwise driven by an internal,
/// network-bound `ApiService` that can't be exercised in a unit test.
bool bootstrapShouldFallbackToUnauthenticated({
  required bool committed,
  required int capturedRevision,
  required int currentRevision,
  required AuthStatus status,
  required bool hasValidToken,
}) {
  return !committed &&
      currentRevision == capturedRevision &&
      status == AuthStatus.loading &&
      !hasValidToken;
}

typedef OpenWebUiCachedAccountOwnerResolution = ({
  bool retainCachedUser,
  bool ownerMismatch,
});

/// Resolves ownership only for the provisional cached-user auth fast path.
///
/// A missing marker is the expected state for installations upgrading from a
/// version that did not persist account ownership. The cached identity can be
/// shown provisionally while the token is validated, but it does not certify
/// the server-scoped database: the storage-isolation barrier performs its own
/// strict marker check and purges markerless storage before opening it.
///
/// Once a marker exists, any token or cached-user mismatch is explicit and the
/// cached identity must not be published.
@visibleForTesting
OpenWebUiCachedAccountOwnerResolution resolveOpenWebUiCachedAccountOwner({
  required OpenWebUiAccountOwnerMarker? marker,
  required String token,
  required String? cachedUserId,
}) {
  final normalizedCachedUserId = cachedUserId?.trim();
  final hasScopedCachedUser =
      normalizedCachedUserId != null && normalizedCachedUserId.isNotEmpty;
  if (marker == null) {
    return (retainCachedUser: hasScopedCachedUser, ownerMismatch: false);
  }

  final tokenMatches = openWebUiAccountOwnerMarkerMatchesToken(
    marker: marker,
    token: token,
  );
  if (!hasScopedCachedUser) {
    return (retainCachedUser: false, ownerMismatch: !tokenMatches);
  }

  final ownerMatches = openWebUiAccountOwnerMarkerMatches(
    marker: marker,
    token: token,
    userId: normalizedCachedUserId,
  );
  return (
    retainCachedUser: ownerMatches,
    ownerMismatch: !tokenMatches || !ownerMatches,
  );
}

/// Unified auth state manager - single source of truth for all auth operations
@Riverpod(keepAlive: true)
class AuthStateManager extends _$AuthStateManager {
  final AuthCacheManager _cacheManager = AuthCacheManager();
  Future<bool>? _silentLoginFuture;
  int _authAttemptRevision = 0;

  // Prevent infinite retry loops
  int _retryCount = 0;
  static const int _maxRetries = 3;
  DateTime? _lastRetryTime;

  AuthState get _current =>
      state.asData?.value ?? const AuthState(status: AuthStatus.initial);

  int _beginAuthAttempt() => ++_authAttemptRevision;

  /// True when a newer auth attempt (login / logout / token-invalidation, each
  /// of which calls [_beginAuthAttempt]) has started since [attemptRevision] was
  /// captured, or the notifier is gone. Foreground logins check this before
  /// persisting a token or publishing state so a slow attempt can't overwrite a
  /// newer one's result.
  bool _authAttemptSuperseded(int attemptRevision) =>
      !ref.mounted || _authAttemptRevision != attemptRevision;

  /// Rolls back a superseded foreground login's persisted writes: value-match
  /// deletes the token (and remembered credentials) it just wrote, so the next
  /// cold start can't restore the rejected session. Value-matched so a newer
  /// login's writes are never clobbered.
  Future<void> _rollbackUncommittedLoginWrites({
    required OptimizedStorageService storage,
    required String token,
    Map<String, String>? credentials,
  }) async {
    try {
      await storage.deleteAuthTokenIfMatches(token);
      if (credentials != null) {
        await storage.deleteSavedCredentialsIfMatches(credentials);
      }
    } catch (error, stack) {
      DebugLogger.error(
        'superseded-login-rollback-failed',
        scope: 'auth/state',
        error: error,
        stackTrace: stack,
      );
    }
  }

  /// `_validateIssuedToken` installs the candidate token on the shared
  /// `ApiService` interceptor before a login is checked for staleness. When a
  /// login is superseded after validation, restore the interceptor token to the
  /// authoritative current auth state so in-flight/subsequent requests don't
  /// keep using the rejected attempt's token until the next update.
  void _restoreApiServiceTokenToCurrent() {
    _updateApiServiceToken(_current.hasValidToken ? _current.token : null);
  }

  bool _canCommitAuth(bool Function()? canCommit) {
    return canCommit == null || canCommit();
  }

  bool _claimAuthCommit({
    required String operation,
    bool Function()? claimCommit,
  }) {
    // [claimCommit] is null only on the foreground silent-login path (no
    // staleness arbitration needed there); `?? true` lets that commit proceed
    // unconditionally. The background path always supplies a non-null
    // [claimCommit] that bumps the auth revision to claim the commit.
    final canCommitNow = claimCommit?.call() ?? true;
    if (!canCommitNow) {
      DebugLogger.auth('$operation ignored stale auth result');
    }
    return canCommitNow;
  }

  Future<void> _restoreStaleSilentLoginPersistence({
    required OptimizedStorageService storage,
    required String staleServerId,
    required String? previousServerId,
    required String staleToken,
    required String? previousToken,
  }) async {
    try {
      final stateToken = _current.hasValidToken ? _current.token : null;
      final replacementToken = stateToken ?? previousToken;
      // Atomic value-matched restore: only entries that still hold the stale
      // token/server are reverted, so a newer login's writes aren't clobbered.
      await storage.restoreActiveServerAndTokenIfStale(
        staleServerId: staleServerId,
        previousServerId: previousServerId,
        staleToken: staleToken,
        replacementToken: replacementToken,
      );

      ref.invalidate(activeServerProvider);
      ref.invalidate(apiServiceProvider);
    } catch (error, stack) {
      DebugLogger.error(
        'stale-silent-login-restore-failed',
        scope: 'auth/state',
        error: error,
        stackTrace: stack,
      );
    }
  }

  void _set(AuthState next, {bool cache = false}) {
    final storage = ref.read(optimizedStorageServiceProvider);
    if (next.user != null && next.isAuthenticated) {
      // Persist user and avatar asynchronously without blocking state update
      unawaited(_persistUserWithAvatar(next, storage));
    } else if (_shouldClearPersistedUser(next)) {
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
    }
    state = AsyncValue.data(next);
    if (cache) {
      _cacheManager.cacheAuthState(next);
    }
  }

  bool _shouldClearPersistedUser(AuthState next) {
    if (next.hasValidToken) return false;
    return next.status == AuthStatus.unauthenticated ||
        next.status == AuthStatus.tokenExpired ||
        next.status == AuthStatus.credentialError;
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
      await storage.saveLocalUserWithAvatar(
        userWithAvatar,
        avatarUrl: resolvedAvatar,
      );
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
          _updateApiServiceToken(token);
          await _activateCachedTokenSession(
            storage: storage,
            token: token,
            reason: 'stored-token-fast-path',
          );
          _validateStoredTokenInBackground(storage: storage, token: token);
          return;
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
            'No token but credentials exist - starting background silent login',
          );
          // Stay in the loading/revalidation state (router shows the splash)
          // while the saved-credential login is in flight, rather than
          // publishing `unauthenticated` — which `authNavigationStateProvider`
          // maps to `needsLogin`, briefly bouncing a cold-starting user to the
          // sign-in page before a valid silent login completes.
          _update(
            (current) => current.copyWith(
              status: AuthStatus.loading,
              isLoading: true,
              clearToken: true,
              clearError: true,
            ),
          );
          unawaited(_bootstrapSilentLogin());
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

  Future<void> _activateCachedTokenSession({
    required OptimizedStorageService storage,
    required String token,
    required String reason,
  }) async {
    var cachedUser = await _readCachedUserWithAvatar(storage);
    final serverId = PreferencesStore.getString(PreferenceKeys.activeServerId);
    final marker = serverId == null || serverId.isEmpty
        ? null
        : ref.read(openWebUiAccountOwnerMarkerStoreProvider).read(serverId);
    final ownerResolution = resolveOpenWebUiCachedAccountOwner(
      marker: marker,
      token: token,
      cachedUserId: cachedUser?.id,
    );
    ref
        .read(openWebUiCachedAccountOwnerMismatchProvider.notifier)
        .set(ownerResolution.ownerMismatch);
    if (!ownerResolution.retainCachedUser) {
      cachedUser = null;
      if (ownerResolution.ownerMismatch) {
        DebugLogger.warning(
          'cached-account-owner-mismatch',
          scope: 'auth/state',
          data: {'hasServer': serverId != null, 'hasMarker': marker != null},
        );
      } else {
        DebugLogger.log(
          'cached-account-user-awaiting-validation',
          scope: 'auth/state',
        );
      }
    }
    DebugLogger.auth(
      'cached-token-session-activated',
      scope: 'auth/state',
      data: {'reason': reason, 'hasUser': cachedUser != null},
    );
    if (cachedUser == null) {
      // No cached user to scope local data by. Publishing `authenticated` here
      // would make `isAuthenticatedProvider2` true while `currentUserProvider2`
      // stays null, so user-scoped reads (e.g. notes) cancel their watch and
      // render empty for the whole session. Hold the normal startup
      // loading/revalidation state instead; background validation recovers the
      // user when reachable (and falls back to proceeding when offline).
      _update(
        (current) => current.copyWith(
          status: AuthStatus.loading,
          token: token,
          isLoading: true,
          clearError: true,
        ),
      );
      return;
    }
    _update(
      (current) => current.copyWith(
        status: AuthStatus.authenticated,
        token: token,
        user: cachedUser,
        isLoading: false,
        clearError: true,
      ),
      cache: true,
    );
  }

  /// Terminal resolution for the no-cached-user bootstrap when background
  /// validation cannot recover a scoped user (offline, server unreachable, or a
  /// transient validation error). We must NOT mark the session authenticated
  /// without a user — user-scoped reads (notes) would pass the auth gate then
  /// return empty — and we must NOT hang on the loading state set by
  /// [_activateCachedTokenSession]. Fall back to a re-login state instead (the
  /// stored token is kept so a later online attempt can reuse it). No-op once a
  /// user has been recovered or the token changed.
  void _failBootstrapWithoutCachedUser(String token) {
    final current = _current;
    if (current.token != token || !current.hasValidToken) return;
    if (current.user != null || current.status != AuthStatus.loading) return;
    DebugLogger.auth(
      'bootstrap-without-cached-user-needs-relogin',
      scope: 'auth/state',
    );
    _update(
      (current) => current.copyWith(
        status: AuthStatus.unauthenticated,
        isLoading: false,
        error: 'Sign in again to load your account',
      ),
    );
  }

  void _validateStoredTokenInBackground({
    required OptimizedStorageService storage,
    required String token,
  }) {
    unawaited(
      Future<void>(() async {
        try {
          final apiReady = await _waitForApiReadiness(
            timeout: const Duration(seconds: 10),
          );
          if (!ref.mounted) return;

          if (!apiReady) {
            DebugLogger.auth(
              'API not reachable during background auth validation',
            );
            _failBootstrapWithoutCachedUser(token);
            return;
          }

          final api = ref.read(apiServiceProvider);
          final user = await api?.getCurrentUser(
            suppressAuthFailureNotification: true,
          );
          if (!ref.mounted) return;

          if (user == null) {
            DebugLogger.auth(
              'Background auth validation skipped: API service unavailable',
            );
            _failBootstrapWithoutCachedUser(token);
            return;
          }

          final current = _current;
          if (current.token != token || !current.hasValidToken) {
            DebugLogger.auth(
              'Background auth validation ignored stale token result',
            );
            return;
          }

          _update(
            (current) => current.copyWith(
              status: AuthStatus.authenticated,
              token: token,
              user: user,
              isLoading: false,
              clearError: true,
            ),
            cache: true,
          );

          _preloadDefaultModel();
        } catch (error) {
          if (!ref.mounted) return;
          if (_isConfirmedAuthFailure(error)) {
            final current = _current;
            if (current.token != token || !current.hasValidToken) {
              DebugLogger.auth(
                'Background auth validation ignored stale token failure',
              );
              return;
            }
            DebugLogger.auth('Stored token rejected during background check');
            await onTokenInvalidated();
            return;
          }

          DebugLogger.warning(
            'background-auth-validation-deferred',
            scope: 'auth/state',
            data: {'error': error.toString()},
          );
          // A transient (non-auth) failure must not strand the no-cached-user
          // bootstrap on the loading state forever; resolve it to re-login.
          _failBootstrapWithoutCachedUser(token);
        }
      }),
    );
  }

  Future<User?> _readCachedUserWithAvatar(OptimizedStorageService storage) =>
      storage.getLocalUserWithAvatar();

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
    bool showLoading = true,
    bool publishErrors = true,
  }) {
    return _loginWithApiKeyInternal(
      apiKey,
      rememberCredentials: rememberCredentials,
      authType: authType,
      showLoading: showLoading,
      publishErrors: publishErrors,
    );
  }

  Future<bool> _loginWithApiKeyInternal(
    String apiKey, {
    bool rememberCredentials = false,
    String authType = 'token',
    bool showLoading = true,
    bool publishErrors = true,
  }) async {
    _beginAuthAttempt();

    if (showLoading) {
      _update(
        (current) => current.copyWith(
          status: AuthStatus.loading,
          isLoading: true,
          clearError: true,
        ),
      );
    }

    final attemptRevision = _authAttemptRevision;
    String? persistedToken;
    Map<String, String>? writtenCredentials;
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

      // Validate by attempting to fetch user info
      try {
        final user = await _validateIssuedToken(api, tokenStr);

        // A concurrent login / logout that started during validation owns the
        // session now; don't persist this token or publish over its state.
        if (_authAttemptSuperseded(attemptRevision)) {
          DebugLogger.auth(
            'JWT login superseded by a newer attempt; not committing',
          );
          _restoreApiServiceTokenToCurrent();
          return false;
        }

        // Save token to storage
        final storage = ref.read(optimizedStorageServiceProvider);
        await storage.saveAuthToken(tokenStr);
        persistedToken = tokenStr;

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
            // Mark rollback-owned only AFTER the write succeeds (see
            // _loginInternal).
            writtenCredentials = {
              'serverId': activeServer.id,
              'username': 'jwt_user',
              'password': tokenStr,
            };
          }
        }

        // Re-check after the persistence awaits: a newer login/logout may have
        // started, and must not be overwritten by this attempt's state.
        if (_authAttemptSuperseded(attemptRevision)) {
          DebugLogger.auth(
            'JWT login superseded after persistence; not publishing',
          );
          await _rollbackUncommittedLoginWrites(
            storage: storage,
            token: tokenStr,
            credentials: writtenCredentials,
          );
          _restoreApiServiceTokenToCurrent();
          return false;
        }

        // Update state with the validated user data.
        _update(
          (current) => current.copyWith(
            status: AuthStatus.authenticated,
            token: tokenStr,
            user: user,
            isLoading: false,
            clearError: true,
          ),
          cache: true,
        );

        // Update API service with token and kick off dependent background work
        _updateApiServiceToken(tokenStr);
        _preloadDefaultModel();

        DebugLogger.auth('JWT token login successful');
        return true;
      } catch (e) {
        // If user fetch fails, the token might be invalid
        if (_isConfirmedAuthFailure(e)) {
          throw Exception(
            'authentication failed: invalid token or insufficient permissions',
          );
        }
        rethrow;
      }
    } catch (e, stack) {
      DebugLogger.error(
        'api-key-login-failed',
        scope: 'auth/state',
        error: e,
        stackTrace: stack,
      );
      // A failed login must not leave its token/credentials in storage; value-
      // match roll them back so a cold start can't restore a failed session.
      if (persistedToken != null) {
        await _rollbackUncommittedLoginWrites(
          storage: ref.read(optimizedStorageServiceProvider),
          token: persistedToken,
          credentials: writtenCredentials,
        );
      }
      // Don't clear the API token or publish an error over a newer attempt;
      // restore the interceptor token to the newer attempt's state instead.
      if (_authAttemptSuperseded(attemptRevision)) {
        _restoreApiServiceTokenToCurrent();
      } else {
        _updateApiServiceToken(null);
        if (publishErrors) {
          _update(
            (current) => current.copyWith(
              status: AuthStatus.error,
              error: e.toString(),
              isLoading: false,
              clearToken: true,
            ),
          );
        }
      }
      rethrow;
    }
  }

  /// Perform login with credentials
  Future<bool> login(
    String username,
    String password, {
    bool rememberCredentials = false,
    bool showLoading = true,
    bool publishErrors = true,
  }) {
    return _loginInternal(
      username,
      password,
      rememberCredentials: rememberCredentials,
      showLoading: showLoading,
      publishErrors: publishErrors,
    );
  }

  Future<bool> _loginInternal(
    String username,
    String password, {
    bool rememberCredentials = false,
    bool showLoading = true,
    bool publishErrors = true,
  }) async {
    _beginAuthAttempt();

    if (showLoading) {
      _update(
        (current) => current.copyWith(
          status: AuthStatus.loading,
          isLoading: true,
          clearError: true,
        ),
      );
    }

    final attemptRevision = _authAttemptRevision;
    String? persistedToken;
    Map<String, String>? writtenCredentials;
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

      // Validate the issued token before publishing authenticated state. Some
      // servers can return a token that is then rejected by /api/v1/auths/.
      final user = await _validateIssuedToken(api, tokenStr);

      // A concurrent login / logout that started during validation owns the
      // session now; don't persist this token or publish over its state.
      if (_authAttemptSuperseded(attemptRevision)) {
        DebugLogger.auth('Login superseded by a newer attempt; not committing');
        _restoreApiServiceTokenToCurrent();
        return false;
      }

      // Save token to storage
      final storage = ref.read(optimizedStorageServiceProvider);
      await storage.saveAuthToken(tokenStr);
      persistedToken = tokenStr;

      // Save credentials if requested
      if (rememberCredentials) {
        final activeServer = await ref.read(activeServerProvider.future);
        if (activeServer != null) {
          await storage.saveCredentials(
            serverId: activeServer.id,
            username: username,
            password: password,
          );
          // Mark rollback-owned only AFTER the write succeeds, so a failed
          // saveCredentials doesn't make the catch delete a pre-existing
          // identical remembered credential this attempt never wrote.
          writtenCredentials = {
            'serverId': activeServer.id,
            'username': username,
            'password': password,
          };
        }
      }

      // Re-check after the persistence awaits: a newer login/logout may have
      // started, and must not be overwritten by this attempt's published state.
      if (_authAttemptSuperseded(attemptRevision)) {
        DebugLogger.auth('Login superseded after persistence; not publishing');
        await _rollbackUncommittedLoginWrites(
          storage: storage,
          token: tokenStr,
          credentials: writtenCredentials,
        );
        _restoreApiServiceTokenToCurrent();
        return false;
      }

      // Update state and API service
      _update(
        (current) => current.copyWith(
          status: AuthStatus.authenticated,
          token: tokenStr,
          user: user,
          isLoading: false,
          clearError: true,
        ),
        cache: true,
      );

      _updateApiServiceToken(tokenStr);
      _preloadDefaultModel();

      DebugLogger.auth('Login successful');
      return true;
    } catch (e, stack) {
      DebugLogger.error(
        'login-failed',
        scope: 'auth/state',
        error: e,
        stackTrace: stack,
      );
      // A failed login must not leave its token/credentials in storage (a later
      // exception can follow a successful token write); value-match roll them
      // back so a cold start can't restore a session presented as failed.
      if (persistedToken != null) {
        await _rollbackUncommittedLoginWrites(
          storage: ref.read(optimizedStorageServiceProvider),
          token: persistedToken,
          credentials: writtenCredentials,
        );
      }
      // Don't clear the API token or publish an error over a newer attempt;
      // restore the interceptor token to the newer attempt's state instead.
      if (_authAttemptSuperseded(attemptRevision)) {
        _restoreApiServiceTokenToCurrent();
      } else {
        _updateApiServiceToken(null);
        if (publishErrors) {
          _update(
            (current) => current.copyWith(
              status: AuthStatus.error,
              error: e.toString(),
              isLoading: false,
              clearToken: true,
            ),
          );
        }
      }
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
    _beginAuthAttempt();
    _update(
      (current) => current.copyWith(
        status: AuthStatus.loading,
        isLoading: true,
        clearError: true,
      ),
    );

    final attemptRevision = _authAttemptRevision;
    String? persistedToken;
    Map<String, String>? writtenCredentials;
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

      // Validate the issued token before publishing authenticated state. Some
      // servers can return a token that is then rejected by /api/v1/auths/.
      final user = await _validateIssuedToken(api, tokenStr);

      // A concurrent login / logout that started during validation owns the
      // session now; don't persist this token or publish over its state.
      if (_authAttemptSuperseded(attemptRevision)) {
        DebugLogger.auth(
          'LDAP login superseded by a newer attempt; not committing',
        );
        _restoreApiServiceTokenToCurrent();
        return false;
      }

      // Save token to storage
      final storage = ref.read(optimizedStorageServiceProvider);
      await storage.saveAuthToken(tokenStr);
      persistedToken = tokenStr;

      if (!ref.mounted) {
        await _rollbackUncommittedLoginWrites(
          storage: storage,
          token: tokenStr,
          credentials: writtenCredentials,
        );
        return false;
      }

      // Save JWT token for re-authentication if requested
      // We store the token (not the raw LDAP password) for security:
      // - JWT tokens can be revoked server-side
      // - Avoids storing the user's directory password
      // - Consistent with SSO token storage approach
      if (rememberCredentials) {
        final activeServer = await ref.read(activeServerProvider.future);
        if (!ref.mounted) {
          await _rollbackUncommittedLoginWrites(
            storage: storage,
            token: tokenStr,
            credentials: writtenCredentials,
          );
          return false;
        }
        if (activeServer != null) {
          await storage.saveCredentials(
            serverId: activeServer.id,
            // Prefix with ldap: to preserve original username for debugging
            // while indicating this is token-based auth
            username: 'ldap:$username',
            password: tokenStr, // Store JWT token, not LDAP password
            authType: 'ldap', // Track that this originated from LDAP login
          );
          // Mark rollback-owned only AFTER the write succeeds (see _loginInternal).
          writtenCredentials = {
            'serverId': activeServer.id,
            'username': 'ldap:$username',
            'password': tokenStr,
          };
        }
      }

      if (!ref.mounted) {
        await _rollbackUncommittedLoginWrites(
          storage: storage,
          token: tokenStr,
          credentials: writtenCredentials,
        );
        return false;
      }

      // Re-check after the persistence awaits: a newer login/logout may have
      // started, and must not be overwritten by this attempt's published state.
      if (_authAttemptSuperseded(attemptRevision)) {
        DebugLogger.auth(
          'LDAP login superseded after persistence; not publishing',
        );
        await _rollbackUncommittedLoginWrites(
          storage: storage,
          token: tokenStr,
          credentials: writtenCredentials,
        );
        _restoreApiServiceTokenToCurrent();
        return false;
      }

      // Update state and API service
      _update(
        (current) => current.copyWith(
          status: AuthStatus.authenticated,
          token: tokenStr,
          user: user,
          isLoading: false,
          clearError: true,
        ),
        cache: true,
      );

      _updateApiServiceToken(tokenStr);
      _preloadDefaultModel();

      DebugLogger.auth('LDAP login successful');
      return true;
    } catch (e, stack) {
      DebugLogger.error(
        'ldap-login-failed',
        scope: 'auth/state',
        error: e,
        stackTrace: stack,
      );
      // A failed login must not leave its token/credentials in storage; value-
      // match roll them back so a cold start can't restore a failed session.
      if (persistedToken != null) {
        await _rollbackUncommittedLoginWrites(
          storage: ref.read(optimizedStorageServiceProvider),
          token: persistedToken,
          credentials: writtenCredentials,
        );
      }
      // Don't clear the API token or publish an error over a newer attempt;
      // restore the interceptor token to the newer attempt's state instead.
      if (_authAttemptSuperseded(attemptRevision)) {
        _restoreApiServiceTokenToCurrent();
      } else {
        _update(
          (current) => current.copyWith(
            status: AuthStatus.error,
            error: e.toString(),
            isLoading: false,
            clearToken: true,
          ),
        );
        _updateApiServiceToken(null);
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

  Future<User> _validateIssuedToken(ApiService api, String token) async {
    api.updateAuthToken(token);
    try {
      return await api.getCurrentUser(suppressAuthFailureNotification: true);
    } catch (error, stackTrace) {
      api.updateAuthToken(null);
      Error.throwWithStackTrace(
        Exception(_loginValidationMessage(error)),
        stackTrace,
      );
    }
  }

  bool _isConfirmedAuthFailure(Object error) {
    if (error is DioException) {
      final statusCode = error.response?.statusCode;
      return statusCode == 401 || statusCode == 403;
    }

    final text = error.toString();
    return text.contains('401') ||
        text.contains('403') ||
        text.contains('Unauthorized') ||
        text.contains('Forbidden');
  }

  String _loginValidationMessage(Object error) {
    if (error is DioException) {
      final statusCode = error.response?.statusCode;
      if (statusCode == 401 || statusCode == 403) {
        return '$statusCode Unauthorized: sign-in token rejected by server';
      }

      final detail = error.response?.data;
      if (detail is Map && detail['detail'] != null) {
        return 'Sign-in validation failed: ${detail['detail']}';
      }
    }

    final text = error.toString();
    if (text.contains('401') || text.contains('Unauthorized')) {
      return '401 Unauthorized: sign-in token rejected by server';
    }
    return 'Unable to validate sign-in session';
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
    // Claim our OWN attempt revision up front (don't piggyback on the current
    // one): otherwise, if a manual login is already validating at revision N,
    // this silent re-login would capture the same N and could `claimCommit()`
    // the OLD saved credentials, bumping the revision and making the manual
    // login treat itself as superseded. Claiming here means a manual login that
    // starts AFTER bumps again and wins; a stale silent login can't commit.
    final startRevision = _beginAuthAttempt();
    int? claimRevision;
    bool canCommit() {
      final expectedRevision = claimRevision ?? startRevision;
      return ref.mounted && _authAttemptRevision == expectedRevision;
    }

    bool claimCommit() {
      if (!canCommit()) return false;
      claimRevision = _beginAuthAttempt();
      return true;
    }

    return _performSilentLoginInternal(
      showLoading: true,
      publishNetworkErrors: true,
      canCommit: canCommit,
      claimCommit: claimCommit,
    );
  }

  /// Bootstrap path (no stored token but saved credentials): runs the
  /// background silent login, then GUARANTEES the bootstrap `loading` state
  /// resolves. On success the login commits `authenticated`; if it commits
  /// nothing (auth/network/unknown failure all `return false` without touching
  /// state in background mode), fall back to `unauthenticated` so the app
  /// reaches the sign-in page instead of hanging on the splash.
  Future<void> _bootstrapSilentLogin() async {
    // Capture the attempt revision: every foreground login / logout /
    // token-invalidation bumps it via `_beginAuthAttempt`. If one starts while
    // this background login runs, it is also briefly `loading` with no token, so
    // the fallback below must NOT fire — otherwise this stale task would clobber
    // the newer attempt with `unauthenticated` and bounce the user to sign-in.
    final bootstrapRevision = _authAttemptRevision;
    final committed = await _performSilentLoginInBackground();
    if (!ref.mounted) return;
    if (bootstrapShouldFallbackToUnauthenticated(
      committed: committed,
      capturedRevision: bootstrapRevision,
      currentRevision: _authAttemptRevision,
      status: _current.status,
      hasValidToken: _current.hasValidToken,
    )) {
      DebugLogger.auth(
        'bootstrap-silent-login-unresolved-needs-login',
        scope: 'auth/state',
      );
      _update(
        (current) => current.copyWith(
          status: AuthStatus.unauthenticated,
          isLoading: false,
          clearToken: true,
        ),
      );
    }
  }

  Future<bool> _performSilentLoginInBackground() async {
    final startRevision = _authAttemptRevision;
    int? claimRevision;

    bool canCommit() {
      final expectedRevision = claimRevision ?? startRevision;
      final current = _current;
      // Accept the bootstrap `loading` state too: the no-token-with-credentials
      // path now holds `loading` (not `unauthenticated`) while this background
      // login runs, so a successful login must still be allowed to commit.
      final commitableStatus =
          current.status == AuthStatus.unauthenticated ||
          current.status == AuthStatus.loading;
      return ref.mounted &&
          _authAttemptRevision == expectedRevision &&
          commitableStatus &&
          !current.hasValidToken;
    }

    bool claimCommit() {
      if (!canCommit()) return false;
      claimRevision = _beginAuthAttempt();
      return true;
    }

    try {
      return await _performSilentLoginInternal(
        showLoading: false,
        publishNetworkErrors: false,
        canCommit: canCommit,
        claimCommit: claimCommit,
      );
    } catch (error, stack) {
      DebugLogger.error(
        'background-silent-login-failed',
        scope: 'auth/state',
        error: error,
        stackTrace: stack,
      );
      return false;
    }
  }

  Future<bool> _performSilentLoginInternal({
    required bool showLoading,
    required bool publishNetworkErrors,
    bool Function()? canCommit,
    bool Function()? claimCommit,
  }) async {
    if (showLoading) {
      _update(
        (current) => current.copyWith(
          status: AuthStatus.loading,
          isLoading: true,
          clearError: true,
        ),
      );
    }

    // Snapshot the credentials being attempted ONCE and use it for both the
    // login attempt AND the failure cleanup, so a confirmed-auth-failure clears
    // exactly the credentials that were tried (not a re-read that may have
    // changed) and never a concurrent login's freshly saved credentials.
    final attemptedCredentials = await ref
        .read(optimizedStorageServiceProvider)
        .getSavedCredentials();

    try {
      return await _performSilentLoginAttempt(
        savedCredentials: attemptedCredentials,
        canCommit: canCommit,
        claimCommit: claimCommit,
      );
    } catch (e, stack) {
      DebugLogger.error(
        'silent-login-failed',
        scope: 'auth/state',
        error: e,
        stackTrace: stack,
      );

      return await _handleSilentLoginFailure(
        e,
        publishNetworkErrors: publishNetworkErrors,
        canCommit: canCommit,
        attemptedCredentials: attemptedCredentials,
      );
    }
  }

  Future<bool> _performSilentLoginAttempt({
    required Map<String, String>? savedCredentials,
    bool Function()? canCommit,
    bool Function()? claimCommit,
  }) async {
    final storage = ref.read(optimizedStorageServiceProvider);

    if (savedCredentials == null) {
      if (_canCommitAuth(canCommit)) {
        _update(
          (current) => current.copyWith(
            status: AuthStatus.unauthenticated,
            isLoading: false,
            clearError: true,
          ),
        );
      }
      return false;
    }

    final serverId = savedCredentials['serverId']!;
    final username = savedCredentials['username']!;
    final password = savedCredentials['password']!;

    // Ensure the saved server still exists before switching
    final serverConfigs = await ref.read(serverConfigsProvider.future);
    final serverConfig = serverConfigs
        .where((config) => config.id == serverId)
        .firstOrNull;

    if (serverConfig == null) {
      // The saved credentials point at a server that no longer exists, so they
      // can never log in: clear them (and the dangling active server) so cold
      // start doesn't re-enter this impossible path every launch. Only skip the
      // mutation for a stale background attempt superseded by a newer login.
      if (!_canCommitAuth(canCommit)) {
        DebugLogger.auth(
          'Silent login skipped stale missing-server credential cleanup',
        );
        return false;
      }
      // Atomic compare-and-delete: only clears the exact credentials we
      // attempted, so a concurrent foreground login that saved fresh
      // credentials in the await window above isn't clobbered.
      final clearedCreds = await storage.deleteSavedCredentialsIfMatches({
        'serverId': serverId,
        'username': username,
        'password': password,
      });
      if (clearedCreds) {
        // Compare-and-clear the active server (only if it still points at the
        // missing one) so a concurrent server switch isn't clobbered.
        if (_canCommitAuth(canCommit)) {
          await storage.clearActiveServerIdIfMatches(serverId);
        }
        ref.invalidate(serverConfigsProvider);
        ref.invalidate(activeServerProvider);
      }

      // Re-check freshness after the delete awaits before publishing state.
      if (!clearedCreds || !_canCommitAuth(canCommit)) {
        DebugLogger.auth(
          'Silent login skipped missing-server state commit (stale or creds changed)',
        );
        return false;
      }
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

    if (!_canCommitAuth(canCommit)) {
      DebugLogger.auth('Silent login skipped stale saved credentials');
      return false;
    }

    // Attempt login based on auth type
    final authType = savedCredentials['authType'] ?? 'credentials';
    final tempApi = ApiService(
      serverConfig: serverConfig,
      workerManager: ref.read(workerManagerProvider),
    );

    // Handle JWT token-based authentication (includes legacy prefixes)
    // LDAP now also stores JWT tokens for re-auth (not raw passwords)
    final usesSavedJwt =
        username == 'api_key_user' ||
        username == 'jwt_user' ||
        username.startsWith('ldap:') ||
        authType == 'token' ||
        authType == 'sso' ||
        authType == 'ldap';

    final result = usesSavedJwt
        ? await _authenticateSavedJwt(tempApi, password)
        : await _authenticateSavedCredentials(tempApi, username, password);

    return _commitSilentLoginResult(
      storage: storage,
      serverId: serverId,
      token: result.token,
      user: result.user,
      canCommit: canCommit,
      claimCommit: claimCommit,
    );
  }

  Future<({String token, User user})> _authenticateSavedJwt(
    ApiService api,
    String token,
  ) async {
    final tokenStr = token.trim();
    if (tokenStr.isEmpty) {
      throw Exception('Token cannot be empty');
    }
    if (TokenValidator.isApiKey(tokenStr)) {
      throw Exception('apiKeyNotSupported');
    }
    if (!_isValidTokenFormat(tokenStr)) {
      throw Exception('Invalid token format');
    }

    final user = await _validateIssuedToken(api, tokenStr);
    return (token: tokenStr, user: user);
  }

  Future<({String token, User user})> _authenticateSavedCredentials(
    ApiService api,
    String username,
    String password,
  ) async {
    final response = await api.login(username, password);
    final token = response['token'] ?? response['access_token'];
    if (token == null || token.toString().trim().isEmpty) {
      throw Exception('No authentication token received');
    }

    final tokenStr = token.toString();
    if (!_isValidTokenFormat(tokenStr)) {
      throw Exception('Invalid authentication token format');
    }

    final user = await _validateIssuedToken(api, tokenStr);
    return (token: tokenStr, user: user);
  }

  Future<bool> _commitSilentLoginResult({
    required OptimizedStorageService storage,
    required String serverId,
    required String token,
    required User user,
    bool Function()? canCommit,
    bool Function()? claimCommit,
  }) async {
    if (!_claimAuthCommit(
      operation: 'Silent login',
      claimCommit: claimCommit,
    )) {
      return false;
    }

    final previousServerId = await storage.getActiveServerId();
    final previousToken = await storage.getAuthToken();
    if (!_canCommitAuth(canCommit)) {
      DebugLogger.auth('Silent login skipped stale persistence commit');
      return false;
    }

    var wrotePersistence = false;
    try {
      await storage.setActiveServerId(serverId);
      wrotePersistence = true;
      if (!_canCommitAuth(canCommit)) {
        DebugLogger.auth('Silent login restoring stale server commit');
        await _restoreStaleSilentLoginPersistence(
          storage: storage,
          staleServerId: serverId,
          previousServerId: previousServerId,
          staleToken: token,
          previousToken: previousToken,
        );
        return false;
      }

      await storage.saveAuthToken(token);
      if (!_canCommitAuth(canCommit)) {
        DebugLogger.auth('Silent login restoring stale persistence commit');
        await _restoreStaleSilentLoginPersistence(
          storage: storage,
          staleServerId: serverId,
          previousServerId: previousServerId,
          staleToken: token,
          previousToken: previousToken,
        );
        return false;
      }
    } catch (error) {
      // Undo any PARTIAL persistence (value-matched, atomic) whenever we wrote
      // some of it — not only when the attempt went stale — so a storage failure
      // between setActiveServerId and saveAuthToken can't strand the app on the
      // silent-login server/token without committing.
      if (wrotePersistence) {
        await _restoreStaleSilentLoginPersistence(
          storage: storage,
          staleServerId: serverId,
          previousServerId: previousServerId,
          staleToken: token,
          previousToken: previousToken,
        );
      }
      if (_canCommitAuth(canCommit)) {
        // We already claimed this attempt (the revision bump suppresses the
        // bootstrap fallback), so a bare rethrow would leave cold start stuck on
        // `loading` with no token. Resolve the claimed attempt to unauthenticated
        // before propagating the persistence error.
        DebugLogger.auth(
          'Silent login resolving claimed attempt after persistence failure',
        );
        _update(
          (current) => current.copyWith(
            status: AuthStatus.unauthenticated,
            isLoading: false,
            clearToken: true,
          ),
        );
      }
      rethrow;
    }

    // Final freshness gate immediately before publishing the in-memory session:
    // if a logout / newer auth attempt landed during persistence, undo our
    // writes and bail so a stale background login can't resurrect the previous
    // session (invalidate providers + install the old token).
    if (!_canCommitAuth(canCommit)) {
      DebugLogger.auth('Silent login skipped stale in-memory commit');
      await _restoreStaleSilentLoginPersistence(
        storage: storage,
        staleServerId: serverId,
        previousServerId: previousServerId,
        staleToken: token,
        previousToken: previousToken,
      );
      return false;
    }

    ref.invalidate(activeServerProvider);
    ref.invalidate(apiServiceProvider);
    _update(
      (current) => current.copyWith(
        status: AuthStatus.authenticated,
        token: token,
        user: user,
        isLoading: false,
        clearError: true,
      ),
      cache: true,
    );
    _updateApiServiceToken(token);
    _preloadDefaultModel();

    DebugLogger.auth('Silent login successful');
    return true;
  }

  Future<bool> _handleSilentLoginFailure(
    Object error, {
    required bool publishNetworkErrors,
    bool Function()? canCommit,
    Map<String, String>? attemptedCredentials,
  }) async {
    var errorMessage = error.toString();

    // Don't clear credentials on connection errors - only clear on actual auth failures
    // Check if this is a genuine auth failure vs network issue
    final isNetworkError =
        error.toString().contains('SocketException') ||
        error.toString().contains('Connection') ||
        error.toString().contains('timeout') ||
        error.toString().contains('NetworkImage');

    // Local saved-token validation failures (raised by `_authenticateSavedJwt`
    // before any server request) mean the stored credential can never succeed,
    // so treat them as terminal credential failures too — otherwise they fall
    // to the unknown-error path, keep the bad credential, and repeat the
    // impossible silent login on every cold start.
    final isInvalidSavedToken =
        error.toString().contains('apiKeyNotSupported') ||
        error.toString().contains('Invalid token format') ||
        error.toString().contains('Token cannot be empty');

    if ((!isNetworkError &&
            (error.toString().contains('401') ||
                error.toString().contains('403') ||
                error.toString().contains('authentication') ||
                error.toString().contains('unauthorized'))) ||
        isInvalidSavedToken) {
      // A confirmed auth failure means the saved secret is bad: clear it so it
      // isn't retried on every cold start (the background bootstrap path turns a
      // bare `false` into a generic unauthenticated state otherwise). Only bail
      // without cleanup when a newer auth attempt has superseded this (stale)
      // background task.
      if (!_canCommitAuth(canCommit)) {
        DebugLogger.auth('Silent login ignored stale credential auth failure');
        return false;
      }

      // Only clear credentials if this is a real auth failure, not a network
      // issue — and only the exact credentials we attempted, so a concurrent
      // login that saved fresh credentials during this attempt isn't clobbered.
      final storage = ref.read(optimizedStorageServiceProvider);
      try {
        // Atomic compare-and-delete: clear only the exact credentials we tried,
        // so a concurrent login that saved fresh credentials isn't clobbered.
        final bool cleared;
        if (attemptedCredentials == null) {
          await storage.deleteSavedCredentials();
          cleared = true;
        } else {
          cleared = await storage.deleteSavedCredentialsIfMatches(
            attemptedCredentials,
          );
        }
        DebugLogger.auth(
          cleared
              ? 'Cleared invalid credentials after auth failure'
              : 'Skipped clearing credentials that changed during the auth attempt',
        );
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

      // The bad credential is gone regardless; only publish the error state if a
      // newer auth attempt hasn't started during the delete await.
      if (!_canCommitAuth(canCommit)) {
        DebugLogger.auth(
          'Silent login cleared bad credentials but skipped stale state commit',
        );
        return false;
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
      if (publishNetworkErrors) {
        if (!_canCommitAuth(canCommit)) {
          DebugLogger.auth('Silent login ignored stale network failure');
          return false;
        }
        errorMessage = 'Connection issue - please check your network';
        _update(
          (current) => current.copyWith(
            status: AuthStatus.error,
            error: errorMessage,
            isLoading: false,
          ),
        );
      }
      return false;
    }

    // Unknown error type - treat as connection issue but keep credentials
    if (errorMessage.trim().isEmpty) {
      errorMessage = 'Connection issue - please try again shortly';
    }
    DebugLogger.auth(
      'Silent login failed with unknown error - keeping credentials',
    );
    if (publishNetworkErrors) {
      if (!_canCommitAuth(canCommit)) {
        DebugLogger.auth('Silent login ignored stale failure');
        return false;
      }
      _update(
        (current) => current.copyWith(
          status: AuthStatus.error,
          error: errorMessage,
          isLoading: false,
        ),
      );
    }
    return false;
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
    // Capture the token being rejected up-front — synchronously, before any
    // await or revision bump — so every cleanup path below deletes only THIS
    // token and never a fresh one that a concurrent foreground login may have
    // already saved through `_authStateLock`.
    final rejectedToken = _current.hasValidToken ? _current.token : null;

    // Coalesce onto an in-flight silent re-login (a prior invalidation, a manual
    // retry, or bootstrap). Bumping the attempt revision here would mark that
    // running login stale, and the logic below would then skip starting a
    // replacement (reloginInProgress) — dead-ending in tokenExpired even though
    // valid saved credentials are available. Let the running login resolve.
    //
    // But still clear the REJECTED token before coalescing: that in-flight login
    // may have been started by a manual/bootstrap flow that won't run the
    // invalidation cleanup, and if it ultimately fails the bad token would
    // otherwise linger and be restored on the next cold start. Value-matched so
    // we never clobber a fresh token the in-flight login may have just saved.
    if (_silentLoginFuture != null) {
      if (rejectedToken != null && rejectedToken.isNotEmpty) {
        try {
          await ref
              .read(optimizedStorageServiceProvider)
              .deleteAuthTokenIfMatches(rejectedToken);
        } catch (error, stack) {
          DebugLogger.error(
            'token-delete-failed',
            scope: 'auth/state',
            error: error,
            stackTrace: stack,
          );
        }
      }
      DebugLogger.auth(
        'Token invalidated while a silent re-login is in progress; cleared '
        'the rejected token and coalesced onto it',
      );
      return;
    }
    _beginAuthAttempt();
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
      // Value-matched delete: only remove the rejected token, never a fresh one
      // a concurrent foreground login may have saved between this 401 arriving
      // and the lock-serialised delete running (which would otherwise leave the
      // app authenticated in memory but with no stored token).
      if (rejectedToken != null && rejectedToken.isNotEmpty) {
        await storage.deleteAuthTokenIfMatches(rejectedToken);
      }
      await storage.clearUserScopedAuthData();
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
    _beginAuthAttempt();
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
}
