import 'dart:io';

import 'package:dio/dio.dart';

import 'package:conduit_core/auth/oidc/oidc_exception.dart';
import 'package:conduit_core/models/oauth_login_probe.dart';
import 'package:conduit_core/ports/browser_auth_port.dart';

/// Why a sign-in through the system browser, or the renewal of one, did not
/// sign in.
///
/// Each is [isSilent] (nothing to tell the user), [isTransient] (trying again
/// later may work, so a renewal keeps the saved sign-in) or else terminal (a
/// renewal ends the saved sign-in, and the user signs in again).
enum BrowserSignInFailure {
  /// The user closed the browser, or a newer sign-in replaced this one.
  cancelled,

  /// The account being signed in stopped being the one in use while the
  /// browser was open: another was switched to, or its addition cancelled.
  accountChanged,

  /// No browser could run the sign-in.
  browserUnavailable,

  /// The provider's redirect can only come back through an Android Auth Tab,
  /// which the default browser does not support (Google).
  authTabRequired,

  /// The browser could not be shown over the app.
  presentationFailed,

  /// The Google client ID is not one: its redirect cannot be derived.
  invalidClientId,

  /// A reverse proxy answered for Open WebUI and wants a sign-in of its own.
  proxySignInRequired,

  /// Open WebUI has no sign-in for the provider (404 on its login route).
  probeNotFound,

  /// Open WebUI does not have the provider set up for its token exchange.
  providerNotConfigured,

  /// No identity provider was found for Open WebUI's sign-in: the issuer has
  /// to be entered.
  discoveryNotFound,

  /// The issuer entered is not a URL.
  invalidIssuer,

  /// The issuer entered is not the provider Open WebUI signs in with.
  endpointMismatch,

  /// The identity provider is not served over `https`.
  insecureIdp,

  /// The browser came back somewhere other than the redirect asked for.
  callbackMismatch,

  /// The sign-in that came back was not the one this app started.
  stateMismatch,

  /// The sign-in came back from another issuer (RFC 9207).
  issuerMismatch,

  /// The identity provider's ID token was not for this sign-in.
  nonceMismatch,

  /// The user, or the identity provider, declined the sign-in.
  accessDenied,

  /// The identity provider does not know or allow Conduit's client.
  clientRejected,

  /// The identity provider failed the sign-in for another reason.
  idpError,

  /// The identity provider no longer accepts the saved refresh token.
  refreshExpired,

  /// The server's browser sign-in settings changed since the account signed
  /// in, so its refresh token belongs to another client or provider.
  configMismatch,

  /// Open WebUI has token exchange off (`ENABLE_OAUTH_TOKEN_EXCHANGE`).
  exchangeDisabled,

  /// The server predates token exchange (Open WebUI 0.8.0).
  serverTooOld,

  /// Open WebUI only trusts tokens of listed clients, and could not tell
  /// which client this one was issued to.
  cannotDetermineClient,

  /// Open WebUI refused the account: an untrusted client, or an email domain
  /// it does not allow.
  accessProhibited,

  /// The identity provider's user info lacked the `sub` or email claim.
  missingClaims,

  /// No Open WebUI user goes with this identity yet: one sign-in on the web
  /// creates it.
  userNotFound,

  /// The exchange signed in as another Open WebUI user than the account.
  userMismatch,

  /// Open WebUI holds the account for an administrator's approval.
  accountPendingApproval,

  /// Open WebUI asks for a two-step verification code, which a renewal
  /// cannot answer. An interactive sign-in takes the step instead.
  twoStepRequired,

  /// Open WebUI could not check the token with the identity provider.
  tokenRejectedByServer,

  /// The account's sign-in changed on the server while this one ran.
  authenticationChanged,

  /// Too many requests: Open WebUI or the identity provider is limiting them.
  rateLimited,

  /// Open WebUI or the identity provider could not be reached.
  network,

  /// Open WebUI or the identity provider did not answer in time.
  timeout,

  /// A TLS certificate was not trusted.
  tls,

  /// Open WebUI or the identity provider failed (5xx).
  serverError,

  /// Anything else.
  failed;

  /// Nothing went wrong that the user needs to hear about.
  bool get isSilent => this == cancelled || this == accountChanged;

  /// Trying again later may succeed without the user doing anything, so a
  /// renewal that failed so keeps the saved sign-in.
  bool get isTransient => switch (this) {
    proxySignInRequired ||
    tokenRejectedByServer ||
    authenticationChanged ||
    rateLimited ||
    network ||
    timeout ||
    tls ||
    serverError ||
    failed => true,
    _ => false,
  };

  /// A renewal that failed so ends the saved sign-in: the user has to sign
  /// in again.
  bool get isTerminal => !isSilent && !isTransient;

  /// The message a renewal that failed for good leaves in the auth state, for
  /// the sign-in page to explain.
  String get renewalErrorMessage => switch (this) {
    twoStepRequired => 'twoStepVerificationRequired',
    accountPendingApproval => 'accountPendingApproval',
    _ => 'browserSignInSessionExpired',
  };
}

/// A sign-in through the system browser, or its renewal, failed with
/// [failure]. Carries no URL, code or token, so it is safe to log.
final class BrowserSignInException implements Exception {
  const BrowserSignInException(this.failure);

  final BrowserSignInFailure failure;

  @override
  String toString() => 'BrowserSignInException(${failure.name})';
}

/// The failure for an identity provider step that threw [error].
///
/// For a [renewal], an answer that is not an OAuth error -- a redirect, a
/// page, an unexpected status, as a firewall or an upgrade in progress
/// gives -- is transient: only the provider refusing the refresh token or
/// the client ends a saved sign-in.
BrowserSignInFailure browserSignInFailureForOidc(
  OidcException error, {
  bool renewal = false,
}) => switch (error.kind) {
  OidcFailureKind.redirected ||
  OidcFailureKind.invalidResponse ||
  OidcFailureKind.responseTooLarge when renewal =>
    BrowserSignInFailure.serverError,
  OidcFailureKind.unexpectedStatus when renewal && error.errorCode == null =>
    BrowserSignInFailure.serverError,
  _ => _failureForOidcKind(error.kind),
};

BrowserSignInFailure _failureForOidcKind(OidcFailureKind kind) =>
    switch (kind) {
      OidcFailureKind.insecureEndpoint => BrowserSignInFailure.insecureIdp,
      OidcFailureKind.discoveryNotFound ||
      OidcFailureKind.invalidMetadata => BrowserSignInFailure.discoveryNotFound,
      OidcFailureKind.invalidIssuer => BrowserSignInFailure.invalidIssuer,
      OidcFailureKind.endpointMismatch => BrowserSignInFailure.endpointMismatch,
      OidcFailureKind.callbackMismatch => BrowserSignInFailure.callbackMismatch,
      OidcFailureKind.stateMismatch => BrowserSignInFailure.stateMismatch,
      OidcFailureKind.issuerMismatch => BrowserSignInFailure.issuerMismatch,
      OidcFailureKind.nonceMismatch => BrowserSignInFailure.nonceMismatch,
      OidcFailureKind.accessDenied => BrowserSignInFailure.accessDenied,
      OidcFailureKind.invalidGrant => BrowserSignInFailure.refreshExpired,
      OidcFailureKind.clientRejected => BrowserSignInFailure.clientRejected,
      OidcFailureKind.rateLimited => BrowserSignInFailure.rateLimited,
      OidcFailureKind.serverError => BrowserSignInFailure.serverError,
      OidcFailureKind.network => BrowserSignInFailure.network,
      OidcFailureKind.timeout => BrowserSignInFailure.timeout,
      OidcFailureKind.tls => BrowserSignInFailure.tls,
      OidcFailureKind.authorizationFailed ||
      OidcFailureKind.tokenRequestFailed ||
      OidcFailureKind.invalidResponse ||
      OidcFailureKind.redirected ||
      OidcFailureKind.responseTooLarge ||
      OidcFailureKind.unexpectedStatus => BrowserSignInFailure.idpError,
    };

/// The failure for a browser that did not come back with a callback, or null
/// for one that did.
BrowserSignInFailure? browserSignInFailureForResult(BrowserAuthResult result) {
  return switch (result.outcome) {
    BrowserAuthOutcome.success when result.callbackUri != null => null,
    BrowserAuthOutcome.success => BrowserSignInFailure.callbackMismatch,
    BrowserAuthOutcome.cancelled => BrowserSignInFailure.cancelled,
    BrowserAuthOutcome.unavailable ||
    BrowserAuthOutcome.failed => switch (result.errorCode) {
      BrowserAuthErrorCodes.authTabRequired =>
        BrowserSignInFailure.authTabRequired,
      BrowserAuthErrorCodes.presentationFailed =>
        BrowserSignInFailure.presentationFailed,
      BrowserAuthErrorCodes.unexpectedCallback =>
        BrowserSignInFailure.callbackMismatch,
      BrowserAuthErrorCodes.superseded => BrowserSignInFailure.cancelled,
      BrowserAuthErrorCodes.invalidRequest => BrowserSignInFailure.failed,
      _ => BrowserSignInFailure.browserUnavailable,
    },
  };
}

/// The failure for [error] from Open WebUI's login route.
BrowserSignInFailure browserSignInFailureForProbe(Object error) {
  if (error is OAuthLoginProbeException) {
    return switch (error.failure) {
      OAuthLoginProbeFailure.proxySignInRequired =>
        BrowserSignInFailure.proxySignInRequired,
      OAuthLoginProbeFailure.notFound => BrowserSignInFailure.probeNotFound,
    };
  }
  if (error is DioException) {
    return _transportFailure(error) ??
        _statusFailure(error.response?.statusCode);
  }
  return BrowserSignInFailure.failed;
}

/// The failure for a refusal from Open WebUI's token exchange, told apart by
/// its status and `detail` as Open WebUI 0.8 to 0.12 word them.
///
/// For a [renewal] -- an account that has exchanged before -- a 404 without
/// Open WebUI's word that the provider is not configured is something in
/// front of the server, such as a proxy while it restarts: transient, where
/// a sign-in or a check calls it a server too old to exchange.
BrowserSignInFailure browserSignInFailureForExchange(
  Object error, {
  bool renewal = false,
}) {
  if (error is! DioException) return BrowserSignInFailure.failed;
  final transport = _transportFailure(error);
  if (transport != null) return transport;

  final response = error.response;
  final status = response?.statusCode;
  final data = response?.data;
  // A refusal from Open WebUI is JSON. A page is something in front of it.
  if (data is! Map) {
    if (status == 401 || status == 403) {
      return BrowserSignInFailure.proxySignInRequired;
    }
    if (status == 404) {
      return renewal
          ? BrowserSignInFailure.serverError
          : BrowserSignInFailure.serverTooOld;
    }
    return _statusFailure(status);
  }
  final rawDetail = data['detail'];
  final detail = rawDetail is String ? rawDetail.toLowerCase() : '';
  return switch (status) {
    400 when detail.contains('determine which client') =>
      BrowserSignInFailure.cannotDetermineClient,
    400 when detail.contains('missing required') =>
      BrowserSignInFailure.missingClaims,
    400 => BrowserSignInFailure.tokenRejectedByServer,
    401 => BrowserSignInFailure.proxySignInRequired,
    403 when detail.contains('token exchange is disabled') =>
      BrowserSignInFailure.exchangeDisabled,
    403 when detail.contains('user not found') =>
      BrowserSignInFailure.userNotFound,
    403 => BrowserSignInFailure.accessProhibited,
    // `Provider '…' is not configured`; a bare `Not Found` is a server with
    // no exchange route at all.
    404 when detail.contains('not configured') =>
      BrowserSignInFailure.providerNotConfigured,
    404 when renewal => BrowserSignInFailure.serverError,
    404 => BrowserSignInFailure.serverTooOld,
    409 => BrowserSignInFailure.authenticationChanged,
    _ => _statusFailure(status),
  };
}

BrowserSignInFailure? _transportFailure(DioException error) {
  return switch (error.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.transformTimeout => BrowserSignInFailure.timeout,
    DioExceptionType.badCertificate => BrowserSignInFailure.tls,
    DioExceptionType.connectionError || DioExceptionType.unknown =>
      error.error is HandshakeException || error.error is TlsException
          ? BrowserSignInFailure.tls
          : BrowserSignInFailure.network,
    DioExceptionType.cancel => BrowserSignInFailure.cancelled,
    DioExceptionType.badResponse => null,
  };
}

BrowserSignInFailure _statusFailure(int? status) {
  if (status == null) return BrowserSignInFailure.failed;
  if (status == 429) return BrowserSignInFailure.rateLimited;
  if (status >= 500) return BrowserSignInFailure.serverError;
  return BrowserSignInFailure.failed;
}
