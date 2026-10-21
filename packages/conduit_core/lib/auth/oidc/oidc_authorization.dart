import 'dart:convert';
import 'dart:math';

import 'package:conduit_core/auth/oidc/oidc_exception.dart';
import 'package:conduit_core/auth/oidc/oidc_metadata.dart';
import 'package:conduit_core/auth/oidc/oidc_pkce.dart';

/// The redirect URI a browser sign-in comes back to, but for Google's.
final Uri oidcConduitRedirectUri = Uri(
  scheme: 'conduit',
  host: 'oauth',
  path: '/callback',
);

final RegExp _googleClientId = RegExp(
  r'^([0-9]+-[a-z0-9]+)\.apps\.googleusercontent\.com$',
  caseSensitive: false,
);

/// Google's redirect URI for a native client: the client ID reversed into a
/// scheme (`com.googleusercontent.apps.<id>:/oauth2redirect`). Google accepts
/// no custom scheme of the app's choosing, so its sign-in needs an iOS-type
/// client. Null when [clientId] is not a Google client ID.
Uri? oidcGoogleRedirectUri(String clientId) {
  final match = _googleClientId.firstMatch(clientId.trim());
  if (match == null) return null;
  return Uri(
    scheme: 'com.googleusercontent.apps.${match.group(1)!.toLowerCase()}',
    path: '/oauth2redirect',
  );
}

/// The redirect URI a sign-in with [provider] registers and comes back to:
/// [oidcGoogleRedirectUri] for Google, which is null when [clientId] is not a
/// Google client ID, and [oidcConduitRedirectUri] for everything else.
Uri? oidcRedirectUriFor({required String provider, required String clientId}) {
  if (provider.toLowerCase() == 'google') {
    return oidcGoogleRedirectUri(clientId);
  }
  return oidcConduitRedirectUri;
}

/// One authorization-code sign-in with PKCE: the URL to open in the browser,
/// and what its callback must carry.
///
/// Holds the PKCE verifier, so it lives only as long as the sign-in, in
/// memory.
final class OidcAuthorizationRequest {
  OidcAuthorizationRequest._({
    required this.metadata,
    required this.provider,
    required this.clientId,
    required this.redirectUri,
    required this.scope,
    required this.state,
    required this.nonce,
    required this.pkce,
    required this.url,
  });

  /// Starts a sign-in with the provider [metadata] describes, for the public
  /// client [clientId].
  ///
  /// Asks for `openid email profile`, and `offline_access` when the provider
  /// lists it, so the sign-in comes with a refresh token; Google is asked
  /// with `access_type=offline` instead. [audience] is passed on as Open
  /// WebUI's own sign-in passes it. [prompt] (`login`, `select_account`) and
  /// [loginHint] are sent only when given.
  factory OidcAuthorizationRequest.create({
    required OidcProviderMetadata metadata,
    required String provider,
    required String clientId,
    required Uri redirectUri,
    String? audience,
    String? prompt,
    String? loginHint,
    Random? random,
  }) {
    final isGoogle = provider.toLowerCase() == 'google';
    final scope = [
      'openid',
      'email',
      'profile',
      if (!isGoogle && metadata.supportsOfflineAccess) 'offline_access',
    ].join(' ');
    final state = oidcRandomToken(random: random);
    final nonce = oidcRandomToken(random: random);
    final pkce = OidcPkce.generate(random: random);
    final endpoint = metadata.authorizationEndpoint;
    final url = endpoint.replace(
      queryParameters: {
        ...endpoint.queryParameters,
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirectUri.toString(),
        'scope': scope,
        'state': state,
        'nonce': nonce,
        'code_challenge': pkce.challenge,
        'code_challenge_method': OidcPkce.method,
        if (isGoogle) 'access_type': 'offline',
        'audience': ?_present(audience),
        'prompt': ?_present(prompt),
        'login_hint': ?_present(loginHint),
      },
    );
    return OidcAuthorizationRequest._(
      metadata: metadata,
      provider: provider,
      clientId: clientId,
      redirectUri: redirectUri,
      scope: scope,
      state: state,
      nonce: nonce,
      pkce: pkce,
      url: url,
    );
  }

  final OidcProviderMetadata metadata;
  final String provider;
  final String clientId;
  final Uri redirectUri;

  /// The scopes asked for, space-separated.
  final String scope;
  final String state;
  final String nonce;
  final OidcPkce pkce;

  /// The URL to open in the browser.
  final Uri url;

  /// The authorization code [callback] carries, once it is shown to answer
  /// this sign-in.
  ///
  /// [callback] must be [redirectUri] exactly (scheme, host and path, with no
  /// port, user info or fragment), and carry this sign-in's `state`, which is
  /// checked before anything else the callback says, an `error` included.
  /// An `iss` must name the provider (RFC 9207), and must be there when the
  /// provider advertises it.
  ///
  /// Throws [OidcException] for a callback that fails any of these, or that
  /// carries an error.
  String codeFromCallback(Uri callback) {
    if (!_isRedirectUri(callback)) {
      throw const OidcException(OidcFailureKind.callbackMismatch);
    }
    final parameters = callback.queryParametersAll;
    String? single(String name) {
      final values = parameters[name];
      if (values == null || values.isEmpty) return null;
      if (values.length > 1) {
        throw const OidcException(OidcFailureKind.callbackMismatch);
      }
      return values.single;
    }

    final returnedState = single('state');
    if (returnedState == null || !_constantTimeEquals(returnedState, state)) {
      throw const OidcException(OidcFailureKind.stateMismatch);
    }

    final issuer = single('iss');
    if (issuer != null
        ? !metadata.isIssuer(issuer)
        : metadata.authorizationResponseIssParameterSupported) {
      throw const OidcException(OidcFailureKind.issuerMismatch);
    }

    final error = single('error');
    if (error != null) {
      throw OidcException(switch (error) {
        'access_denied' => OidcFailureKind.accessDenied,
        'unauthorized_client' ||
        'invalid_client' => OidcFailureKind.clientRejected,
        _ => OidcFailureKind.authorizationFailed,
      }, errorCode: error);
    }

    final code = single('code');
    if (code == null || code.isEmpty || code.length > 4096) {
      throw const OidcException(OidcFailureKind.invalidResponse);
    }
    return code;
  }

  bool _isRedirectUri(Uri callback) =>
      callback.scheme.toLowerCase() == redirectUri.scheme.toLowerCase() &&
      callback.hasAuthority == redirectUri.hasAuthority &&
      callback.host.toLowerCase() == redirectUri.host.toLowerCase() &&
      callback.path == redirectUri.path &&
      !callback.hasPort &&
      callback.userInfo.isEmpty &&
      callback.fragment.isEmpty;

  @override
  String toString() => 'OidcAuthorizationRequest($provider, <redacted>)';
}

String? _present(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// Compares in time that depends only on the lengths, so a forged `state`
/// learns nothing from how long it took to be refused.
bool _constantTimeEquals(String a, String b) {
  final left = utf8.encode(a);
  final right = utf8.encode(b);
  var difference = left.length ^ right.length;
  for (var i = 0; i < left.length; i++) {
    difference |= left[i] ^ (i < right.length ? right[i] : 0);
  }
  return difference == 0;
}
