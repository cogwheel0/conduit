import 'package:conduit_core/auth/oidc/oidc_exception.dart';

/// The path a discovery document sits at under its issuer (OpenID Connect
/// Discovery 1.0, section 4).
const String oidcWellKnownPath = '/.well-known/openid-configuration';

// Microsoft's multi-tenant documents (`common`, `organizations`,
// `consumers`) give the issuer with this placeholder for the tenant.
const String _tenantPlaceholder = '{tenantid}';
const String _tenantSentinel = 'conduit-tenant-placeholder';

/// What an identity provider's discovery document says about the endpoints a
/// sign-in uses.
final class OidcProviderMetadata {
  const OidcProviderMetadata({
    required this.issuer,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    this.revocationEndpoint,
    this.scopesSupported,
    this.authorizationResponseIssParameterSupported = false,
  });

  /// Parses a discovery document.
  ///
  /// Throws [OidcException]: [OidcFailureKind.insecureEndpoint] when the
  /// issuer or an endpoint a sign-in uses is not `https`, and
  /// [OidcFailureKind.invalidMetadata] when the document is malformed.
  factory OidcProviderMetadata.fromJson(Map<String, dynamic> json) {
    final issuer = json['issuer'];
    if (issuer is! String || issuer.isEmpty) {
      throw const OidcException(OidcFailureKind.invalidMetadata);
    }
    final issuerUri = _issuerUri(issuer);
    if (issuerUri == null ||
        issuerUri.hasQuery ||
        issuerUri.hasFragment ||
        issuerUri.userInfo.isNotEmpty) {
      throw const OidcException(OidcFailureKind.invalidMetadata);
    }
    if (issuerUri.scheme != 'https') {
      throw const OidcException(OidcFailureKind.insecureEndpoint);
    }

    final revocation = json['revocation_endpoint'];
    final scopes = json['scopes_supported'];
    return OidcProviderMetadata(
      issuer: issuer,
      authorizationEndpoint: _httpsEndpoint(json['authorization_endpoint']),
      tokenEndpoint: _httpsEndpoint(json['token_endpoint']),
      revocationEndpoint: revocation == null
          ? null
          : _httpsEndpoint(revocation),
      scopesSupported: scopes is List
          ? {for (final scope in scopes) ?(scope is String ? scope : null)}
          : null,
      authorizationResponseIssParameterSupported:
          json['authorization_response_iss_parameter_supported'] == true,
    );
  }

  /// The issuer exactly as the document gives it, which is what an `iss`
  /// must equal.
  final String issuer;
  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;

  /// Where a refresh token is revoked (RFC 7009), when the provider has one.
  final Uri? revocationEndpoint;

  /// The scopes the provider lists, or null when it lists none.
  final Set<String>? scopesSupported;

  /// Whether the provider puts `iss` in its authorization responses
  /// (RFC 9207), so a response without it is refused.
  final bool authorizationResponseIssParameterSupported;

  /// Whether a sign-in may ask for `offline_access`. Only a provider that
  /// lists it is asked: some refuse a scope they do not know.
  bool get supportsOfflineAccess =>
      scopesSupported?.contains('offline_access') ?? false;

  /// Whether this provider's issuer is templated by tenant, as Microsoft's
  /// multi-tenant documents are.
  bool get hasTenantTemplate => issuer.contains(_tenantPlaceholder);

  /// Whether [value], an `iss` from a response, names this provider.
  ///
  /// A templated issuer matches any single tenant in the placeholder's place.
  bool isIssuer(String value) {
    if (!hasTenantTemplate) return value == issuer;
    final tenant = _tenantIn(Uri.tryParse(value));
    return tenant != null &&
        issuer.replaceAll(_tenantPlaceholder, tenant) == value;
  }

  /// Whether this document belongs at [documentUrl]: an issuer's document
  /// sits at the issuer plus [oidcWellKnownPath], and one served anywhere
  /// else speaks for a provider it is not.
  bool isDiscoveredAt(Uri documentUrl) {
    if (!hasTenantTemplate) {
      return oidcEndpointsMatch(oidcDiscoveryUrl(issuer), documentUrl);
    }
    final tenant = _tenantIn(documentUrl);
    if (tenant == null) return false;
    return oidcEndpointsMatch(
      oidcDiscoveryUrl(issuer.replaceAll(_tenantPlaceholder, tenant)),
      documentUrl,
    );
  }

  /// The path segment of [uri] in the tenant placeholder's place.
  String? _tenantIn(Uri? uri) {
    final template = _issuerUri(issuer);
    if (uri == null || template == null) return null;
    final index = template.pathSegments.indexOf(_tenantSentinel);
    if (index < 0 || uri.pathSegments.length <= index) return null;
    final tenant = uri.pathSegments[index];
    return _tenantSegment.hasMatch(tenant) ? tenant : null;
  }

  @override
  String toString() => 'OidcProviderMetadata(${_originOf(issuer)})';
}

/// The URL of the discovery document for [issuer]. A trailing slash on the
/// issuer, as Authentik's have, is not doubled.
Uri oidcDiscoveryUrl(String issuer) {
  final base = issuer.endsWith('/')
      ? issuer.substring(0, issuer.length - 1)
      : issuer;
  return Uri.parse('$base$oidcWellKnownPath');
}

/// Whether [a] and [b] are the same endpoint: the same scheme, host and
/// effective port, and the same path but for trailing slashes and
/// percent-encoding. Queries and fragments are ignored.
bool oidcEndpointsMatch(Uri a, Uri b) {
  final key = _endpointKey(a);
  return key != null && key == _endpointKey(b);
}

String? _endpointKey(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if ((scheme != 'https' && scheme != 'http') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  final segments = [...uri.pathSegments];
  while (segments.isNotEmpty && segments.last.isEmpty) {
    segments.removeLast();
  }
  final path = segments.map(Uri.encodeComponent).join('/');
  return '$scheme://${uri.host.toLowerCase()}:${uri.port}/$path';
}

Uri? _issuerUri(String issuer) {
  final uri = Uri.tryParse(
    issuer.replaceAll(_tenantPlaceholder, _tenantSentinel),
  );
  if (uri == null || !uri.isAbsolute || uri.host.isEmpty) return null;
  return uri;
}

Uri _httpsEndpoint(Object? value) {
  final uri = value is String ? Uri.tryParse(value) : null;
  if (uri == null ||
      !uri.isAbsolute ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const OidcException(OidcFailureKind.invalidMetadata);
  }
  if (uri.scheme != 'https') {
    throw const OidcException(OidcFailureKind.insecureEndpoint);
  }
  return uri;
}

String _originOf(String issuer) {
  final uri = _issuerUri(issuer);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
    return '<invalid>';
  }
  return uri.origin;
}

final RegExp _tenantSegment = RegExp(r'^[A-Za-z0-9.\-]+$');
