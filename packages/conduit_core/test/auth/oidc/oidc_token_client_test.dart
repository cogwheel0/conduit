import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/oidc/oidc.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

final _now = DateTime.utc(2026, 10, 21, 12);

final _metadata = OidcProviderMetadata.fromJson({
  'issuer': 'https://id.example.com',
  'authorization_endpoint': 'https://id.example.com/authorize',
  'token_endpoint': 'https://id.example.com/token',
  'revocation_endpoint': 'https://id.example.com/revoke',
  'scopes_supported': ['openid', 'offline_access'],
});

OidcAuthorizationRequest _request() => OidcAuthorizationRequest.create(
  metadata: _metadata,
  provider: 'oidc',
  clientId: 'conduit',
  redirectUri: oidcConduitRedirectUri,
);

String _idToken(Map<String, dynamic> claims) {
  String part(Map<String, dynamic> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${part({'alg': 'RS256'})}.${part(claims)}.signature';
}

/// A token endpoint that answers with [status] and [body], recording the
/// requests it was sent.
final class _Endpoint {
  _Endpoint(this.status, this.body);

  final int status;
  final Object body;
  final List<http.Request> requests = [];

  late final OidcTokenClient client = OidcTokenClient(
    OidcHttp(
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
          body is String ? body as String : jsonEncode(body),
          status,
          headers: {'content-type': 'application/json'},
        );
      }),
    ),
    now: () => _now,
  );
}

Future<OidcException> _errorOf(Future<Object?> future) async {
  try {
    await future;
  } on OidcException catch (error) {
    return error;
  }
  fail('expected an OidcException');
}

void main() {
  group('redeeming the code', () {
    test('posts it with the verifier as a public client', () async {
      final request = _request();
      final endpoint = _Endpoint(200, {
        'access_token': 'access-1',
        'token_type': 'Bearer',
        'refresh_token': 'refresh-1',
        'expires_in': 300,
        'scope': 'openid email profile offline_access',
        'id_token': _idToken({'nonce': request.nonce, 'sub': 'ada'}),
      });

      final tokens = await endpoint.client.exchangeCode(request, 'code-1');

      check(tokens.accessToken).equals('access-1');
      check(tokens.refreshToken).equals('refresh-1');
      check(tokens.scope).equals('openid email profile offline_access');
      check(tokens.expiresAt).equals(_now.add(const Duration(minutes: 5)));
      // Who signed in, from the ID token, which is not kept.
      check(tokens.subject).equals('ada');
      final sent = endpoint.requests.single;
      check(sent.url.toString()).equals('https://id.example.com/token');
      check(sent.headers['content-type'])
          .isNotNull()
          .startsWith('application/x-www-form-urlencoded');
      check(sent.bodyFields).deepEquals({
        'grant_type': 'authorization_code',
        'code': 'code-1',
        'redirect_uri': 'conduit://oauth/callback',
        'client_id': 'conduit',
        'code_verifier': request.pkce.verifier,
      });
    });

    test('takes a lifetime sent as a string, and no token type', () async {
      final endpoint = _Endpoint(200, {
        'access_token': 'access-1',
        'expires_in': '3600',
      });
      final tokens = await endpoint.client.exchangeCode(_request(), 'code-1');
      check(tokens.refreshToken).isNull();
      check(tokens.expiresAt).equals(_now.add(const Duration(hours: 1)));
      check(tokens.subject).isNull();
    });

    test('refuses an ID token without the sign-in nonce', () async {
      final request = _request();
      for (final (idToken, kind) in [
        (_idToken({'nonce': 'other'}), OidcFailureKind.nonceMismatch),
        (_idToken({'sub': 'ada'}), OidcFailureKind.nonceMismatch),
        ('not-a-jwt', OidcFailureKind.invalidResponse),
        ('a.%%%.c', OidcFailureKind.invalidResponse),
      ]) {
        final endpoint = _Endpoint(200, {
          'access_token': 'access-1',
          'token_type': 'Bearer',
          'id_token': idToken,
        });
        check(
          (await _errorOf(endpoint.client.exchangeCode(request, 'code-1')))
              .kind,
        ).equals(kind);
      }
    });

    test('refuses an answer that is not a bearer token', () async {
      for (final body in <Object>[
        {'token_type': 'Bearer'},
        {'access_token': '', 'token_type': 'Bearer'},
        {'access_token': 'a', 'token_type': 'DPoP'},
        {'access_token': 'a', 'refresh_token': 42},
        '<html>proxy</html>',
      ]) {
        final endpoint = _Endpoint(200, body);
        check(
          (await _errorOf(endpoint.client.exchangeCode(_request(), 'c'))).kind,
        ).equals(OidcFailureKind.invalidResponse);
      }
    });

    test('tells the provider errors apart', () async {
      for (final (status, body, kind) in [
        (400, {'error': 'invalid_grant'}, OidcFailureKind.invalidGrant),
        (401, {'error': 'invalid_client'}, OidcFailureKind.clientRejected),
        (400, {'error': 'unauthorized_client'}, OidcFailureKind.clientRejected),
        (400, {'error': 'invalid_scope'}, OidcFailureKind.tokenRequestFailed),
        (429, {'error': 'slow_down'}, OidcFailureKind.rateLimited),
        (503, 'down', OidcFailureKind.serverError),
        (
          400,
          {'error': 'temporarily_unavailable'},
          OidcFailureKind.serverError,
        ),
        (404, 'missing', OidcFailureKind.unexpectedStatus),
      ]) {
        final endpoint = _Endpoint(status, body);
        final error = await _errorOf(
          endpoint.client.exchangeCode(_request(), 'c'),
        );
        check(error.kind).equals(kind);
        check(error.statusCode).equals(status);
      }
    });

    test('keeps the provider description out of the failure', () async {
      final endpoint = _Endpoint(400, {
        'error': 'invalid_grant',
        'error_description': 'Code abc for ada@example.com expired',
      });
      final error = await _errorOf(
        endpoint.client.exchangeCode(_request(), 'abc'),
      );
      check(error.errorCode).equals('invalid_grant');
      check(error.toString())
        ..not((it) => it.contains('ada@example.com'))
        ..not((it) => it.contains('abc'));
    });

    test('drops an error code that is not one', () async {
      final endpoint = _Endpoint(400, {'error': 'Bad "thing" at https://x'});
      final error = await _errorOf(
        endpoint.client.exchangeCode(_request(), 'abc'),
      );
      check(error.kind).equals(OidcFailureKind.tokenRequestFailed);
      check(error.errorCode).isNull();
    });
  });

  group('refreshing', () {
    Future<(OidcTokenSet, http.Request)> refreshWith(Object body) async {
      final endpoint = _Endpoint(200, body);
      final tokens = await endpoint.client.refresh(
        tokenEndpoint: _metadata.tokenEndpoint,
        clientId: 'conduit',
        refreshToken: 'refresh-1',
        scope: 'openid email profile offline_access',
      );
      return (tokens, endpoint.requests.single);
    }

    test('takes the rotated refresh token', () async {
      final (tokens, sent) = await refreshWith({
        'access_token': 'access-2',
        'token_type': 'Bearer',
        'refresh_token': 'refresh-2',
        'scope': 'openid email',
      });
      check(tokens.accessToken).equals('access-2');
      check(tokens.refreshToken).equals('refresh-2');
      check(tokens.scope).equals('openid email');
      check(sent.bodyFields).deepEquals({
        'grant_type': 'refresh_token',
        'refresh_token': 'refresh-1',
        'client_id': 'conduit',
      });
    });

    test(
      'keeps the refresh token and scope the provider did not resend',
      () async {
        final (tokens, _) = await refreshWith({
          'access_token': 'access-2',
          'token_type': 'Bearer',
        });
        check(tokens.refreshToken).equals('refresh-1');
        check(tokens.scope).equals('openid email profile offline_access');
      },
    );

    test('ignores an ID token, which carries no nonce', () async {
      final (tokens, _) = await refreshWith({
        'access_token': 'access-2',
        'token_type': 'Bearer',
        'id_token': _idToken({'sub': 'ada'}),
      });
      check(tokens.accessToken).equals('access-2');
      check(tokens.subject).isNull();
    });

    test('reports a refresh token that is no longer good', () async {
      final endpoint = _Endpoint(400, {'error': 'invalid_grant'});
      final error = await _errorOf(
        endpoint.client.refresh(
          tokenEndpoint: _metadata.tokenEndpoint,
          clientId: 'conduit',
          refreshToken: 'refresh-1',
        ),
      );
      check(error.kind).equals(OidcFailureKind.invalidGrant);
      check(error.isTransient).isFalse();
    });

    test('never shows the tokens in logs', () async {
      final (tokens, _) = await refreshWith({
        'access_token': 'access-2',
        'refresh_token': 'refresh-2',
      });
      check(tokens.toString())
        ..not((it) => it.contains('access-2'))
        ..not((it) => it.contains('refresh-2'));
    });
  });

  group('revoking', () {
    test('posts the refresh token and reports the answer', () async {
      final endpoint = _Endpoint(200, '');
      check(
        await endpoint.client.revoke(
          revocationEndpoint: _metadata.revocationEndpoint!,
          clientId: 'conduit',
          token: 'refresh-1',
        ),
      ).isTrue();
      check(endpoint.requests.single.bodyFields).deepEquals({
        'token': 'refresh-1',
        'token_type_hint': 'refresh_token',
        'client_id': 'conduit',
      });
      check(
        await _Endpoint(400, {'error': 'unsupported_token_type'}).client.revoke(
          revocationEndpoint: _metadata.revocationEndpoint!,
          clientId: 'conduit',
          token: 'refresh-1',
        ),
      ).isFalse();
    });

    test('never throws', () async {
      final unreachable = OidcTokenClient(
        OidcHttp(
          client: MockClient((_) async => throw http.ClientException('down')),
        ),
      );
      check(
        await unreachable.revoke(
          revocationEndpoint: _metadata.revocationEndpoint!,
          clientId: 'conduit',
          token: 'refresh-1',
        ),
      ).isFalse();
      check(
        await unreachable.revoke(
          revocationEndpoint: Uri.parse('http://id.example.com/revoke'),
          clientId: 'conduit',
          token: 'refresh-1',
        ),
      ).isFalse();

      final hanging = OidcTokenClient(
        OidcHttp(client: MockClient((_) => Completer<http.Response>().future)),
      );
      check(
        await hanging.revoke(
          revocationEndpoint: _metadata.revocationEndpoint!,
          clientId: 'conduit',
          token: 'refresh-1',
          timeout: const Duration(milliseconds: 10),
        ),
      ).isFalse();
    });
  });
}
