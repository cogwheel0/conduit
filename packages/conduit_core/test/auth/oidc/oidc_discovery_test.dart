import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/oidc/oidc.dart';
import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

List<String> _candidates(
  String endpoint, {
  String provider = 'oidc',
  String? clientId,
}) => [
  for (final uri in oidcDiscoveryCandidates(
    provider: provider,
    authorizationEndpoint: Uri.parse(endpoint),
    clientId: clientId,
  ))
    uri.toString(),
];

String _document(String issuer) => '$issuer/.well-known/openid-configuration';

/// A provider that serves [documents] by URL and answers 404 to anything
/// else, recording what was asked.
final class _Provider {
  _Provider(this.documents);

  final Map<String, Map<String, dynamic>> documents;
  final List<http.BaseRequest> requests = [];

  late final OidcDiscoveryClient client = OidcDiscoveryClient(
    OidcHttp(
      client: MockClient((request) async {
        requests.add(request);
        final document = documents[request.url.toString()];
        if (document == null) return http.Response('not found', 404);
        return http.Response(
          jsonEncode(document),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    ),
  );
}

Map<String, dynamic> _metadata({
  required String issuer,
  required String authorization,
}) => {
  'issuer': issuer,
  'authorization_endpoint': authorization,
  'token_endpoint': '$issuer/token',
};

Future<OidcFailureKind> _failureOf(Future<Object?> future) async {
  try {
    await future;
  } on OidcException catch (error) {
    return error.kind;
  }
  fail('expected an OidcException');
}

void main() {
  group('discovery looks', () {
    test('for Keycloak at its realm', () {
      check(
          _candidates(
            'https://kc.example.com/realms/acme/protocol/openid-connect/auth',
          ),
        )
        ..contains(_document('https://kc.example.com/realms/acme'))
        ..last.equals(_document('https://kc.example.com'));
    });

    test('for Keycloak before 17 at its /auth realm', () {
      check(
        _candidates(
          'https://kc.example.com/auth/realms/acme/protocol/openid-connect/auth',
        ),
      ).contains(_document('https://kc.example.com/auth/realms/acme'));
    });

    test('for Rauthy at /auth/v1', () {
      check(_candidates('https://iam.example.com/auth/v1/oidc/authorize'))
          .contains(_document('https://iam.example.com/auth/v1'));
    });

    test('for Okta at its authorization server, or the root', () {
      check(_candidates('https://acme.okta.com/oauth2/default/v1/authorize'))
          .contains(_document('https://acme.okta.com/oauth2/default'));
      check(_candidates('https://acme.okta.com/oauth2/v1/authorize')).last
          .equals(_document('https://acme.okta.com'));
    });

    test('for Authelia, Zitadel and PocketID at the root', () {
      check(_candidates('https://auth.example.com/api/oidc/authorization')).last
          .equals(_document('https://auth.example.com'));
      check(_candidates('https://acme.zitadel.cloud/oauth/v2/authorize')).last
          .equals(_document('https://acme.zitadel.cloud'));
      check(_candidates('https://id.example.com/authorize'))
          .deepEquals([_document('https://id.example.com')]);
    });

    test('for Kanidm at the client the sign-in uses', () {
      check(
        _candidates('https://idm.example.com/ui/oauth2', clientId: 'conduit'),
      ).first.equals(
        _document('https://idm.example.com/oauth2/openid/conduit'),
      );
    });

    test('for Google at its one document', () {
      check(
        _candidates(
          'https://accounts.google.com/o/oauth2/v2/auth',
          provider: 'google',
        ),
      ).deepEquals([_document('https://accounts.google.com')]);
    });

    test('for Microsoft at the tenant', () {
      check(
            _candidates(
              'https://login.microsoftonline.com/common/oauth2/v2.0/authorize',
              provider: 'microsoft',
            ),
          ).first
          .equals(_document('https://login.microsoftonline.com/common/v2.0'));
      check(
        _candidates(
          'https://login.microsoftonline.com/9188040d-6c67-4c5b-b112-36a304b66dad/oauth2/v2.0/authorize',
          provider: 'microsoft',
        ),
      ).first.equals(
        _document(
          'https://login.microsoftonline.com/9188040d-6c67-4c5b-b112-36a304b66dad/v2.0',
        ),
      );
    });

    test('nowhere near an Authentik application', () {
      check(_candidates('https://auth.example.com/application/o/authorize/'))
          .deepEquals([
            _document('https://auth.example.com/application/o'),
            _document('https://auth.example.com/application'),
            _document('https://auth.example.com'),
          ]);
    });

    test('in at most eight places, the root last', () {
      final candidates = _candidates(
        'https://id.example.com/a/b/c/d/e/f/g/h/i/j/k/authorize',
      );
      check(candidates).length.equals(oidcMaxDiscoveryCandidates);
      check(candidates).first
          .equals(_document('https://id.example.com/a/b/c/d/e/f/g/h/i/j/k'));
      check(candidates).last.equals(_document('https://id.example.com'));
    });

    test('on the endpoint port', () {
      check(_candidates('https://id.example.com:8443/authorize'))
          .deepEquals([_document('https://id.example.com:8443')]);
    });
  });

  group('discovery', () {
    const keycloakAuth =
        'https://kc.example.com/realms/acme/protocol/openid-connect/auth';

    test('finds Keycloak, sending nothing of Open WebUI', () async {
      final provider = _Provider({
        _document('https://kc.example.com/realms/acme'): _metadata(
          issuer: 'https://kc.example.com/realms/acme',
          authorization: keycloakAuth,
        ),
      });
      final metadata = await provider.client.discover(
        provider: 'oidc',
        authorizationEndpoint: Uri.parse(keycloakAuth),
        clientId: 'conduit',
      );
      check(metadata.issuer).equals('https://kc.example.com/realms/acme');
      // .../openid-connect, .../protocol, then the realm.
      check(provider.requests).length.equals(3);
      for (final request in provider.requests) {
        check(request.method).equals('GET');
        check(request.followRedirects).isFalse();
        check(request.headers.keys.map((key) => key.toLowerCase()))
          ..not((it) => it.contains(HttpHeaders.cookieHeader))
          ..not((it) => it.contains(HttpHeaders.authorizationHeader));
      }
    });

    test('passes over a document for another endpoint or issuer', () async {
      final provider = _Provider({
        // Names another authorization endpoint.
        _document('https://kc.example.com/realms/acme/protocol'): _metadata(
          issuer: 'https://kc.example.com/realms/acme/protocol',
          authorization: 'https://kc.example.com/other/auth',
        ),
        // Speaks for an issuer it does not sit under.
        _document('https://kc.example.com/realms/acme'): _metadata(
          issuer: 'https://kc.example.com/realms/other',
          authorization: keycloakAuth,
        ),
      });
      check(
        await _failureOf(
          provider.client.discover(
            provider: 'oidc',
            authorizationEndpoint: Uri.parse(keycloakAuth),
            clientId: 'conduit',
          ),
        ),
      ).equals(OidcFailureKind.discoveryNotFound);
    });

    test('finds Microsoft through its templated issuer', () async {
      const authorize =
          'https://login.microsoftonline.com/common/oauth2/v2.0/authorize';
      final provider = _Provider({
        _document('https://login.microsoftonline.com/common/v2.0'): {
          'issuer': 'https://login.microsoftonline.com/{tenantid}/v2.0',
          'authorization_endpoint': authorize,
          'token_endpoint':
              'https://login.microsoftonline.com/common/oauth2/v2.0/token',
          'scopes_supported': ['openid', 'offline_access'],
        },
      });
      final metadata = await provider.client.discover(
        provider: 'microsoft',
        authorizationEndpoint: Uri.parse(authorize),
        clientId: 'conduit',
      );
      check(metadata.hasTenantTemplate).isTrue();
      check(provider.requests).length.equals(1);
    });

    group('finds a Microsoft tenant whose document names it by ID', () {
      const tenantId = '72f988bf-86f1-41af-91ab-2d7cd011db47';
      const consumersId = '9188040d-6c67-4c5b-b112-36a304b66dad';
      const host = 'https://login.microsoftonline.com';

      Map<String, dynamic> tenantDocument(String issuerTenant, String named) =>
          {
            'issuer': '$host/$issuerTenant/v2.0',
            'authorization_endpoint': '$host/$named/oauth2/v2.0/authorize',
            'token_endpoint': '$host/$named/oauth2/v2.0/token',
          };

      test('a tenant named by its domain', () async {
        const authorize =
            '$host/contoso.onmicrosoft.com/oauth2/v2.0/authorize';
        final provider = _Provider({
          _document('$host/contoso.onmicrosoft.com/v2.0'): tenantDocument(
            tenantId,
            tenantId,
          ),
        });
        final metadata = await provider.client.discover(
          provider: 'microsoft',
          authorizationEndpoint: Uri.parse(authorize),
          clientId: 'conduit',
        );
        check(metadata.issuer).equals('$host/$tenantId/v2.0');
        check(
          metadata.authorizationEndpoint.toString(),
        ).equals('$host/$tenantId/oauth2/v2.0/authorize');
        check(metadata.isIssuer('$host/$tenantId/v2.0')).isTrue();
      });

      test('consumers', () async {
        const authorize = '$host/consumers/oauth2/v2.0/authorize';
        final provider = _Provider({
          _document('$host/consumers/v2.0'): tenantDocument(
            consumersId,
            'consumers',
          ),
        });
        final metadata = await provider.client.discover(
          provider: 'microsoft',
          authorizationEndpoint: Uri.parse(authorize),
          clientId: 'conduit',
        );
        check(metadata.issuer).equals('$host/$consumersId/v2.0');
        check(provider.requests).length.equals(1);
      });

      test('also when its issuer is entered by hand', () async {
        const authorize = '$host/consumers/oauth2/v2.0/authorize';
        final provider = _Provider({
          _document('$host/consumers/v2.0'): tenantDocument(
            consumersId,
            'consumers',
          ),
        });
        final metadata = await provider.client.discover(
          provider: 'microsoft',
          authorizationEndpoint: Uri.parse(authorize),
          clientId: 'conduit',
          issuer: '$host/consumers/v2.0',
        );
        check(metadata.issuer).equals('$host/$consumersId/v2.0');
      });

      test('but not one naming a third tenant', () async {
        const authorize = '$host/consumers/oauth2/v2.0/authorize';
        final provider = _Provider({
          _document('$host/consumers/v2.0'): tenantDocument(
            consumersId,
            tenantId,
          ),
        });
        check(
          await _failureOf(
            provider.client.discover(
              provider: 'microsoft',
              authorizationEndpoint: Uri.parse(authorize),
              clientId: 'conduit',
            ),
          ),
        ).equals(OidcFailureKind.discoveryNotFound);
      });

      test('nor for another provider, or off Microsoft\'s host', () async {
        const authorize = '$host/consumers/oauth2/v2.0/authorize';
        final provider = _Provider({
          _document('$host/consumers/v2.0'): tenantDocument(
            consumersId,
            'consumers',
          ),
          _document('https://id.example.com/consumers/v2.0'): {
            'issuer': 'https://id.example.com/$consumersId/v2.0',
            'authorization_endpoint':
                'https://id.example.com/consumers/oauth2/v2.0/authorize',
            'token_endpoint':
                'https://id.example.com/consumers/oauth2/v2.0/token',
          },
        });
        check(
          await _failureOf(
            provider.client.discover(
              provider: 'oidc',
              authorizationEndpoint: Uri.parse(authorize),
              clientId: 'conduit',
            ),
          ),
        ).equals(OidcFailureKind.discoveryNotFound);
        check(
          await _failureOf(
            provider.client.discover(
              provider: 'microsoft',
              authorizationEndpoint: Uri.parse(
                'https://id.example.com/consumers/oauth2/v2.0/authorize',
              ),
              clientId: 'conduit',
            ),
          ),
        ).equals(OidcFailureKind.discoveryNotFound);
      });
    });

    test('of Authentik needs its issuer entered by hand', () async {
      const authorize = 'https://auth.example.com/application/o/authorize/';
      const issuer = 'https://auth.example.com/application/o/conduit/';
      final provider = _Provider({
        'https://auth.example.com/application/o/conduit/.well-known/openid-configuration':
            _metadata(issuer: issuer, authorization: authorize),
      });
      check(
        await _failureOf(
          provider.client.discover(
            provider: 'oidc',
            authorizationEndpoint: Uri.parse(authorize),
            clientId: 'conduit',
          ),
        ),
      ).equals(OidcFailureKind.discoveryNotFound);

      for (final entered in [
        issuer,
        ' https://auth.example.com/application/o/conduit ',
        'https://auth.example.com/application/o/conduit/.well-known/openid-configuration',
      ]) {
        final metadata = await provider.client.discover(
          provider: 'oidc',
          authorizationEndpoint: Uri.parse(authorize),
          clientId: 'conduit',
          issuer: entered,
        );
        check(metadata.issuer).equals(issuer);
      }
    });

    test('refuses an issuer entered by hand for another endpoint', () async {
      final provider = _Provider({
        _document('https://id.example.com'): _metadata(
          issuer: 'https://id.example.com',
          authorization: 'https://id.example.com/authorize',
        ),
      });
      check(
        await _failureOf(
          provider.client.discover(
            provider: 'oidc',
            authorizationEndpoint: Uri.parse(keycloakAuth),
            clientId: 'conduit',
            issuer: 'https://id.example.com',
          ),
        ),
      ).equals(OidcFailureKind.endpointMismatch);
    });

    test('refuses an issuer entered by hand that is not https', () async {
      final provider = _Provider({});
      for (final (entered, kind) in [
        ('http://id.example.com', OidcFailureKind.insecureEndpoint),
        ('id.example.com', OidcFailureKind.invalidIssuer),
        ('https://id.example.com?x=1', OidcFailureKind.invalidIssuer),
      ]) {
        check(
          await _failureOf(
            provider.client.discover(
              provider: 'oidc',
              authorizationEndpoint: Uri.parse(keycloakAuth),
              clientId: 'conduit',
              issuer: entered,
            ),
          ),
        ).equals(kind);
      }
      check(provider.requests).isEmpty();
    });

    test('refuses an authorization endpoint that is not https', () async {
      final provider = _Provider({});
      check(
        await _failureOf(
          provider.client.discover(
            provider: 'oidc',
            authorizationEndpoint: Uri.parse('http://id.example.com/authorize'),
            clientId: 'conduit',
          ),
        ),
      ).equals(OidcFailureKind.insecureEndpoint);
    });

    test('reports an unreachable provider as such, asking it once', () async {
      var asked = 0;
      final client = OidcDiscoveryClient(
        OidcHttp(
          client: MockClient((_) async {
            asked++;
            throw http.ClientException('connection refused');
          }),
        ),
      );
      check(
        await _failureOf(
          client.discover(
            provider: 'oidc',
            authorizationEndpoint: Uri.parse(keycloakAuth),
            clientId: 'conduit',
          ),
        ),
      ).equals(OidcFailureKind.network);
      // Every candidate is on the same host: the others would only take as
      // long to fail.
      check(asked).equals(1);
    });

    test('stops at a provider that does not answer in time', () {
      fakeAsync((async) {
        var asked = 0;
        final client = OidcDiscoveryClient(
          OidcHttp(
            timeout: const Duration(seconds: 15),
            client: MockClient((_) async {
              asked++;
              await Future<void>.delayed(const Duration(minutes: 1));
              return http.Response('{}', 200);
            }),
          ),
        );
        OidcFailureKind? failure;
        _failureOf(
          client.discover(
            provider: 'oidc',
            authorizationEndpoint: Uri.parse(keycloakAuth),
            clientId: 'conduit',
          ),
        ).then((kind) => failure = kind);
        async.elapse(const Duration(seconds: 15));
        check(failure).equals(OidcFailureKind.timeout);
        check(asked).equals(1);
      });
    });

    test('goes on past a candidate that fails on the server', () async {
      final requests = <Uri>[];
      final client = OidcDiscoveryClient(
        OidcHttp(
          client: MockClient((request) async {
            requests.add(request.url);
            if (request.url.toString() ==
                _document('https://kc.example.com/realms/acme')) {
              return http.Response(
                jsonEncode(
                  _metadata(
                    issuer: 'https://kc.example.com/realms/acme',
                    authorization: keycloakAuth,
                  ),
                ),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response('busy', 503);
          }),
        ),
      );
      final metadata = await client.discover(
        provider: 'oidc',
        authorizationEndpoint: Uri.parse(keycloakAuth),
        clientId: 'conduit',
      );
      check(metadata.issuer).equals('https://kc.example.com/realms/acme');
      check(requests.length).isGreaterThan(1);
    });

    test('reports a matching provider with an http endpoint', () async {
      final provider = _Provider({
        _document('https://id.example.com'): {
          'issuer': 'https://id.example.com',
          'authorization_endpoint': 'https://id.example.com/authorize',
          'token_endpoint': 'http://id.example.com/token',
        },
      });
      check(
        await _failureOf(
          provider.client.discover(
            provider: 'oidc',
            authorizationEndpoint: Uri.parse(
              'https://id.example.com/authorize',
            ),
            clientId: 'conduit',
          ),
        ),
      ).equals(OidcFailureKind.insecureEndpoint);
    });
  });
}
