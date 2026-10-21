import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpHeaders, HttpStatus;
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/browser_sign_in/browser_sign_in_failure.dart';
import 'package:conduit_core/auth/browser_sign_in/browser_sign_in_service.dart';
import 'package:conduit_core/auth/oidc/oidc.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/browser_sign_in_config.dart';
import 'package:conduit_core/models/browser_sign_in_session.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/ports/browser_auth_port.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/conduit_core.dart' show InlineWorkerPort;
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

const _issuer = 'https://id.example/realms/main';
const _authorize = '$_issuer/protocol/openid-connect/auth';
const _tokenEndpoint = '$_issuer/protocol/openid-connect/token';
const _revocation = '$_issuer/protocol/openid-connect/revoke';
const _exchangePath = '/api/v1/auths/oauth/oidc/token/exchange';
const _config = BrowserSignInConfig(provider: 'oidc', clientId: 'conduit');

/// Shaped like an Open WebUI JWT, so a caller's format check accepts it.
const _owuiToken = 'eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InVzZXItYSJ9.sig';

/// Open WebUI's side: its login route and token exchange, by path.
final class _OpenWebUi implements HttpClientAdapter {
  _OpenWebUi(this.answers);

  final Map<String, ResponseBody Function(RequestOptions)> answers;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return answers[options.uri.path]?.call(options) ??
        _json(HttpStatus.notFound, {'detail': 'Not Found'});
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, Object body) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

ResponseBody _redirectTo(String location) => ResponseBody.fromString(
  '',
  HttpStatus.found,
  headers: {
    HttpHeaders.locationHeader: [location],
  },
);

/// Open WebUI sending a browser to [authorize] for its own sign-in.
ResponseBody _loginRedirect({String authorize = _authorize}) => _redirectTo(
  Uri.parse(authorize)
      .replace(
        queryParameters: {
          'response_type': 'code',
          'client_id': 'open-webui',
          'redirect_uri': 'https://chat.example/oauth/oidc/callback',
          'state': 'open-webui-state',
          'audience': 'chat-api',
        },
      )
      .toString(),
);

/// The identity provider: its discovery document, token and revocation
/// endpoints. Records each request.
final class _Idp {
  final requests = <http.Request>[];
  String refreshTokenIssued = 'idp-refresh';
  Map<String, Object?>? tokenError;
  bool unreachable = false;

  /// Runs before the token endpoint answers a refresh.
  FutureOr<void> Function()? onRefresh;

  late final MockClient client = MockClient((request) async {
    requests.add(request);
    if (unreachable) throw http.ClientException('offline');
    final url = request.url.toString();
    if (url == '$_issuer/.well-known/openid-configuration') {
      return _jsonResponse(200, {
        'issuer': _issuer,
        'authorization_endpoint': _authorize,
        'token_endpoint': _tokenEndpoint,
        'revocation_endpoint': _revocation,
        'scopes_supported': ['openid', 'email', 'profile', 'offline_access'],
      });
    }
    if (url == _tokenEndpoint) {
      if (request.bodyFields['grant_type'] == 'refresh_token') {
        await onRefresh?.call();
      }
      final error = tokenError;
      if (error != null) return _jsonResponse(400, error);
      return _jsonResponse(200, {
        'access_token': 'idp-access',
        'refresh_token': refreshTokenIssued,
        'token_type': 'Bearer',
        'scope': 'openid email profile offline_access',
        'expires_in': 300,
      });
    }
    if (url == _revocation) return http.Response('', 200);
    return _jsonResponse(404, {'error': 'not_found'});
  });

  Iterable<http.Request> get tokenRequests =>
      requests.where((request) => request.url.toString() == _tokenEndpoint);
}

http.Response _jsonResponse(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// The system browser: answers each sign-in with [answer].
final class _Browser implements BrowserAuthPort {
  _Browser(this.answer);

  BrowserAuthResult Function(Uri url, Uri redirectUri) answer;
  final opened = <Uri>[];
  bool supported = true;

  @override
  bool get isSupported => supported;

  @override
  Uri get defaultRedirectUri => Uri.parse(browserAuthDefaultRedirect);

  @override
  Future<BrowserAuthResult> authorize(
    Uri url, {
    required Uri redirectUri,
    bool preferEphemeral = false,
  }) async {
    opened.add(url);
    return answer(url, redirectUri);
  }

  @override
  Future<void> cancel() async {}
}

/// The identity provider signing the user in and sending them back.
BrowserAuthResult _signedIn(Uri url, Uri redirectUri) => BrowserAuthResult(
  outcome: BrowserAuthOutcome.success,
  callbackUri: redirectUri.replace(
    queryParameters: {
      'code': 'the-code',
      'state': url.queryParameters['state']!,
    },
  ),
);

final class _Storage extends Mock implements OptimizedStorageService {}

BrowserSignInSession _session({String refreshToken = 'saved-refresh'}) =>
    BrowserSignInSession(
      serverId: 'server-1',
      provider: 'oidc',
      clientId: 'conduit',
      issuer: _issuer,
      tokenEndpoint: _tokenEndpoint,
      revocationEndpoint: _revocation,
      refreshToken: refreshToken,
      scope: 'openid email profile offline_access',
      owuiUserId: 'user-a',
    );

OpenWebUiRegistry _registry({BrowserSignInConfig? config = _config}) =>
    OpenWebUiRegistry(
      servers: [
        OpenWebUiServer(
          id: 'server-1',
          name: 'Chat',
          endpoints: [
            OpenWebUiEndpoint(id: 'endpoint-1', url: 'https://chat.example'),
          ],
          browserSignIn: config,
        ),
      ],
      accounts: [OpenWebUiAccount(id: 'account-a', serverId: 'server-1')],
    );

void main() {
  late WorkerManager workerManager;
  late ApiService api;
  late _OpenWebUi openWebUi;
  late _Idp idp;
  late _Browser browser;
  late BrowserSignInService service;

  /// What the exchange answers next.
  late ResponseBody Function() exchangeAnswer;

  setUpAll(() {
    registerFallbackValue(_session());
  });

  setUp(() {
    workerManager = WorkerManager(worker: const InlineWorkerPort());
    api = ApiService(
      serverConfig: const ServerConfig(
        id: 'account-a',
        name: 'Chat',
        url: 'https://chat.example',
      ),
      workerManager: workerManager,
    );
    exchangeAnswer = () => _json(200, {
      'id': 'user-a',
      'token': _owuiToken,
      'token_type': 'Bearer',
    });
    openWebUi = _OpenWebUi({
      '/oauth/oidc/login': (_) => _loginRedirect(),
      _exchangePath: (_) => exchangeAnswer(),
    });
    api.dio.httpClientAdapter = openWebUi;
    idp = _Idp();
    browser = _Browser(_signedIn);
    service = BrowserSignInService(
      port: browser,
      http: (route) => OidcHttp(route: route, client: idp.client),
    );
    addTearDown(() {
      api.dispose();
      workerManager.dispose();
    });
  });

  Future<BrowserSignInGrant?> authorize({
    BrowserSignInConfig config = _config,
    String? prompt,
    String? loginHint,
  }) => service.authorize(
    api: api,
    config: config,
    serverId: 'server-1',
    prompt: prompt,
    loginHint: loginHint,
  );

  Future<BrowserSignInFailure> failureOf(Future<Object?> future) async {
    try {
      await future;
    } on BrowserSignInException catch (error) {
      return error.failure;
    }
    fail('expected a BrowserSignInException');
  }

  group('signing in', () {
    test('finds the provider Open WebUI uses, signs in to it in the browser, '
        'and redeems the code', () async {
      final grant = await authorize(
        prompt: 'login',
        loginHint: 'a@example.test',
      );

      check(grant).isNotNull()
        ..has((g) => g.serverId, 'serverId').equals('server-1')
        ..has((g) => g.issuer, 'issuer').equals(_issuer)
        ..has((g) => g.accessToken, 'accessToken').equals('idp-access')
        ..has((g) => g.refreshToken, 'refreshToken').equals('idp-refresh')
        ..has(
          (g) => g.revocationEndpoint,
          'revocationEndpoint',
        ).equals(Uri.parse(_revocation));
      final url = browser.opened.single;
      check(url.path).equals(Uri.parse(_authorize).path);
      check(url.queryParameters)
        ..['client_id'].equals('conduit')
        ..['redirect_uri'].equals('conduit://oauth/callback')
        ..['code_challenge_method'].equals('S256')
        ..['scope'].equals('openid email profile offline_access')
        ..['audience'].equals('chat-api')
        ..['prompt'].equals('login')
        ..['login_hint'].equals('a@example.test');
      // Open WebUI's own state stays with its own sign-in.
      check(url.queryParameters['state'])
          .not((s) => s.equals('open-webui-state'));
      final redeem = idp.tokenRequests.single.bodyFields;
      check(redeem)
        ..['grant_type'].equals('authorization_code')
        ..['code'].equals('the-code')
        ..['client_id'].equals('conduit');
      check(redeem.containsKey('client_secret')).isFalse();
      // The probe never carries a session.
      check(openWebUi.requests.single.headers.containsKey('Authorization'))
          .isFalse();
    });

    test(
      'the session it keeps is for the user Open WebUI signs in as',
      () async {
        final grant = (await authorize())!;
        check(grant.session(owuiUserId: 'user-a')).isNotNull()
          ..has((s) => s.owuiUserId, 'owuiUserId').equals('user-a')
          ..has((s) => s.serverId, 'serverId').equals('server-1')
          ..has((s) => s.refreshToken, 'refreshToken').equals('idp-refresh')
          ..has((s) => s.tokenEndpoint, 'tokenEndpoint').equals(_tokenEndpoint);
        check(grant.toString()).not((s) => s.contains('idp-access'));
      },
    );

    test('a grant without a refresh token keeps no session', () {
      final grant = BrowserSignInGrant(
        serverId: 'server-1',
        provider: 'oidc',
        clientId: 'conduit',
        issuer: _issuer,
        tokenEndpoint: Uri.parse(_tokenEndpoint),
        accessToken: 'idp-access',
      );
      check(grant.session(owuiUserId: 'user-a')).isNull();
    });

    test('closing the browser is no failure', () async {
      browser.answer = (_, _) => const BrowserAuthResult.cancelled();
      check(await authorize()).isNull();
      check(idp.tokenRequests).isEmpty();
    });

    for (final (code, failure) in [
      (
        BrowserAuthErrorCodes.authTabRequired,
        BrowserSignInFailure.authTabRequired,
      ),
      (
        BrowserAuthErrorCodes.noBrowser,
        BrowserSignInFailure.browserUnavailable,
      ),
      (
        BrowserAuthErrorCodes.presentationFailed,
        BrowserSignInFailure.presentationFailed,
      ),
      (
        BrowserAuthErrorCodes.unexpectedCallback,
        BrowserSignInFailure.callbackMismatch,
      ),
    ]) {
      test('a browser that fails with $code', () async {
        browser.answer = (_, _) => BrowserAuthResult.failed(code);
        check(await failureOf(authorize())).equals(failure);
      });
    }

    test('a newer sign-in replacing this one is no failure', () async {
      browser.answer = (_, _) =>
          const BrowserAuthResult.failed(BrowserAuthErrorCodes.superseded);
      check(await authorize()).isNull();
    });

    test('a callback for another sign-in is refused before its code is '
        'redeemed', () async {
      browser.answer = (url, redirect) => BrowserAuthResult(
        outcome: BrowserAuthOutcome.success,
        callbackUri: redirect.replace(
          queryParameters: {'code': 'stolen', 'state': 'not-ours'},
        ),
      );
      check(await failureOf(authorize()))
          .equals(BrowserSignInFailure.stateMismatch);
      check(idp.tokenRequests).isEmpty();
    });

    test('a Google client ID that is not one cannot sign in', () async {
      check(
        await failureOf(
          authorize(
            config: const BrowserSignInConfig(
              provider: 'google',
              clientId: 'not-a-google-client',
            ),
          ),
        ),
      ).equals(BrowserSignInFailure.invalidClientId);
      check(browser.opened).isEmpty();
    });

    test('no system browser', () async {
      browser.supported = false;
      check(await failureOf(authorize()))
          .equals(BrowserSignInFailure.browserUnavailable);
    });

    test('a server without the provider', () async {
      openWebUi.answers.remove('/oauth/oidc/login');
      check(await failureOf(authorize()))
          .equals(BrowserSignInFailure.probeNotFound);
    });

    test('a reverse proxy answering for Open WebUI', () async {
      openWebUi.answers['/oauth/oidc/login'] = (_) => ResponseBody.fromString(
        '<html>Sign in to the proxy</html>',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html'],
        },
      );
      check(await failureOf(authorize()))
          .equals(BrowserSignInFailure.proxySignInRequired);
    });

    test(
      'an identity provider discovery cannot find asks for its issuer',
      () async {
        openWebUi.answers['/oauth/oidc/login'] = (_) =>
            _loginRedirect(authorize: 'https://elsewhere.example/authorize');
        check(await failureOf(authorize()))
            .equals(BrowserSignInFailure.discoveryNotFound);
        check(browser.opened).isEmpty();
      },
    );
  });

  group('the exchange', () {
    Future<BrowserSignInAnswer> exchange() =>
        service.exchange(api: api, provider: 'oidc', accessToken: 'idp-access');

    test('answers with a session', () async {
      final answer = await exchange();
      check(answer)
          .isA<BrowserSignInSessionToken>()
          .has((a) => a.token, 'token')
          .equals(_owuiToken);
      final request = openWebUi.requests.single;
      check(request.data)
          .isA<Map<String, dynamic>>()['token']
          .equals('idp-access');
      check(request.headers.containsKey('Authorization')).isFalse();
    });

    test('answers with a second step', () async {
      exchangeAnswer = () => _json(200, {
        'next_step': 'verify',
        'challenge_token': 'challenge',
        'expires_in': 300,
      });
      final answer = await exchange();
      check(answer)
          .isA<BrowserSignInSecondStep>()
          .has((a) => a.challenge.challengeToken, 'challengeToken')
          .equals('challenge');
    });

    test('an account awaiting approval', () async {
      exchangeAnswer = () => _json(200, {'next_step': 'pending'});
      check(await failureOf(exchange()))
          .equals(BrowserSignInFailure.accountPendingApproval);
    });

    for (final (status, detail, failure) in [
      (
        403,
        'Token exchange is disabled',
        BrowserSignInFailure.exchangeDisabled,
      ),
      (
        403,
        'User not found. Please sign in via the web interface first.',
        BrowserSignInFailure.userNotFound,
      ),
      (
        403,
        'You do not have permission to access this resource.',
        BrowserSignInFailure.accessProhibited,
      ),
      (
        404,
        "Provider 'oidc' is not configured",
        BrowserSignInFailure.providerNotConfigured,
      ),
      (404, 'Not Found', BrowserSignInFailure.serverTooOld),
      (
        400,
        'Unable to determine which client the token was issued to',
        BrowserSignInFailure.cannotDetermineClient,
      ),
      (
        400,
        'Token missing required email claim',
        BrowserSignInFailure.missingClaims,
      ),
      (
        400,
        'Invalid token or unable to validate with provider',
        BrowserSignInFailure.tokenRejectedByServer,
      ),
      (
        409,
        'Authentication changed. Please sign in again.',
        BrowserSignInFailure.authenticationChanged,
      ),
      (429, 'API rate limit exceeded', BrowserSignInFailure.rateLimited),
      (502, 'Bad Gateway', BrowserSignInFailure.serverError),
    ]) {
      test('refused with $status "$detail"', () async {
        exchangeAnswer = () => _json(status, {'detail': detail});
        check(await failureOf(exchange())).equals(failure);
      });
    }

    test('a proxy page refusing it', () async {
      exchangeAnswer = () => ResponseBody.fromString(
        '<html>Forbidden</html>',
        403,
        headers: {
          Headers.contentTypeHeader: ['text/html'],
        },
      );
      check(await failureOf(exchange()))
          .equals(BrowserSignInFailure.proxySignInRequired);
    });
  });

  group('renewing', () {
    late _Storage storage;

    void saves(Future<bool> Function() answer) => when(
      () => storage.replaceBrowserSignInSessionIfCurrent(
        'account-a',
        expected: any(named: 'expected'),
        next: any(named: 'next'),
      ),
    ).thenAnswer((_) => answer());

    setUp(() {
      storage = _Storage();
      when(() => storage.browserSignInSessionFor('account-a'))
          .thenAnswer((_) async => _session());
      when(() => storage.getOpenWebUiRegistryStrict())
          .thenAnswer((_) async => _registry());
      saves(() async => true);
    });

    Future<BrowserSignInRenewal> renew() =>
        service.renew(accountId: 'account-a', api: api, storage: storage);

    test('saves the rotated refresh token before it is used, then trades '
        'the new access token', () async {
      idp.refreshTokenIssued = 'rotated-refresh';
      var savedBeforeExchange = false;
      saves(() async {
        savedBeforeExchange = openWebUi.requests.isEmpty;
        return true;
      });

      final renewal = await renew();

      check(savedBeforeExchange).isTrue();
      check(renewal.token).equals(_owuiToken);
      check(renewal.session.refreshToken).equals('rotated-refresh');
      final saved = verify(
        () => storage.replaceBrowserSignInSessionIfCurrent(
          'account-a',
          expected: captureAny(named: 'expected'),
          next: captureAny(named: 'next'),
        ),
      ).captured;
      check(saved[0]).equals(_session());
      check(saved[1]).equals(_session(refreshToken: 'rotated-refresh'));
      final refresh = idp.tokenRequests.single.bodyFields;
      check(refresh)
        ..['grant_type'].equals('refresh_token')
        ..['refresh_token'].equals('saved-refresh')
        ..['client_id'].equals('conduit');
    });

    test('a refresh token that did not rotate is not written again', () async {
      idp.refreshTokenIssued = 'saved-refresh';
      final renewal = await renew();
      check(renewal.session).equals(_session());
      verifyNever(
        () => storage.replaceBrowserSignInSessionIfCurrent(
          any(),
          expected: any(named: 'expected'),
          next: any(named: 'next'),
        ),
      );
    });

    test('two callers at once share one refresh', () async {
      final release = Completer<void>();
      idp.onRefresh = () => release.future;
      final first = renew();
      final second = renew();
      release.complete();
      final results = await Future.wait([first, second]);
      check(results[0].token).equals(results[1].token);
      check(idp.tokenRequests.length).equals(1);
    });

    test('a session something else replaced meanwhile stops the renewal '
        'before the exchange', () async {
      idp.refreshTokenIssued = 'rotated-refresh';
      saves(() async => false);
      check(await failureOf(renew()))
          .equals(BrowserSignInFailure.accountChanged);
      check(openWebUi.requests).isEmpty();
    });

    test('an account without a session', () async {
      when(() => storage.browserSignInSessionFor('account-a'))
          .thenAnswer((_) async => null);
      check(await failureOf(renew()))
          .equals(BrowserSignInFailure.refreshExpired);
      check(idp.requests).isEmpty();
    });

    test('settings changed since the account signed in', () async {
      when(() => storage.getOpenWebUiRegistryStrict()).thenAnswer(
        (_) async => _registry(
          config: const BrowserSignInConfig(
            provider: 'oidc',
            clientId: 'another-client',
          ),
        ),
      );
      check(await failureOf(renew()))
          .equals(BrowserSignInFailure.configMismatch);
      check(idp.requests).isEmpty();
    });

    test('a refresh token the provider no longer accepts', () async {
      idp.tokenError = {'error': 'invalid_grant'};
      final failure = await failureOf(renew());
      check(failure).equals(BrowserSignInFailure.refreshExpired);
      check(failure.isTerminal).isTrue();
    });

    test('an unreachable provider keeps the session', () async {
      idp.unreachable = true;
      final failure = await failureOf(renew());
      check(failure).equals(BrowserSignInFailure.network);
      check(failure.isTransient).isTrue();
    });

    test('a second step cannot be taken without the user', () async {
      exchangeAnswer = () =>
          _json(200, {'next_step': 'verify', 'challenge_token': 'challenge'});
      final failure = await failureOf(renew());
      check(failure).equals(BrowserSignInFailure.twoStepRequired);
      check(failure.isTerminal).isTrue();
      check(failure.renewalErrorMessage).equals('twoStepVerificationRequired');
    });
  });

  group('the Test button', () {
    test('finds the provider, and an exchange that checks tokens', () async {
      exchangeAnswer = () => _json(400, {
        'detail': 'Invalid token or unable to validate with provider',
      });
      final diagnosis = await service.diagnose(api: api, config: _config);
      check(diagnosis.issuer).equals(_issuer);
      check(diagnosis.ready).isTrue();
      check(browser.opened).isEmpty();
    });

    test('an exchange that is off', () async {
      exchangeAnswer = () =>
          _json(403, {'detail': 'Token exchange is disabled'});
      final diagnosis = await service.diagnose(api: api, config: _config);
      check(diagnosis.exchangeFailure)
          .equals(BrowserSignInFailure.exchangeDisabled);
      check(diagnosis.ready).isFalse();
    });

    test('an exchange that only trusts listed clients', () async {
      exchangeAnswer = () => _json(400, {
        'detail': 'Unable to determine which client the token was issued to',
      });
      final diagnosis = await service.diagnose(api: api, config: _config);
      check(diagnosis.exchangeFailure)
          .equals(BrowserSignInFailure.cannotDetermineClient);
    });

    test('a provider that cannot be reached', () async {
      idp.unreachable = true;
      exchangeAnswer = () => _json(400, {
        'detail': 'Invalid token or unable to validate with provider',
      });
      final diagnosis = await service.diagnose(api: api, config: _config);
      check(diagnosis.issuer).isNull();
      check(diagnosis.discoveryFailure).equals(BrowserSignInFailure.network);
    });
  });

  group('revoking', () {
    test('sends the refresh token to the revocation endpoint', () async {
      await service.revokeBestEffort(_session());
      final request = idp.requests.single;
      check(request.url.toString()).equals(_revocation);
      check(request.bodyFields)
        ..['token'].equals('saved-refresh')
        ..['token_type_hint'].equals('refresh_token')
        ..['client_id'].equals('conduit');
    });

    test('never throws', () async {
      idp.unreachable = true;
      await service.revokeBestEffort(_session());
    });

    test('a provider without a revocation endpoint is not asked', () async {
      await service.revokeBestEffort(
        const BrowserSignInSession(
          serverId: 'server-1',
          provider: 'oidc',
          clientId: 'conduit',
          issuer: _issuer,
          tokenEndpoint: _tokenEndpoint,
          refreshToken: 'saved-refresh',
          owuiUserId: 'user-a',
        ),
      );
      check(idp.requests).isEmpty();
    });
  });

  group('renewal ahead of expiry', () {
    String token(Map<String, Object?> claims) {
      final payload = base64Url
          .encode(utf8.encode(jsonEncode(claims)))
          .replaceAll('=', '');
      return 'eyJhbGciOiJIUzI1NiJ9.$payload.sig';
    }

    final now = DateTime.utc(2026, 10, 21, 12);
    final seconds = now.millisecondsSinceEpoch ~/ 1000;

    test('within ten minutes of expiry', () {
      check(browserSessionNeedsRenewal(token({'exp': seconds + 300}), now: now))
          .isTrue();
      check(
        browserSessionNeedsRenewal(token({'exp': seconds + 3600}), now: now),
      ).isFalse();
    });

    test('within the last tenth of its lifetime', () {
      check(
        browserSessionNeedsRenewal(
          token({'iat': seconds - 86400 * 9, 'exp': seconds + 43200}),
          now: now,
        ),
      ).isTrue();
      check(
        browserSessionNeedsRenewal(
          token({'iat': seconds - 3600, 'exp': seconds + 86400}),
          now: now,
        ),
      ).isFalse();
    });

    test('a session that never expires', () {
      check(browserSessionNeedsRenewal(token({'id': 'user-a'}), now: now))
          .isFalse();
      check(browserSessionNeedsRenewal('not-a-jwt', now: now)).isFalse();
    });
  });

  test('only OIDC, Microsoft and Google sign in through the browser', () {
    const providers = OAuthProviders(
      google: 'Google',
      github: 'GitHub',
      oidc: 'Company SSO',
      feishu: 'Feishu',
    );
    check(browserSignInEligibleProviders(providers))
        .deepEquals(['google', 'oidc']);
    check(browserSignInServerSupported('0.7.2')).isFalse();
    check(browserSignInServerSupported('0.8.0')).isTrue();
    check(browserSignInServerSupported(null)).isTrue();
  });

  test('every failure is exactly one of silent, transient or terminal', () {
    for (final failure in BrowserSignInFailure.values) {
      final kinds = [
        failure.isSilent,
        failure.isTransient,
        failure.isTerminal,
      ].where((kind) => kind);
      check(because: failure.name, kinds.length).equals(1);
    }
    check(BrowserSignInFailure.proxySignInRequired.isTransient).isTrue();
    check(BrowserSignInFailure.userMismatch.isTerminal).isTrue();
    check(BrowserSignInFailure.configMismatch.isTerminal).isTrue();
  });
}
