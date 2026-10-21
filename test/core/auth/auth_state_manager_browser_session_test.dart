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
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  final exp = DateTime.now().add(expiresIn).millisecondsSinceEpoch ~/ 1000;
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

OpenWebUiRegistry _registry({bool secondAccount = false, String? userId}) =>
    OpenWebUiRegistry(
      servers: [
        OpenWebUiServer(
          id: 'server-1',
          name: 'Chat',
          endpoints: [OpenWebUiEndpoint(id: 'e1', url: 'https://a.example')],
          browserSignIn: _config,
        ),
      ],
      accounts: [
        OpenWebUiAccount(id: 'account-a', serverId: 'server-1', userId: userId),
        if (secondAccount)
          OpenWebUiAccount(id: 'account-b', serverId: 'server-1'),
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
        final rig = await _Rig.start(
          registry: _registry(secondAccount: secondAccount),
        );

        await rig.auth.loginWithBrowser(
          config: BrowserSignInConfig(provider: provider, clientId: 'conduit'),
        );

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
    when(() => storage.browserSignInSessionFor(any()))
        .thenAnswer((_) async => null);
    when(
      () => storage.clearActiveAccountAuthDataIf(
        canClear: any(named: 'canClear'),
      ),
    ).thenAnswer(
      (invocation) async =>
          clears && (invocation.namedArguments[#canClear] as bool Function())(),
    );

    final isolation = _Isolation();
    rig.container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        apiServiceProvider.overrideWith((ref) => rig.api),
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

  Future<AuthState> settledOn(bool Function(AuthState) done) async {
    await container.read(authStateManagerProvider.future);
    for (var i = 0; i < 400; i++) {
      final current = state;
      if (done(current) && !current.isLoading) return current;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return state;
  }
}

final class _Storage extends Mock implements OptimizedStorageService {
  late OpenWebUiRegistry registry;
  String? committedToken;
  Map<String, String>? remembered;
  Map<String, String>? expected;
  BrowserSessionCommit? browserSession;
  final ownershipConfigs = <ServerConfig>[];

  @override
  Future<OpenWebUiRegistry> getOpenWebUiRegistryStrict() async => registry;

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
  BrowserSignInAnswer Function() answer = () =>
      BrowserSignInSessionToken(_issued);
  BrowserSignInException? exchangeError;
  Future<BrowserSignInRenewal> Function()? onRenew;
  int renewals = 0;

  @override
  Future<BrowserSignInGrant?> authorize({
    required ApiService api,
    required BrowserSignInConfig config,
    required String serverId,
    String? prompt,
    String? loginHint,
  }) async {
    authorizeCalls.add((
      api: api,
      serverId: serverId,
      prompt: prompt,
      loginHint: loginHint,
    ));
    duringBrowser?.call();
    return grant;
  }

  @override
  Future<BrowserSignInAnswer> exchange({
    required ApiService api,
    required String provider,
    required String accessToken,
  }) async {
    exchanges.add((api: api, accessToken: accessToken));
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
