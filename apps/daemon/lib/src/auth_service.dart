import 'dart:async';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/auth/proxy_session.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'settled.dart';

/// Implements the `auth.*` family over the core's `AuthStateManager`.
///
/// The manager is where every login path already converges on mobile --
/// password, LDAP, API key, silent restore, trusted proxy -- so this is a
/// projection, not a reimplementation. What it adds is the boundary: a token
/// never leaves, and errors leave as codes rather than as server prose.
final class AuthService {
  AuthService(this._container);

  final ProviderContainer _container;

  AuthStateManager get _manager =>
      _container.read(authStateManagerProvider.notifier);

  /// Waits for the manager's first build before reading state.
  ///
  /// `AuthStateManager.build` is async -- it restores a session from storage
  /// -- and reading the provider synchronously during startup would report
  /// `initial` for a user who is in fact signed in, which the UI would render
  /// as onboarding.
  Future<AuthSnapshot> status() async {
    await readSettled(_container, authStateManagerProvider.future);
    return _snapshot();
  }

  Future<AuthSnapshot> loginWithPassword(PasswordLogin params) async {
    await _manager.login(
      params.username,
      params.password,
      rememberCredentials: true,
    );
    return _snapshot();
  }

  Future<AuthSnapshot> loginWithLdap(PasswordLogin params) async {
    await _manager.ldapLogin(
      params.username,
      params.password,
      rememberCredentials: true,
    );
    return _snapshot();
  }

  Future<AuthSnapshot> loginWithApiKey(ApiKeyLogin params) async {
    await _manager.loginWithApiKey(params.apiKey, rememberCredentials: true);
    return _snapshot();
  }

  Future<AuthSnapshot> silentLogin() async {
    await _manager.silentLogin();
    return _snapshot();
  }

  Future<bool> hasSavedCredentials() => _manager.hasSavedCredentials();

  /// Finishes a sign-in that happened in an Electron window.
  ///
  /// Runs the core's [prevalidateProxySession] first, which is the whole
  /// point: trusted-header discovery can report success while handing back a
  /// JWT the server has already expired, so the token is proved with a real
  /// authenticated call before anything is persisted. A window closed halfway
  /// through therefore cannot leave a half-authenticated state.
  Future<AuthSnapshot> completeExternal(ExternalAuthCompletion params) async {
    final active = await readSettled(_container, activeServerProvider.future);
    if (active == null) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'auth.completeExternal needs an active server',
      );
    }
    // Cookies are only meaningful to the origin that set them; attaching a
    // capture from one server to another would leak a session sideways.
    if (!_sameOrigin(active.url, params.origin)) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'origin': params.origin},
        debugMessage:
            'captured origin ${params.origin} is not the active server',
      );
    }

    final outcome = await prevalidateProxySession(
      serverConfig: active,
      capture: ProxyAuthCapture(cookies: params.cookies, token: params.token),
      workerManager: _container.read(workerManagerProvider),
    );

    switch (outcome) {
      case ProxySessionAuthenticated(
        :final serverConfig,
        :final token,
        :final user,
      ):
        await _manager.commitPrevalidatedProxySession(
          serverConfig: serverConfig,
          token: token,
          user: user,
        );
      case ProxySessionNeedsSignIn():
        // The proxy let us through but Open WebUI still wants credentials.
        // Not an error: the UI shows its sign-in form next.
        break;
      case ProxySessionRejected(:final failure):
        throw RpcError(
          code: switch (failure) {
            ProxySessionFailure.serverUnreachable =>
              ConduitErrorCodes.connectionFailed,
            ProxySessionFailure.notOpenWebUi =>
              ConduitErrorCodes.connectionFailed,
            ProxySessionFailure.tokenMissing =>
              ConduitErrorCodes.unauthenticated,
            ProxySessionFailure.tokenRejected =>
              ConduitErrorCodes.sessionExpired,
          },
          args: <String, String>{'reason': failure.name},
        );
    }
    return _snapshot();
  }

  /// Scheme, host and port, ignoring path and trailing slash.
  static bool _sameOrigin(String a, String b) {
    final left = Uri.tryParse(a);
    final right = Uri.tryParse(b);
    if (left == null || right == null) return false;
    return left.scheme == right.scheme &&
        left.host == right.host &&
        left.port == right.port;
  }

  Future<SignOutResult> signOut(SignOutRequest request) async {
    final outcome = await _manager.logoutAndClearAppData(
      keepServerDetails: request.keepServerDetails,
      beforeClear: () async {},
    );
    return SignOutResult(
      outcome: _mapOutcome(outcome),
      remaining: switch (outcome) {
        FullAppDataClearOutcome.cleared => const <String>[],
        FullAppDataClearOutcome.localDataClearedSessionCleanupIncomplete =>
          const <String>['session'],
        FullAppDataClearOutcome.incomplete => const <String>[
          'session',
          'localData',
        ],
        FullAppDataClearOutcome.ownershipYielded => const <String>[],
      },
    );
  }

  Future<AuthSnapshot> setReviewerMode({required bool enabled}) async {
    await _container.read(reviewerModeProvider.notifier).setEnabled(enabled);
    return _snapshot();
  }

  /// Exhaustive on purpose. `FullAppDataClearOutcome` and [SignOutOutcome]
  /// are two enums that have to stay in step across a package boundary the
  /// compiler cannot see across; a switch without a default is what turns
  /// adding a case on one side into a compile error on the other.
  static SignOutOutcome _mapOutcome(FullAppDataClearOutcome outcome) =>
      switch (outcome) {
        FullAppDataClearOutcome.cleared => SignOutOutcome.cleared,
        FullAppDataClearOutcome.localDataClearedSessionCleanupIncomplete =>
          SignOutOutcome.localDataClearedSessionCleanupIncomplete,
        FullAppDataClearOutcome.incomplete => SignOutOutcome.incomplete,
        FullAppDataClearOutcome.ownershipYielded =>
          SignOutOutcome.ownershipYielded,
      };

  static AuthPhase _mapPhase(AuthStatus status) => switch (status) {
    AuthStatus.initial => AuthPhase.initial,
    AuthStatus.loading => AuthPhase.loading,
    AuthStatus.authenticated => AuthPhase.authenticated,
    AuthStatus.unauthenticated => AuthPhase.unauthenticated,
    AuthStatus.tokenExpired => AuthPhase.tokenExpired,
    AuthStatus.error => AuthPhase.error,
    AuthStatus.credentialError => AuthPhase.credentialError,
  };

  AuthSnapshot _snapshot() {
    final state = _container.read(authStateManagerProvider).value;
    if (state == null) {
      return const AuthSnapshot(phase: AuthPhase.loading, isLoading: true);
    }
    return AuthSnapshot(
      phase: _mapPhase(state.status),
      isAuthenticated: state.isAuthenticated,
      isLoading: state.isLoading,
      // Whether, never what. The token stays in the secure store; every
      // authenticated request is made by this process.
      hasToken: state.hasValidToken,
      user: state.user == null ? null : _mapUser(state.user!),
      errorCode: _errorCodeFor(state),
      isReviewerMode: _container.read(reviewerModeProvider),
    );
  }

  /// The core's `AuthState.error` is a human string, sometimes from the
  /// server. Errors cross the protocol as codes, so the phase decides the
  /// code and the prose is dropped rather than shown in the server's locale.
  static String? _errorCodeFor(AuthState state) => switch (state.status) {
    AuthStatus.credentialError => ConduitErrorCodes.invalidCredentials,
    AuthStatus.tokenExpired => ConduitErrorCodes.sessionExpired,
    AuthStatus.error when state.error != null =>
      ConduitErrorCodes.connectionFailed,
    _ => null,
  };

  static AuthUser _mapUser(User user) => AuthUser(
    id: user.id,
    // `username` is what Open WebUI always populates; `name` is the optional
    // display override, so it wins when present.
    name: user.name?.trim().isNotEmpty ?? false ? user.name! : user.username,
    email: user.email.isEmpty ? null : user.email,
    role: user.role,
    avatarUrl: user.profileImage,
  );
}
