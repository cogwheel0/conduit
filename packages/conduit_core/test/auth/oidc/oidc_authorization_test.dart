import 'package:checks/checks.dart';
import 'package:conduit_core/auth/oidc/oidc.dart';
import 'package:test/test.dart';

OidcProviderMetadata _metadata({
  List<String>? scopes,
  bool issParameter = false,
  String authorization = 'https://id.example.com/authorize',
}) => OidcProviderMetadata.fromJson({
  'issuer': 'https://id.example.com',
  'authorization_endpoint': authorization,
  'token_endpoint': 'https://id.example.com/token',
  'scopes_supported': ?scopes,
  'authorization_response_iss_parameter_supported': issParameter,
});

OidcAuthorizationRequest _request({
  OidcProviderMetadata? metadata,
  String provider = 'oidc',
  String clientId = 'conduit',
  Uri? redirectUri,
  String? audience,
  String? prompt,
  String? loginHint,
}) => OidcAuthorizationRequest.create(
  metadata: metadata ?? _metadata(),
  provider: provider,
  clientId: clientId,
  redirectUri: redirectUri ?? oidcConduitRedirectUri,
  audience: audience,
  prompt: prompt,
  loginHint: loginHint,
);

OidcFailureKind? _failureOf(void Function() body) {
  try {
    body();
  } on OidcException catch (error) {
    return error.kind;
  }
  return null;
}

void main() {
  group('the authorization URL', () {
    test('asks for a code with S256 PKCE, state and nonce', () {
      final request = _request();
      final query = request.url.queryParameters;
      check(request.url.path).equals('/authorize');
      check(query['response_type']).equals('code');
      check(query['client_id']).equals('conduit');
      check(query['redirect_uri']).equals('conduit://oauth/callback');
      check(query['scope']).equals('openid email profile');
      check(query['code_challenge_method']).equals('S256');
      check(query['code_challenge'])
          .equals(oidcS256Challenge(request.pkce.verifier));
      check(query['state']).equals(request.state);
      check(request.state.length).equals(43);
      check(query['nonce']).equals(request.nonce);
      check(query.keys)
        ..not((it) => it.contains('prompt'))
        ..not((it) => it.contains('login_hint'))
        ..not((it) => it.contains('audience'))
        ..not((it) => it.contains('access_type'))
        ..not((it) => it.contains('code_verifier'));
    });

    test('asks for offline access only when the provider lists it', () {
      final request = _request(
        metadata: _metadata(scopes: ['openid', 'offline_access']),
      );
      check(request.scope).equals('openid email profile offline_access');
      check(request.url.queryParameters['scope'])
          .equals('openid email profile offline_access');
    });

    test('asks Google for offline access its own way', () {
      final request = _request(
        provider: 'google',
        metadata: _metadata(scopes: ['openid', 'offline_access']),
      );
      check(request.scope).equals('openid email profile');
      check(request.url.queryParameters['access_type']).equals('offline');
    });

    test('carries the audience, prompt and login hint it is given', () {
      final request = _request(
        audience: 'open-webui',
        prompt: 'select_account',
        loginHint: 'ada@example.com',
      );
      final query = request.url.queryParameters;
      check(query['audience']).equals('open-webui');
      check(query['prompt']).equals('select_account');
      check(query['login_hint']).equals('ada@example.com');
      check(_request(prompt: ' ', loginHint: '').url.queryParameters.keys)
          .not((it) => it.any((key) => key.equals('prompt')));
    });

    test('keeps the query the endpoint already has', () {
      final request = _request(
        metadata: _metadata(
          authorization: 'https://id.example.com/authorize?p=signin',
        ),
      );
      check(request.url.queryParameters['p']).equals('signin');
    });

    test('is new for every sign-in', () {
      final first = _request();
      final second = _request();
      check(first.state).not((it) => it.equals(second.state));
      check(first.nonce).not((it) => it.equals(second.nonce));
      check(first.pkce.verifier).not((it) => it.equals(second.pkce.verifier));
    });

    test('never shows its secrets in logs', () {
      final request = _request();
      check(request.toString())
        ..not((it) => it.contains(request.state))
        ..not((it) => it.contains(request.nonce))
        ..not((it) => it.contains(request.pkce.verifier));
    });
  });

  group('the callback', () {
    Uri callback(
      OidcAuthorizationRequest request,
      Map<String, String> parameters, {
      String base = 'conduit://oauth/callback',
    }) => Uri.parse(base).replace(queryParameters: parameters);

    test('gives the code', () {
      final request = _request();
      check(
        request.codeFromCallback(
          callback(request, {'code': 'abc', 'state': request.state}),
        ),
      ).equals('abc');
    });

    test('must come back to the redirect URI exactly', () {
      final request = _request();
      for (final base in [
        'conduit://oauth/other',
        'conduit://evil/callback',
        'other://oauth/callback',
        'conduit://oauth:443/callback',
        'conduit://user@oauth/callback',
        'conduit://oauth/callback/',
        'https://oauth/callback',
      ]) {
        check(
          _failureOf(
            () => request.codeFromCallback(
              callback(request, {
                'code': 'abc',
                'state': request.state,
              }, base: base),
            ),
          ),
        ).equals(OidcFailureKind.callbackMismatch);
      }
      check(
        _failureOf(
          () => request.codeFromCallback(
            Uri.parse(
              'conduit://oauth/callback?code=abc&state=${request.state}#x',
            ),
          ),
        ),
      ).equals(OidcFailureKind.callbackMismatch);
    });

    test('is checked for state before its error is read', () {
      final request = _request();
      check(
        _failureOf(
          () => request.codeFromCallback(
            callback(request, {'error': 'access_denied', 'state': 'forged'}),
          ),
        ),
      ).equals(OidcFailureKind.stateMismatch);
      check(
        _failureOf(
          () => request.codeFromCallback(callback(request, {'code': 'abc'})),
        ),
      ).equals(OidcFailureKind.stateMismatch);
    });

    test('says why the provider declined', () {
      final request = _request();
      OidcException? errorFor(String code) {
        try {
          request.codeFromCallback(
            callback(request, {
              'error': code,
              'error_description': 'Ada declined at https://id.example.com',
              'state': request.state,
            }),
          );
        } on OidcException catch (error) {
          return error;
        }
        return null;
      }

      check(errorFor('access_denied')!.kind)
          .equals(OidcFailureKind.accessDenied);
      check(errorFor('unauthorized_client')!.kind)
          .equals(OidcFailureKind.clientRejected);
      final other = errorFor('login_required')!;
      check(other.kind).equals(OidcFailureKind.authorizationFailed);
      check(other.errorCode).equals('login_required');
      check(other.toString()).not((it) => it.contains('https://'));
    });

    test('must name the provider in iss when it says anything', () {
      final request = _request();
      check(
        request.codeFromCallback(
          callback(request, {
            'code': 'abc',
            'state': request.state,
            'iss': 'https://id.example.com',
          }),
        ),
      ).equals('abc');
      check(
        _failureOf(
          () => request.codeFromCallback(
            callback(request, {
              'code': 'abc',
              'state': request.state,
              'iss': 'https://evil.example.com',
            }),
          ),
        ),
      ).equals(OidcFailureKind.issuerMismatch);
    });

    test('must carry iss when the provider advertises it', () {
      final request = _request(metadata: _metadata(issParameter: true));
      check(
        _failureOf(
          () => request.codeFromCallback(
            callback(request, {'code': 'abc', 'state': request.state}),
          ),
        ),
      ).equals(OidcFailureKind.issuerMismatch);
    });

    test('must not repeat a parameter, nor lack the code', () {
      final request = _request();
      check(
        _failureOf(
          () => request.codeFromCallback(
            Uri.parse(
              'conduit://oauth/callback?code=a&code=b&state=${request.state}',
            ),
          ),
        ),
      ).equals(OidcFailureKind.callbackMismatch);
      check(
        _failureOf(
          () => request.codeFromCallback(
            callback(request, {'state': request.state}),
          ),
        ),
      ).equals(OidcFailureKind.invalidResponse);
    });

    test('comes back to Google by the reversed client ID', () {
      const clientId = '1234567890-abc123def.apps.googleusercontent.com';
      final redirect = oidcGoogleRedirectUri(clientId)!;
      check(redirect.toString()).equals(
        'com.googleusercontent.apps.1234567890-abc123def:/oauth2redirect',
      );
      final request = _request(
        provider: 'google',
        clientId: clientId,
        redirectUri: redirect,
      );
      check(request.url.queryParameters['redirect_uri']).equals(
        'com.googleusercontent.apps.1234567890-abc123def:/oauth2redirect',
      );
      check(
        request.codeFromCallback(
          Uri.parse(
            'com.googleusercontent.apps.1234567890-abc123def:/oauth2redirect'
            '?code=abc&state=${request.state}',
          ),
        ),
      ).equals('abc');
      check(
        _failureOf(
          () => request.codeFromCallback(
            Uri.parse(
              'com.googleusercontent.apps.1234567890-other:/oauth2redirect'
              '?code=abc&state=${request.state}',
            ),
          ),
        ),
      ).equals(OidcFailureKind.callbackMismatch);
    });
  });

  group('the redirect URI', () {
    test('is conduit://oauth/callback but for Google', () {
      check(oidcRedirectUriFor(provider: 'oidc', clientId: 'x').toString())
          .equals('conduit://oauth/callback');
      check(oidcRedirectUriFor(provider: 'microsoft', clientId: 'x').toString())
          .equals('conduit://oauth/callback');
      check(
        oidcRedirectUriFor(
          provider: 'google',
          clientId: '42-xyz.apps.googleusercontent.com',
        ).toString(),
      ).equals('com.googleusercontent.apps.42-xyz:/oauth2redirect');
    });

    test('for Google needs a Google client ID', () {
      check(oidcGoogleRedirectUri('conduit')).isNull();
      check(oidcGoogleRedirectUri('42-xyz.apps.googleusercontent.com.evil.com'))
          .isNull();
      check(oidcRedirectUriFor(provider: 'google', clientId: '')).isNull();
    });
  });
}
