import 'package:conduit_core/auth/oidc/oidc_exception.dart';
import 'package:conduit_core/auth/oidc/oidc_http.dart';
import 'package:conduit_core/auth/oidc/oidc_metadata.dart';

/// How many discovery documents a sign-in looks for before it asks for the
/// issuer.
const int oidcMaxDiscoveryCandidates = 8;

const String _googleDiscoveryUrl =
    'https://accounts.google.com/.well-known/openid-configuration';

/// The discovery documents that may describe [authorizationEndpoint], the
/// endpoint Open WebUI's sign-in with [provider] redirected to, most specific
/// first and the endpoint's root last, at most [limit] of them.
///
/// - Google has one fixed document.
/// - Microsoft's `/{tenant}/oauth2/v2.0/authorize` is described by
///   `/{tenant}/v2.0`'s, whose issuer may be templated by tenant.
/// - Kanidm's shared `/ui/oauth2` is described per client, by
///   `/oauth2/openid/{clientId}`'s, [clientId] being the client the sign-in
///   uses.
/// - Every other provider is looked for at each ancestor of the endpoint's
///   path: Keycloak (`/realms/{realm}`, or `/auth/realms/{realm}` before
///   version 17), Rauthy (`/auth/v1`), Okta (`/oauth2/{server}`), and at the
///   root Authelia, PocketID, Zitadel and Okta's organization server.
///
/// Authentik's issuers are per application under a shared endpoint, so its
/// documents cannot be found from the endpoint: its issuer is entered by hand.
List<Uri> oidcDiscoveryCandidates({
  required String provider,
  required Uri authorizationEndpoint,
  String? clientId,
  int limit = oidcMaxDiscoveryCandidates,
}) {
  final host = authorizationEndpoint.host.toLowerCase();
  if (provider.toLowerCase() == 'google' || host == 'accounts.google.com') {
    return [Uri.parse(_googleDiscoveryUrl)];
  }

  final segments = [...authorizationEndpoint.pathSegments];
  while (segments.isNotEmpty && segments.last.isEmpty) {
    segments.removeLast();
  }
  Uri documentAt(Iterable<String> issuerPath) => Uri(
    scheme: authorizationEndpoint.scheme,
    host: authorizationEndpoint.host,
    port: authorizationEndpoint.hasPort ? authorizationEndpoint.port : null,
    pathSegments: [...issuerPath, '.well-known', 'openid-configuration'],
  );

  final candidates = <Uri>[];
  void add(Uri candidate) {
    if (!candidates.any((known) => oidcEndpointsMatch(known, candidate))) {
      candidates.add(candidate);
    }
  }

  if (segments.length == 4 &&
      segments[1] == 'oauth2' &&
      segments[2] == 'v2.0' &&
      segments[3] == 'authorize') {
    add(documentAt([segments[0], 'v2.0']));
  }
  final client = clientId?.trim();
  if (client != null &&
      client.isNotEmpty &&
      segments.length == 2 &&
      segments[0] == 'ui' &&
      segments[1] == 'oauth2') {
    add(documentAt(['oauth2', 'openid', client]));
  }
  for (var depth = segments.length - 1; depth >= 1; depth--) {
    add(documentAt(segments.take(depth)));
  }

  final root = documentAt(const []);
  final bounded = candidates
      .where((candidate) => !oidcEndpointsMatch(candidate, root))
      .take(limit - 1)
      .toList();
  return [...bounded, root];
}

/// The discovery document URL for an issuer entered by hand: an issuer, or
/// the full URL of its discovery document.
///
/// Throws [OidcException]: [OidcFailureKind.invalidIssuer] for anything but
/// an absolute URL without a query or fragment, and
/// [OidcFailureKind.insecureEndpoint] for one that is not `https`.
Uri oidcDiscoveryUrlForInput(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      !uri.isAbsolute ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const OidcException(OidcFailureKind.invalidIssuer);
  }
  if (uri.scheme != 'https') {
    throw const OidcException(OidcFailureKind.insecureEndpoint);
  }
  final text = uri.toString();
  final issuer = text.endsWith(oidcWellKnownPath)
      ? text.substring(0, text.length - oidcWellKnownPath.length)
      : text;
  return oidcDiscoveryUrl(issuer);
}

/// Finds the identity provider Open WebUI signs in with, from where its
/// sign-in redirects.
final class OidcDiscoveryClient {
  OidcDiscoveryClient(this._http);

  final OidcHttp _http;

  /// The provider whose authorization endpoint is [authorizationEndpoint],
  /// the endpoint Open WebUI's sign-in with [provider] redirected to.
  ///
  /// With an [issuer] entered by hand, only its document is read. Otherwise
  /// [oidcDiscoveryCandidates] are read in turn, and the first document
  /// accepted wins. A document is accepted only when it sits under its own
  /// issuer and names [authorizationEndpoint] -- or, for Microsoft, when it
  /// is Microsoft's own document for the tenant the endpoint names
  /// ([_isMicrosoftTenantDocument]).
  ///
  /// The candidates are all on the endpoint's host, so the first that cannot
  /// be reached (a network failure, a timeout, an untrusted certificate)
  /// ends the search: the others would only take as long to fail.
  ///
  /// Throws [OidcException]: [OidcFailureKind.discoveryNotFound] when no
  /// document was accepted, [OidcFailureKind.endpointMismatch] when the
  /// document of an [issuer] entered by hand names another endpoint, or the
  /// failure that kept the provider from being reached.
  Future<OidcProviderMetadata> discover({
    required String provider,
    required Uri authorizationEndpoint,
    required String clientId,
    String? issuer,
  }) async {
    if (authorizationEndpoint.scheme != 'https') {
      throw const OidcException(OidcFailureKind.insecureEndpoint);
    }
    final microsoft = provider.toLowerCase() == 'microsoft';
    bool microsoftTenant(OidcProviderMetadata metadata, Uri url) =>
        microsoft &&
        _isMicrosoftTenantDocument(
          metadata,
          documentUrl: url,
          authorizationEndpoint: authorizationEndpoint,
        );

    final manual = issuer?.trim();
    if (manual != null && manual.isNotEmpty) {
      final url = oidcDiscoveryUrlForInput(manual);
      final metadata = await _read(url);
      if (microsoftTenant(metadata, url)) return metadata;
      if (!metadata.isDiscoveredAt(url)) {
        throw const OidcException(OidcFailureKind.invalidMetadata);
      }
      if (!oidcEndpointsMatch(
        metadata.authorizationEndpoint,
        authorizationEndpoint,
      )) {
        throw const OidcException(OidcFailureKind.endpointMismatch);
      }
      return metadata;
    }

    OidcException? insecure;
    OidcException? transient;
    for (final url in oidcDiscoveryCandidates(
      provider: provider,
      authorizationEndpoint: authorizationEndpoint,
      clientId: clientId,
    )) {
      try {
        final metadata = await _read(url);
        if (microsoftTenant(metadata, url) ||
            (metadata.isDiscoveredAt(url) &&
                oidcEndpointsMatch(
                  metadata.authorizationEndpoint,
                  authorizationEndpoint,
                ))) {
          return metadata;
        }
      } on OidcException catch (error) {
        switch (error.kind) {
          case OidcFailureKind.network ||
              OidcFailureKind.timeout ||
              OidcFailureKind.tls:
            rethrow;
          case OidcFailureKind.insecureEndpoint:
            insecure ??= error;
          case _ when error.isTransient:
            transient ??= error;
          case _:
            break;
        }
      }
    }
    throw insecure ??
        transient ??
        const OidcException(OidcFailureKind.discoveryNotFound);
  }

  /// The document at [url], accepted only when it sits under its own issuer.
  Future<OidcProviderMetadata> fetch(Uri url) async {
    final metadata = await _read(url);
    if (!metadata.isDiscoveredAt(url)) {
      throw const OidcException(OidcFailureKind.invalidMetadata);
    }
    return metadata;
  }

  Future<OidcProviderMetadata> _read(Uri url) async =>
      OidcProviderMetadata.fromJson(await _http.getJson(url));
}

/// The login hosts of Microsoft's clouds.
const Set<String> _microsoftLoginHosts = {
  'login.microsoftonline.com',
  'login.microsoftonline.us',
  'login.chinacloudapi.cn',
  'login.partner.microsoftonline.cn',
};

final RegExp _tenantId = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{12}$',
);

/// Whether [metadata], read from [documentUrl], is Microsoft's document for
/// the tenant [authorizationEndpoint] signs in to.
///
/// Microsoft serves a tenant's document at `/{tenant}/v2.0` under any name
/// for the tenant -- its ID, a domain such as `contoso.onmicrosoft.com`,
/// `consumers` -- but names the issuer by the tenant's ID (or the
/// `{tenantid}` template of the multi-tenant documents), and its endpoints
/// by the name asked for or by the ID. Such a document does not sit under
/// its own issuer, and may name the authorization endpoint differently from
/// Open WebUI's redirect; read from Microsoft's own host at the tenant that
/// redirect named, it is Microsoft's answer for that tenant all the same.
bool _isMicrosoftTenantDocument(
  OidcProviderMetadata metadata, {
  required Uri documentUrl,
  required Uri authorizationEndpoint,
}) {
  final host = documentUrl.host.toLowerCase();
  if (!_microsoftLoginHosts.contains(host)) return false;
  List<String>? pathOf(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.host.toLowerCase() != host ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    final segments = [...uri.pathSegments];
    while (segments.isNotEmpty && segments.last.isEmpty) {
      segments.removeLast();
    }
    return segments;
  }

  bool isAuthorize(List<String>? path) =>
      path != null &&
      path.length == 4 &&
      path[1] == 'oauth2' &&
      path[2] == 'v2.0' &&
      path[3] == 'authorize';

  final document = pathOf(documentUrl);
  final probed = pathOf(authorizationEndpoint);
  if (document == null ||
      document.length != 4 ||
      document[1] != 'v2.0' ||
      document[2] != '.well-known' ||
      document[3] != 'openid-configuration' ||
      !isAuthorize(probed) ||
      probed![0].toLowerCase() != document[0].toLowerCase()) {
    return false;
  }
  final tenant = document[0].toLowerCase();

  final issuer = pathOf(
    Uri.parse(metadata.issuer.replaceAll('{tenantid}', 'common')),
  );
  if (issuer == null || issuer.length != 2 || issuer[1] != 'v2.0') {
    return false;
  }
  final issuerTenant = metadata.hasTenantTemplate ? null : issuer[0];
  if (issuerTenant != null && !_tenantId.hasMatch(issuerTenant)) return false;

  final authorize = pathOf(metadata.authorizationEndpoint);
  if (!isAuthorize(authorize)) return false;
  final named = authorize![0].toLowerCase();
  return (named == tenant || named == issuerTenant?.toLowerCase()) &&
      pathOf(metadata.tokenEndpoint) != null;
}
