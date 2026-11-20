import 'package:meta/meta.dart';

/// Where an Open WebUI server sends a browser to sign in with one of its
/// OAuth providers: what `GET /oauth/{provider}/login` redirects to.
///
/// Only what a browser sign-in of Conduit's own needs. Open WebUI's client
/// id, state and the rest of its query are dropped: they belong to its own
/// sign-in, never to Conduit's.
@immutable
final class OAuthLoginProbe {
  const OAuthLoginProbe({
    required this.authorizationEndpoint,
    required this.redirectUri,
    this.audience,
  });

  /// The identity provider's authorization endpoint, without a query or
  /// fragment.
  final Uri authorizationEndpoint;

  /// Open WebUI's own callback, as the redirect named it. It can name another
  /// host than the address in use (`WEBUI_URL`), so only its path is checked.
  final Uri redirectUri;

  /// The `audience` Open WebUI asks the provider for, when it asks for one.
  final String? audience;

  @override
  bool operator ==(Object other) =>
      other is OAuthLoginProbe &&
      other.authorizationEndpoint == authorizationEndpoint &&
      other.redirectUri == redirectUri &&
      other.audience == audience;

  @override
  int get hashCode => Object.hash(authorizationEndpoint, redirectUri, audience);

  @override
  String toString() => 'OAuthLoginProbe(${authorizationEndpoint.host})';
}

/// Why the login route did not say where its provider signs in.
enum OAuthLoginProbeFailure {
  /// Something in front of the server answered instead of Open WebUI: a
  /// reverse proxy wanting a sign-in of its own (a page, a 401 or 403, or a
  /// redirect that is not to an identity provider for Open WebUI's callback).
  proxySignInRequired,

  /// The server has no such provider, or no OAuth sign-in at all: a 404.
  notFound,
}

class OAuthLoginProbeException implements Exception {
  const OAuthLoginProbeException(this.failure, {this.statusCode});

  final OAuthLoginProbeFailure failure;
  final int? statusCode;

  @override
  String toString() => 'OAuthLoginProbeException(${failure.name})';
}
