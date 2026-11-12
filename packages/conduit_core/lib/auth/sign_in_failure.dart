/// Why an Open WebUI sign-in failed, read from the message the auth state
/// manager publishes (`AuthState.error`) or throws for it.
///
/// The manager words its failures as fixed English phrases and a few codes
/// (`accountPendingApproval`, `apiKeyNotSupported`, ...), never server prose,
/// and each app shows its own words for them. Reading them here, beside the
/// phrases the manager uses, keeps an app from looking for words the manager
/// never says.
enum SignInFailure {
  /// Saved credentials met an account that now asks for a second step:
  /// sign in again by hand to answer it.
  twoStepRequired,

  /// The second step was answered, but the session it issued was refused.
  twoStepSessionRejected,

  /// The account waits for an administrator's approval.
  accountPendingApproval,

  /// An API key (`sk-…`) was given where a session token is needed.
  apiKeyNotSupported,

  /// A saved API key can no longer sign in.
  apiKeyNoLongerSupported,

  /// The server does not offer LDAP sign-in.
  ldapNotEnabled,

  /// The server refused the credentials or the token.
  invalidCredentials,

  /// The server answered with a redirect.
  serverRedirect,

  /// The request never reached the server.
  unreachable,

  /// The server took too long to answer.
  timedOut,

  /// Anything else.
  failed,
}

/// The message the manager gives a sign-in that never reached the server.
const String signInUnreachableMessage = 'Unable to connect to server';

/// The message the manager gives a sign-in the server was too slow for.
const String signInTimedOutMessage = 'Sign-in request timed out';

/// Reads a failed sign-in's [error]: an `AuthState.error`, or the text of
/// the exception a sign-in threw (a raw `SocketException` or timeout reads
/// as the manager's own phrase for it would).
SignInFailure classifySignInFailure(String error) {
  if (error.contains('twoStepVerificationRequired')) {
    return SignInFailure.twoStepRequired;
  }
  if (error.contains('twoStepSessionRejected')) {
    return SignInFailure.twoStepSessionRejected;
  }
  if (error.contains('accountPendingApproval')) {
    return SignInFailure.accountPendingApproval;
  }
  if (error.contains('apiKeyNotSupported')) {
    return SignInFailure.apiKeyNotSupported;
  }
  if (error.contains('apiKeyNoLongerSupported')) {
    return SignInFailure.apiKeyNoLongerSupported;
  }
  if (error.contains('LDAP authentication is not enabled')) {
    return SignInFailure.ldapNotEnabled;
  }
  if (error.contains('401') || error.contains('Unauthorized')) {
    return SignInFailure.invalidCredentials;
  }
  if (error.contains('redirect')) return SignInFailure.serverRedirect;
  // In the manager's order and case: a timeout before a lost connection.
  final lower = error.toLowerCase();
  if (lower.contains('timeout') || error.contains(signInTimedOutMessage)) {
    return SignInFailure.timedOut;
  }
  if (lower.contains('socketexception') ||
      error.contains(signInUnreachableMessage)) {
    return SignInFailure.unreachable;
  }
  return SignInFailure.failed;
}
