import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/auth/browser_sign_in/browser_sign_in_failure.dart';
import 'package:conduit_core/auth/browser_sign_in/browser_sign_in_service.dart';
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/auth/openwebui_two_step.dart';
import 'package:conduit_core/database/account_storage_isolation.dart';
import 'package:conduit_core/models/browser_sign_in_config.dart';
import 'package:conduit_core/models/browser_sign_in_session.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/browser_auth_port.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_time.dart';

const _server = ServerConfig(
  id: 'account-a',
  name: 'A',
  url: 'https://a.example',
);

const _userA = User(
  id: 'user-a',
  username: 'a',
  email: 'a@example.test',
  role: 'user',
);

const _config = BrowserSignInConfig(provider: 'oidc', clientId: 'conduit');

/// An Open WebUI session token that expires [expiresIn] from now.
String _jwt(Duration expiresIn, {String tag = 'session'}) {
  final exp = clock.now().add(expiresIn).millisecondsSinceEpoch ~/ 1000;
  final payload = base64Url
      .encode(utf8.encode(jsonEncode({'id': 'user-a', 'exp': exp})))
      .replaceAll('=', '');
  return 'eyJhbGciOiJIUzI1NiJ9.$payload.$tag';
}

final _issued = _jwt(const Duration(days: 1), tag: 'issued');
final _renewed = _jwt(const Duration(days: 1), tag: 'renewed');

BrowserSignInGrant _grant({String? refreshToken = 'idp-refresh'}) =>
    BrowserSignInGrant(
      serverId: 'server-1',
      provider: 'oidc',
      clientId: 'conduit',
      issuer: 'https://id.example',
      tokenEndpoint: Uri.parse('https://id.example/token'),
      revocationEndpoint: Uri.parse('https://id.example/revoke'),
      accessToken: 'idp-access',
      refreshToken: refreshToken,
      scope: 'openid email profile offline_access',
    );

const _session = BrowserSignInSession(
  serverId: 'server-1',
  provider: 'oidc',
  clientId: 'conduit',
  issuer: 'https://id.example',
  tokenEndpoint: 'https://id.example/token',
  revocationEndpoint: 'https://id.example/revoke',
  refreshToken: 'idp-refresh',
  scope: 'openid email profile offline_access',
  owuiUserId: 'user-a',
);

Map<String, String> _savedBrowserSignIn(String token) => {
  'serverId': 'account-a',
  'username': 'jwt_user',
  'password': token,
  'authType': 'sso_browser',
};

OpenWebUiRegistry _registry({
  bool secondAccount = false,
  String? userId,
  BrowserSignInConfig config = _config,
}) => OpenWebUiRegistry(
  servers: [
    OpenWebUiServer(
      id: 'server-1',
      name: 'Chat',
      endpoints: [OpenWebUiEndpoint(id: 'e1', url: 'https://a.example')],
      browserSignIn: config,
    ),
  ],
  accounts: [
    OpenWebUiAccount(id: 'account-a', serverId: 'server-1', userId: userId),
    if (secondAccount) OpenWebUiAccount(id: 'account-b', serverId: 'server-1'),
  ],
);

/// Signing in through the system browser, renewing that sign-in with the
/// identity provider's refresh token whenever its Open WebUI session lapses,
/// and revoking the refresh token on every way out.
void main() {
  setUpAll(() {
    registerFallbackValue(_userA);
    registerFallbackValue(<String, String>{});
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      PreferenceKeys.activeServerId: 'account-a',
    });
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  });

  tearDown(PreferencesStore.debugReset);

  group('signing in', () {
    test('commits the exchanged session, saved as a browser sign-in with '
        'the identity provider session for the user it signed in as', () async {
      final rig = await _Rig.start();

      check(await rig.auth.loginWithBrowser(config: _config)).isTrue();

      final state = rig.state;
      check(state.status).equals(AuthStatus.authenticated);
      check(state.token).equals(_issued);
      check(rig.storage.remembered).isNotNull().deepEquals({
        'serverId': 'account-a',
        'username': 'jwt_user',
        'password': _issued,
        'authType': 'sso_browser',
      });
      check(rig.storage.browserSession)
          .isA<BrowserSessionReplace>()
          .has((c) => c.session, 'session')
          .equals(_session);
      final call = rig.service.authorizeCalls.single;
      check(call.serverId).equals('server-1');
      check(call.prompt).isNull();
      check(call.loginHint).isNull();
      check(rig.service.exchanges.single.accessToken).equals('idp-access');
      // Nothing showed as loading while the browser was open.
      check(rig.statuses).not((s) => s.contains(AuthStatus.loading));
    });

    test('a provider that issues no refresh token signs in as a plain SSO '
        'sign-in, with nothing to renew', () async {
      final rig = await _Rig.start();
      rig.service.grant = _grant(refreshToken: null);

      check(await rig.auth.loginWithBrowser(config: _config)).isTrue();

      check(rig.storage.remembered?['authType']).equals('sso');
      check(rig.storage.browserSession).isA<BrowserSessionDelete>();
    });

    for (final (provider, secondAccount, prompt) in [
      ('oidc', true, 'login'),
      ('microsoft', true, 'select_account'),
      ('microsoft', false, null),
      ('google', true, 'select_account consent'),
      ('google', false, 'consent'),
    ]) {
      test('$provider with${secondAccount ? '' : 'out'} another account on '
          'the server asks for prompt=$prompt', () async {
        final config = BrowserSignInConfig(
          provider: provider,
          clientId: 'conduit',
        );
        final rig = await _Rig.start(
          registry: _registry(secondAccount: secondAccount, config: config),
        );

        await rig.auth.loginWithBrowser(config: config);

        check(rig.service.authorizeCalls.single.prompt).equals(prompt);
      });
    }

    test('an account proved to be a user is hinted with its email', () async {
      final rig = await _Rig.start(
        registry: _registry(userId: 'user-a'),
        summaries: const {
          'account-a': OpenWebUiAccountSummary(email: 'a@example.test'),
        },
      );

      await rig.auth.loginWithBrowser(config: _config);

      check(rig.service.authorizeCalls.single.loginHint)
          .equals('a@example.test');
    });

    test('closing the browser stops quietly', () async {
      final rig = await _Rig.start();
      rig.service.grant = null;

      check(await rig.auth.loginWithBrowser(config: _config)).isFalse();

      check(rig.service.exchanges).isEmpty();
      check(rig.state.error).isNull();
    });

    test('Cancel before the browser opens keeps it closed', () async {
      final rig = await _Rig.start();
      rig.service.findingProvider = Completer<void>();

      final signIn = rig.auth.loginWithBrowser(config: _config);
      await pumpEventQueue();
      await rig.auth.cancelBrowserSignIn();
      rig.service.findingProvider!.complete();

      check(await signIn).isFalse();
      check(rig.service.browserOpened).equals(0);
      check(rig.storage.remembered).isNull();
      check(rig.state.isAuthenticated).isFalse();
    });

    test('Cancel after the browser came back commits nothing it brings',
        () async {
      final rig = await _Rig.start();
      rig.service.exchanging = Completer<void>();

      final signIn = rig.auth.loginWithBrowser(config: _config);
      await pumpEventQueue();
      check(rig.service.exchanges).length.equals(1);
      await rig.auth.cancelBrowserSignIn();
      rig.service.exchanging!.complete();

      check(await signIn).isFalse();
      check(rig.storage.remembered).isNull();
      check(rig.state.isAuthenticated).isFalse();
    });

    test('a sign-in begun after Cancel is not called off by it', () async {
      final rig = await _Rig.start();
      rig.service.findingProvider = Completer<void>();
      final cancelled = rig.auth.loginWithBrowser(config: _config);
      await pumpEventQueue();
      await rig.auth.cancelBrowserSignIn();
      rig.service.findingProvider!.complete();
      check(await cancelled).isFalse();
      rig.service.findingProvider = null;

      check(await rig.auth.loginWithBrowser(config: _config)).isTrue();
      check(rig.state.token).equals(_issued);
    });

    test('another account becoming active while the browser is open stops '
        'it before the exchange', () async {
      final rig = await _Rig.start();
      rig.service.duringBrowser = () => rig.activeId = 'account-b';

      check(await rig.auth.loginWithBrowser(config: _config)).isFalse();

      check(rig.service.exchanges).isEmpty();
      check(rig.storage.committedToken).isNull();
    });

    test('an addition cancelled while the browser is open stops it before '
        'the exchange', () async {
      final rig = await _Rig.start();
      var stillAdding = true;
      rig.service.duringBrowser = () => stillAdding = false;

      check(
        await rig.auth.loginWithBrowser(
          config: _config,
          canCommit: () => stillAdding,
        ),
      ).isFalse();

      check(rig.service.exchanges).isEmpty();
      check(rig.storage.committedToken).isNull();
    });

    test('an account moved to another address while the browser was open '
        'is exchanged and committed there', () async {
      final rig = await _Rig.start();
      final public = _Api(
        rig.workerManager,
        serverConfig: const ServerConfig(
          id: 'account-a',
          name: 'A',
          url: 'https://public.example',
        ),
      );
      rig.service.duringBrowser = () {
        rig.api = public;
        rig.container.invalidate(apiServiceProvider);
      };

      check(await rig.auth.loginWithBrowser(config: _config)).isTrue();

      check(rig.service.authorizeCalls.single.api.serverConfig.url)
          .equals('https://a.example');
      check(rig.service.exchanges.single.api).identicalTo(public);
      check(rig.storage.ownershipConfigs.last.url)
          .equals('https://public.example');
    });

    fakeTimeTest('a client still being rebuilt when the browser returns is '
        'waited for, not taken for another account', () async {
      final rig = await _Rig.start();
      rig.service.duringBrowser = () {
        rig.apiGone = true;
        rig.container.invalidate(apiServiceProvider);
        Timer(const Duration(milliseconds: 120), () {
          rig.apiGone = false;
          rig.container.invalidate(apiServiceProvider);
        });
      };

      check(await rig.auth.loginWithBrowser(config: _config)).isTrue();

      check(rig.storage.committedToken).equals(_issued);
    });

    test('a commit lost to the account moving to another address is tried '
        'once more there, with the same grant', () async {
      final rig = await _Rig.start();
      rig.storage.refusedCommits = 1;

      check(await rig.auth.loginWithBrowser(config: _config)).isTrue();

      check(rig.service.authorizeCalls).length.equals(1);
      check(rig.service.exchanges).length.equals(2);
      check(rig.storage.committedToken).equals(_issued);
    });

    test('a commit lost twice is a failure to try again', () async {
      final rig = await _Rig.start();
      rig.storage.refusedCommits = 2;

      await check(rig.auth.loginWithBrowser(config: _config))
          .throws<BrowserSignInException>(
            (it) => it
                .has((e) => e.failure, 'failure')
                .equals(BrowserSignInFailure.failed),
          );
      check(rig.storage.committedToken).isNull();
    });

    test('settings other than the server\'s are refused before the browser '
        'opens', () async {
      final rig = await _Rig.start();

      await check(
        rig.auth.loginWithBrowser(
          config: const BrowserSignInConfig(
            provider: 'oidc',
            clientId: 'other',
          ),
        ),
      ).throws<BrowserSignInException>(
        (it) => it
            .has((e) => e.failure, 'failure')
            .equals(BrowserSignInFailure.configMismatch),
      );
      check(rig.service.authorizeCalls).isEmpty();
    });

    test('settings that are the server\'s put another way sign in', () async {
      final rig = await _Rig.start(
        registry: OpenWebUiRegistry(
          servers: [
            OpenWebUiServer(
              id: 'server-1',
              name: 'Chat',
              endpoints: [
                OpenWebUiEndpoint(id: 'e1', url: 'https://a.example'),
              ],
              browserSignIn: const BrowserSignInConfig(
                provider: 'oidc',
                clientId: 'conduit',
                issuer: 'https://id.example/',
              ),
            ),
          ],
          accounts: [OpenWebUiAccount(id: 'account-a', serverId: 'server-1')],
        ),
      );

      check(
        await rig.auth.loginWithBrowser(
          config: const BrowserSignInConfig(
            provider: 'oidc',
            clientId: 'conduit',
            issuer: 'https://ID.example:443',
          ),
        ),
      ).isTrue();
    });

    test(
      'a refusal is thrown with its reason, and nothing is committed',
      () async {
        final rig = await _Rig.start();
        rig.service.exchangeError = const BrowserSignInException(
          BrowserSignInFailure.exchangeDisabled,
        );

        await check(rig.auth.loginWithBrowser(config: _config))
            .throws<BrowserSignInException>(
              (it) => it
                  .has((e) => e.failure, 'failure')
                  .equals(BrowserSignInFailure.exchangeDisabled),
            );
        check(rig.storage.committedToken).isNull();
      },
    );

    test('a user Open WebUI does not know yet signs in on retry with the '
        'same access token, without the browser', () async {
      final rig = await _Rig.start();
      rig.service.exchangeError = const BrowserSignInException(
        BrowserSignInFailure.userNotFound,
      );
      await check(rig.auth.loginWithBrowser(config: _config))
          .throws<BrowserSignInException>();

      rig.service.exchangeError = null;
      check(await rig.auth.retryBrowserExchange()).isTrue();

      check(rig.service.authorizeCalls.length).equals(1);
      check(rig.service.exchanges.map((e) => e.accessToken))
          .deepEquals(['idp-access', 'idp-access']);
      check(rig.state.token).equals(_issued);
      // Spent: there is nothing left to retry.
      check(await rig.auth.retryBrowserExchange()).isFalse();
    });

    test('a second step is taken as a password sign-in takes it, and the '
        'session it issues keeps the identity provider session', () async {
      final rig = await _Rig.start();
      rig.service.answer = () => const BrowserSignInSecondStep(
        OpenWebUiTwoStepChallenge(
          kind: OpenWebUiTwoStepKind.verify,
          challengeToken: 'user-a.challenge',
          expiresIn: Duration(minutes: 5),
        ),
      );

      OpenWebUiTwoStepChallenge? challenge;
      try {
        await rig.auth.loginWithBrowser(config: _config);
      } on OpenWebUiTwoStepRequired catch (e) {
        challenge = e.challenge;
      }
      check(challenge).isNotNull();
      check(rig.state.status).equals(AuthStatus.unauthenticated);
      check(rig.state.error).isNull();
      check(rig.storage.committedToken).isNull();

      final session = await rig.auth.submitTwoStepCode(challenge!, '123456');
      check(await rig.auth.finishTwoStepSignIn(session)).isTrue();

      check(rig.state.token).equals(_issued);
      check(rig.storage.remembered).isNotNull().deepEquals({
        'serverId': 'account-a',
        'username': 'jwt_user',
        'password': _issued,
        'authType': 'sso_browser',
      });
      check(rig.storage.browserSession)
          .isA<BrowserSessionReplace>()
          .has((c) => c.session, 'session')
          .equals(_session);
    });

    test('Test checks a server being added through a client of its own, '
        'and the active account through its own', () async {
      final rig = await _Rig.start();
      const added = ServerConfig(
        id: 'account-new',
        name: 'New',
        url: 'https://new.example',
      );

      await rig.auth.diagnoseBrowserSignIn(_config, server: added);
      await rig.auth.diagnoseBrowserSignIn(_config, server: _server);
      await rig.auth.diagnoseBrowserSignIn(_config);

      check(rig.service.diagnosed).deepEquals([
        rig.savedCredentialApi,
        rig.api,
        rig.api,
      ]);
    });
  });

  group('renewing', () {
    test('an expired session at cold start renews with the identity '
        'provider, keeping the session it renewed with', () async {
      final expired = _jwt(const Duration(minutes: -5), tag: 'expired');
      final rig = await _Rig.start(
        storedToken: expired,
        saved: _savedBrowserSignIn(expired),
        renew: () async => (token: _renewed, session: _session),
      );

      check(rig.state.status).equals(AuthStatus.authenticated);
      check(rig.state.token).equals(_renewed);
      check(rig.service.renewals).equals(1);
      check(rig.storage.expected)
          .isNotNull()
          .deepEquals(_savedBrowserSignIn(expired));
      check(rig.storage.remembered)
          .isNotNull()
          .deepEquals(_savedBrowserSignIn(_renewed));
      check(rig.storage.browserSession).isA<BrowserSessionKeep>();
      verify(() => rig.storage.deleteAuthTokenIfMatches(expired)).called(1);
    });

    test('switching to an account whose session expired renews it', () async {
      final expired = _jwt(const Duration(minutes: -5), tag: 'expired');
      final rig = await _Rig.start(
        activeId: 'account-b',
        renew: () async => (token: _renewed, session: _session),
      );
      when(
        () => rig.storage.switchActiveServer(
          fromServerId: 'account-b',
          toServerId: 'account-a',
        ),
      ).thenAnswer((_) async {
        rig.activeId = 'account-a';
        rig.storedToken = expired;
        rig.saved = _savedBrowserSignIn(expired);
        return true;
      });

      await rig.auth.switchToAccount('account-a');
      final state = await rig.settled();

      check(state.status).equals(AuthStatus.authenticated);
      check(state.token).equals(_renewed);
      check(rig.service.renewals).equals(1);
    });

    test(
      'a renewal that signs in as another user ends the saved sign-in',
      () async {
        final expired = _jwt(const Duration(minutes: -5), tag: 'expired');
        final rig = await _Rig.start(
          storedToken: expired,
          saved: _savedBrowserSignIn(expired),
          renew: () async => (
            token: _renewed,
            session: const BrowserSignInSession(
              serverId: 'server-1',
              provider: 'oidc',
              clientId: 'conduit',
              issuer: 'https://id.example',
              tokenEndpoint: 'https://id.example/token',
              refreshToken: 'idp-refresh',
              owuiUserId: 'someone-else',
            ),
          ),
        );

        check(rig.state.status).equals(AuthStatus.credentialError);
        check(rig.state.error).equals('browserSignInSessionExpired');
        check(rig.storage.committedToken).isNull();
        verify(
          () => rig.storage.deleteSavedCredentialsIfMatches(
            _savedBrowserSignIn(expired),
          ),
        ).called(1);
      },
    );

    for (final (failure, message) in [
      (BrowserSignInFailure.refreshExpired, 'browserSignInSessionExpired'),
      (BrowserSignInFailure.configMismatch, 'browserSignInSessionExpired'),
      (BrowserSignInFailure.twoStepRequired, 'twoStepVerificationRequired'),
      (BrowserSignInFailure.accountPendingApproval, 'accountPendingApproval'),
    ]) {
      test(
        'a renewal that fails with ${failure.name} ends the saved sign-in',
        () async {
          final expired = _jwt(const Duration(minutes: -5), tag: 'expired');
          final rig = await _Rig.start(
            storedToken: expired,
            saved: _savedBrowserSignIn(expired),
            renew: () async => throw BrowserSignInException(failure),
          );

          check(rig.state.status).equals(AuthStatus.credentialError);
          check(rig.state.error).equals(message);
          verify(
            () => rig.storage.deleteSavedCredentialsIfMatches(
              _savedBrowserSignIn(expired),
            ),
          ).called(1);
        },
      );
    }

    test('a renewal that fails for now keeps the saved sign-in', () async {
      final expired = _jwt(const Duration(minutes: -5), tag: 'expired');
      final rig = await _Rig.start(
        storedToken: expired,
        saved: _savedBrowserSignIn(expired),
        renew: () async =>
            throw const BrowserSignInException(BrowserSignInFailure.network),
      );

      check(rig.state.status).equals(AuthStatus.unauthenticated);
      verifyNever(() => rig.storage.deleteSavedCredentialsIfMatches(any()));
    });

    test('a session the server refuses renews in the background, showing '
        'nothing until the new one is in', () async {
      final token = _jwt(const Duration(hours: 1), tag: 'live');
      final rig = await _Rig.start(
        storedToken: token,
        saved: _savedBrowserSignIn(token),
        renew: () async => (token: _renewed, session: _session),
      );
      check(rig.state.token).equals(token);
      rig.statuses.clear();

      rig.auth.onAuthIssue(AuthFailureKind.sessionRejected);
      final state = await rig.settledOn((s) => s.token == _renewed);

      check(state.status).equals(AuthStatus.authenticated);
      check(rig.service.renewals).equals(1);
      check(rig.statuses).deepEquals([AuthStatus.authenticated]);
    });

    test('a sign-in begun while a renewal reads the saved sign-in is not '
        'ended by it', () async {
      final token = _jwt(const Duration(hours: 1), tag: 'live');
      final rig = await _Rig.start(
        storedToken: token,
        saved: _savedBrowserSignIn(token),
        renew: () async => (token: _renewed, session: _session),
      );
      final readHeld = Completer<void>();
      var reads = 0;
      when(() => rig.storage.getSavedCredentialsStrict()).thenAnswer((_) async {
        if (reads++ == 0) await readHeld.future;
        return rig.saved;
      });

      rig.service.browserOpen = Completer<void>();

      rig.auth.onAuthIssue(AuthFailureKind.sessionRejected);
      await pumpEventQueue();
      // The user signs in while the renewal reads, and is in the browser
      // when the read comes back.
      final signIn = rig.auth.loginWithBrowser(config: _config);
      await pumpEventQueue();
      readHeld.complete();
      await pumpEventQueue();
      rig.service.browserOpen!.complete();

      check(await signIn).isTrue();
      check(rig.service.renewals).equals(0);
      check(rig.state.token).equals(_issued);
    });

    test('a sign-in begun while resume checks the saved sign-in is not '
        'ended by the renewal that follows', () async {
      final token = _jwt(const Duration(minutes: 8), tag: 'expiring');
      final rig = await _Rig.start(
        storedToken: token,
        saved: _savedBrowserSignIn(token),
        renew: () async => (token: _renewed, session: _session),
      );
      final readHeld = Completer<void>();
      var reads = 0;
      when(() => rig.storage.getSavedCredentialsStrict()).thenAnswer((_) async {
        if (reads++ == 0) await readHeld.future;
        return rig.saved;
      });
      rig.service.browserOpen = Completer<void>();

      final resumed = rig.auth.renewBrowserSessionIfExpiring();
      await pumpEventQueue();
      final signIn = rig.auth.loginWithBrowser(config: _config);
      await pumpEventQueue();
      readHeld.complete();
      await resumed;
      rig.service.browserOpen!.complete();

      check(await signIn).isTrue();
      check(rig.service.renewals).equals(0);
      check(rig.state.token).equals(_issued);
    });

    test('a refusal during a renewal ahead of expiry is not answered over a '
        'sign-in begun meanwhile', () async {
      final token = _jwt(const Duration(minutes: 8), tag: 'expiring');
      final release = Completer<void>();
      var renewals = 0;
      final rig = await _Rig.start(
        storedToken: token,
        saved: _savedBrowserSignIn(token),
        renew: () async {
          if (renewals++ == 0) {
            await release.future;
            throw const BrowserSignInException(BrowserSignInFailure.timeout);
          }
          return (token: _renewed, session: _session);
        },
      );
      rig.service.browserOpen = Completer<void>();

      final early = rig.auth.renewBrowserSessionIfExpiring();
      await pumpEventQueue();
      rig.auth.onAuthIssue(AuthFailureKind.sessionRejected);
      final signIn = rig.auth.loginWithBrowser(config: _config);
      await pumpEventQueue();
      release.complete();
      await early;
      await pumpEventQueue();
      rig.service.browserOpen!.complete();

      check(await signIn).isTrue();
      check(rig.service.renewals).equals(1);
      check(rig.state.token).equals(_issued);
    });

    test('a burst of refusals renews once', () async {
      final token = _jwt(const Duration(hours: 1), tag: 'live');
      final release = Completer<void>();
      final rig = await _Rig.start(
        storedToken: token,
        saved: _savedBrowserSignIn(token),
        renew: () async {
          await release.future;
          return (token: _renewed, session: _session);
        },
      );

      rig.auth.onAuthIssue(AuthFailureKind.sessionRejected);
      rig.auth.onAuthIssue(AuthFailureKind.sessionRejected);
      await pumpEventQueue();
      rig.auth.onAuthIssue(AuthFailureKind.sessionRejected);
      release.complete();
      await rig.settledOn((s) => s.token == _renewed);

      check(rig.service.renewals).equals(1);
    });

    test('a refusal that cannot be renewed for now shows the connection '
        'issue, keeping the session for Retry', () async {
      final token = _jwt(const Duration(hours: 1), tag: 'live');
      final rig = await _Rig.start(
        storedToken: token,
        saved: _savedBrowserSignIn(token),
        renew: () async =>
            throw const BrowserSignInException(BrowserSignInFailure.timeout),
      );

      rig.auth.onAuthIssue(AuthFailureKind.sessionRejected);
      final state = await rig.settledOn((s) => s.status == AuthStatus.error);

      check(state.token).equals(token);
      verifyNever(() => rig.storage.deleteSavedCredentialsIfMatches(any()));
    });

    for (final kind in [
      AuthFailureKind.proxyPage,
      AuthFailureKind.proxySessionExpired,
    ]) {
      test('a ${kind.name} refusal never renews', () async {
        final token = _jwt(const Duration(hours: 1), tag: 'live');
        final rig = await _Rig.start(
          storedToken: token,
          saved: _savedBrowserSignIn(token),
          renew: () async => (token: _renewed, session: _session),
        );

        rig.auth.onAuthIssue(kind);

        check(rig.state.status).equals(AuthStatus.error);
        await pumpEventQueue();
        check(rig.service.renewals).equals(0);
      });
    }

    test('a refused session that is no browser sign-in shows the connection '
        'issue', () async {
      final token = _jwt(const Duration(hours: 1), tag: 'live');
      final rig = await _Rig.start(
        storedToken: token,
        saved: const {
          'serverId': 'account-a',
          'username': 'a@example.test',
          'password': 'pw',
          'authType': 'credentials',
        },
      );

      rig.auth.onAuthIssue(AuthFailureKind.sessionRejected);
      final state = await rig.settledOn((s) => s.status == AuthStatus.error);

      check(state.token).equals(token);
      check(rig.service.renewals).equals(0);
    });

    test(
      'on resume, a session close to expiry is renewed ahead of time',
      () async {
        final token = _jwt(const Duration(minutes: 8), tag: 'expiring');
        final rig = await _Rig.start(
          storedToken: token,
          saved: _savedBrowserSignIn(token),
          renew: () async => (token: _renewed, session: _session),
        );
        rig.statuses.clear();

        await rig.auth.renewBrowserSessionIfExpiring();

        check(rig.state.token).equals(_renewed);
        check(rig.statuses).deepEquals([AuthStatus.authenticated]);
        // The saved token was not asked about first, it is on its way out:
        // only the renewed one was checked.
        check(rig.savedCredentialApi.validated).deepEquals([_renewed]);
      },
    );

    fakeTimeTest('on resume, a session that is no browser sign-in is left to '
        'the server, even past its expiry by the device clock', () async {
      final token = _jwt(const Duration(seconds: 2), tag: 'password');
      final rig = await _Rig.start(
        storedToken: token,
        saved: const {
          'serverId': 'account-a',
          'username': 'a@example.test',
          'password': 'pw',
          'authType': 'credentials',
        },
      );
      check(rig.state.status).equals(AuthStatus.authenticated);
      // The app sat in the background past the token's expiry.
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      final renewals = rig.service.renewals;
      rig.statuses.clear();

      await rig.auth.renewBrowserSessionIfExpiring();
      await pumpEventQueue();

      check(rig.statuses).isEmpty();
      check(rig.state.status).equals(AuthStatus.authenticated);
      check(rig.service.renewals).equals(renewals);
    });

    test('on resume, a browser sign-in without its session is left alone',
        () async {
      final token = _jwt(const Duration(minutes: 8), tag: 'expiring');
      final rig = await _Rig.start(
        storedToken: token,
        saved: _savedBrowserSignIn(token),
        renew: () async => (token: _renewed, session: _session),
      );
      when(() => rig.storage.browserSignInSessionFor('account-a'))
          .thenAnswer((_) async => null);
      rig.statuses.clear();

      await rig.auth.renewBrowserSessionIfExpiring();

      check(rig.statuses).isEmpty();
      check(rig.service.renewals).equals(0);
    });

    test('on resume, a session with time left is left alone', () async {
      final token = _jwt(const Duration(days: 2), tag: 'fresh');
      final rig = await _Rig.start(
        storedToken: token,
        saved: _savedBrowserSignIn(token),
        renew: () async => (token: _renewed, session: _session),
      );

      await rig.auth.renewBrowserSessionIfExpiring();

      check(rig.service.renewals).equals(0);
      check(rig.state.token).equals(token);
    });

    test('a refusal during a renewal ahead of expiry is answered once that '
        'renewal fails', () async {
      final token = _jwt(const Duration(minutes: 8), tag: 'expiring');
      final release = Completer<void>();
      final rig = await _Rig.start(
        storedToken: token,
        saved: _savedBrowserSignIn(token),
        renew: () async {
          await release.future;
          throw const BrowserSignInException(BrowserSignInFailure.timeout);
        },
      );

      final early = rig.auth.renewBrowserSessionIfExpiring();
      await pumpEventQueue();
      rig.auth.onAuthIssue(AuthFailureKind.sessionRejected);
      release.complete();
      await early;
      final state = await rig.settledOn((s) => s.status == AuthStatus.error);

      check(state.status).equals(AuthStatus.error);
      check(state.token).equals(token);
      check(rig.service.renewals).equals(2);
    });

    test('a refusal during a renewal ahead of expiry that succeeds is '
        'answered by it', () async {
      final token = _jwt(const Duration(minutes: 8), tag: 'expiring');
      final release = Completer<void>();
      final rig = await _Rig.start(
        storedToken: token,
        saved: _savedBrowserSignIn(token),
        renew: () async {
          await release.future;
          return (token: _renewed, session: _session);
        },
      );

      final early = rig.auth.renewBrowserSessionIfExpiring();
      await pumpEventQueue();
      rig.auth.onAuthIssue(AuthFailureKind.sessionRejected);
      release.complete();
      await early;
      await pumpEventQueue();

      check(rig.state.status).equals(AuthStatus.authenticated);
      check(rig.state.token).equals(_renewed);
      check(rig.service.renewals).equals(1);
    });

    test('a failed renewal ahead of expiry changes nothing', () async {
      final token = _jwt(const Duration(minutes: 8), tag: 'expiring');
      final rig = await _Rig.start(
        storedToken: token,
        saved: _savedBrowserSignIn(token),
        renew: () async => throw const BrowserSignInException(
          BrowserSignInFailure.refreshExpired,
        ),
      );

      await rig.auth.renewBrowserSessionIfExpiring();

      check(rig.state.status).equals(AuthStatus.authenticated);
      check(rig.state.token).equals(token);
      verifyNever(() => rig.storage.deleteSavedCredentialsIfMatches(any()));
    });
  });

  group('signing out', () {
    test("revokes the refresh token of an account signed out of", () async {
      final rig = await _Rig.start();
      when(() => rig.storage.browserSignInSessionFor('account-b'))
          .thenAnswer((_) async => _session);
      when(() => rig.storage.vaultedSessions(accountIds: {'account-b'}))
          .thenAnswer((_) async => const []);
      when(() => rig.storage.removeInactiveAccount('account-b'))
          .thenAnswer((_) async => true);

      await rig.auth.signOutAccount('account-b');
      await pumpEventQueue();

      check(rig.service.revoked).deepEquals([_session]);
    });

    test('revokes the refresh token on a plain logout', () async {
      final rig = await _Rig.start(clears: true);
      when(() => rig.storage.browserSignInSessionFor('account-a'))
          .thenAnswer((_) async => _session);

      await rig.auth.logout();
      await pumpEventQueue();

      check(rig.service.revoked).deepEquals([_session]);
    });

    test('revokes nothing when a newer sign-in owns the account', () async {
      final rig = await _Rig.start(clears: false);
      when(() => rig.storage.browserSignInSessionFor('account-a'))
          .thenAnswer((_) async => _session);

      await rig.auth.logout();
      await pumpEventQueue();

      check(rig.service.revoked).isEmpty();
    });

    test('sessions storage drops on its own are revoked', () async {
      final rig = await _Rig.start();

      rig.storage.dropped.add(const [
        (accountId: 'account-a', session: _session),
      ]);
      await pumpEventQueue();

      check(rig.service.revoked).deepEquals([_session]);
    });

    test('a merge waits for a renewal of the account it folds away, and '
        'holds off new ones until the session moved', () async {
      final rig = await _Rig.start();
      rig.service.renewalInFlight = Completer<void>();
      var heldDuringMerge = false;
      when(
        () => rig.storage.mergeActiveAccountInto(
          'account-b',
          expectedSourceAccountId: 'account-a',
          expectedToken: any(named: 'expectedToken'),
        ),
      ).thenAnswer((_) async {
        heldDuringMerge =
            rig.service.held.length == 1 && rig.service.released.isEmpty;
        return false;
      });

      final merge = rig.auth.mergeActiveAccountInto(
        'account-b',
        expectedSourceAccountId: 'account-a',
      );
      await pumpEventQueue();
      verifyNever(
        () => rig.storage.mergeActiveAccountInto(
          any(),
          expectedSourceAccountId: any(named: 'expectedSourceAccountId'),
          expectedToken: any(named: 'expectedToken'),
        ),
      );

      rig.service.renewalInFlight!.complete();
      await merge;
      check(heldDuringMerge).isTrue();
      check(rig.service.held).deepEquals([
        ['account-a'],
      ]);
      check(rig.service.released).deepEquals([
        ['account-a'],
      ]);
    });

    test('a sign-in started while a merge waits on a renewal is not '
        'cancelled by it', () async {
      final rig = await _Rig.start();
      rig.service.renewalInFlight = Completer<void>();
      when(
        () => rig.storage.mergeActiveAccountInto(
          any(),
          expectedSourceAccountId: any(named: 'expectedSourceAccountId'),
          expectedToken: any(named: 'expectedToken'),
        ),
      ).thenAnswer((_) async => true);

      final merge = rig.auth.mergeActiveAccountInto(
        'account-b',
        expectedSourceAccountId: 'account-a',
      );
      await pumpEventQueue();
      // A sign-in begins meanwhile, and owns what comes next.
      unawaited(rig.auth.refresh());
      rig.service.renewalInFlight!.complete();

      check(await merge).isFalse();
      verifyNever(
        () => rig.storage.mergeActiveAccountInto(
          any(),
          expectedSourceAccountId: any(named: 'expectedSourceAccountId'),
          expectedToken: any(named: 'expectedToken'),
        ),
      );
      check(rig.service.released).length.equals(1);
    });

    test('signing out of an account revokes the refresh token a renewal in '
        'flight rotated, not the spent one', () async {
      final rig = await _Rig.start();
      const rotated = BrowserSignInSession(
        serverId: 'server-1',
        provider: 'oidc',
        clientId: 'conduit',
        issuer: 'https://id.example',
        tokenEndpoint: 'https://id.example/token',
        revocationEndpoint: 'https://id.example/revoke',
        refreshToken: 'idp-refresh-rotated',
        owuiUserId: 'user-a',
      );
      var stored = _session;
      when(
        () => rig.storage.browserSignInSessionFor('account-b'),
      ).thenAnswer((_) async => stored);
      when(() => rig.storage.vaultedSessions(accountIds: {'account-b'}))
          .thenAnswer((_) async => const []);
      when(() => rig.storage.removeInactiveAccount('account-b'))
          .thenAnswer((_) async => true);
      rig.service.renewalInFlight = Completer<void>();
      // The renewal saves the rotated refresh token as it ends.
      rig.service.onRenewalLanded = () => stored = rotated;

      final signOut = rig.auth.signOutAccount('account-b');
      await pumpEventQueue();
      verifyNever(() => rig.storage.removeInactiveAccount(any()));
      rig.service.renewalInFlight!.complete();
      await signOut;
      await pumpEventQueue();

      check(rig.service.revoked).deepEquals([rotated]);
      check(rig.service.held).deepEquals([
        ['account-b'],
      ]);
      check(rig.service.released).length.equals(1);
    });

    test('a plain logout holds renewals from the session read through the '
        'clear', () async {
      final rig = await _Rig.start(clears: true);
      when(() => rig.storage.browserSignInSessionFor('account-a'))
          .thenAnswer((_) async => _session);
      var heldDuringClear = false;
      when(
        () => rig.storage.clearActiveAccountAuthDataIf(
          canClear: any(named: 'canClear'),
          tellDroppedBrowserSession: any(named: 'tellDroppedBrowserSession'),
        ),
      ).thenAnswer((invocation) async {
        heldDuringClear =
            rig.service.held.length == 1 && rig.service.released.isEmpty;
        return (invocation.namedArguments[#canClear] as bool Function())();
      });

      await rig.auth.logout();
      await pumpEventQueue();

      check(heldDuringClear).isTrue();
      check(rig.service.held).deepEquals([
        ['account-a'],
      ]);
      check(rig.service.released).length.equals(1);
      check(rig.service.revoked).deepEquals([_session]);
    });

    test('a refresh token is not revoked while a session of the same grant '
        'is still stored', () async {
      final rig = await _Rig.start();
      // The same user signed in again: the new session replaced the old.
      rig.storage.storedSessions = [
        (
          accountId: 'account-a',
          session: _session.copyWith(refreshToken: 'idp-refresh-new'),
        ),
      ];

      rig.storage.dropped.add(const [
        (accountId: 'account-a', session: _session),
      ]);
      await pumpEventQueue();

      check(rig.service.revoked).isEmpty();
    });

    test('saving browser sign-in settings holds renewals of the server\'s '
        'accounts while it ends their sessions', () async {
      final rig = await _Rig.start(registry: _registry(secondAccount: true));
      var heldDuringSave = false;
      when(() => rig.storage.setServerBrowserSignIn('server-1', null))
          .thenAnswer((_) async {
            heldDuringSave =
                rig.service.held.length == 1 && rig.service.released.isEmpty;
            return const [(accountId: 'account-b', session: _session)];
          });

      await rig.auth.saveBrowserSignInConfig(accountId: 'account-a');
      await pumpEventQueue();

      check(heldDuringSave).isTrue();
      check(rig.service.held.single).unorderedEquals([
        'account-a',
        'account-b',
      ]);
      check(rig.service.released).length.equals(1);
      check(rig.service.revoked).deepEquals([_session]);
    });

    test('sessions left behind by an interrupted operation are swept and '
        'revoked once, at startup', () async {
      final rig = await _Rig.start(
        swept: const [(accountId: 'account-x', session: _session)],
      );
      await pumpEventQueue();

      check(rig.service.revoked).deepEquals([_session]);
      await rig.auth.refresh();
      await pumpEventQueue();
      verify(() => rig.storage.sweepOrphanBrowserSignInSessions()).called(1);
    });
  });
}

/// An auth state manager over mocked storage, an API client per address,
/// and a browser sign-in service that records what it is asked.
final class _Rig {
  _Rig._(this.workerManager);

  final WorkerManager workerManager;
  final storage = _Storage();
  final service = _Service();
  final statuses = <AuthStatus>[];
  late _Api api;

  /// The client is rebuilding: none is there to read.
  bool apiGone = false;
  late _Api savedCredentialApi;
  late ProviderContainer container;
  String activeId = 'account-a';
  String? storedToken;
  Map<String, String>? saved;

  AuthStateManager get auth =>
      container.read(authStateManagerProvider.notifier);
  AuthState get state => container.read(authStateManagerProvider).requireValue;

  static Future<_Rig> start({
    OpenWebUiRegistry? registry,
    Map<String, OpenWebUiAccountSummary> summaries = const {},
    String? storedToken,
    Map<String, String>? saved,
    String activeId = 'account-a',
    Future<BrowserSignInRenewal> Function()? renew,
    bool clears = true,
    List<StoredBrowserSignInSession> swept = const [],
  }) async {
    final workerManager = WorkerManager();
    addTearDown(workerManager.dispose);
    final rig = _Rig._(workerManager)
      ..activeId = activeId
      ..storedToken = storedToken
      ..saved = saved;
    rig.api = _Api(workerManager);
    rig.savedCredentialApi = _Api(workerManager);
    rig.service.onRenew = renew;
    final storage = rig.storage;
    storage.registry = registry ?? _registry();

    when(() => storage.getAuthTokenStrict())
        .thenAnswer((_) async => rig.storedToken);
    when(() => storage.getSavedCredentialsStrict())
        .thenAnswer((_) async => rig.saved);
    when(() => storage.getSavedCredentials())
        .thenAnswer((_) async => rig.saved);
    when(() => storage.getActiveServerId())
        .thenAnswer((_) async => rig.activeId);
    when(() => storage.getEffectiveActiveServerId())
        .thenAnswer((_) async => rig.activeId);
    when(() => storage.getLocalUserWithAvatar())
        .thenAnswer((_) async => _userA);
    when(() => storage.saveLocalUser(any())).thenAnswer((_) async {});
    when(
      () => storage.saveLocalUserWithAvatar(
        any(),
        avatarUrl: any(named: 'avatarUrl'),
      ),
    ).thenAnswer((_) async {});
    when(() => storage.deleteAuthTokenIfMatches(any()))
        .thenAnswer((_) async => true);
    when(() => storage.deleteSavedCredentialsIfMatches(any()))
        .thenAnswer((_) async => true);
    when(() => storage.captureSavedServerSessionOwnership('account-a'))
        .thenAnswer(
          (_) async =>
              (revision: 1, serverConfig: _server, requireActive: false),
        );
    when(() => storage.getServerConfigs()).thenAnswer((_) async => [_server]);
    when(() => storage.sweepOrphanBrowserSignInSessions())
        .thenAnswer((_) async => swept);
    // Every account holds the session of its browser sign-in.
    when(() => storage.browserSignInSessionFor(any()))
        .thenAnswer((_) async => _session);
    when(
      () => storage.clearActiveAccountAuthDataIf(
        canClear: any(named: 'canClear'),
        tellDroppedBrowserSession: any(named: 'tellDroppedBrowserSession'),
      ),
    ).thenAnswer(
      (invocation) async =>
          clears && (invocation.namedArguments[#canClear] as bool Function())(),
    );

    final isolation = _Isolation();
    rig.container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        apiServiceProvider.overrideWith((ref) => rig.apiGone ? null : rig.api),
        activeServerProvider.overrideWith((ref) async => _server),
        browserSignInServiceProvider.overrideWithValue(rig.service),
        savedCredentialAuthApiFactoryProvider.overrideWithValue(
          ({required serverConfig, required workerManager}) =>
              rig.savedCredentialApi,
        ),
        openWebUiAccountSummariesProvider.overrideWith(
          () => _Summaries(summaries),
        ),
        openWebUiAccountStorageIsolationProvider.overrideWith(() => isolation),
      ],
    );
    addTearDown(rig.container.dispose);
    rig.container.read(openWebUiAccountStorageIsolationProvider);
    rig.container.listen<AsyncValue<AuthState>>(authStateManagerProvider, (
      _,
      next,
    ) {
      final status = next.asData?.value.status;
      if (status != null) rig.statuses.add(status);
    }, fireImmediately: true);
    await rig.settled();
    rig.statuses.clear();
    return rig;
  }

  /// The auth state once its restore, and any sign-in it started, settled.
  Future<AuthState> settled() =>
      settledOn((s) => !s.isLoading && s.status != AuthStatus.loading);

  /// The first auth state [done] accepts, once nothing loads: as it
  /// stands, or as it is published next. A state that never comes leaves the
  /// test to its own timeout.
  Future<AuthState> settledOn(bool Function(AuthState) done) async {
    await container.read(authStateManagerProvider.future);
    bool ready(AuthState s) => done(s) && !s.isLoading;
    if (ready(state)) return state;
    final reached = Completer<AuthState>();
    final subscription = container.listen<AsyncValue<AuthState>>(
      authStateManagerProvider,
      (_, next) {
        final value = next.value;
        if (value != null && ready(value) && !reached.isCompleted) {
          reached.complete(value);
        }
      },
    );
    try {
      return await reached.future;
    } finally {
      subscription.close();
    }
  }
}

final class _Storage extends Mock implements OptimizedStorageService {
  late OpenWebUiRegistry registry;

  /// The browser sign-in sessions still stored, which revocation spares a
  /// grant they share.
  List<StoredBrowserSignInSession> storedSessions = const [];

  @override
  Future<List<StoredBrowserSignInSession>>
  browserSignInSessionsForRevocation() async => storedSessions;
  final dropped =
      StreamController<List<StoredBrowserSignInSession>>.broadcast();

  /// Commits refused, as a move of the account to another address refuses
  /// one taken before it.
  int refusedCommits = 0;
  String? committedToken;
  Map<String, String>? remembered;
  Map<String, String>? expected;
  BrowserSessionCommit? browserSession;
  final ownershipConfigs = <ServerConfig>[];

  @override
  Future<OpenWebUiRegistry> getOpenWebUiRegistryStrict() async => registry;

  @override
  Stream<List<StoredBrowserSignInSession>> get droppedBrowserSessions =>
      dropped.stream;

  @override
  Future<ServerSessionOwnershipSnapshot?> captureServerSessionOwnership({
    required ServerConfig validatedConfig,
    required bool requireActive,
  }) async {
    ownershipConfigs.add(validatedConfig);
    return (
      revision: 1,
      serverConfig: validatedConfig,
      requireActive: requireActive,
    );
  }

  @override
  Future<bool> commitExistingServerSession({
    required ServerSessionOwnershipSnapshot ownership,
    required String token,
    required bool Function() canCommit,
    required FutureOr<void> Function() publish,
    Map<String, String>? rememberedCredentials,
    Map<String, String>? expectedSavedCredentials,
    BrowserSessionCommit? browserSession,
    void Function()? onRollbackUncertain,
  }) async {
    if (!canCommit()) return false;
    if (refusedCommits > 0) {
      refusedCommits--;
      return false;
    }
    committedToken = token;
    remembered = rememberedCredentials;
    expected = expectedSavedCredentials;
    this.browserSession = browserSession;
    await publish();
    return true;
  }
}

/// Records what it is asked, and answers as each test sets it to.
final class _Service extends BrowserSignInService {
  _Service() : super(port: const NullBrowserAuthPort());

  final authorizeCalls =
      <
        ({ApiService api, String serverId, String? prompt, String? loginHint})
      >[];
  final exchanges = <({ApiService api, String accessToken})>[];
  final revoked = <BrowserSignInSession>[];
  BrowserSignInGrant? grant = _grant();
  void Function()? duringBrowser;

  /// Keeps the browser open until completed.
  Completer<void>? browserOpen;

  /// Holds the steps before the browser opens until completed.
  Completer<void>? findingProvider;

  /// Holds the token exchange until completed.
  Completer<void>? exchanging;

  /// How many times the browser opened.
  int browserOpened = 0;
  BrowserSignInAnswer Function() answer = () =>
      BrowserSignInSessionToken(_issued);
  BrowserSignInException? exchangeError;
  Future<BrowserSignInRenewal> Function()? onRenew;
  int renewals = 0;
  final diagnosed = <ApiService>[];

  @override
  Future<BrowserSignInDiagnosis> diagnose({
    required ApiService api,
    required BrowserSignInConfig config,
  }) async {
    diagnosed.add(api);
    return const BrowserSignInDiagnosis(issuer: 'https://id.example');
  }

  /// Holds every hold's start until completed, as a renewal in flight would.
  Completer<void>? renewalInFlight;

  /// Runs once [renewalInFlight] completes, before the hold is taken: what
  /// that renewal left.
  void Function()? onRenewalLanded;
  final held = <List<String>>[];
  final released = <List<String>>[];

  @override
  Future<void Function()> holdRenewalsOf(Iterable<String> accountIds) async {
    final ids = accountIds.toList();
    await renewalInFlight?.future;
    onRenewalLanded?.call();
    held.add(ids);
    var done = false;
    return () {
      if (done) return;
      done = true;
      released.add(ids);
    };
  }

  @override
  Future<BrowserSignInGrant?> authorize({
    required ApiService api,
    required BrowserSignInConfig config,
    required String serverId,
    String? prompt,
    String? loginHint,
    bool Function()? stopped,
  }) async {
    authorizeCalls.add((
      api: api,
      serverId: serverId,
      prompt: prompt,
      loginHint: loginHint,
    ));
    await findingProvider?.future;
    if (stopped?.call() ?? false) return null;
    browserOpened++;
    duringBrowser?.call();
    await browserOpen?.future;
    return grant;
  }

  @override
  Future<BrowserSignInAnswer> exchange({
    required ApiService api,
    required String provider,
    required String accessToken,
    bool renewal = false,
  }) async {
    exchanges.add((api: api, accessToken: accessToken));
    await exchanging?.future;
    final error = exchangeError;
    if (error != null) throw error;
    return answer();
  }

  @override
  Future<BrowserSignInRenewal> renew({
    required String accountId,
    required ApiService api,
    required OptimizedStorageService storage,
  }) {
    renewals++;
    final renew = onRenew;
    if (renew == null) {
      throw const BrowserSignInException(BrowserSignInFailure.refreshExpired);
    }
    return renew();
  }

  @override
  Future<void> revokeBestEffort(
    BrowserSignInSession session, {
    ServerConfig? route,
  }) async {
    revoked.add(session);
  }
}

/// An Open WebUI client that signs in as user A, and records the tokens it
/// was asked to check.
final class _Api extends ApiService {
  _Api(WorkerManager workerManager, {super.serverConfig = _server})
    : super(workerManager: workerManager);

  final validated = <String?>[];

  @override
  Future<User> getCurrentUser({
    bool suppressAuthFailureNotification = false,
    String? candidateAuthToken,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    validated.add(candidateAuthToken);
    return _userA;
  }

  @override
  Future<OpenWebUiTwoStepSession> verifyTwoStepCode(
    String challengeToken,
    String code, {
    bool recovery = false,
  }) async => OpenWebUiTwoStepSession(token: _issued);

  @override
  Future<void> logout({ApiAuthSnapshot? authSnapshot}) async {}

  // Never closed: a test may hand the same client out again.
  @override
  void dispose() {}
}

final class _Summaries extends OpenWebUiAccountSummaries {
  _Summaries(this.summaries);

  final Map<String, OpenWebUiAccountSummary> summaries;

  @override
  Map<String, OpenWebUiAccountSummary> build() => summaries;
}

final class _Isolation extends OpenWebUiAccountStorageIsolation {
  @override
  Future<void> recordAccountPurge(String accountId) async {}

  @override
  Future<void> purgeAccount(
    String accountId, {
    bool keepsRecord = false,
  }) async {}

  @override
  void build() {
    ref.listen(authStateManagerProvider, (_, _) {});
  }

  @override
  void beginAccountSwitch() {}
}
