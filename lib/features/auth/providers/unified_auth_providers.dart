import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/auth/auth_state_manager.dart';
import '../../../core/models/user.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/backend_mode_providers.dart';
import '../../../core/services/api_service.dart';
import '../../../core/utils/debug_logger.dart';

/// Unified auth providers using the new auth state manager
/// These replace the old auth providers for better efficiency

/// Runs an Open WebUI authentication attempt and persists the backend choice
/// only after the attempt has been confirmed successful.
///
/// Keeping this boundary shared prevents server discovery/config persistence
/// from being mistaken for completed authentication by individual UI flows.
Future<bool> completeOpenWebUiAuthentication({
  required Future<bool> Function() authenticate,
  required Future<void> Function() persistPreference,
}) async {
  final success = await authenticate();
  if (success) {
    try {
      await persistPreference();
    } catch (error) {
      // The session is already authenticated. A best-effort routing preference
      // write must not make the sign-in UI report that authentication failed.
      DebugLogger.warning(
        'preferred-backend-persist-failed',
        scope: 'auth/backend',
        data: {'error': error.toString()},
      );
    }
  }
  return success;
}

/// Imperative auth actions wrapper to avoid side-effects during provider build
class AuthActions {
  final Ref _ref;
  AuthActions(this._ref);

  AuthStateManager get _auth => _ref.read(authStateManagerProvider.notifier);

  Future<bool> _completeOpenWebUiAuth(Future<bool> Function() authenticate) =>
      completeOpenWebUiAuthentication(
        authenticate: authenticate,
        persistPreference: () => _ref
            .read(preferredBackendProvider.notifier)
            .set(PreferredBackend.owui),
      );

  Future<bool> login(
    String username,
    String password, {
    bool rememberCredentials = false,
  }) {
    return _completeOpenWebUiAuth(
      () => _auth.login(
        username,
        password,
        rememberCredentials: rememberCredentials,
      ),
    );
  }

  Future<bool> loginWithApiKey(
    String apiKey, {
    bool rememberCredentials = false,
    String authType = 'token',
  }) {
    return _completeOpenWebUiAuth(
      () => _auth.loginWithApiKey(
        apiKey,
        rememberCredentials: rememberCredentials,
        authType: authType,
      ),
    );
  }

  Future<bool> ldapLogin(
    String username,
    String password, {
    bool rememberCredentials = false,
  }) {
    return _completeOpenWebUiAuth(
      () => _auth.ldapLogin(
        username,
        password,
        rememberCredentials: rememberCredentials,
      ),
    );
  }

  Future<bool> silentLogin() {
    return _auth.silentLogin();
  }

  Future<void> logout() {
    return _auth.logout();
  }

  Future<void> refresh() {
    return _auth.refresh();
  }
}

final authActionsProvider = Provider<AuthActions>((ref) => AuthActions(ref));

// Legacy action providers have been replaced by `authActionsProvider`

/// Check if saved credentials exist
final hasSavedCredentialsProvider2 = FutureProvider<bool>((ref) async {
  final authManager = ref.read(authStateManagerProvider.notifier);
  return await authManager.hasSavedCredentials();
});

/// Computed providers for UI consumption
/// These automatically update when auth state changes
/// These are keepAlive since they derive from keepAlive authStateManagerProvider
/// and are used throughout the app lifecycle

final isAuthenticatedProvider2 = Provider<bool>((ref) {
  final authState = ref.watch(authStateManagerProvider);
  return authState.maybeWhen(
    data: (state) => state.isAuthenticated,
    orElse: () => false,
  );
});

final authTokenProvider3 = Provider<String?>((ref) {
  final authState = ref.watch(authStateManagerProvider);
  return authState.maybeWhen(data: (state) => state.token, orElse: () => null);
});

final currentUserProvider2 = Provider<User?>((ref) {
  final authState = ref.watch(authStateManagerProvider);
  return authState.maybeWhen(data: (state) => state.user, orElse: () => null);
});

final authErrorProvider3 = Provider<String?>((ref) {
  final authState = ref.watch(authStateManagerProvider);
  return authState.maybeWhen(data: (state) => state.error, orElse: () => null);
});

final isAuthLoadingProvider2 = Provider<bool>((ref) {
  final authState = ref.watch(authStateManagerProvider);
  if (authState.isLoading) return true;
  return authState.maybeWhen(
    data: (state) => state.isLoading,
    orElse: () => false,
  );
});

final authStatusProvider = Provider<AuthStatus>((ref) {
  final authState = ref.watch(authStateManagerProvider);
  return authState.maybeWhen(
    data: (state) => state.status,
    orElse: () => AuthStatus.loading,
  );
});

// Use `ref.read(authActionsProvider).refresh()` instead of refresh providers

/// Provider to watch for auth state changes and update API service
final authApiIntegrationProvider = Provider<void>((ref) {
  void syncToken(ApiService? api, String? token) {
    if (api == null) return;
    if (token == null || token.isEmpty) {
      api.updateAuthToken(null);
      return;
    }
    api.updateAuthToken(token);
  }

  // Ensure the current ApiService instance immediately picks up the cached token.
  syncToken(ref.read(apiServiceProvider), ref.read(authTokenProvider3));

  ref.listen<ApiService?>(apiServiceProvider, (previous, next) {
    syncToken(next, ref.read(authTokenProvider3));
  });

  ref.listen<String?>(authTokenProvider3, (previous, next) {
    syncToken(ref.read(apiServiceProvider), next);
  });
});

/// Navigation helper provider - determines where user should go
final authNavigationStateProvider = Provider<AuthNavigationState>((ref) {
  final authState = ref.watch(authStateManagerProvider);
  return authState.when(
    data: (state) {
      switch (state.status) {
        case AuthStatus.initial:
        case AuthStatus.loading:
          return AuthNavigationState.loading;
        case AuthStatus.authenticated:
          return AuthNavigationState.authenticated;
        case AuthStatus.unauthenticated:
        case AuthStatus.tokenExpired:
        case AuthStatus.credentialError:
          return AuthNavigationState.needsLogin;
        case AuthStatus.error:
          return AuthNavigationState.error;
      }
    },
    loading: () => AuthNavigationState.loading,
    error: (_, stack) => AuthNavigationState.error,
  );
});

enum AuthNavigationState { loading, authenticated, needsLogin, error }
