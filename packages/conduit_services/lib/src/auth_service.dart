import 'dart:async';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/auth/openwebui_two_step.dart';
import 'package:conduit_core/auth/proxy_renewal.dart';
import 'package:conduit_core/auth/proxy_session.dart';
import 'package:conduit_core/auth/sign_in_failure.dart';
import 'package:conduit_core/models/openwebui_registry.dart'
    show isCapturedSessionHeader;
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart'
    show accountAdditionOriginProvider;
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'account_scope.dart';
import 'event_bus.dart';
import 'settled.dart';

/// Implements the `auth.*` family over the core's `AuthStateManager`: signing
/// in to the active account. Signing out of one, which hands over to the
/// next, is `accounts.signOut`.
///
/// The manager is where every login path already converges on mobile --
/// password, LDAP, API key, silent restore, trusted proxy -- so this is a
/// projection, not a reimplementation. What it adds is the boundary: a token
/// never leaves, and errors leave as codes rather than as server prose.
final class AuthService {
  AuthService(this._container, {EventBus? events}) : _events = events {
    if (events == null) return;
    // A session that changes in a way the account list does not show -- a
    // kept session becoming a connection issue, or back -- is announced, so
    // every window asks `auth.status` again.
    _watch = _container.listen<(AuthStatus?, bool)>(
      authStateManagerProvider.select(
        (state) => (state.value?.status, state.value?.hasValidToken ?? false),
      ),
      (previous, next) {
        if (previous != next) _announce();
      },
    );
  }

  final ProviderContainer _container;
  final EventBus? _events;
  ProviderSubscription<(AuthStatus?, bool)>? _watch;
  Timer? _announcing;

  /// `auth.changed`, once for a burst of changes.
  void _announce() {
    if (_events == null || _announcing != null) return;
    _announcing = Timer(const Duration(milliseconds: 150), () {
      _announcing = null;
      _events.emit(ConduitEventSpecs.authChanged, null);
    });
  }

  void dispose() {
    _watch?.close();
    _watch = null;
    _announcing?.cancel();
    _announcing = null;
  }

  /// A password or LDAP sign-in waiting on its second step. Held here, as
  /// the phone's sign-in page holds it: the challenge token never leaves.
  _PendingTwoStep? _twoStep;

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

  Future<AuthSnapshot> loginWithPassword(PasswordLogin params) => _signIn(
    account: params.username,
    () => _manager.login(
      params.username,
      params.password,
      rememberCredentials: true,
    ),
  );

  Future<AuthSnapshot> loginWithLdap(PasswordLogin params) => _signIn(
    account: params.username,
    () => _manager.ldapLogin(
      params.username,
      params.password,
      rememberCredentials: true,
    ),
  );

  /// A session token (JWT) pasted from Open WebUI, checked as the phone's
  /// form checks it before the server is asked: API keys never sign in.
  Future<AuthSnapshot> loginWithApiKey(ApiKeyLogin params) async {
    switch (jwtSignInTokenProblem(params.apiKey)) {
      case JwtTokenProblem.apiKey:
        throw const RpcError(code: ConduitErrorCodes.apiKeyNotSupported);
      case JwtTokenProblem.tooShort:
        throw const RpcError(code: ConduitErrorCodes.tokenTooShort);
      case JwtTokenProblem.missing:
        throw const RpcError(
          code: ConduitErrorCodes.invalidParams,
          debugMessage: 'auth.loginWithApiKey needs a token',
        );
      case null:
        break;
    }
    return _signIn(
      () => _manager.loginWithApiKey(params.apiKey, rememberCredentials: true),
    );
  }

  /// Runs a sign-in. A second step is not a failure: the snapshot carries
  /// it for the window to ask for the code. A failure leaves as a code.
  Future<AuthSnapshot> _signIn(
    Future<bool> Function() run, {
    String account = '',
  }) async {
    _twoStep = null;
    // The server a second step belongs to, once it has settled: during
    // startup it is still being read, and a step filed under none would be
    // dropped the moment it is.
    final serverId = (await readSettled(
      _container,
      activeServerProvider.future,
    ))?.id;
    try {
      await run();
    } on OpenWebUiTwoStepRequired catch (required) {
      _twoStep = _PendingTwoStep(
        serverId: serverId,
        account: account,
        challenge: required.challenge,
      );
      _announce();
    } on RpcError {
      rethrow;
    } catch (error) {
      throw _signInError(error);
    }
    return _snapshot();
  }

  /// What to add to an authenticator app for an `enroll` step.
  Future<TwoStepSetup> twoStepSetup() async {
    final pending = _pendingAt({OpenWebUiTwoStepKind.enroll});
    final challenge = pending.challenge;
    final OpenWebUiTwoStepSetup setup;
    try {
      setup = await _manager.startTwoStepEnrollment(challenge);
    } catch (error) {
      throw _twoStepError(error);
    }
    // A key for an attempt cancelled or replaced meanwhile: not this one's.
    _requireAttempt(pending, challenge);
    return TwoStepSetup(
      manualKey: setup.manualKey,
      qrSvg: setup.qrSvg,
      authenticatorUri: setup
          .authenticatorUri(account: pending.account)
          .toString(),
    );
  }

  /// Answers a `verify` or `enroll` step. A new authenticator comes with
  /// recovery codes, which are shown before the session is signed in to.
  Future<AuthSnapshot> twoStepVerify(TwoStepCode params) async {
    final pending = _pendingAt({
      OpenWebUiTwoStepKind.verify,
      OpenWebUiTwoStepKind.enroll,
    });
    if (params.code.trim().isEmpty) {
      throw const RpcError(code: ConduitErrorCodes.twoStepInvalidCode);
    }
    final challenge = pending.challenge;
    final OpenWebUiTwoStepSession session;
    try {
      session = await _manager.submitTwoStepCode(
        challenge,
        params.code,
        recovery:
            params.recovery && challenge.kind == OpenWebUiTwoStepKind.verify,
      );
    } catch (error) {
      throw _twoStepError(error);
    }
    // Cancelled, or another sign-in began, while the code was checked: the
    // session it brought finishes nothing.
    _requireAttempt(pending, challenge);
    if (session.recoveryCodes.isNotEmpty) {
      pending.issued = session;
      _announce();
      return _snapshot();
    }
    return _finishTwoStep(pending, session);
  }

  /// Redeems an administrator's recovery token: the step moves on to
  /// adding a new authenticator.
  Future<AuthSnapshot> twoStepRedeem(TwoStepResetToken params) async {
    final pending = _pendingAt({OpenWebUiTwoStepKind.recover});
    if (params.resetToken.trim().isEmpty) {
      throw const RpcError(code: ConduitErrorCodes.twoStepInvalidCode);
    }
    final challenge = pending.challenge;
    final OpenWebUiTwoStepChallenge next;
    try {
      next = await _manager.redeemTwoStepResetToken(
        challenge,
        params.resetToken,
      );
    } catch (error) {
      throw _twoStepError(error);
    }
    _requireAttempt(pending, challenge);
    pending.challenge = next;
    _announce();
    return _snapshot();
  }

  /// Signs in with the session whose recovery codes were just shown.
  Future<AuthSnapshot> twoStepFinish() async {
    final pending = _currentTwoStep();
    final issued = pending?.issued;
    if (pending == null || issued == null) {
      throw const RpcError(code: ConduitErrorCodes.twoStepExpired);
    }
    return _finishTwoStep(pending, issued);
  }

  /// Back to the sign-in form. The attempt ends in the core too, where its
  /// session would be committed: a code still being checked signs nobody in.
  Future<AuthSnapshot> twoStepCancel() async {
    if (_twoStep != null) {
      _manager.cancelTwoStepSignIn();
      _announce();
    }
    _twoStep = null;
    return _snapshot();
  }

  Future<AuthSnapshot> _finishTwoStep(
    _PendingTwoStep pending,
    OpenWebUiTwoStepSession session,
  ) async {
    // Checked with no wait before the core commits the session: once it
    // starts, this attempt is the one in charge.
    _requireAttempt(pending, pending.challenge);
    final bool signedIn;
    try {
      signedIn = await _manager.finishTwoStepSignIn(session);
    } catch (error) {
      // The code was right; a refused session means starting again.
      throw _signInError(error);
    }
    if (!signedIn) {
      // A newer sign-in or sign-out took over meanwhile.
      throw const RpcError(code: ConduitErrorCodes.signInFailed);
    }
    if (identical(_twoStep, pending)) _twoStep = null;
    return _snapshot();
  }

  /// The pending step, if it is still for the active server. A server still
  /// being read (no answer yet) is not another one: the step stays.
  _PendingTwoStep? _currentTwoStep() {
    final pending = _twoStep;
    if (pending == null) return null;
    final active = _container.read(activeServerProvider);
    if (!active.hasValue) return pending;
    if (pending.serverId != active.value?.id) {
      _twoStep = null;
      return null;
    }
    return pending;
  }

  /// The ticket every answer of a two-step attempt is checked against after
  /// its wait, and before the session is signed in to: still this attempt
  /// ([pending], for the same server and account) at the same step
  /// ([challenge]). Cancelling, a new sign-in, another server or a step
  /// moved on ends it.
  void _requireAttempt(
    _PendingTwoStep pending,
    OpenWebUiTwoStepChallenge challenge,
  ) {
    if (identical(_currentTwoStep(), pending) &&
        identical(pending.challenge, challenge)) {
      return;
    }
    throw const RpcError(
      code: ConduitErrorCodes.twoStepExpired,
      args: <String, String>{'reason': 'superseded'},
    );
  }

  _PendingTwoStep _pendingAt(Set<OpenWebUiTwoStepKind> kinds) {
    final pending = _currentTwoStep();
    if (pending == null) {
      throw const RpcError(code: ConduitErrorCodes.twoStepExpired);
    }
    if (pending.issued != null || !kinds.contains(pending.challenge.kind)) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'the two-step sign-in is at ${pending.stage.name}',
      );
    }
    return pending;
  }

  /// A failed sign-in as a code, read from what the core threw: its words
  /// are fixed phrases and codes, never server prose.
  static RpcError _signInError(Object error) {
    final failure = classifySignInFailure(error.toString());
    return RpcError(
      code: _signInFailureCode(failure),
      args: <String, String>{'reason': failure.name},
    );
  }

  static String _signInFailureCode(SignInFailure failure) => switch (failure) {
    SignInFailure.browserSignInSessionExpired =>
      ConduitErrorCodes.sessionExpired,
    SignInFailure.twoStepRequired => ConduitErrorCodes.twoStepRequired,
    SignInFailure.twoStepSessionRejected => ConduitErrorCodes.twoStepExpired,
    SignInFailure.accountPendingApproval => ConduitErrorCodes.pendingApproval,
    SignInFailure.apiKeyNotSupported => ConduitErrorCodes.apiKeyNotSupported,
    SignInFailure.apiKeyNoLongerSupported =>
      ConduitErrorCodes.apiKeyNoLongerSupported,
    SignInFailure.ldapNotEnabled => ConduitErrorCodes.ldapNotEnabled,
    SignInFailure.invalidCredentials => ConduitErrorCodes.invalidCredentials,
    SignInFailure.serverRedirect => ConduitErrorCodes.serverRedirect,
    SignInFailure.unreachable => ConduitErrorCodes.connectionFailed,
    SignInFailure.timedOut => ConduitErrorCodes.timeout,
    SignInFailure.failed => ConduitErrorCodes.signInFailed,
  };

  static RpcError _twoStepError(Object error) {
    final failure = error is OpenWebUiTwoStepException
        ? error.failure
        : OpenWebUiTwoStepFailure.failed;
    return RpcError(
      code: switch (failure) {
        OpenWebUiTwoStepFailure.invalidCode =>
          ConduitErrorCodes.twoStepInvalidCode,
        OpenWebUiTwoStepFailure.expired => ConduitErrorCodes.twoStepExpired,
        OpenWebUiTwoStepFailure.tooManyAttempts =>
          ConduitErrorCodes.twoStepTooManyAttempts,
        OpenWebUiTwoStepFailure.failed => ConduitErrorCodes.twoStepFailed,
      },
    );
  }

  /// The connection issue's Retry, as the phone's: the kept session is
  /// checked with the server again, or, with none kept, the saved sign-in
  /// is tried. The server is asked before the session is shown signed in
  /// ([AuthStateManager.retryConnectionIssue]): a refresh trusts the stored
  /// token at once, and a proxy still turning it away came back as signed
  /// in until its check failed a moment later.
  Future<AuthSnapshot> retry() async {
    final state = await readSettled(
      _container,
      authStateManagerProvider.future,
    );
    _manager.resetRetryCounter();
    try {
      if (state.hasValidToken) {
        await _manager.retryConnectionIssue();
      } else {
        await _manager.silentLogin();
      }
    } catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.connectionFailed,
        debugMessage: error.runtimeType.toString(),
      );
    }
    // Behind a proxy still turning the session away the check keeps
    // retrying for a while; the window keeps the issue shown meanwhile.
    return _settledSnapshot(limit: const Duration(seconds: 4));
  }

  /// Renews the active account's expired reverse-proxy session in place
  /// with what a proxy sign-in window captured: the account stays, its
  /// saved proxy cookies are replaced, and its session is checked again
  /// (or the window's Open WebUI session adopted, when it signed in too).
  Future<AuthSnapshot> renewProxy(ExternalAuthCompletion params) async {
    final active = await readSettled(_container, activeServerProvider.future);
    if (active == null) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'auth.renewProxy needs an active server',
      );
    }
    // The renewal belongs to the account whose window it was: another
    // account in charge now (on the same origin, say) is never written to,
    // neither when it asks nor at any write after.
    final account = AccountScope.capture(_container);
    final opened = params.account;
    if (opened == null) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'auth.renewProxy needs the account its window was for',
      );
    }
    if (opened != active.id) {
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        args: <String, String>{'reason': 'account'},
        debugMessage: 'the proxy sign-in was opened for another account',
      );
    }
    if (!_sameOrigin(active.url, params.origin)) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'origin': params.origin},
        debugMessage:
            'captured origin ${params.origin} is not the active server',
      );
    }
    final capture = ProxyAuthCapture(
      cookies: params.cookies,
      token: params.token,
    );
    if (capture.cookies.isEmpty && !capture.isFullyAuthenticated) {
      // The window closed with nothing to renew with.
      throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        args: <String, String>{'reason': 'nothingCaptured'},
      );
    }
    var refused = false;
    try {
      await renewProxySessionInPlace(
        _container,
        activeServer: active,
        capture: capture,
        // Asked right before the first write, after everything that waits:
        // the account AND its session as the renewal began (a newer
        // sign-in on this account is not this renewal's to overwrite).
        canCommit: () => !(refused = !account.isCurrent),
      );
    } on ProxyRenewalWrongUser {
      // Someone else signed in at the proxy's window: nothing was saved.
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        args: <String, String>{'reason': 'account'},
        debugMessage: 'the proxy sign-in was for another user',
      );
    } catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.connectionFailed,
        debugMessage: error.runtimeType.toString(),
      );
    }
    if (refused) {
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        args: <String, String>{'reason': 'account'},
        debugMessage: 'the account changed before the proxy session was saved',
      );
    }
    return _settledSnapshot();
  }

  Future<AuthSnapshot> silentLogin() async {
    await _manager.silentLogin();
    return _snapshot();
  }

  Future<bool> hasSavedCredentials() => _manager.hasSavedCredentials();

  /// Finishes a sign-in that happened in one of the desktop app's windows.
  ///
  /// Runs the core's [prevalidateProxySession] first, which is the whole
  /// point: trusted-header discovery can report success while handing back a
  /// JWT the server has already expired, so the token is proved with a real
  /// authenticated call before anything is persisted. A window closed halfway
  /// through therefore cannot leave a half-authenticated state.
  Future<AuthSnapshot> completeExternal(ExternalAuthCompletion params) async {
    // First, before anything is awaited: what the capture is for. The
    // account in charge (its session, and the addition it finishes, if one
    // is in progress), the revocations so far, and the saved servers as they
    // are now. If any of them moved by the time it would be kept, nothing of
    // it is kept, and the window signs in again: an edit made meanwhile is
    // never merged into it, nor overwritten by it.
    final storage = _container.read(optimizedStorageServiceProvider);
    final account = AccountScope.capture(_container);
    final revocations = storage.sessionRevocationRevision;
    final configs = storage.serverConfigRevision;
    final stillAdding = _container.read(accountAdditionOriginProvider) == null
        ? null
        : _container
              .read(accountAdditionOriginProvider.notifier)
              .stillInProgress();
    bool accountUnchanged() =>
        account.isCurrent &&
        storage.sessionRevocationRevision == revocations &&
        (stillAdding?.call() ?? true);
    bool unchanged() =>
        accountUnchanged() && storage.serverConfigRevision == configs;

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

    // The capture is the account's whose window it was: once another account
    // is in charge (on the same origin, say), it is never filed on that one.
    final opened = params.account;
    if (opened != null && opened != active.id) {
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        args: <String, String>{'reason': 'account'},
        debugMessage: 'the sign-in window was opened for another account',
      );
    }

    final outcome = await prevalidateProxySession(
      serverConfig: active,
      capture: ProxyAuthCapture(cookies: params.cookies, token: params.token),
      workerManager: _container.read(workerManagerProvider),
    );
    if (outcome is! ProxySessionRejected &&
        (await storage.getEffectiveActiveServerId() != active.id ||
            !unchanged())) {
      throw _signInAgain();
    }

    switch (outcome) {
      case ProxySessionAuthenticated(
        :final serverConfig,
        :final token,
        :final user,
      ):
        final committed = await _manager.commitPrevalidatedProxySession(
          serverConfig: serverConfig,
          token: token,
          user: user,
          // Asked once, right before the commit's first write; the saved
          // servers are checked again inside storage's section as the
          // candidate is staged ([configs]). The commit itself moves the
          // session, so only the addition is asked from then on.
          mayBegin: unchanged,
          configRevision: configs,
          canCommit: stillAdding,
        );
        if (!committed) throw _signInAgain();
      case ProxySessionNeedsSignIn(:final serverConfig):
        // The proxy let us through but Open WebUI still wants credentials.
        // Not an error: the UI shows its sign-in form next, whose requests
        // pass the proxy too -- so the cookie the window captured stays on
        // the account, as the phone's sign-in page carries it on.
        await _keepProxyCookie(serverConfig, unchanged);
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

  /// A capture that can no longer be kept as it was made: the window signs
  /// in again.
  static RpcError _signInAgain() => const RpcError(
    code: ConduitErrorCodes.sessionExpired,
    args: <String, String>{'reason': 'changed'},
    debugMessage: 'the account or its saved servers changed during sign-in',
  );

  /// Keeps the cookie a proxy sign-in captured in [config] -- the active
  /// account's connection with it -- on that account, not the shared
  /// address (`isCapturedSessionHeader`). Storage asks [unchanged] inside
  /// its own write, right before it writes; declined, the window signs in
  /// again. A reload of the account that then fails leaves its state
  /// unknown: never reported as kept, the window signs in again too.
  Future<void> _keepProxyCookie(
    ServerConfig config,
    bool Function() unchanged,
  ) async {
    if (!config.customHeaders.keys.any(isCapturedSessionHeader)) return;
    final storage = _container.read(optimizedStorageServiceProvider);
    final kept = await storage.saveCapturedSessionHeaders(
      config,
      canCommit: unchanged,
    );
    if (!kept) throw _signInAgain();
    _container
      ..invalidate(serverConfigsProvider)
      ..invalidate(activeServerProvider);
    try {
      await readSettled(_container, activeServerProvider.future);
    } on Object catch (error, stackTrace) {
      DebugLogger.error(
        'proxy-cookie-reload-failed',
        scope: 'daemon/auth',
        error: error,
        stackTrace: stackTrace,
      );
      throw _signInAgain();
    }
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

  Future<AuthSnapshot> setReviewerMode({required bool enabled}) async {
    await _container.read(reviewerModeProvider.notifier).setEnabled(enabled);
    return _snapshot();
  }

  static AuthPhase _mapPhase(AuthStatus status) => switch (status) {
    AuthStatus.initial => AuthPhase.initial,
    AuthStatus.loading => AuthPhase.loading,
    AuthStatus.authenticated => AuthPhase.authenticated,
    AuthStatus.unauthenticated => AuthPhase.unauthenticated,
    AuthStatus.tokenExpired => AuthPhase.tokenExpired,
    AuthStatus.error => AuthPhase.error,
    AuthStatus.credentialError => AuthPhase.credentialError,
  };

  /// The session once a check started here settles: `refresh` publishes
  /// loading first and the server's answer after (at most [limit]).
  Future<AuthSnapshot> _settledSnapshot({
    Duration limit = const Duration(seconds: 15),
  }) async {
    final deadline = DateTime.now().add(limit);
    while (DateTime.now().isBefore(deadline)) {
      final state = _container.read(authStateManagerProvider).value;
      if (state != null &&
          !state.isLoading &&
          state.status != AuthStatus.loading) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return _snapshot();
  }

  /// The session now. The active server is read settled: a sign-in or a
  /// renewal that just saved it has its provider rebuilding.
  Future<AuthSnapshot> _snapshot() async {
    ServerConfig? active;
    try {
      active = await readSettled(
        _container,
        activeServerProvider.future,
      ).timeout(const Duration(seconds: 5));
    } on Object {
      active = _container.read(activeServerProvider).asData?.value;
    }
    final state = _container.read(authStateManagerProvider).value;
    if (state == null) {
      return const AuthSnapshot(phase: AuthPhase.loading, isLoading: true);
    }
    final signedIn = state.isAuthenticated;
    if (signedIn) _twoStep = null;
    return AuthSnapshot(
      phase: _mapPhase(state.status),
      isAuthenticated: signedIn,
      isLoading: state.isLoading,
      // Whether, never what. The token stays in the secure store; every
      // authenticated request is made by this process.
      hasToken: state.hasValidToken,
      user: state.user == null ? null : _mapUser(state.user!),
      errorCode: _errorCodeFor(state),
      isReviewerMode: _container.read(reviewerModeProvider),
      twoStep: signedIn ? null : _currentTwoStep()?.dto,
      canRenewProxy: serverConfigHasProxyCookie(active),
    );
  }

  /// The core's `AuthState.error` is a human string, sometimes from the
  /// server. Errors cross the protocol as codes: the phase decides, and an
  /// error is read as the phone's sign-in page reads it (pending approval,
  /// an API key, a second step needed); anything else is a connection
  /// issue. The prose is dropped rather than shown in the server's locale.
  static String? _errorCodeFor(AuthState state) => switch (state.status) {
    AuthStatus.credentialError
        when classifySignInFailure(state.error ?? '') ==
            SignInFailure.browserSignInSessionExpired =>
      ConduitErrorCodes.sessionExpired,
    AuthStatus.credentialError => ConduitErrorCodes.invalidCredentials,
    AuthStatus.tokenExpired => ConduitErrorCodes.sessionExpired,
    AuthStatus.error when state.error != null => switch (classifySignInFailure(
      state.error!,
    )) {
      SignInFailure.failed => ConduitErrorCodes.connectionFailed,
      final failure => _signInFailureCode(failure),
    },
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

/// A sign-in at its second step: the server it began on, the username that
/// labels the authenticator entry, the server's step, and -- once a new
/// authenticator was confirmed -- the session waiting on its recovery codes
/// being seen.
final class _PendingTwoStep {
  _PendingTwoStep({
    required this.serverId,
    required this.account,
    required this.challenge,
  });

  final String? serverId;
  final String account;
  OpenWebUiTwoStepChallenge challenge;
  OpenWebUiTwoStepSession? issued;

  TwoStepStage get stage {
    if (issued != null) return TwoStepStage.recoveryCodes;
    return switch (challenge.kind) {
      OpenWebUiTwoStepKind.verify => TwoStepStage.verify,
      OpenWebUiTwoStepKind.enroll => TwoStepStage.enroll,
      OpenWebUiTwoStepKind.recover => TwoStepStage.recover,
    };
  }

  TwoStepChallenge get dto => TwoStepChallenge(
    stage: stage,
    account: account,
    expiresInSeconds: challenge.expiresIn.inSeconds,
    recoveryCodes: issued?.recoveryCodes ?? const <String>[],
  );
}
