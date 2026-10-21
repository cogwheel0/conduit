import 'dart:io' show HttpHeaders, HttpStatus;
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/models/oauth_login_probe.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// Answers each request by its path, and records the requests.
final class _Server implements HttpClientAdapter {
  _Server(this.answers);

  final Map<String, ResponseBody Function()> answers;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return answers[options.uri.path]?.call() ??
        _json(HttpStatus.notFound, '{"detail":"Not Found"}');
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, String body) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

ResponseBody _page(int status) => ResponseBody.fromString(
  '<html><body>Sign in</body></html>',
  status,
  headers: {
    Headers.contentTypeHeader: ['text/html; charset=utf-8'],
  },
);

ResponseBody _redirect(String location) => ResponseBody.fromString(
  '',
  HttpStatus.found,
  headers: {
    HttpHeaders.locationHeader: [location],
  },
);

/// Open WebUI's redirect for its own sign-in with [provider], to
/// [authorize].
String _providerRedirect(
  String authorize, {
  String provider = 'oidc',
  String callback = 'https://chat.example/oauth/oidc/callback',
  Map<String, String> extra = const {},
}) => Uri.parse(authorize)
    .replace(
      queryParameters: {
        'response_type': 'code',
        'client_id': 'open-webui',
        'redirect_uri': callback,
        'scope': 'openid email profile',
        'state': 'open-webui-state',
        ...extra,
      },
    )
    .toString();

/// Open WebUI's routes for a sign-in in the system browser: where a provider
/// signs in, and the exchange of its token for a session.
void main() {
  const server = 'https://chat.example';
  late WorkerManager workerManager;
  late ApiService api;
  late List<Uri> rejected;

  setUp(() {
    workerManager = WorkerManager(worker: const InlineWorkerPort());
    api = ApiService(
      serverConfig: const ServerConfig(
        id: 'account',
        name: 'Chat',
        url: server,
        customHeaders: {'X-Tenant': 'one', 'Cookie': 'proxy_session=abc'},
      ),
      workerManager: workerManager,
      reportsRouteRefusals: true,
    );
    api.updateAuthToken('another-session');
    rejected = [];
    final rejections = ConnectivityService.routeRejections.listen(
      (rejection) => rejected.add(rejection.server),
    );
    addTearDown(() async {
      await rejections.cancel();
      api.dispose();
      workerManager.dispose();
    });
  });

  _Server answer(Map<String, ResponseBody Function()> answers) {
    final adapter = _Server(answers);
    api.dio.httpClientAdapter = adapter;
    return adapter;
  }

  group('the login route', () {
    test('says where a provider on another host signs in', () async {
      final adapter = answer({
        '/oauth/oidc/login': () => _redirect(
          _providerRedirect(
            'https://id.example/realms/main/protocol/openid-connect/auth',
            extra: {'audience': 'chat-api'},
          ),
        ),
      });

      final probe = await api.probeOAuthLogin('oidc');

      check(probe.authorizationEndpoint).equals(
        Uri.parse(
          'https://id.example/realms/main/protocol/openid-connect/auth',
        ),
      );
      check(probe.redirectUri)
          .equals(Uri.parse('https://chat.example/oauth/oidc/callback'));
      check(probe.audience).equals('chat-api');
      final request = adapter.requests.single;
      check(request.headers.containsKey('Authorization')).isFalse();
      check(request.headers['X-Tenant']).equals('one');
      check(request.headers['Cookie']).equals('proxy_session=abc');
      check(rejected).isEmpty();
    });

    test('is not followed to a provider on the same host', () async {
      final adapter = answer({
        '/oauth/oidc/login': () =>
            _redirect(_providerRedirect('https://chat.example/idp/authorize')),
      });

      final probe = await api.probeOAuthLogin('oidc');

      check(probe.authorizationEndpoint)
          .equals(Uri.parse('https://chat.example/idp/authorize'));
      check(probe.audience).isNull();
      check(adapter.requests).length.equals(1);
      check(rejected).isEmpty();
    });

    test('takes a callback on another address of the server', () async {
      answer({
        '/oauth/microsoft/login': () => _redirect(
          _providerRedirect(
            'https://login.example/common/oauth2/v2.0/authorize',
            provider: 'microsoft',
            callback: 'https://public.example/oauth/microsoft/callback',
          ),
        ),
      });

      final probe = await api.probeOAuthLogin('microsoft');

      check(probe.redirectUri.host).equals('public.example');
    });

    for (final (what, answers)
        in <(String, Map<String, ResponseBody Function()>)>[
          ('a page', {'/oauth/oidc/login': () => _page(HttpStatus.ok)}),
          (
            'a page refusing access',
            {'/oauth/oidc/login': () => _page(HttpStatus.unauthorized)},
          ),
          (
            'a refusal',
            {'/oauth/oidc/login': () => _json(HttpStatus.forbidden, '{}')},
          ),
          (
            'a redirect to a proxy\'s own sign-in',
            {
              '/oauth/oidc/login': () => _redirect(
                'https://sso.example/login?rd=https://chat.example',
              ),
            },
          ),
          (
            'a redirect to a provider for a proxy\'s callback',
            {
              '/oauth/oidc/login': () => _redirect(
                _providerRedirect(
                  'https://id.example/authorize',
                  callback: 'https://chat.example/oauth2/callback',
                ),
              ),
            },
          ),
          (
            'a redirect to a provider for another provider\'s callback',
            {
              '/oauth/oidc/login': () => _redirect(
                _providerRedirect(
                  'https://id.example/authorize',
                  callback: 'https://chat.example/oauth/google/callback',
                ),
              ),
            },
          ),
          (
            'a redirect to another scheme',
            {
              '/oauth/oidc/login': () =>
                  _redirect(_providerRedirect('ftp://id.example/authorize')),
            },
          ),
        ]) {
      test('answered with $what wants a proxy sign-in', () async {
        answer(answers);

        await check(api.probeOAuthLogin('oidc'))
            .throws<OAuthLoginProbeException>(
              (it) => it
                  .has((it) => it.failure, 'failure')
                  .equals(OAuthLoginProbeFailure.proxySignInRequired),
            );
      });
    }

    test('of a provider the server does not have is not found', () async {
      answer({});

      await check(api.probeOAuthLogin('github'))
          .throws<OAuthLoginProbeException>(
            (it) => it
                .has((it) => it.failure, 'failure')
                .equals(OAuthLoginProbeFailure.notFound),
          );
    });

    test('that cannot be reached fails as the request did', () async {
      answer({
        '/oauth/oidc/login': () =>
            _json(HttpStatus.badGateway, '{"detail":"Bad Gateway"}'),
      });

      await check(api.probeOAuthLogin('oidc')).throws<DioException>(
        (it) => it
            .has((it) => it.response?.statusCode, 'status')
            .equals(HttpStatus.badGateway),
      );
    });

    test('is asked only for a provider name', () async {
      final adapter = answer({});

      for (final provider in ['', '../admin', 'OIDC', 'a/b']) {
        await check(
          because: provider,
          api.probeOAuthLogin(provider),
        ).throws<ArgumentError>();
      }
      check(adapter.requests).isEmpty();
    });
  });

  group('the exchange', () {
    const path = '/api/v1/auths/oauth/oidc/token/exchange';

    test('trades the access token for a session', () async {
      final adapter = answer({
        path: () => _json(
          HttpStatus.ok,
          '{"token":"session-jwt","token_type":"Bearer","id":"user-1"}',
        ),
      });

      final answered = await api.exchangeOAuthToken('oidc', 'access-token');

      check(answered).deepEquals({
        'token': 'session-jwt',
        'token_type': 'Bearer',
        'id': 'user-1',
      });
      final request = adapter.requests.single;
      check(request.method).equals('POST');
      check(request.data as Map<String, dynamic>)
          .deepEquals({'token': 'access-token'});
      check(request.headers.containsKey('Authorization')).isFalse();
      check(request.headers['Cookie']).equals('proxy_session=abc');
    });

    test('returns a second step as it came', () async {
      answer({
        path: () => _json(
          HttpStatus.ok,
          '{"next_step":"verify","challenge_token":"challenge",'
          '"expires_in":300}',
        ),
      });

      check(await api.exchangeOAuthToken('oidc', 'access-token')).deepEquals({
        'next_step': 'verify',
        'challenge_token': 'challenge',
        'expires_in': 300,
      });
    });

    test('refused, fails with the server\'s reason', () async {
      answer({
        path: () => _json(
          HttpStatus.forbidden,
          '{"detail":"User not found. Please sign in via the web interface '
          'first."}',
        ),
      });

      await check(api.exchangeOAuthToken('oidc', 'access-token'))
          .throws<DioException>((it) {
            it
                .has((it) => it.response?.statusCode, 'status')
                .equals(HttpStatus.forbidden);
            it
                .has((it) => (it.response?.data as Map)['detail'], 'detail')
                .isA<String>()
                .startsWith('User not found');
          });
    });

    test('answered with anything but an object fails', () async {
      answer({path: () => _page(HttpStatus.ok)});

      await check(api.exchangeOAuthToken('oidc', 'access-token'))
          .throws<FormatException>();
    });
  });
}
