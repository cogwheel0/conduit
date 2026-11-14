import 'package:checks/checks.dart';
import 'package:conduit_core/auth/oidc/oidc.dart';
import 'package:test/test.dart';

Map<String, dynamic> _document({
  String issuer = 'https://kc.example.com/realms/acme',
  String? authorization,
  String? token,
  Object? revocation,
  Object? scopes,
  Object? issParameter,
  Object? introspection,
}) => {
  'issuer': issuer,
  'authorization_endpoint':
      authorization ??
      'https://kc.example.com/realms/acme/protocol/openid-connect/auth',
  'token_endpoint':
      token ??
      'https://kc.example.com/realms/acme/protocol/openid-connect/token',
  'revocation_endpoint': ?revocation,
  'scopes_supported': ?scopes,
  'authorization_response_iss_parameter_supported': ?issParameter,
  'introspection_endpoint': ?introspection,
};

Subject<OidcFailureKind> _failure(
  Subject<OidcProviderMetadata Function()> subject,
) => subject.throws<OidcException>().has((error) => error.kind, 'kind');

void main() {
  group('a discovery document', () {
    test('gives the endpoints a sign-in uses', () {
      final metadata = OidcProviderMetadata.fromJson(
        _document(
          revocation: 'https://kc.example.com/realms/acme/protocol/openid-connect/revoke',
          scopes: ['openid', 'email', 'offline_access', 42],
          issParameter: true,
          introspection:
              'https://kc.example.com/realms/acme/protocol/openid-connect/token/introspect',
        ),
      );
      check(metadata.issuer).equals('https://kc.example.com/realms/acme');
      check(metadata.tokenEndpoint.path).endsWith('/token');
      check(metadata.revocationEndpoint).isNotNull();
      check(metadata.supportsOfflineAccess).isTrue();
      check(metadata.authorizationResponseIssParameterSupported).isTrue();
      check(metadata.hasIntrospectionEndpoint).isTrue();
      check(
        OidcProviderMetadata.fromJson(_document()).hasIntrospectionEndpoint,
      ).isFalse();
    });

    test('asks for offline access only when the provider lists it', () {
      check(OidcProviderMetadata.fromJson(_document()).supportsOfflineAccess)
          .isFalse();
      check(
        OidcProviderMetadata.fromJson(_document(scopes: ['openid', 'email']))
            .supportsOfflineAccess,
      ).isFalse();
    });

    test('is refused when the issuer or an endpoint is not https', () {
      for (final document in [
        _document(issuer: 'http://kc.example.com/realms/acme'),
        _document(token: 'http://kc.example.com/token'),
        _document(authorization: 'http://kc.example.com/auth'),
        _document(revocation: 'http://kc.example.com/revoke'),
      ]) {
        check(
          () => OidcProviderMetadata.fromJson(document),
        ).which((it) => _failure(it).equals(OidcFailureKind.insecureEndpoint));
      }
    });

    test('is refused when malformed', () {
      for (final document in [
        <String, dynamic>{..._document()}..remove('token_endpoint'),
        <String, dynamic>{..._document()}..remove('issuer'),
        _document(issuer: 'https://kc.example.com/realms/acme?x=1'),
        _document(token: 'not a url'),
        _document(token: 'https://user@kc.example.com/token'),
        _document(revocation: 42),
      ]) {
        check(
          () => OidcProviderMetadata.fromJson(document),
        ).which((it) => _failure(it).equals(OidcFailureKind.invalidMetadata));
      }
    });

    test('belongs only under its own issuer', () {
      final metadata = OidcProviderMetadata.fromJson(_document());
      check(
        metadata.isDiscoveredAt(
          Uri.parse(
            'https://KC.example.com:443/realms/acme/.well-known/openid-configuration',
          ),
        ),
      ).isTrue();
      check(
        metadata.isDiscoveredAt(
          Uri.parse('https://kc.example.com/.well-known/openid-configuration'),
        ),
      ).isFalse();
      check(
        metadata.isDiscoveredAt(
          Uri.parse(
            'https://evil.example.com/realms/acme/.well-known/openid-configuration',
          ),
        ),
      ).isFalse();
    });

    test('of an issuer with a trailing slash sits under it once', () {
      final metadata = OidcProviderMetadata.fromJson(
        _document(
          issuer: 'https://auth.example.com/application/o/conduit/',
          authorization: 'https://auth.example.com/application/o/authorize/',
        ),
      );
      check(
        metadata.isDiscoveredAt(
          Uri.parse(
            'https://auth.example.com/application/o/conduit/.well-known/openid-configuration',
          ),
        ),
      ).isTrue();
    });

    test('with a tenant-templated issuer matches any one tenant', () {
      final metadata = OidcProviderMetadata.fromJson(
        _document(
          issuer: 'https://login.microsoftonline.com/{tenantid}/v2.0',
          authorization:
              'https://login.microsoftonline.com/common/oauth2/v2.0/authorize',
          token: 'https://login.microsoftonline.com/common/oauth2/v2.0/token',
        ),
      );
      check(metadata.hasTenantTemplate).isTrue();
      check(
        metadata.isDiscoveredAt(
          Uri.parse(
            'https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration',
          ),
        ),
      ).isTrue();
      check(
        metadata.isDiscoveredAt(
          Uri.parse(
            'https://evil.example.com/common/v2.0/.well-known/openid-configuration',
          ),
        ),
      ).isFalse();
      check(
        metadata.isIssuer(
          'https://login.microsoftonline.com/9188040d-6c67-4c5b-b112-36a304b66dad/v2.0',
        ),
      ).isTrue();
      check(metadata.isIssuer('https://login.microsoftonline.com/a/b/v2.0'))
          .isFalse();
      check(metadata.isIssuer('https://evil.example.com/common/v2.0'))
          .isFalse();
    });

    test('names its issuer exactly', () {
      final metadata = OidcProviderMetadata.fromJson(_document());
      check(metadata.isIssuer('https://kc.example.com/realms/acme')).isTrue();
      check(metadata.isIssuer('https://kc.example.com/realms/acme/')).isFalse();
      check(metadata.isIssuer('https://KC.example.com/realms/acme')).isFalse();
    });

    test('logs only the issuer origin', () {
      final metadata = OidcProviderMetadata.fromJson(_document());
      check(metadata.toString())
          .equals('OidcProviderMetadata(https://kc.example.com)');
    });
  });

  group('endpoints match', () {
    bool match(String a, String b) =>
        oidcEndpointsMatch(Uri.parse(a), Uri.parse(b));

    test('despite case, default ports, trailing slashes and queries', () {
      check(
        match(
          'https://ID.example.com/authorize/',
          'https://id.example.com:443/authorize?client_id=x',
        ),
      ).isTrue();
      check(match('https://id.example.com/a%2Db', 'https://id.example.com/a-b'))
          .isTrue();
    });

    test('not across scheme, port, host or path', () {
      check(
        match(
          'https://id.example.com/authorize',
          'http://id.example.com/authorize',
        ),
      ).isFalse();
      check(
        match(
          'https://id.example.com/authorize',
          'https://id.example.com:8443/authorize',
        ),
      ).isFalse();
      check(
        match(
          'https://id.example.com/authorize',
          'https://example.com/authorize',
        ),
      ).isFalse();
      check(
        match(
          'https://id.example.com/authorize',
          'https://id.example.com/auth',
        ),
      ).isFalse();
      check(match('conduit://oauth/callback', 'conduit://oauth/callback'))
          .isFalse();
    });
  });
}
