/// Sign-in with an OpenID Connect provider as a public client: discovery,
/// authorization code with PKCE, refresh and revocation.
///
/// Pure Dart, with no knowledge of Open WebUI or of the browser: the caller
/// opens [OidcAuthorizationRequest.url] and hands back the callback.
library;

export 'oidc_authorization.dart';
export 'oidc_discovery.dart';
export 'oidc_exception.dart';
export 'oidc_http.dart' show OidcHttp, OidcHttpResponse, OidcRouteClientFactory;
export 'oidc_metadata.dart';
export 'oidc_pkce.dart';
export 'oidc_token_client.dart';
