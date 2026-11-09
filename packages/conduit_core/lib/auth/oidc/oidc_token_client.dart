import 'dart:async';

import 'package:conduit_core/auth/jwt_claims.dart';
import 'package:conduit_core/auth/oidc/oidc_authorization.dart';
import 'package:conduit_core/auth/oidc/oidc_exception.dart';
import 'package:conduit_core/auth/oidc/oidc_http.dart';

/// The tokens a token endpoint issued.
///
/// The access token is for Open WebUI's token exchange and nothing else: it
/// is kept in memory only. An ID token, when one came, has been checked and
/// dropped; only the user it names is kept, as [subject].
final class OidcTokenSet {
  const OidcTokenSet({
    required this.accessToken,
    this.refreshToken,
    this.scope,
    this.expiresAt,
    this.subject,
  });

  final String accessToken;

  /// The refresh token to keep, which after a refresh is the previous one
  /// when the provider does not rotate it.
  final String? refreshToken;

  /// The scopes granted, space-separated, when the provider said or a
  /// previous grant did.
  final String? scope;

  /// When [accessToken] expires, when the provider said.
  final DateTime? expiresAt;

  /// The user the provider signed in (the ID token's `sub`), when a code
  /// exchange came with an ID token that named one.
  final String? subject;

  @override
  String toString() =>
      'OidcTokenSet(refreshToken: ${refreshToken != null}, '
      'expiresAt: ${expiresAt?.toIso8601String()})';
}

/// Talks to a provider's token and revocation endpoints as a public client:
/// the client ID is sent, and no secret.
final class OidcTokenClient {
  OidcTokenClient(this._http, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final OidcHttp _http;
  final DateTime Function() _now;

  /// Redeems the [code] the callback of [request] carried.
  ///
  /// An ID token in the answer must carry the request's nonce.
  ///
  /// Throws [OidcException] for an error answer (see [oidcErrorResponse]) or
  /// a malformed one.
  Future<OidcTokenSet> exchangeCode(
    OidcAuthorizationRequest request,
    String code,
  ) async {
    final response = await _http.postForm(request.metadata.tokenEndpoint, {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': request.redirectUri.toString(),
      'client_id': request.clientId,
      'code_verifier': request.pkce.verifier,
    });
    return _tokenSet(response, nonce: request.nonce);
  }

  /// Trades [refreshToken] for new tokens.
  ///
  /// The answer keeps [refreshToken] when the provider issues no new one, and
  /// [scope], the scopes granted before, when it names none. No scope is
  /// sent, so the grant is never narrowed.
  ///
  /// Throws [OidcException]: [OidcFailureKind.invalidGrant] when the refresh
  /// token is no longer good.
  Future<OidcTokenSet> refresh({
    required Uri tokenEndpoint,
    required String clientId,
    required String refreshToken,
    String? scope,
  }) async {
    final response = await _http.postForm(tokenEndpoint, {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': clientId,
    });
    return _tokenSet(
      response,
      previousRefreshToken: refreshToken,
      previousScope: scope,
    );
  }

  /// Revokes [token] (RFC 7009), within [timeout] when given.
  ///
  /// Never throws: a sign-out goes ahead whatever the provider says. Returns
  /// whether the provider confirmed it.
  Future<bool> revoke({
    required Uri revocationEndpoint,
    required String clientId,
    required String token,
    String tokenTypeHint = 'refresh_token',
    Duration? timeout,
  }) async {
    try {
      var request = _http.postForm(revocationEndpoint, {
        'token': token,
        'token_type_hint': tokenTypeHint,
        'client_id': clientId,
      });
      if (timeout != null) request = request.timeout(timeout);
      return (await request).isSuccess;
    } catch (_) {
      return false;
    }
  }

  OidcTokenSet _tokenSet(
    OidcHttpResponse response, {
    String? nonce,
    String? previousRefreshToken,
    String? previousScope,
  }) {
    if (!response.isSuccess) throw oidcErrorResponse(response);
    final json = response.json;
    if (json == null) {
      throw const OidcException(OidcFailureKind.invalidResponse);
    }
    final accessToken = json['access_token'];
    final tokenType = json['token_type'];
    final refreshToken = json['refresh_token'];
    final scope = json['scope'];
    if (accessToken is! String ||
        accessToken.isEmpty ||
        accessToken.length > 16384 ||
        (tokenType != null &&
            (tokenType is! String || tokenType.toLowerCase() != 'bearer')) ||
        (refreshToken != null && refreshToken is! String) ||
        (scope != null && scope is! String)) {
      throw const OidcException(OidcFailureKind.invalidResponse);
    }
    final idClaims = nonce != null && json.containsKey('id_token')
        ? _requireNonce(json['id_token'], nonce)
        : null;
    final subject = idClaims?['sub'];

    final expiresIn = _seconds(json['expires_in']);
    final issuedRefreshToken = refreshToken as String?;
    final grantedScope = scope as String?;
    return OidcTokenSet(
      accessToken: accessToken,
      refreshToken: issuedRefreshToken == null || issuedRefreshToken.isEmpty
          ? previousRefreshToken
          : issuedRefreshToken,
      scope: grantedScope == null || grantedScope.isEmpty
          ? previousScope
          : grantedScope,
      expiresAt: expiresIn == null
          ? null
          : _now().toUtc().add(Duration(seconds: expiresIn)),
      subject: subject is String && subject.isNotEmpty ? subject : null,
    );
  }
}

/// Checks that [idToken] carries [nonce], and returns its claims. Only the
/// payload is read: the token is not used for anything but naming the user,
/// so its signature is not checked, and it is not kept.
Map<String, dynamic> _requireNonce(Object? idToken, String nonce) {
  final claims = idToken is String ? jwtClaims(idToken) : null;
  if (claims == null) {
    throw const OidcException(OidcFailureKind.invalidResponse);
  }
  if (claims['nonce'] != nonce) {
    throw const OidcException(OidcFailureKind.nonceMismatch);
  }
  return claims;
}

/// A lifetime in seconds, as a number or numeric string (as some providers
/// send it), or null when it is missing or not a plausible lifetime.
int? _seconds(Object? value) {
  final seconds = switch (value) {
    final num number when number.isFinite => number.toInt(),
    final String text => int.tryParse(text.trim()),
    _ => null,
  };
  if (seconds == null || seconds <= 0 || seconds > 315360000) return null;
  return seconds;
}
