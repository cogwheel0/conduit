/// Why a step of a sign-in with an identity provider failed.
enum OidcFailureKind {
  /// An endpoint of the identity provider is not `https`.
  insecureEndpoint,

  /// No discovery document described the authorization endpoint Open WebUI
  /// signs in with: the issuer has to be entered by hand.
  discoveryNotFound,

  /// The issuer entered by hand is not an absolute URL.
  invalidIssuer,

  /// The discovery document entered by hand describes a different
  /// authorization endpoint than the one Open WebUI signs in with.
  endpointMismatch,

  /// A discovery document was malformed or contradicted itself.
  invalidMetadata,

  /// The browser came back to a different redirect URI than the one the
  /// sign-in asked for.
  callbackMismatch,

  /// The callback's `state` was not the one the sign-in sent.
  stateMismatch,

  /// The callback's `iss` named a different issuer (RFC 9207), or left it out
  /// although the provider advertises it.
  issuerMismatch,

  /// The ID token did not carry the sign-in's nonce.
  nonceMismatch,

  /// The user, or the provider on their behalf, declined the sign-in.
  accessDenied,

  /// The provider answered the authorization request with another error.
  authorizationFailed,

  /// The provider refused the grant: the code was used or expired, or the
  /// refresh token was revoked or expired (`invalid_grant`).
  invalidGrant,

  /// The provider does not know or does not allow the client
  /// (`invalid_client`, `unauthorized_client`).
  clientRejected,

  /// The token endpoint answered with another OAuth error.
  tokenRequestFailed,

  /// An answer was not the JSON its endpoint is specified to return.
  invalidResponse,

  /// An endpoint answered with a redirect, which is never followed.
  redirected,

  /// An answer was larger than any discovery document or token response.
  responseTooLarge,

  /// The provider is limiting requests (HTTP 429).
  rateLimited,

  /// The provider failed (HTTP 5xx).
  serverError,

  /// The provider answered with an HTTP status nothing above explains.
  unexpectedStatus,

  /// The provider could not be reached.
  network,

  /// The provider did not answer in time.
  timeout,

  /// The provider's TLS certificate was not trusted.
  tls,
}

/// A failed step of a sign-in with an identity provider.
///
/// Carries no URL, code or token, so it is safe to log.
final class OidcException implements Exception {
  const OidcException(this.kind, {String? errorCode, this.statusCode})
    : _errorCode = errorCode;

  final OidcFailureKind kind;
  final String? _errorCode;

  /// The HTTP status the failure came with, if any.
  final int? statusCode;

  /// The OAuth `error` code the provider answered with, such as
  /// `invalid_grant`, when it is one: a provider's free-form text is dropped.
  String? get errorCode {
    final code = _errorCode;
    if (code == null || !_oauthErrorCode.hasMatch(code)) return null;
    return code;
  }

  /// Whether trying again later may succeed without the user doing anything:
  /// the provider was unreachable, slow, busy or failing.
  bool get isTransient => switch (kind) {
    OidcFailureKind.network ||
    OidcFailureKind.timeout ||
    OidcFailureKind.tls ||
    OidcFailureKind.rateLimited ||
    OidcFailureKind.serverError => true,
    _ => false,
  };

  @override
  String toString() {
    final details = [
      if (errorCode case final code?) 'error: $code',
      if (statusCode case final status?) 'status: $status',
    ];
    return details.isEmpty
        ? 'OidcException(${kind.name})'
        : 'OidcException(${kind.name}, ${details.join(', ')})';
  }
}

// RFC 6749 limits `error` to printable ASCII without quotes or backslashes;
// the registered codes are all of this shape.
final RegExp _oauthErrorCode = RegExp(r'^[A-Za-z0-9_.\-]{1,64}$');
