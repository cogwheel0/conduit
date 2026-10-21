import 'package:conduit_core/auth/browser_sign_in/browser_sign_in_failure.dart';

import 'package:conduit/l10n/app_localizations.dart';

/// What to tell the user about a browser sign-in that failed with [failure],
/// or null when there is nothing to tell ([BrowserSignInFailure.isSilent]).
///
/// Exhaustive, so a new failure does not compile until it has a message.
String? browserSignInFailureMessage(
  AppLocalizations l10n,
  BrowserSignInFailure failure,
) => switch (failure) {
  BrowserSignInFailure.cancelled || BrowserSignInFailure.accountChanged => null,
  BrowserSignInFailure.browserUnavailable =>
    l10n.browserSignInErrorBrowserUnavailable,
  BrowserSignInFailure.authTabRequired =>
    l10n.browserSignInErrorAuthTabRequired,
  BrowserSignInFailure.presentationFailed =>
    l10n.browserSignInErrorPresentationFailed,
  BrowserSignInFailure.invalidClientId =>
    l10n.browserSignInErrorInvalidClientId,
  BrowserSignInFailure.proxySignInRequired =>
    l10n.browserSignInErrorProxySignInRequired,
  BrowserSignInFailure.probeNotFound => l10n.browserSignInErrorProbeNotFound,
  BrowserSignInFailure.providerNotConfigured =>
    l10n.browserSignInErrorProviderNotConfigured,
  BrowserSignInFailure.discoveryNotFound =>
    l10n.browserSignInErrorDiscoveryNotFound,
  BrowserSignInFailure.invalidIssuer => l10n.browserSignInErrorInvalidIssuer,
  BrowserSignInFailure.endpointMismatch =>
    l10n.browserSignInErrorEndpointMismatch,
  BrowserSignInFailure.insecureIdp => l10n.browserSignInErrorInsecureIdp,
  BrowserSignInFailure.callbackMismatch =>
    l10n.browserSignInErrorCallbackMismatch,
  BrowserSignInFailure.stateMismatch => l10n.browserSignInErrorStateMismatch,
  BrowserSignInFailure.issuerMismatch => l10n.browserSignInErrorIssuerMismatch,
  BrowserSignInFailure.nonceMismatch => l10n.browserSignInErrorNonceMismatch,
  BrowserSignInFailure.accessDenied => l10n.browserSignInErrorAccessDenied,
  BrowserSignInFailure.clientRejected => l10n.browserSignInErrorClientRejected,
  BrowserSignInFailure.idpError => l10n.browserSignInErrorIdpError,
  BrowserSignInFailure.refreshExpired => l10n.browserSignInErrorRefreshExpired,
  BrowserSignInFailure.configMismatch => l10n.browserSignInErrorConfigMismatch,
  BrowserSignInFailure.exchangeDisabled =>
    l10n.browserSignInErrorExchangeDisabled,
  BrowserSignInFailure.serverTooOld => l10n.browserSignInErrorServerTooOld,
  BrowserSignInFailure.cannotDetermineClient =>
    l10n.browserSignInErrorCannotDetermineClient,
  BrowserSignInFailure.accessProhibited =>
    l10n.browserSignInErrorAccessProhibited,
  BrowserSignInFailure.missingClaims => l10n.browserSignInErrorMissingClaims,
  BrowserSignInFailure.userNotFound => l10n.browserSignInErrorUserNotFound,
  BrowserSignInFailure.userMismatch => l10n.browserSignInErrorUserMismatch,
  BrowserSignInFailure.accountPendingApproval =>
    l10n.signInAccountPendingApproval,
  BrowserSignInFailure.twoStepRequired =>
    l10n.signInTwoStepVerificationRequired,
  BrowserSignInFailure.tokenRejectedByServer =>
    l10n.browserSignInErrorTokenRejected,
  BrowserSignInFailure.authenticationChanged =>
    l10n.browserSignInErrorAuthenticationChanged,
  BrowserSignInFailure.rateLimited => l10n.browserSignInErrorRateLimited,
  BrowserSignInFailure.network => l10n.browserSignInErrorNetwork,
  BrowserSignInFailure.timeout => l10n.requestTimedOut,
  BrowserSignInFailure.tls => l10n.browserSignInErrorTls,
  BrowserSignInFailure.serverError => l10n.browserSignInErrorServerError,
  BrowserSignInFailure.failed => l10n.genericSignInFailed,
};

/// Whether [failure] is better answered by the in-app sign-in: the system
/// browser cannot run it here, or something in front of the server wants a
/// sign-in of its own that only the in-app page can carry.
bool browserSignInSuggestsInApp(BrowserSignInFailure failure) =>
    switch (failure) {
      BrowserSignInFailure.browserUnavailable ||
      BrowserSignInFailure.authTabRequired ||
      BrowserSignInFailure.presentationFailed ||
      BrowserSignInFailure.proxySignInRequired => true,
      _ => false,
    };

/// Whether [failure] is about the browser sign-in settings, which the user
/// should open to fix it.
bool browserSignInSuggestsSettings(BrowserSignInFailure failure) =>
    switch (failure) {
      BrowserSignInFailure.invalidClientId ||
      BrowserSignInFailure.discoveryNotFound ||
      BrowserSignInFailure.invalidIssuer ||
      BrowserSignInFailure.endpointMismatch ||
      BrowserSignInFailure.insecureIdp ||
      BrowserSignInFailure.clientRejected => true,
      _ => false,
    };

/// Whether [failure] means the identity provider was not found from Open
/// WebUI's sign-in, so its issuer has to be entered.
bool browserSignInNeedsIssuer(BrowserSignInFailure failure) =>
    failure == BrowserSignInFailure.discoveryNotFound ||
    failure == BrowserSignInFailure.invalidIssuer ||
    failure == BrowserSignInFailure.endpointMismatch;
