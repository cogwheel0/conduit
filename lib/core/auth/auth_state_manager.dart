import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
// Types are used through app_providers.dart
import '../providers/app_providers.dart';
import '../models/user.dart';
import '../models/server_config.dart';
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

typedef SavedCredentialAuthApiFactory =
    ApiService Function({
      required ServerConfig serverConfig,
      required WorkerManager workerManager,
    });

const _newerAuthAttemptSettleGrace = Duration(milliseconds: 500);

final class _AuthPublicationRolledBack implements Exception {
  const _AuthPublicationRolledBack(this.cause);

  final Object cause;

  @override
  String toString() => 'Authentication publication was rolled back';
}

/// Testable construction seam for the short-lived client used to validate
/// saved credentials against their owning server before a silent-login commit.
@Riverpod(keepAlive: true)
SavedCredentialAuthApiFactory savedCredentialAuthApiFactory(Ref ref) =>
    ({required serverConfig, required workerManager}) {
      // Saved-credential validation deliberately uses a short-lived client,
      // but it is still created from the configured server headers. Keep the
      // incomplete-logout Cookie fence on that client too: otherwise silent
      // login can reattach a surviving reverse-proxy session while logout
      // cleanup is pending. Fail closed if provider teardown races creation.
      bool shouldSuppressCookieHeader() {
        try {
          return ref.read(incompleteLogoutFenceProvider) ||
              ref
                  .read(incompleteLogoutFenceProvider.notifier)
                  .desiredSuppressed;
        } catch (_) {
          return true;
        }
      }

      return ApiService(
        serverConfig: serverConfig,
        workerManager: workerManager,
        suppressCookieCustomHeader: shouldSuppressCookieHeader(),
        shouldSuppressCookieCustomHeader: shouldSuppressCookieHeader,
      );
    };

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

/// Runs a delayed retry reset only while it still owns the latest generation.
@visibleForTesting
Future<void> resetAuthRetryStateWhenCurrent({
  required Future<void> delay,
  required int scheduledGeneration,
  required int Function() currentGeneration,
  required void Function() reset,
}) async {
  await delay;
  if (currentGeneration() == scheduledGeneration) reset();
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
  int _authAttemptSafetyEpoch = 0;
  int _sessionSafetyEpoch = 0;
  int? _lastTransactionalSessionRevision;
  final List<String> _recentlyRevokedTokens = <String>[];
  int _activeLogoutOperations = 0;
  AuthState _lastSettledState = const AuthState(status: AuthStatus.initial);

  // Prevent infinite retry loops
  int _retryCount = 0;
  static const int _maxRetries = 3;
  DateTime? _lastRetryTime;
  int _retryResetGeneration = 0;

  AuthState get _current =>
      state.asData?.value ?? const AuthState(status: AuthStatus.initial);

  int _beginAuthAttempt() {
    _authAttemptSafetyEpoch = _sessionSafetyEpoch;
    return ++_authAttemptRevision;
  }

  /// True when a newer auth attempt (login / logout / token-invalidation, each
  /// of which calls [_beginAuthAttempt]) has started since [attemptRevision] was
  /// captured, or the notifier is gone. Foreground logins check this before
  /// persisting a token or publishing state so a slow attempt can't overwrite a
  /// newer one's result.
  bool _authAttemptSuperseded(int attemptRevision) =>
      !ref.mounted ||
      _authAttemptRevision != attemptRevision ||
      _authAttemptSafetyEpoch != _sessionSafetyEpoch;

  void _resolveAbortedAuthAttempt(int attemptRevision) {
    // A disposed notifier no longer owns an API provider. In particular, do
    // not touch `ref` while resolving a late validation continuation.
    if (!ref.mounted) return;
    if (_authAttemptRevision != attemptRevision) {
      _restoreApiServiceTokenToCurrent();
      return;
    }

    final current = _current;
    if (!current.isLoading && current.status != AuthStatus.loading) {
      // The owned attempt already published its terminal credential/network
      // error. Abort resolution is only the fallback for a state still stuck
      // in loading and must not erase that actionable result.
      return;
    }

    // A current attempt can abort because its server ownership changed even
    // when no newer auth attempt bumped the auth revision. Never restore the
    // loading state's old token onto the newly selected API origin; settle the
    // owned attempt explicitly and rebuild the API client tokenless.
    _set(const AuthState(status: AuthStatus.unauthenticated, isLoading: false));
    _updateApiServiceToken(null);
    ref.invalidate(apiServiceProvider);
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

  Future<ServerSessionOwnershipSnapshot> _captureLoginServerOwnership(
    OptimizedStorageService storage,
    ApiService api, {
    required bool requireActive,
  }) async {
    final ownership = await storage.captureServerSessionOwnership(
      validatedConfig: api.serverConfig,
      requireActive: requireActive,
    );
    if (ownership == null) {
      throw Exception(
        'Server configuration changed during authentication. Please retry.',
      );
    }
    return ownership;
  }

  Future<bool> _commitValidatedExistingServerSession({
    required OptimizedStorageService storage,
    required ServerSessionOwnershipSnapshot ownership,
    required String token,
    required User user,
    required int attemptRevision,
    Map<String, String>? rememberedCredentials,
    bool invalidateServerProviders = false,
  }) async {
    final previousState =
        _current.isLoading || _current.status == AuthStatus.loading
        ? _lastSettledState
        : _current;
    final publicationSafetyEpoch = _sessionSafetyEpoch;
    var publicationAttempted = false;
    try {
      return await storage.commitExistingServerSession(
        ownership: ownership,
        token: token,
        rememberedCredentials: rememberedCredentials,
        canCommit: () => !_authAttemptSuperseded(attemptRevision),
        onRollbackUncertain: () {
          if (!ref.mounted) return;
          _poisonUncertainServerSession(failedAttemptRevision: attemptRevision);
        },
        publish: () {
          publicationAttempted = true;
          return _publishCommittedAuthenticatedSession(
            attemptRevision: attemptRevision,
            candidateToken: token,
            publish: () {
              _setIncompleteLogoutFenceInMemory(false);
              _updateApiServiceToken(token);
              if (invalidateServerProviders) {
                ref.invalidate(activeServerProvider);
                ref.invalidate(apiServiceProvider);
              }
              if (_authAttemptSuperseded(attemptRevision)) {
                throw StateError(
                  'Authentication attempt was superseded during publication.',
                );
              }
              _lastTransactionalSessionRevision = attemptRevision;
              // Auth state is the final externally observable commit point. No
              // stale ownership metadata may be written after listeners run.
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
            },
          );
        },
      );
    } catch (error, stackTrace) {
      if (publicationAttempted &&
          _restoreRolledBackAuthPublication(
            attemptRevision: attemptRevision,
            capturedSessionSafetyEpoch: publicationSafetyEpoch,
            previousState: previousState,
          ) &&
          error is! ServerConfigSessionRollbackException) {
        Error.throwWithStackTrace(
          _AuthPublicationRolledBack(error),
          stackTrace,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  void _set(AuthState next, {bool cache = false}) {
    final storage = ref.read(optimizedStorageServiceProvider);
    final shouldPersistAuthenticatedUser =
        next.user != null && next.isAuthenticated;
    final shouldClearPersistedUser =
        !shouldPersistAuthenticatedUser && _shouldClearPersistedUser(next);
    final userCacheAttemptRevision = _authAttemptRevision;
    final userCacheSafetyEpoch = _sessionSafetyEpoch;
    if (!next.isLoading && next.status != AuthStatus.loading) {
      _lastSettledState = next;
    }
    // Riverpod listeners run synchronously during this assignment. Any cache
    // derived from the publication must therefore be fenced after listeners
    // have had a chance to replace it or start a newer auth operation.
    state = AsyncValue.data(next);
    // Publish token/user removal before starting durable cleanup. A rejected
    // bearer must stop authorizing live requests immediately even when the
    // Keychain/Drift cleanup is slow or fails.
    final stillOwnsPersistedUserClear =
        shouldClearPersistedUser &&
        ref.mounted &&
        _authAttemptRevision == userCacheAttemptRevision &&
        _sessionSafetyEpoch == userCacheSafetyEpoch &&
        !_current.hasValidToken &&
        _current.user == null;
    if (stillOwnsPersistedUserClear) {
      unawaited(
        storage.saveLocalUser(null).onError((error, stack) {
          _logAuthenticationFailure(
            'local-user-clear-failed',
            error,
            stackTrace: stack,
          );
        }),
      );
    }
    final stillOwnsAuthenticatedPublication =
        shouldPersistAuthenticatedUser &&
        _ownsUserCachePersistence(
          next,
          attemptRevision: userCacheAttemptRevision,
          safetyEpoch: userCacheSafetyEpoch,
        );
    if (cache && stillOwnsAuthenticatedPublication) {
      _cacheManager.cacheAuthState(next);
    }
    if (stillOwnsAuthenticatedPublication) {
      // Riverpod listeners run synchronously during the assignment above. They
      // may immediately start logout, rotate accounts, or replace this state.
      // Start the durable cache write only after publication, and fence it to
      // the exact auth operation/session that is still current.
      unawaited(
        _persistUserWithAvatar(
          next,
          storage,
          attemptRevision: userCacheAttemptRevision,
          safetyEpoch: userCacheSafetyEpoch,
        ),
      );
    }
  }

  bool _shouldClearPersistedUser(AuthState next) {
    if (next.hasValidToken) return false;
    return next.status == AuthStatus.unauthenticated ||
        next.status == AuthStatus.tokenExpired ||
        next.status == AuthStatus.credentialError;
  }

  void _publishTokenlessAuthRejection({
    required AuthStatus status,
    String? error,
    required bool isLoading,
  }) {
    _lastTransactionalSessionRevision = null;
    _updateApiServiceToken(null);
    _update(
      (current) => current.copyWith(
        status: status,
        error: error,
        isLoading: isLoading,
        clearToken: true,
        clearUser: true,
        clearError: error == null,
      ),
    );
  }

  Future<void> _persistUserWithAvatar(
    AuthState authState,
    OptimizedStorageService storage, {
    required int attemptRevision,
    required int safetyEpoch,
  }) async {
    try {
      if (!_ownsUserCachePersistence(
        authState,
        attemptRevision: attemptRevision,
        safetyEpoch: safetyEpoch,
      )) {
        return;
      }
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
      // Keep this check immediately adjacent to the storage call. The storage
      // service serializes user writes with auth cleanup, so a write admitted
      // here completes before any later logout/account transition can clear or
      // replace it; a continuation that lost ownership never enters the queue.
      if (!_ownsUserCachePersistence(
        authState,
        attemptRevision: attemptRevision,
        safetyEpoch: safetyEpoch,
      )) {
        return;
      }
      await storage.saveLocalUserWithAvatar(
        userWithAvatar,
        avatarUrl: resolvedAvatar,
      );
    } catch (error) {
      _logAuthenticationFailure('local-user-persist-failed', error);
    }
  }

  bool _ownsUserCachePersistence(
    AuthState expected, {
    required int attemptRevision,
    required int safetyEpoch,
  }) {
    if (!ref.mounted ||
        _authAttemptRevision != attemptRevision ||
        _sessionSafetyEpoch != safetyEpoch) {
      return false;
    }
    final current = _current;
    return current.isAuthenticated &&
        current.token == expected.token &&
        current.user == expected.user;
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
    final attemptRevision = _beginAuthAttempt();
    await _initialize(attemptRevision: attemptRevision);
    return _current;
  }

  /// Initialize auth state from storage
  Future<void> _initialize({
    required int attemptRevision,
    int? inheritedTransactionalRevision,
    String? inheritedTransactionalToken,
  }) async {
    if (_authAttemptSuperseded(attemptRevision)) return;
    _update(
      (current) =>
          current.copyWith(status: AuthStatus.loading, isLoading: true),
    );
    if (_authAttemptSuperseded(attemptRevision)) return;

    final canInheritTransactionalOwnership =
        inheritedTransactionalRevision != null &&
        inheritedTransactionalToken != null;

    void clearInheritedTransactionalOwnership() {
      if (!canInheritTransactionalOwnership ||
          _authAttemptSuperseded(attemptRevision)) {
        return;
      }
      if (_lastTransactionalSessionRevision == inheritedTransactionalRevision) {
        _lastTransactionalSessionRevision = null;
      }
    }

    bool promoteInheritedTransactionalOwnershipIfSessionStillIntact() {
      if (!canInheritTransactionalOwnership ||
          _authAttemptSuperseded(attemptRevision) ||
          _lastTransactionalSessionRevision != inheritedTransactionalRevision) {
        return false;
      }
      final current = _current;
      if (current.token != inheritedTransactionalToken ||
          !current.hasValidToken ||
          current.user == null) {
        return false;
      }
      _lastTransactionalSessionRevision = attemptRevision;
      return true;
    }

    try {
      final storage = ref.read(optimizedStorageServiceProvider);

      // A logout begins by durably fencing restoration before any remote or
      // local cleanup. If the prior process died mid-sign-out, never restore a
      // surviving bearer or saved credential. Retry the token/config scrub and
      // remain explicitly signed out if secure storage is still unavailable.
      final logoutFence = ref.read(incompleteLogoutFenceProvider.notifier);
      if (logoutFence.desiredSuppressed ||
          ref.read(incompleteLogoutFenceProvider) ||
          PreferencesStore.getBool(PreferenceKeys.incompleteLogoutFence) ==
              true) {
        clearInheritedTransactionalOwnership();
        _updateApiServiceToken(null);
        _setIncompleteLogoutFenceInMemory(true);
        try {
          await storage.clearAuthData();
        } catch (error) {
          if (_authAttemptSuperseded(attemptRevision)) return;
          _logAuthenticationFailure('incomplete-logout-recovery-failed', error);
          _set(
            const AuthState(
              status: AuthStatus.unauthenticated,
              isLoading: false,
              error: 'Sign out did not finish. Please try again.',
            ),
          );
          return;
        }
        if (_authAttemptSuperseded(attemptRevision)) return;
        final webViewDataCleared =
            await WebViewCookieHelper.ensurePendingLogoutDataCleared();
        if (_authAttemptSuperseded(attemptRevision)) return;
        if (!webViewDataCleared) {
          _set(
            const AuthState(
              status: AuthStatus.unauthenticated,
              isLoading: false,
              error: 'Sign out did not finish. Please try again.',
            ),
          );
          return;
        }

        const safeState = AuthState(
          status: AuthStatus.unauthenticated,
          isLoading: false,
        );
        clearInheritedTransactionalOwnership();
        _set(safeState);
        _updateApiServiceToken(null);
        _clearIncompleteLogoutFenceAfterTokenlessCleanup();
        ref.invalidate(serverConfigsProvider);
        ref.invalidate(activeServerProvider);
        ref.invalidate(apiServiceProvider);
        return;
      }

      // A confirmed missing token is the normal signed-out state and should
      // not pay retry delays. The strict storage read retries only actual
      // transient Keychain failures and propagates an exhausted failure.
      final token = await storage.getAuthTokenStrict();
      if (_authAttemptSuperseded(attemptRevision)) return;
      final inheritsTransactionalOwnership =
          canInheritTransactionalOwnership &&
          token == inheritedTransactionalToken &&
          _lastTransactionalSessionRevision == inheritedTransactionalRevision;
      if (!inheritsTransactionalOwnership) {
        clearInheritedTransactionalOwnership();
      }

      if (token != null && token.isNotEmpty) {
        DebugLogger.auth('Found stored token during initialization');

        // Check if stored token is an API key - force logout if so
        if (TokenValidator.isApiKey(token)) {
          DebugLogger.auth('Detected API key token, forcing logout');
          clearInheritedTransactionalOwnership();
          _publishTokenlessAuthRejection(
            status: AuthStatus.credentialError,
            error: 'apiKeyNoLongerSupported',
            isLoading: false,
          );
          final cleared = await storage.clearAuthDataIf(
            canClear: () => !_authAttemptSuperseded(attemptRevision),
          );
          if (!cleared || _authAttemptSuperseded(attemptRevision)) return;
          return;
        }

        // Fast path: trust token format to avoid blocking startup on network
        final formatOk = _isValidTokenFormat(token);
        if (formatOk) {
          _updateApiServiceToken(token);
          final activated = await _activateCachedTokenSession(
            storage: storage,
            token: token,
            reason: 'stored-token-fast-path',
            attemptRevision: attemptRevision,
            inheritedTransactionalRevision: inheritsTransactionalOwnership
                ? inheritedTransactionalRevision
                : null,
          );
          if (!activated || _authAttemptSuperseded(attemptRevision)) return;
          _validateStoredTokenInBackground(
            token: token,
            inheritedTransactionalRevision: inheritsTransactionalOwnership
                ? inheritedTransactionalRevision
                : null,
          );
          return;
        } else {
          // Token format invalid; clear and require login
          DebugLogger.auth('Token format invalid, deleting token');
          clearInheritedTransactionalOwnership();
          _publishTokenlessAuthRejection(
            status: AuthStatus.unauthenticated,
            isLoading: false,
          );
          await storage.deleteAuthTokenIfMatches(token);
          if (_authAttemptSuperseded(attemptRevision)) return;
        }
      } else {
        // A strict missing-token result rejects any inherited live session.
        // Clear the shared client and in-memory user before the slower saved
        // credential lookup/cleanup path can yield.
        clearInheritedTransactionalOwnership();
        _publishTokenlessAuthRejection(
          status: AuthStatus.loading,
          isLoading: true,
        );
        // Snapshot saved credentials once through the strict Keychain path.
        // A transient failure must not be cached as absence, and the exact
        // snapshot is passed into bootstrap so it is not re-read/raced.
        final savedCredentials = await storage.getSavedCredentialsStrict();
        if (_authAttemptSuperseded(attemptRevision)) return;
        if (savedCredentials != null) {
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
          unawaited(_bootstrapSilentLogin(savedCredentials));
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
      if (_authAttemptSuperseded(attemptRevision)) return;
      if (!promoteInheritedTransactionalOwnershipIfSessionStillIntact()) {
        clearInheritedTransactionalOwnership();
      }
      _logAuthenticationFailure('auth-init-failed', e);
      _update(
        (current) => current.copyWith(
          status: AuthStatus.error,
          error: 'Failed to initialize authentication',
          isLoading: false,
        ),
      );
    }
  }

  Future<bool> _activateCachedTokenSession({
    required OptimizedStorageService storage,
    required String token,
    required String reason,
    required int attemptRevision,
    int? inheritedTransactionalRevision,
  }) async {
    var cachedUser = await _readCachedUserWithAvatar(storage);
    if (_authAttemptSuperseded(attemptRevision)) return false;
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
      return true;
    }
    if (_authAttemptSuperseded(attemptRevision)) return false;
    if (inheritedTransactionalRevision != null &&
        _lastTransactionalSessionRevision == inheritedTransactionalRevision) {
      _lastTransactionalSessionRevision = attemptRevision;
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
    return true;
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
    required String token,
    int? inheritedTransactionalRevision,
  }) {
    final validationRevision = _authAttemptRevision;
    final validationSafetyEpoch = _sessionSafetyEpoch;

    bool stillOwnsValidation() {
      if (!ref.mounted ||
          _authAttemptRevision != validationRevision ||
          _sessionSafetyEpoch != validationSafetyEpoch) {
        return false;
      }
      final current = _current;
      return current.token == token && current.hasValidToken;
    }

    void clearUnpromotedInheritedOwnership() {
      if (inheritedTransactionalRevision != null &&
          _lastTransactionalSessionRevision == inheritedTransactionalRevision) {
        _lastTransactionalSessionRevision = null;
      }
    }

    unawaited(
      Future<void>(() async {
        // Cold starts behind slow tunnels (for example Cloudflare) can keep
        // the API service or the first /auths request failing transiently for
        // several seconds. Retry for roughly seven seconds in total before
        // resolving the no-cached-user bootstrap to re-login, mirroring the
        // pre-hardening 10s API-readiness wait.
        const retryDelays = <Duration>[
          Duration.zero,
          Duration(milliseconds: 200),
          Duration(milliseconds: 500),
          Duration(seconds: 1),
          Duration(seconds: 2),
          Duration(seconds: 3),
        ];
        Object? lastTransientError;

        for (var attempt = 0; attempt < retryDelays.length; attempt++) {
          final delay = retryDelays[attempt];
          if (delay > Duration.zero) await Future<void>.delayed(delay);
          if (!stillOwnsValidation()) return;

          final api = ref.read(apiServiceProvider);
          if (api == null || api.authToken != token) {
            lastTransientError = StateError(
              'API service unavailable for the stored auth session',
            );
            continue;
          }

          final authSnapshot = api.captureAuthSnapshot();
          try {
            final user = await api.getCurrentUser(
              suppressAuthFailureNotification: true,
              authSnapshot: authSnapshot,
            );
            if (!stillOwnsValidation()) {
              DebugLogger.auth(
                'Background auth validation ignored stale token result',
              );
              return;
            }

            if (inheritedTransactionalRevision != null &&
                _lastTransactionalSessionRevision ==
                    inheritedTransactionalRevision) {
              _lastTransactionalSessionRevision = validationRevision;
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

            return;
          } catch (error) {
            if (!stillOwnsValidation()) return;
            if (_isConfirmedAuthFailure(error)) {
              DebugLogger.auth('Stored token rejected during background check');
              clearUnpromotedInheritedOwnership();
              await onTokenInvalidated();
              return;
            }

            lastTransientError = error;
          }
        }

        if (!stillOwnsValidation()) return;
        if (lastTransientError != null) {
          _logAuthenticationFailure(
            'background-auth-validation-deferred',
            lastTransientError,
          );
        }
        // A transient (non-auth) failure must not strand the no-cached-user
        // bootstrap on the loading state forever; resolve it to re-login.
        if (_current.user == null) {
          clearUnpromotedInheritedOwnership();
        }
        _failBootstrapWithoutCachedUser(token);
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
    ServerConfig? expectedServerConfig,
    bool showLoading = true,
    bool publishErrors = true,
  }) {
    return _loginWithApiKeyInternal(
      apiKey,
      rememberCredentials: rememberCredentials,
      authType: authType,
      expectedServerConfig: expectedServerConfig,
      showLoading: showLoading,
      publishErrors: publishErrors,
    );
  }

  /// Selects a newly verified server while making both durable and in-memory
  /// auth tokenless before the new API provider can be observed.
  Future<void> selectUnauthenticatedServerConfig(ServerConfig config) async {
    final currentState = _current;
    final previousState =
        currentState.isLoading || currentState.status == AuthStatus.loading
        ? _lastSettledState
        : currentState;
    final capturedSessionSafetyEpoch = _sessionSafetyEpoch;
    final attemptRevision = _beginAuthAttempt();
    final storage = ref.read(optimizedStorageServiceProvider);
    try {
      await storage.selectUnauthenticatedServerConfig(
        config,
        canCommit: () => !_authAttemptSuperseded(attemptRevision),
        onRollbackUncertain: () {
          if (!ref.mounted) return;
          _poisonUncertainServerSession(failedAttemptRevision: attemptRevision);
        },
        publish: () {
          if (_authAttemptSuperseded(attemptRevision)) {
            throw StateError(
              'Server selection was superseded before publication.',
            );
          }
          const safeState = AuthState(
            status: AuthStatus.unauthenticated,
            isLoading: false,
          );
          _lastSettledState = safeState;
          _lastTransactionalSessionRevision = null;
          _set(safeState);
          if (_authAttemptSuperseded(attemptRevision)) {
            throw StateError(
              'Server selection was superseded during publication.',
            );
          }
          _updateApiServiceToken(null);
          ref.invalidate(serverConfigsProvider);
          if (_authAttemptSuperseded(attemptRevision)) {
            throw StateError(
              'Server selection was superseded during publication.',
            );
          }
          ref.invalidate(activeServerProvider);
          if (_authAttemptSuperseded(attemptRevision)) {
            throw StateError(
              'Server selection was superseded during publication.',
            );
          }
          ref.invalidate(apiServiceProvider);
          if (_authAttemptSuperseded(attemptRevision)) {
            throw StateError(
              'Server selection was superseded during publication.',
            );
          }
          _clearIncompleteLogoutFenceAfterTokenlessCleanup();
        },
      );
    } catch (error, stackTrace) {
      if (error is! ServerConfigSessionRollbackException) {
        _restoreRolledBackAuthPublication(
          attemptRevision: attemptRevision,
          capturedSessionSafetyEpoch: capturedSessionSafetyEpoch,
          previousState: previousState,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  bool _restoreRolledBackAuthPublication({
    required int attemptRevision,
    required int capturedSessionSafetyEpoch,
    required AuthState previousState,
  }) {
    if (!ref.mounted ||
        _authAttemptRevision != attemptRevision ||
        _sessionSafetyEpoch != capturedSessionSafetyEpoch) {
      return false;
    }
    try {
      _lastTransactionalSessionRevision = null;
      final previousToken = previousState.token;
      final safeState =
          previousToken != null &&
              _recentlyRevokedTokens.contains(previousToken)
          ? const AuthState(
              status: AuthStatus.unauthenticated,
              isLoading: false,
            )
          : previousState;
      _set(safeState);
      _updateApiServiceToken(safeState.hasValidToken ? safeState.token : null);
      ref.invalidate(serverConfigsProvider);
      ref.invalidate(activeServerProvider);
      ref.invalidate(apiServiceProvider);
      final fence = ref.read(incompleteLogoutFenceProvider.notifier);
      if (fence.desiredSuppressed || ref.read(incompleteLogoutFenceProvider)) {
        _setIncompleteLogoutFenceInMemory(true);
      }
      return true;
    } catch (error, stackTrace) {
      _logAuthenticationFailure(
        'auth-publication-rollback-restore-failed',
        error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  /// Accepts a bearer the server just handed to an interactive sign-in.
  ///
  /// Older Open WebUI servers (no jti claim, `JWT_EXPIRES_IN=-1`) issue a
  /// byte-identical token for every login of the same account. Without this
  /// hook, `_recentlyRevokedTokens` would keep rejecting logout -> login until
  /// the app restarts. A token freshly returned by the server during the
  /// current interactive attempt is a live session, so its stale revocation
  /// marker is dropped.
  ///
  /// The removal is skipped while any logout is still executing: that logout's
  /// remote revocation may still land, and the revocation list must keep
  /// rejecting a resurrection of the exact bearer it is signing out (including
  /// stale async capture tasks completing mid-logout).
  void _acceptFreshlyIssuedServerToken(String token, {required String source}) {
    if (_activeLogoutOperations > 0) return;
    if (_recentlyRevokedTokens.remove(token)) {
      DebugLogger.auth(
        'Server reissued a previously revoked bearer during $source sign-in; '
        'accepting it as a fresh session',
      );
    }
  }

  /// Commits a proxy/trusted-header session whose token and user were already
  /// validated with the cookie-scoped discovery client.
  ///
  /// This deliberately skips a second network validation after the provisional
  /// server config is written. The config, active-server id, and token are
  /// committed as one revision-owned attempt; a persistence failure restores
  /// the previous config/session, while a newer auth attempt always wins.
  Future<bool> commitPrevalidatedProxySession({
    required ServerConfig serverConfig,
    required String token,
    required User user,
  }) async {
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
    // An interactive proxy commit validated this token with the server during
    // the current connect attempt; a completed logout's marker no longer
    // applies. While a logout is still in flight, the marker keeps rejecting
    // resurrection of the bearer being revoked.
    _acceptFreshlyIssuedServerToken(tokenStr, source: 'proxy');
    if (_recentlyRevokedTokens.contains(tokenStr)) {
      throw Exception(
        'This sign-in session was already signed out. Please authenticate again.',
      );
    }

    final currentState = _current;
    final previousState =
        currentState.isLoading || currentState.status == AuthStatus.loading
        ? _lastSettledState
        : currentState;
    final capturedSessionSafetyEpoch = _sessionSafetyEpoch;
    final attemptRevision = _beginAuthAttempt();
    _update(
      (current) => current.copyWith(
        status: AuthStatus.loading,
        isLoading: true,
        clearError: true,
      ),
    );

    final storage = ref.read(optimizedStorageServiceProvider);
    ServerConfigCandidateSnapshot? candidateSnapshot;
    try {
      if (_authAttemptSuperseded(attemptRevision)) return false;
      final snapshot = await storage.stageServerConfigCandidate(serverConfig);
      candidateSnapshot = snapshot;
      if (_authAttemptSuperseded(attemptRevision)) {
        await _restorePrevalidatedProxyConfig(
          storage: storage,
          candidate: serverConfig,
          snapshot: snapshot,
        );
        return false;
      }

      final committed = await _commitSilentLoginResult(
        storage: storage,
        token: tokenStr,
        user: user,
        canCommit: () => !_authAttemptSuperseded(attemptRevision),
        commitPersistenceAndPublish: ({required publish}) {
          return storage.commitServerConfigCandidateSession(
            candidate: serverConfig,
            transactionId: snapshot.transactionId,
            token: tokenStr,
            canCommit: () => !_authAttemptSuperseded(attemptRevision),
            publish: () async {
              await publish();
              ref.invalidate(serverConfigsProvider);
              _lastTransactionalSessionRevision = attemptRevision;
            },
            onRollbackUncertain: () {
              if (!ref.mounted) return;
              _poisonUncertainServerSession(
                failedAttemptRevision: attemptRevision,
              );
            },
          );
        },
      );
      if (!committed) {
        await _restorePrevalidatedProxyConfig(
          storage: storage,
          candidate: serverConfig,
          snapshot: snapshot,
        );
        _restorePrevalidatedProxyAttemptState(
          attemptRevision: attemptRevision,
          capturedSessionSafetyEpoch: capturedSessionSafetyEpoch,
          previousState: previousState,
        );
      }
      return committed;
    } catch (error, stackTrace) {
      final rollbackUncertain = error is ServerConfigSessionRollbackException;
      if (rollbackUncertain &&
          capturedSessionSafetyEpoch == _sessionSafetyEpoch) {
        // Poison the prior session before any provider invalidation. A newer
        // attempt may already be loading while still carrying the old token;
        // revision checks alone cannot make that cross-origin state safe.
        _poisonUncertainServerSession(failedAttemptRevision: attemptRevision);
      }
      final snapshot = candidateSnapshot;
      if (snapshot != null) {
        await _restorePrevalidatedProxyConfig(
          storage: storage,
          candidate: serverConfig,
          snapshot: snapshot,
        );
      }
      if (!rollbackUncertain) {
        _restorePrevalidatedProxyAttemptState(
          attemptRevision: attemptRevision,
          capturedSessionSafetyEpoch: capturedSessionSafetyEpoch,
          previousState: previousState,
        );
      }
      final failureMessage = _safeLoginFailureMessage(error);
      _logAuthenticationFailure(
        'prevalidated-proxy-session-commit-failed',
        error,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(Exception(failureMessage), stackTrace);
    }
  }

  void _restorePrevalidatedProxyAttemptState({
    required int attemptRevision,
    required int capturedSessionSafetyEpoch,
    required AuthState previousState,
  }) {
    if (!ref.mounted || _authAttemptRevision != attemptRevision) return;
    if (capturedSessionSafetyEpoch == _sessionSafetyEpoch) {
      _set(previousState);
      _restoreApiServiceTokenToCurrent();
      return;
    }

    // Another overlapping proxy attempt encountered an incomplete durable
    // rollback. This attempt's captured previousState may contain the poisoned
    // token, so it must settle tokenless if it cannot publish a fresh session.
    _set(const AuthState(status: AuthStatus.unauthenticated, isLoading: false));
    _updateApiServiceToken(null);
    ref.invalidate(apiServiceProvider);
  }

  void _poisonUncertainServerSession({required int failedAttemptRevision}) {
    _sessionSafetyEpoch++;
    final current = _current;
    final newerTransactionalSession =
        _authAttemptRevision != failedAttemptRevision &&
        _currentRevisionOwnsCommittedSession();
    if (newerTransactionalSession) {
      // A newer transaction has already published a complete server/token
      // pair after the uncertain lock was released; it supersedes the poison.
      return;
    }

    _lastTransactionalSessionRevision = null;
    const safeState = AuthState(
      status: AuthStatus.unauthenticated,
      isLoading: false,
    );
    _lastSettledState = safeState;
    final newerAttemptOwnsLoading =
        _authAttemptRevision != failedAttemptRevision &&
        (current.isLoading || current.status == AuthStatus.loading);
    if (newerAttemptOwnsLoading) {
      // Preserve the newer attempt's loading ownership while stripping the
      // prior token/user. Its epoch fence prevents failure from restoring them.
      _set(const AuthState(status: AuthStatus.loading, isLoading: true));
    } else {
      _set(safeState);
    }
    _updateApiServiceToken(null);
    ref.invalidate(apiServiceProvider);
  }

  Future<void> _restorePrevalidatedProxyConfig({
    required OptimizedStorageService storage,
    required ServerConfig candidate,
    required ServerConfigCandidateSnapshot snapshot,
  }) async {
    try {
      await storage.discardServerConfigCandidate(
        candidate: candidate,
        transactionId: snapshot.transactionId,
      );
    } catch (error, stackTrace) {
      _logAuthenticationFailure(
        'prevalidated-proxy-config-restore-failed',
        error,
        stackTrace: stackTrace,
      );
    } finally {
      if (ref.mounted) ref.invalidate(serverConfigsProvider);
    }
  }

  Future<bool> _loginWithApiKeyInternal(
    String apiKey, {
    bool rememberCredentials = false,
    String authType = 'token',
    ServerConfig? expectedServerConfig,
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

      // Reject malformed local input before taking the strict Keychain/config
      // ownership snapshot.
      if (!_isValidTokenFormat(tokenStr)) {
        throw Exception('Invalid token format');
      }
      final storage = ref.read(optimizedStorageServiceProvider);
      final expectedOwnership = expectedServerConfig == null
          ? null
          : await storage.captureServerSessionOwnership(
              validatedConfig: expectedServerConfig,
              requireActive: true,
            );
      final ownership = await _captureLoginServerOwnership(
        storage,
        api,
        requireActive: true,
      );
      if (expectedServerConfig != null &&
          (expectedOwnership == null ||
              expectedOwnership.revision != ownership.revision ||
              expectedOwnership.serverConfig.id != ownership.serverConfig.id)) {
        throw Exception(
          'SSO server configuration changed before token validation. Please retry.',
        );
      }

      // Validate by attempting to fetch user info
      try {
        if (_authAttemptSuperseded(attemptRevision)) {
          _resolveAbortedAuthAttempt(attemptRevision);
          return false;
        }
        final user = await _validateIssuedToken(api, tokenStr);

        // A concurrent login / logout that started during validation owns the
        // session now; don't persist this token or publish over its state.
        if (_authAttemptSuperseded(attemptRevision)) {
          DebugLogger.auth(
            'JWT login superseded by a newer attempt; not committing',
          );
          _resolveAbortedAuthAttempt(attemptRevision);
          return false;
        }

        final committed = await _commitValidatedExistingServerSession(
          storage: storage,
          ownership: ownership,
          token: tokenStr,
          user: user,
          attemptRevision: attemptRevision,
          rememberedCredentials: rememberCredentials
              ? {
                  'serverId': ownership.serverConfig.id,
                  'username': 'jwt_user',
                  'password': tokenStr,
                  'authType': authType,
                }
              : null,
        );
        if (!committed) {
          _resolveAbortedAuthAttempt(attemptRevision);
          return false;
        }

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
      final failureMessage = _safeLoginFailureMessage(e);
      _logAuthenticationFailure('api-key-login-failed', e, stackTrace: stack);
      // Don't clear the API token or publish an error over a newer attempt;
      // restore the interceptor token to the newer attempt's state instead.
      if (_authAttemptSuperseded(attemptRevision)) {
        _resolveAbortedAuthAttempt(attemptRevision);
      } else if (e is! _AuthPublicationRolledBack) {
        _updateApiServiceToken(null);
        if (publishErrors) {
          _update(
            (current) => current.copyWith(
              status: AuthStatus.error,
              error: failureMessage,
              isLoading: false,
              clearToken: true,
            ),
          );
        }
      }
      Error.throwWithStackTrace(Exception(failureMessage), stack);
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
    try {
      // Ensure API service is available (active server/provider rebuild race)
      await _ensureApiServiceAvailable();
      final api = ref.read(apiServiceProvider);
      if (api == null) {
        throw Exception('No server connection available');
      }
      final storage = ref.read(optimizedStorageServiceProvider);
      final ownership = await _captureLoginServerOwnership(
        storage,
        api,
        requireActive: true,
      );

      if (_authAttemptSuperseded(attemptRevision)) {
        _resolveAbortedAuthAttempt(attemptRevision);
        return false;
      }

      // Perform login API call
      final response = await api.login(username, password);
      if (_authAttemptSuperseded(attemptRevision)) {
        _resolveAbortedAuthAttempt(attemptRevision);
        return false;
      }

      // Extract and validate token
      final token = response['token'] ?? response['access_token'];
      if (token == null || token.toString().trim().isEmpty) {
        throw Exception('No authentication token received');
      }

      final tokenStr = token.toString();
      if (!_isValidTokenFormat(tokenStr)) {
        throw Exception('Invalid authentication token format');
      }
      // This exact bearer was just returned by the server's signin endpoint
      // for this interactive attempt, so any completed logout's revocation
      // marker for it is stale.
      _acceptFreshlyIssuedServerToken(tokenStr, source: 'credentials');

      // Validate the issued token before publishing authenticated state. Some
      // servers can return a token that is then rejected by /api/v1/auths/.
      final user = await _validateIssuedToken(api, tokenStr);

      // A concurrent login / logout that started during validation owns the
      // session now; don't persist this token or publish over its state.
      if (_authAttemptSuperseded(attemptRevision)) {
        DebugLogger.auth('Login superseded by a newer attempt; not committing');
        _resolveAbortedAuthAttempt(attemptRevision);
        return false;
      }

      final committed = await _commitValidatedExistingServerSession(
        storage: storage,
        ownership: ownership,
        token: tokenStr,
        user: user,
        attemptRevision: attemptRevision,
        rememberedCredentials: rememberCredentials
            ? {
                'serverId': ownership.serverConfig.id,
                'username': username,
                'password': password,
                'authType': 'credentials',
              }
            : null,
      );
      if (!committed) {
        _resolveAbortedAuthAttempt(attemptRevision);
        return false;
      }

      DebugLogger.auth('Login successful');
      return true;
    } catch (e, stack) {
      final failureMessage = _safeLoginFailureMessage(
        e,
        credentialRequest: true,
      );
      _logAuthenticationFailure('login-failed', e, stackTrace: stack);
      // Don't clear the API token or publish an error over a newer attempt;
      // restore the interceptor token to the newer attempt's state instead.
      if (_authAttemptSuperseded(attemptRevision)) {
        _resolveAbortedAuthAttempt(attemptRevision);
      } else if (e is! _AuthPublicationRolledBack) {
        _updateApiServiceToken(null);
        if (publishErrors) {
          _update(
            (current) => current.copyWith(
              status: AuthStatus.error,
              error: failureMessage,
              isLoading: false,
              clearToken: true,
            ),
          );
        }
      }
      Error.throwWithStackTrace(Exception(failureMessage), stack);
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
    try {
      // Ensure API service is available
      await _ensureApiServiceAvailable();
      final api = ref.read(apiServiceProvider);
      if (api == null) {
        throw Exception('No server connection available');
      }
      final storage = ref.read(optimizedStorageServiceProvider);
      final ownership = await _captureLoginServerOwnership(
        storage,
        api,
        requireActive: true,
      );

      if (_authAttemptSuperseded(attemptRevision)) {
        _resolveAbortedAuthAttempt(attemptRevision);
        return false;
      }

      // Perform LDAP login API call
      final response = await api.ldapLogin(username, password);
      if (_authAttemptSuperseded(attemptRevision)) {
        _resolveAbortedAuthAttempt(attemptRevision);
        return false;
      }

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
      // This exact bearer was just returned by the server's signin endpoint
      // for this interactive attempt, so any completed logout's revocation
      // marker for it is stale.
      _acceptFreshlyIssuedServerToken(tokenStr, source: 'credentials');

      // Validate the issued token before publishing authenticated state. Some
      // servers can return a token that is then rejected by /api/v1/auths/.
      final user = await _validateIssuedToken(api, tokenStr);

      // A concurrent login / logout that started during validation owns the
      // session now; don't persist this token or publish over its state.
      if (_authAttemptSuperseded(attemptRevision)) {
        DebugLogger.auth(
          'LDAP login superseded by a newer attempt; not committing',
        );
        _resolveAbortedAuthAttempt(attemptRevision);
        return false;
      }

      final committed = await _commitValidatedExistingServerSession(
        storage: storage,
        ownership: ownership,
        token: tokenStr,
        user: user,
        attemptRevision: attemptRevision,
        rememberedCredentials: rememberCredentials
            ? {
                'serverId': ownership.serverConfig.id,
                'username': 'ldap:$username',
                'password': tokenStr,
                'authType': 'ldap',
              }
            : null,
      );
      if (!committed) {
        _resolveAbortedAuthAttempt(attemptRevision);
        return false;
      }

      DebugLogger.auth('LDAP login successful');
      return true;
    } catch (e, stack) {
      final failureMessage = _safeLoginFailureMessage(
        e,
        credentialRequest: true,
      );
      _logAuthenticationFailure('ldap-login-failed', e, stackTrace: stack);
      // Don't clear the API token or publish an error over a newer attempt;
      // restore the interceptor token to the newer attempt's state instead.
      if (_authAttemptSuperseded(attemptRevision)) {
        _resolveAbortedAuthAttempt(attemptRevision);
      } else if (e is! _AuthPublicationRolledBack) {
        _update(
          (current) => current.copyWith(
            status: AuthStatus.error,
            error: failureMessage,
            isLoading: false,
            clearToken: true,
          ),
        );
        _updateApiServiceToken(null);
      }
      Error.throwWithStackTrace(Exception(failureMessage), stack);
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
    try {
      return await api.getCurrentUser(
        suppressAuthFailureNotification: true,
        candidateAuthToken: token,
      );
    } catch (error, stackTrace) {
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

  void _logAuthenticationFailure(
    String event,
    Object? error, {
    StackTrace? stackTrace,
  }) {
    DebugLogger.error(
      event,
      stackTrace: stackTrace,
      scope: 'auth/state',
      data: {
        'errorType': error?.runtimeType.toString() ?? 'unknown',
        if (error is DioException) ...{
          'dioType': error.type.name,
          'statusCode': error.response?.statusCode,
        },
      },
    );
  }

  String _safeLoginFailureMessage(
    Object error, {
    bool credentialRequest = false,
  }) {
    final statusCode = error is DioException
        ? error.response?.statusCode
        : null;

    // Only recognize the one server response that has a dedicated, safe UI
    // message. Never surface arbitrary response text here: credential errors
    // can reflect request data, headers, or upstream diagnostics.
    final responseData = error is DioException ? error.response?.data : null;
    final responseDetail = responseData is Map
        ? responseData['detail']
        : responseData;
    final text = error.toString().toLowerCase();
    final ldapDisabled =
        responseDetail is String &&
            responseDetail.trim().toLowerCase() ==
                'ldap authentication is not enabled' ||
        text.contains('ldap authentication is not enabled');
    if (ldapDisabled) {
      return 'LDAP authentication is not enabled';
    }

    if (statusCode == 401 ||
        statusCode == 403 ||
        (credentialRequest && statusCode == 400)) {
      return '401 Unauthorized: sign-in rejected by server';
    }

    if (text.contains('apikeynolongersupported')) {
      return 'apiKeyNoLongerSupported';
    }
    if (text.contains('apikeynotsupported')) {
      return 'apiKeyNotSupported';
    }
    if (text.contains('authentication failed')) {
      return '401 Unauthorized: sign-in rejected by server';
    }
    if (text.contains('token cannot be empty')) {
      return 'Token cannot be empty';
    }
    if (text.contains('invalid token format')) {
      return 'Invalid token format';
    }
    if (text.contains('no server connection available')) {
      return 'No server connection available';
    }
    if (text.contains('redirect')) {
      return 'Server redirect detected. Please check your server URL configuration.';
    }

    final timedOut =
        error is DioException &&
        (error.type == DioExceptionType.connectionTimeout ||
            error.type == DioExceptionType.sendTimeout ||
            error.type == DioExceptionType.receiveTimeout);
    if (timedOut || text.contains('timeout')) {
      return 'Sign-in request timed out';
    }

    final connectionFailed =
        error is DioException &&
        (error.type == DioExceptionType.connectionError ||
            error.type == DioExceptionType.unknown);
    if (connectionFailed ||
        text.contains('socketexception') ||
        text.contains('connection')) {
      return 'Unable to connect to server';
    }
    return 'Sign-in failed. Please try again.';
  }

  String _loginValidationMessage(Object error) {
    if (error is DioException) {
      final statusCode = error.response?.statusCode;
      if (statusCode == 401 || statusCode == 403) {
        return '$statusCode Unauthorized: sign-in token rejected by server';
      }
    }

    final text = error.toString();
    if (text.contains('401') || text.contains('Unauthorized')) {
      return '401 Unauthorized: sign-in token rejected by server';
    }
    return 'Unable to validate sign-in session';
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
      return !_authAttemptSuperseded(expectedRevision);
    }

    bool claimCommit() {
      if (!canCommit()) return false;
      claimRevision = _beginAuthAttempt();
      return true;
    }

    final committed = await _performSilentLoginInternal(
      showLoading: true,
      publishNetworkErrors: true,
      canCommit: canCommit,
      claimCommit: claimCommit,
    );
    if (!committed) {
      _resolveAbortedAuthAttempt(claimRevision ?? startRevision);
    }
    return committed;
  }

  /// Bootstrap path (no stored token but saved credentials): runs the
  /// background silent login, then GUARANTEES the bootstrap `loading` state
  /// resolves. On success the login commits `authenticated`; if it commits
  /// nothing (auth/network/unknown failure all `return false` without touching
  /// state in background mode), fall back to `unauthenticated` so the app
  /// reaches the sign-in page instead of hanging on the splash.
  Future<void> _bootstrapSilentLogin(
    Map<String, String> savedCredentials,
  ) async {
    // Capture the attempt revision: every foreground login / logout /
    // token-invalidation bumps it via `_beginAuthAttempt`. If one starts while
    // this background login runs, it is also briefly `loading` with no token, so
    // the fallback below must NOT fire — otherwise this stale task would clobber
    // the newer attempt with `unauthenticated` and bounce the user to sign-in.
    final bootstrapRevision = _authAttemptRevision;
    final committed = await _performSilentLoginInBackground(
      savedCredentials: Map<String, String>.unmodifiable(savedCredentials),
    );
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

  Future<bool> _performSilentLoginInBackground({
    Map<String, String>? savedCredentials,
  }) async {
    final startRevision = _authAttemptRevision;
    final startSafetyEpoch = _sessionSafetyEpoch;
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
      final ownsFence = claimRevision == null
          ? _sessionSafetyEpoch == startSafetyEpoch &&
                _authAttemptRevision == expectedRevision
          : !_authAttemptSuperseded(expectedRevision);
      return ref.mounted &&
          ownsFence &&
          commitableStatus &&
          !current.hasValidToken;
    }

    bool claimCommit() {
      if (!canCommit()) return false;
      claimRevision = _beginAuthAttempt();
      return true;
    }

    try {
      final committed = await _performSilentLoginInternal(
        showLoading: false,
        publishNetworkErrors: false,
        canCommit: canCommit,
        claimCommit: claimCommit,
        savedCredentialsSnapshot: savedCredentials,
      );
      if (!committed && claimRevision != null) {
        _resolveAbortedAuthAttempt(claimRevision!);
      }
      return committed;
    } catch (error) {
      _logAuthenticationFailure('background-silent-login-failed', error);
      return false;
    }
  }

  Future<bool> _performSilentLoginInternal({
    required bool showLoading,
    required bool publishNetworkErrors,
    bool Function()? canCommit,
    bool Function()? claimCommit,
    Map<String, String>? savedCredentialsSnapshot,
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
    Map<String, String>? attemptedCredentials = savedCredentialsSnapshot;

    try {
      // Keep the Keychain read inside the same failure boundary as the network
      // attempt. Secure-storage failures are now intentionally propagated; a
      // foreground silent login must publish a terminal error rather than throw
      // past this handler and leave the auth state stuck in `loading`.
      attemptedCredentials ??= await ref
          .read(optimizedStorageServiceProvider)
          .getSavedCredentialsStrict();
      return await _performSilentLoginAttempt(
        savedCredentials: attemptedCredentials,
        canCommit: canCommit,
        claimCommit: claimCommit,
      );
    } catch (e) {
      _logAuthenticationFailure('silent-login-failed', e);

      if (e is _AuthPublicationRolledBack) return false;

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

    // Resolve against locked storage, not a potentially stale provider cache.
    // This is both the exact config used for validation and proof that a
    // missing id is safe to clean up below.
    final ownership = await storage.captureSavedServerSessionOwnership(
      serverId,
    );

    if (ownership == null) {
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
      final clearedCreds = await storage
          .deleteSavedCredentialsIfMatchesAndServerMissing(savedCredentials);
      if (clearedCreds) {
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

    if (!_canCommitAuth(canCommit)) {
      DebugLogger.auth('Silent login skipped stale ownership snapshot');
      return false;
    }

    // Attempt login based on auth type
    final authType = savedCredentials['authType'] ?? 'credentials';
    final tempApi = ref.read(savedCredentialAuthApiFactoryProvider)(
      serverConfig: ownership.serverConfig,
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

    final ({String token, User user}) result;
    try {
      result = usesSavedJwt
          ? await _authenticateSavedJwt(tempApi, password)
          : await _authenticateSavedCredentials(tempApi, username, password);
    } finally {
      tempApi.dispose();
    }

    return _commitSilentLoginResult(
      storage: storage,
      ownership: ownership,
      token: result.token,
      user: result.user,
      expectedSavedCredentials: savedCredentials,
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
    required String token,
    required User user,
    ServerSessionOwnershipSnapshot? ownership,
    Map<String, String>? expectedSavedCredentials,
    bool Function()? canCommit,
    bool Function()? claimCommit,
    Future<bool> Function({required FutureOr<void> Function() publish})?
    commitPersistenceAndPublish,
  }) async {
    if (!_claimAuthCommit(
      operation: 'Silent login',
      claimCommit: claimCommit,
    )) {
      return false;
    }

    final commitRevision = _authAttemptRevision;
    if (!_canCommitAuth(canCommit)) {
      DebugLogger.auth('Silent login skipped stale persistence commit');
      return false;
    }

    final currentState = _current;
    final previousState =
        currentState.isLoading || currentState.status == AuthStatus.loading
        ? _lastSettledState
        : currentState;
    final publicationSafetyEpoch = _sessionSafetyEpoch;
    var publicationAttempted = false;

    Future<void> publishSession() {
      publicationAttempted = true;
      return _publishCommittedAuthenticatedSession(
        attemptRevision: commitRevision,
        candidateToken: token,
        publish: () {
          _setIncompleteLogoutFenceInMemory(false);
          _updateApiServiceToken(token);
          ref.invalidate(activeServerProvider);
          ref.invalidate(apiServiceProvider);
          if (_authAttemptSuperseded(commitRevision)) {
            throw StateError(
              'Authentication attempt was superseded during publication.',
            );
          }
          _lastTransactionalSessionRevision = commitRevision;
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
        },
      );
    }

    try {
      if (commitPersistenceAndPublish != null) {
        final committed = await commitPersistenceAndPublish(
          publish: publishSession,
        );
        if (committed) DebugLogger.auth('Silent login successful');
        return committed;
      }

      if (ownership == null) {
        throw StateError('Existing-server session commit requires ownership');
      }

      final committed = await storage.commitExistingServerSession(
        ownership: ownership,
        token: token,
        expectedSavedCredentials: expectedSavedCredentials,
        canCommit: () => _canCommitAuth(canCommit),
        publish: publishSession,
        onRollbackUncertain: () {
          if (!ref.mounted) return;
          _poisonUncertainServerSession(failedAttemptRevision: commitRevision);
        },
      );
      if (committed) DebugLogger.auth('Silent login successful');
      return committed;
    } catch (error, stackTrace) {
      if (publicationAttempted &&
          _restoreRolledBackAuthPublication(
            attemptRevision: commitRevision,
            capturedSessionSafetyEpoch: publicationSafetyEpoch,
            previousState: previousState,
          ) &&
          error is! ServerConfigSessionRollbackException) {
        Error.throwWithStackTrace(
          _AuthPublicationRolledBack(error),
          stackTrace,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<bool> _handleSilentLoginFailure(
    Object error, {
    required bool publishNetworkErrors,
    bool Function()? canCommit,
    Map<String, String>? attemptedCredentials,
  }) async {
    var errorMessage = _safeLoginFailureMessage(error, credentialRequest: true);
    final errorText = error.toString().toLowerCase();
    final statusCode = error is DioException
        ? error.response?.statusCode
        : null;

    // Don't clear credentials on connection errors - only clear on actual auth failures
    // Check if this is a genuine auth failure vs network issue
    final isNetworkError =
        error is SocketException ||
        error is TimeoutException ||
        (error is DioException &&
            (error.type == DioExceptionType.connectionTimeout ||
                error.type == DioExceptionType.sendTimeout ||
                error.type == DioExceptionType.receiveTimeout ||
                error.type == DioExceptionType.connectionError ||
                error.type == DioExceptionType.unknown));

    // Local saved-token validation failures (raised by `_authenticateSavedJwt`
    // before any server request) mean the stored credential can never succeed,
    // so treat them as terminal credential failures too — otherwise they fall
    // to the unknown-error path, keep the bad credential, and repeat the
    // impossible silent login on every cold start.
    final isInvalidSavedToken =
        errorText.contains('apikeynotsupported') ||
        errorText.contains('invalid token format') ||
        errorText.contains('token cannot be empty');

    if ((!isNetworkError &&
            (statusCode == 400 ||
                statusCode == 401 ||
                statusCode == 403 ||
                errorText.contains('401 unauthorized') ||
                errorText.contains('authentication failed'))) ||
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
      } catch (deleteError) {
        _logAuthenticationFailure(
          'silent-login-credential-clear-failed',
          deleteError,
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
    _retryResetGeneration++;
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
    final silentLoginWasInProgress = _silentLoginFuture != null;
    // Claim ownership before publishing tokenExpired: synchronous listeners
    // may start a replacement login, and that newer attempt must supersede
    // this cleanup rather than being superseded by a later revision bump.
    final claimedAttemptRevision = silentLoginWasInProgress
        ? null
        : _beginAuthAttempt();

    if (rejectedToken != null && rejectedToken.isNotEmpty) {
      _publishTokenlessAuthRejection(
        status: AuthStatus.tokenExpired,
        error: 'Session expired - please sign in again',
        isLoading: false,
      );
    }
    if (!ref.mounted) return;

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
        } catch (error) {
          _logAuthenticationFailure('token-delete-failed', error);
        }
      }
      DebugLogger.auth(
        'Token invalidated while a silent re-login is in progress; cleared '
        'the rejected token and coalesced onto it',
      );
      return;
    }
    final attemptRevision = claimedAttemptRevision!;
    var maxRetriesReached = false;
    // A new retry-window mutation owns its delayed reset. Timers left behind by
    // an older burst must never clear failures accumulated after a manual retry
    // or a later token invalidation.
    final retryResetGeneration = ++_retryResetGeneration;
    // Prevent infinite retry loops
    final now = DateTime.now();
    if (_lastRetryTime != null &&
        now.difference(_lastRetryTime!).inSeconds < 5) {
      _retryCount++;
      if (_retryCount >= _maxRetries) {
        DebugLogger.auth(
          'Max retry attempts reached - stopping silent re-login',
        );
        maxRetriesReached = true;
        // Reset after 30 seconds to allow manual retry
        unawaited(
          resetAuthRetryStateWhenCurrent(
            delay: Future<void>.delayed(const Duration(seconds: 30)),
            scheduledGeneration: retryResetGeneration,
            currentGeneration: () => _retryResetGeneration,
            reset: () {
              _retryCount = 0;
              _lastRetryTime = null;
            },
          ),
        );
      }
    } else {
      // Reset counter if enough time has passed
      _retryCount = 0;
    }
    _lastRetryTime = now;

    // Avoid spamming logs if multiple requests invalidate at once
    final reloginInProgress = _silentLoginFuture != null;
    if (!reloginInProgress && !maxRetriesReached) {
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
    } catch (e) {
      _logAuthenticationFailure('token-delete-failed', e);
    }
    if (_authAttemptSuperseded(attemptRevision)) {
      DebugLogger.auth('Token invalidation ignored after a newer auth attempt');
      return;
    }

    try {
      await storage.clearUserScopedAuthData();
      DebugLogger.auth('Cleared invalidated token from secure storage');
    } catch (e) {
      _logAuthenticationFailure('user-auth-cache-clear-failed', e);
    }
    if (_authAttemptSuperseded(attemptRevision)) {
      DebugLogger.auth('Token invalidation cleanup lost auth ownership');
      return;
    }
    _updateApiServiceToken(null);
    _lastTransactionalSessionRevision = null;

    _update(
      (current) => current.copyWith(
        status: maxRetriesReached ? AuthStatus.error : AuthStatus.tokenExpired,
        error: maxRetriesReached
            ? 'Connection issue - please retry manually'
            : 'Session expired - please sign in again',
        clearToken: true,
        clearUser: true,
        isLoading: false,
      ),
    );

    if (maxRetriesReached) return;

    // Attempt silent re-login if credentials are available
    final hasCredentials = await storage.getSavedCredentials() != null;
    if (_authAttemptSuperseded(attemptRevision)) {
      DebugLogger.auth(
        'Token invalidation re-login skipped after a newer auth attempt',
      );
      return;
    }
    if (hasCredentials && !reloginInProgress) {
      DebugLogger.auth('Attempting silent re-login after token invalidation');
      final success = await silentLogin();
      if (success) {
        // Reset retry counter on success
        _retryResetGeneration++;
        _retryCount = 0;
        _lastRetryTime = null;
      }
    }
  }

  /// Logout user and clear auth data while preserving connection settings.
  /// The URL, self-signed-certificate policy, user-configured custom headers,
  /// and the mTLS client identity remain available so a proxy-gated sign-in
  /// page stays reachable. Captured proxy Cookie headers and the legacy
  /// apiKey bearer are revoked with the session.
  void _publishTokenlessLogout({
    required bool durableAuthDataCleared,
    String? error,
  }) {
    final safeState = AuthState(
      status: AuthStatus.unauthenticated,
      isLoading: false,
      error: error,
    );
    _lastSettledState = safeState;
    _lastTransactionalSessionRevision = null;
    _cacheManager.clearAuthCache();
    _set(safeState);
    _updateApiServiceToken(null);
    if (durableAuthDataCleared) {
      _clearIncompleteLogoutFenceAfterTokenlessCleanup();
    } else {
      _setIncompleteLogoutFenceInMemory(true);
    }
    ref.invalidate(serverConfigsProvider);
    ref.invalidate(activeServerProvider);
    ref.invalidate(apiServiceProvider);
  }

  Future<void> logout() async {
    // While this counter is non-zero, `_acceptFreshlyIssuedServerToken` must
    // not drop revocation markers: the remote sign-out may still revoke the
    // captured bearer, and same-token resurrection has to stay rejected until
    // this logout's cleanup and ownership arbitration have fully settled.
    _activeLogoutOperations++;
    try {
      await _logoutInternal();
    } finally {
      _activeLogoutOperations--;
    }
  }

  Future<void> _logoutInternal() async {
    // Capture the exact client/session synchronously. Persisting the restart
    // fence can yield long enough for another login to rotate the shared API
    // token; the eventual remote sign-out must never adopt that newer token.
    final logoutApi = ref.read(apiServiceProvider);
    final logoutAuthSnapshot = logoutApi?.captureAuthSnapshot();
    final logoutToken = logoutApi?.authToken;
    final attemptRevision = _beginAuthAttempt();
    _update(
      (current) =>
          current.copyWith(status: AuthStatus.loading, isLoading: true),
    );
    // Queue the shared WKWebView/Android WebView purge before any newer auth
    // route can construct a WebView. Entry points serialize behind this future,
    // and tokenless route publication below waits for it to complete.
    final webViewDataClear = WebViewCookieHelper.clearAllWebViewData();

    var durableAuthDataCleared = false;
    var suppressionMarkerPersisted = false;
    var remoteLogoutAttempted = false;
    Object? terminalFailure;

    Future<bool> clearAuthDataForCurrentOwnership() async {
      final storage = ref.read(optimizedStorageServiceProvider);
      while (true) {
        final revokedToken = remoteLogoutAttempted ? logoutToken : null;
        await _waitForNewerAuthAttemptToSettle(
          attemptRevision,
          remotelyRevokedToken: revokedToken,
        );
        if (_newerCommittedSessionOwnsAuthData(
          attemptRevision,
          remotelyRevokedToken: revokedToken,
        )) {
          return false;
        }

        // A newer transaction may have cleared the original marker before the
        // remote POST returned. Re-arm it from the current ownership decision
        // so failed Keychain cleanup remains fail-closed across restart.
        try {
          suppressionMarkerPersisted = await ref
              .read(incompleteLogoutFenceProvider.notifier)
              .persist(true);
        } catch (error) {
          suppressionMarkerPersisted = false;
          _logAuthenticationFailure('logout-fence-rearm-failed', error);
        }
        // The checked fence write yields. A different-token transaction may
        // have committed while it was queued, and owns both durable auth data
        // and the live API client. Re-evaluate before mutating either one.
        if (_newerCommittedSessionOwnsAuthData(
          attemptRevision,
          remotelyRevokedToken: revokedToken,
        )) {
          return false;
        }
        _updateApiServiceToken(null);
        _setIncompleteLogoutFenceInMemory(true);

        final revokedCommitRevisionBeforeClear =
            _newerCommittedSessionReusesRevokedToken(
              attemptRevision,
              revokedToken,
            )
            ? _authAttemptRevision
            : null;
        final cleared = await storage.clearAuthDataIf(
          canClear: () => !_newerCommittedSessionOwnsAuthData(
            attemptRevision,
            remotelyRevokedToken: revokedToken,
          ),
        );
        if (!cleared) return false;

        await _waitForNewerAuthAttemptToSettle(
          attemptRevision,
          remotelyRevokedToken: revokedToken,
        );
        if (!_newerCommittedSessionReusesRevokedToken(
          attemptRevision,
          revokedToken,
        )) {
          return true;
        }
        final resurrectedRevision = _authAttemptRevision;
        _sanitizeRevokedCommittedSession(revokedToken);
        if (revokedCommitRevisionBeforeClear == resurrectedRevision) {
          // This exact transaction was already present when the locked clear
          // ran, so its durable token was covered by that clear.
          return true;
        }
        // A same-token transaction queued behind the clear and resurrected the
        // jti that the server just revoked. Re-arm and clear that transaction
        // as another locked iteration before publishing any local result.
        DebugLogger.auth('Logout clearing a resurrected revoked session');
      }
    }

    try {
      // Fence restoration durably before the remote request. The live client
      // keeps its credentials long enough to call the server logout endpoint,
      // but a process death from this point onward restarts signed out.
      try {
        suppressionMarkerPersisted = await ref
            .read(incompleteLogoutFenceProvider.notifier)
            .persist(true, publishState: false);
        if (!suppressionMarkerPersisted) {
          throw StateError('Incomplete logout fence could not be persisted.');
        }
      } catch (error, stackTrace) {
        _logAuthenticationFailure('logout-fence-persist-failed', error);
        Error.throwWithStackTrace(error, stackTrace);
      }

      // Call server logout if possible
      if (logoutApi != null) {
        try {
          // Once dispatched, the server may revoke the session even if the
          // client times out, is disposed, or never receives the response.
          // Treat this exact bearer as possibly revoked from this point on.
          remoteLogoutAttempted = true;
          if (logoutToken != null && logoutToken.isNotEmpty) {
            _recentlyRevokedTokens.remove(logoutToken);
            _recentlyRevokedTokens.add(logoutToken);
            if (_recentlyRevokedTokens.length > 8) {
              _recentlyRevokedTokens.removeAt(0);
            }
          }
          await logoutApi.logout(authSnapshot: logoutAuthSnapshot);
        } catch (e) {
          _logAuthenticationFailure('server-logout-failed', e);
        }
      }

      durableAuthDataCleared = await clearAuthDataForCurrentOwnership();
      if (!durableAuthDataCleared) {
        DebugLogger.auth('Logout cleanup yielded to a committed newer session');
        return;
      }

      // Keep active server ID so router redirects to sign-in page, not server
      // connection page. Users can navigate to server settings if they need to
      // change server configuration.

      DebugLogger.auth(
        'Logout complete - auth data cleared, non-auth server settings preserved',
      );
    } catch (e) {
      _logAuthenticationFailure('logout-failed', e);
      // Even if logout fails, clear local state where possible
      try {
        durableAuthDataCleared = await clearAuthDataForCurrentOwnership();
        if (!durableAuthDataCleared) {
          DebugLogger.auth('Logout retry yielded to a committed newer session');
          return;
        }
      } catch (clearError) {
        _logAuthenticationFailure('logout-clear-failed', clearError);
        terminalFailure = clearError;
      }
    } finally {
      var webViewDataCleared = !isWebViewSupported;
      try {
        final clearResult = await webViewDataClear;
        webViewDataCleared = !isWebViewSupported || clearResult;
        if (!webViewDataCleared) {
          terminalFailure ??= StateError(
            'The shared WebView session could not be cleared.',
          );
        }
      } catch (e) {
        terminalFailure ??= e;
        DebugLogger.warning(
          'webview-data-clear-failed',
          scope: 'auth/state',
          data: {'errorType': e.runtimeType.toString()},
        );
      }

      // A changed safety epoch alone does not supersede this logout. Logout is
      // the operation that can resolve an uncertain older session by clearing
      // auth data under the storage lock and retaining the restart fence when
      // that cleanup fails. Only a genuinely newer revision owns final state.
      final superseded =
          !ref.mounted || _authAttemptRevision != attemptRevision;
      final newerCommitted = _newerCommittedSessionOwnsAuthData(
        attemptRevision,
        remotelyRevokedToken: remoteLogoutAttempted ? logoutToken : null,
      );
      if (newerCommitted) {
        DebugLogger.auth('Logout finalization yielded to a newer auth attempt');
      } else if (superseded) {
        // A newer attempt failed after the old logout was durably fenced. Do
        // not overwrite its error state, but finish revoking the old live
        // transport identity and independent WebView cookie store.
        _lastTransactionalSessionRevision = null;
        _cacheManager.clearAuthCache();
        _update((current) {
          if (current.isAuthenticated) {
            return current.copyWith(
              status: AuthStatus.tokenExpired,
              error: 'Session expired - please sign in again',
              clearToken: true,
              clearUser: true,
              isLoading: false,
            );
          }
          return current.copyWith(
            status:
                current.status == AuthStatus.loading ||
                    current.status == AuthStatus.initial
                ? AuthStatus.unauthenticated
                : current.status,
            clearToken: true,
            clearUser: true,
            isLoading: false,
          );
        });
        _updateApiServiceToken(null);
        _setIncompleteLogoutFenceInMemory(true);
        ref.invalidate(serverConfigsProvider);
        ref.invalidate(activeServerProvider);
        ref.invalidate(apiServiceProvider);
      } else {
        final completeLocalCleanup =
            durableAuthDataCleared && webViewDataCleared;
        final fullyFenced = completeLocalCleanup || suppressionMarkerPersisted;
        _publishTokenlessLogout(
          durableAuthDataCleared: completeLocalCleanup,
          error: terminalFailure == null && fullyFenced
              ? null
              : 'Sign out did not finish. Please try again.',
        );
      }
    }
  }

  bool _newerCommittedSessionOwnsAuthData(
    int logoutRevision, {
    String? remotelyRevokedToken,
  }) {
    final currentRevision = _authAttemptRevision;
    final current = _current;
    return currentRevision != logoutRevision &&
        _currentRevisionOwnsCommittedSession() &&
        (remotelyRevokedToken == null || current.token != remotelyRevokedToken);
  }

  bool _newerCommittedSessionReusesRevokedToken(
    int logoutRevision,
    String? remotelyRevokedToken,
  ) {
    if (remotelyRevokedToken == null) return false;
    final currentRevision = _authAttemptRevision;
    final current = _current;
    return currentRevision != logoutRevision &&
        _currentRevisionOwnsCommittedSession() &&
        current.token == remotelyRevokedToken;
  }

  /// Durable auth ownership is transactional metadata, not presentation
  /// state. A committed session remains the owner while the UI temporarily
  /// shows loading or a recoverable connection error, provided its revision,
  /// bearer, and user identity are still intact.
  bool _currentRevisionOwnsCommittedSession() {
    final current = _current;
    return _lastTransactionalSessionRevision == _authAttemptRevision &&
        current.hasValidToken &&
        current.user != null;
  }

  void _sanitizeRevokedCommittedSession(String? revokedToken) {
    if (revokedToken == null || _current.token != revokedToken) return;
    _lastTransactionalSessionRevision = null;
    _cacheManager.clearAuthCache();
    _update(
      (current) => current.copyWith(
        status: AuthStatus.tokenExpired,
        error: 'Session expired - please sign in again',
        clearToken: true,
        clearUser: true,
        isLoading: false,
      ),
    );
    _updateApiServiceToken(null);
  }

  Future<void> _waitForNewerAuthAttemptToSettle(
    int logoutRevision, {
    String? remotelyRevokedToken,
  }) async {
    final settleTimer = Stopwatch()..start();
    while (ref.mounted && _authAttemptRevision != logoutRevision) {
      if (_newerCommittedSessionOwnsAuthData(
        logoutRevision,
        remotelyRevokedToken: remotelyRevokedToken,
      )) {
        return;
      }
      final current = _current;
      if (!current.isLoading &&
          current.status != AuthStatus.loading &&
          current.status != AuthStatus.initial) {
        return;
      }
      if (settleTimer.elapsed >= _newerAuthAttemptSettleGrace) {
        DebugLogger.warning(
          'newer-auth-attempt-settle-deadline-reached',
          scope: 'auth/state',
          data: {'graceMs': _newerAuthAttemptSettleGrace.inMilliseconds},
        );
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Preload the default model as soon as authentication succeeds.
  /// Update API service with current token
  void _updateApiServiceToken(String? token) {
    ref.read(apiAuthTokenMirrorProvider.notifier).set(token);
    final api = ref.read(apiServiceProvider);
    api?.updateAuthToken(token);
  }

  void _setIncompleteLogoutFenceInMemory(bool suppressed) {
    final api = ref.read(apiServiceProvider);
    api?.setCookieCustomHeaderSuppressed(suppressed);
    ref.read(incompleteLogoutFenceProvider.notifier).setSuppressed(suppressed);
  }

  void _clearIncompleteLogoutFenceAfterTokenlessCleanup() {
    final fence = ref.read(incompleteLogoutFenceProvider.notifier);

    Future<void> restoreFailedClear(
      Object error,
      StackTrace stack,
      int failedGeneration,
    ) async {
      _logAuthenticationFailure(
        'logout-fence-clear-failed',
        error,
        stackTrace: stack,
      );
      if (!ref.mounted ||
          !fence.desiredSuppressed ||
          !fence.ownsRequest(failedGeneration)) {
        return;
      }
      fence.setSuppressed(true);
      try {
        await fence.persist(true);
      } catch (restoreError, restoreStack) {
        _logAuthenticationFailure(
          'logout-fence-clear-restore-failed',
          restoreError,
          stackTrace: restoreStack,
        );
      }
    }

    final clearOperation = fence.persist(false, publishState: false);
    final clearGeneration = fence.requestGeneration;
    unawaited(
      clearOperation.then<void>(
        (cleared) async {
          if (cleared && ref.mounted && !fence.desiredSuppressed) {
            _setIncompleteLogoutFenceInMemory(false);
            return;
          }
          if (!cleared && fence.ownsRequest(clearGeneration)) {
            await restoreFailedClear(
              StateError('Incomplete logout fence could not be cleared.'),
              StackTrace.current,
              clearGeneration,
            );
          }
        },
        onError: (error, stack) {
          return restoreFailedClear(error, stack, clearGeneration);
        },
      ),
    );
  }

  /// Removes a durable incomplete-logout fence before exposing a newly
  /// authenticated session. This callback is awaited by the storage
  /// transaction while its auth/config locks remain held, so a failed checked
  /// preference write rolls the new token and ownership changes back.
  Future<void> _publishCommittedAuthenticatedSession({
    required int attemptRevision,
    required String candidateToken,
    required void Function() publish,
  }) async {
    if (_authAttemptSuperseded(attemptRevision)) {
      throw StateError('Authentication attempt was superseded before publish.');
    }
    final fence = ref.read(incompleteLogoutFenceProvider.notifier);
    final fenceWasSet =
        fence.desiredSuppressed ||
        ref.read(incompleteLogoutFenceProvider) ||
        PreferencesStore.getBool(PreferenceKeys.incompleteLogoutFence) == true;
    int? fenceClearGeneration;
    if (fenceWasSet) {
      try {
        if (_authAttemptSuperseded(attemptRevision)) {
          throw StateError(
            'Authentication attempt was superseded before fence clear.',
          );
        }
        final clearOperation = fence.persist(false, publishState: false);
        fenceClearGeneration = fence.requestGeneration;
        final cleared = await clearOperation;
        if (!cleared || fence.desiredSuppressed) {
          throw StateError('Incomplete logout fence could not be cleared.');
        }
        if (_authAttemptSuperseded(attemptRevision)) {
          throw StateError(
            'Authentication attempt was superseded during fence clear.',
          );
        }
      } catch (commitError, commitStackTrace) {
        final newerFenceRequest =
            fenceClearGeneration != null &&
            !fence.ownsRequest(fenceClearGeneration);
        final newerAuthAttempt =
            ref.mounted && _authAttemptRevision != attemptRevision;
        if (!newerFenceRequest && !newerAuthAttempt) {
          try {
            final restored = await fence.persist(true);
            if (!restored) {
              throw StateError(
                'Incomplete logout fence could not be restored.',
              );
            }
          } catch (rollbackError, rollbackStackTrace) {
            _poisonUncertainServerSession(
              failedAttemptRevision: attemptRevision,
            );
            Error.throwWithStackTrace(
              ServerConfigSessionRollbackException(
                commitError: commitError,
                rollbackError: rollbackError,
              ),
              rollbackStackTrace,
            );
          }
        }
        Error.throwWithStackTrace(commitError, commitStackTrace);
      }
    }

    // No await occurs between this ownership check and the synchronous state
    // publication below, so another auth attempt cannot interleave on the
    // isolate after this point.
    if (_authAttemptSuperseded(attemptRevision)) {
      throw StateError('Authentication attempt was superseded before publish.');
    }
    try {
      if (_recentlyRevokedTokens.contains(candidateToken)) {
        throw StateError(
          'Authentication token was revoked before session publication.',
        );
      }
      publish();
      if (_authAttemptSuperseded(attemptRevision)) {
        throw StateError(
          'Authentication attempt was superseded by a publication listener.',
        );
      }
    } catch (commitError, commitStackTrace) {
      // The callback may have partially updated Riverpod state. If publication
      // itself started a newer auth operation through a synchronous listener,
      // that operation now owns memory/API recovery and may need the captured
      // bearer to finish a remote logout. The storage transaction will roll
      // this failed commit back; only an actually uncertain rollback invokes
      // its onRollbackUncertain poison callback. With no newer revision, scrub
      // the partial publication immediately.
      if (ref.mounted && _authAttemptRevision != attemptRevision) {
        if (_lastTransactionalSessionRevision == attemptRevision) {
          _lastTransactionalSessionRevision = null;
        }
      } else {
        // Durable rollback still runs in the storage transaction after this
        // callback throws. Revoke the candidate bearer immediately, but do not
        // advance the uncertainty epoch: a successful rollback restores the
        // captured prior in-memory session at the transaction call boundary.
        try {
          _lastTransactionalSessionRevision = null;
          _set(const AuthState(status: AuthStatus.loading, isLoading: true));
          _updateApiServiceToken(null);
          ref.invalidate(apiServiceProvider);
        } catch (recoveryError, recoveryStackTrace) {
          _logAuthenticationFailure(
            'partial-auth-publication-scrub-failed',
            recoveryError,
            stackTrace: recoveryStackTrace,
          );
        }
      }
      if (fenceWasSet &&
          (!ref.mounted || _authAttemptRevision == attemptRevision)) {
        try {
          final restored = await fence.persist(true);
          if (!restored) {
            throw StateError('Incomplete logout fence could not be restored.');
          }
          if (ref.mounted && _authAttemptRevision == attemptRevision) {
            _setIncompleteLogoutFenceInMemory(true);
          }
        } catch (rollbackError, rollbackStackTrace) {
          Error.throwWithStackTrace(
            ServerConfigSessionRollbackException(
              commitError: commitError,
              rollbackError: rollbackError,
            ),
            rollbackStackTrace,
          );
        }
      }
      Error.throwWithStackTrace(commitError, commitStackTrace);
    }
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
    final inheritedRevision = _authAttemptRevision;
    final inheritedToken = _currentRevisionOwnsCommittedSession()
        ? _current.token
        : null;
    final attemptRevision = _beginAuthAttempt();
    // Refresh does not create a new durable session; it temporarily advances
    // the attempt revision while retaining the exact already-committed owner.
    // Carry that ownership synchronously so incidental error/loading UI updates
    // cannot open a window where an older logout clears the retained session.
    // `_initialize` revokes this carry as soon as strict storage proves the
    // token missing, changed, fenced, or invalid.
    if (inheritedToken != null &&
        _lastTransactionalSessionRevision == inheritedRevision &&
        _current.token == inheritedToken &&
        _current.user != null) {
      _lastTransactionalSessionRevision = attemptRevision;
    }
    // Clear cache before refresh to ensure fresh data
    _cacheManager.clearAuthCache();
    TokenValidationCache.clearCache();

    await _initialize(
      attemptRevision: attemptRevision,
      inheritedTransactionalRevision: inheritedToken == null
          ? null
          : attemptRevision,
      inheritedTransactionalToken: inheritedToken,
    );
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
