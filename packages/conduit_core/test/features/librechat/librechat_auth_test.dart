import 'package:checks/checks.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_server_info.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/services/librechat_auth_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/features/librechat/services/librechat_probe.dart';
import 'package:conduit_core/testing.dart';
import 'package:test/test.dart';

/// What [future] failed with, which must be a [T].
Future<T> _thrown<T extends Object>(Future<Object?> future) async {
  try {
    await future;
  } on T catch (error) {
    return error;
  }
  fail('Expected a $T.');
}

void main() {
  const server = LibreChatServer(baseUrl: 'https://chat.example.com');
  late FakeLibreChatServer fake;
  late LibreChatAuthService auth;

  setUp(() {
    fake = FakeLibreChatServer();
    auth = LibreChatAuthService(server, adapter: fake);
  });
  tearDown(() => auth.close());

  group('sign-in', () {
    test('returns the token, the user and the refresh cookie', () async {
      fake.addUser();
      final result = await auth.signIn(
        email: ' dev@example.com ',
        password: 'devpassword',
      );
      final session = (result as LibreChatSignedIn).session;
      check(session.user.email).equals('dev@example.com');
      check(session.user.role).equals('USER');
      check(session.cookies.value('refreshToken')).isNotNull();
      check(session.cookies.value('token_provider')).equals('librechat');
      check(session.accessTokenExpiry).isNotNull();

      final request = fake.requests.single;
      // A native client has no origin; one that sends a foreign one is
      // refused as cross-site.
      check(request.header('origin')).isNull();
      check(
        FakeLibreChatServer.looksLikeBrowser(request.header('user-agent')),
      ).isTrue();
      check(request.header('authorization')).isNull();
    });

    test('passes on what the server says about a wrong password', () async {
      fake.addUser();
      final error = await _thrown<LibreChatApiException>(
        auth.signIn(email: 'dev@example.com', password: 'nope'),
      );
      check(error.message).equals('Incorrect password.');
    });

    test('two-step verification with a code or a backup code', () async {
      fake.addUser(totpCode: '123456', backupCodes: ['backup-1']);
      final first = await auth.signIn(
        email: 'dev@example.com',
        password: 'devpassword',
      );
      final tempToken = (first as LibreChatTwoFactorRequired).tempToken;
      await check(
        auth.verifyTwoFactor(tempToken: tempToken, code: '000000'),
      ).throws<LibreChatApiException>();
      final session = await auth.verifyTwoFactor(
        tempToken: tempToken,
        code: '123 456',
      );
      check(session.cookies.hasRefreshToken).isTrue();

      final second = await auth.signIn(
        email: 'dev@example.com',
        password: 'devpassword',
      );
      final backup = await auth.verifyTwoFactor(
        tempToken: (second as LibreChatTwoFactorRequired).tempToken,
        backupCode: ' backup-1 ',
      );
      check(backup.user.email).equals('dev@example.com');
      check(fake.requests.last.data).isA<Map<Object?, Object?>>().deepEquals({
        'tempToken': second.tempToken,
        'backupCode': 'backup-1',
      });
    });
  });

  group('renewal', () {
    test('rotates the refresh cookie and keeps the user', () async {
      fake.addUser();
      final signedIn =
          (await auth.signIn(email: 'dev@example.com', password: 'devpassword')
                  as LibreChatSignedIn)
              .session;
      final renewed = await auth.renew(signedIn);
      check(renewed.accessToken).not((it) => it.equals(signedIn.accessToken));
      check(
        renewed.cookies.value('refreshToken'),
      ).not((it) => it.equals(signedIn.cookies.value('refreshToken')));
      check(renewed.user).equals(signedIn.user);
      // The rotated-out cookie is dead, as on the real server.
      await check(
        auth.renew(signedIn),
      ).throws<LibreChatSessionExpiredException>();
    });

    test('a session without a refresh cookie is over', () async {
      fake.addUser();
      final signedIn =
          (await auth.signIn(email: 'dev@example.com', password: 'devpassword')
                  as LibreChatSignedIn)
              .session;
      final cookieless = signedIn.copyWith(
        cookies: signedIn.cookies.apply([
          'refreshToken=; Max-Age=0',
        ], now: DateTime.now()),
      );
      await check(
        auth.renew(cookieless),
      ).throws<LibreChatSessionExpiredException>();
    });

    test('LibreChat\'s plain-text 200 is a failed renewal', () async {
      fake.on(
        'POST',
        '/api/auth/refresh',
        (request, match) =>
            FakeLibreChatResponse.text('Refresh token not provided'),
      );
      fake.addUser();
      final signedIn =
          (await auth.signIn(email: 'dev@example.com', password: 'devpassword')
                  as LibreChatSignedIn)
              .session;
      await check(
        auth.renew(signedIn),
      ).throws<LibreChatSessionExpiredException>();
    });

    for (final (name, response) in [
      (
        'a proxy\'s sign-in page',
        () => FakeLibreChatResponse.text(
          '<html><body>Sign in to the network</body></html>',
        ),
      ),
      (
        'a reply without a token',
        () => FakeLibreChatResponse.json({'message': 'ok'}),
      ),
    ]) {
      test('$name with a 200 leaves the session for another try', () async {
        fake.addUser();
        final signedIn =
            (await auth.signIn(
                      email: 'dev@example.com',
                      password: 'devpassword',
                    )
                    as LibreChatSignedIn)
                .session;
        fake.on('POST', '/api/auth/refresh', (request, match) => response());
        final error = await _thrown<LibreChatApiException>(
          auth.renew(signedIn),
        );
        check(error).not((it) => it.isA<LibreChatSessionExpiredException>());
        check(error.statusCode).equals(200);
      });
    }

    test('a server error leaves the session for another try', () async {
      fake.addUser();
      final signedIn =
          (await auth.signIn(email: 'dev@example.com', password: 'devpassword')
                  as LibreChatSignedIn)
              .session;
      fake.on(
        'POST',
        '/api/auth/refresh',
        (request, match) =>
            FakeLibreChatResponse.json({'message': 'busy'}, statusCode: 503),
      );
      final error = await _thrown<LibreChatApiException>(
        auth.renew(signedIn),
      );
      check(error).not((it) => it.isA<LibreChatSessionExpiredException>());
      check(error.statusCode).equals(503);
    });

    group('a refused renewal', () {
      late LibreChatSession signedIn;
      setUp(() async {
        fake.addUser();
        signedIn =
            (await auth.signIn(
                      email: 'dev@example.com',
                      password: 'devpassword',
                    )
                    as LibreChatSignedIn)
                .session;
      });
      void refuse(FakeLibreChatResponse response) =>
          fake.on('POST', '/api/auth/refresh', (request, match) => response);

      for (final (name, response) in [
        (
          'a 401',
          () => FakeLibreChatResponse.text(
            'Refresh token expired or not found for this user',
            statusCode: 401,
          ),
        ),
        (
          'LibreChat\'s own 403',
          () => FakeLibreChatResponse.text(
            'Invalid refresh token',
            statusCode: 403,
          ),
        ),
        (
          'a redirect to its sign-in page',
          () => FakeLibreChatResponse(302, headers: {'location': '/login'}),
        ),
      ]) {
        test('by $name ends the session', () async {
          refuse(response());
          await check(
            auth.renew(signedIn),
          ).throws<LibreChatSessionExpiredException>();
        });
      }

      for (final (name, response) in [
        (
          'a proxy\'s 403',
          () => FakeLibreChatResponse.text(
            '<html><body>403 Forbidden</body></html>',
            statusCode: 403,
          ),
        ),
        (
          'a redirect to another site',
          () => FakeLibreChatResponse(
            302,
            headers: {'location': 'https://sso.example.com/login'},
          ),
        ),
        (
          'a redirect to a gateway on the same site',
          () => FakeLibreChatResponse(
            302,
            headers: {'location': '/cdn-cgi/access/login/chat.example.com'},
          ),
        ),
        (
          'a redirect to an auth proxy\'s sign-in page',
          () => FakeLibreChatResponse(
            302,
            headers: {'location': '/oauth2/login?rd=/api/auth/refresh'},
          ),
        ),
      ]) {
        test('by $name leaves the session for another try', () async {
          refuse(response());
          final error = await _thrown<LibreChatApiException>(
            auth.renew(signedIn),
          );
          check(error).not((it) => it.isA<LibreChatSessionExpiredException>());
        });
      }

      test('by a redirect to its sign-in page under a sub-path ends the '
          'session', () async {
        const subPath = LibreChatServer(
          baseUrl: 'https://example.com/librechat',
        );
        final subPathFake = FakeLibreChatServer(baseUrl: subPath.baseUrl);
        final subPathAuth = LibreChatAuthService(subPath, adapter: subPathFake);
        addTearDown(subPathAuth.close);
        subPathFake.on(
          'POST',
          '/api/auth/refresh',
          (request, match) => FakeLibreChatResponse(
            302,
            headers: {'location': '/librechat/login'},
          ),
        );
        await check(
          subPathAuth.renew(signedIn),
        ).throws<LibreChatSessionExpiredException>();
      });

      test('by a ban says so', () async {
        refuse(
          FakeLibreChatResponse.json({
            'message': LibreChatApiException.bannedMessage,
          }, statusCode: 403),
        );
        await check(auth.renew(signedIn)).throws<LibreChatBannedException>();
      });
    });

    test('sign-out ends the session on the server', () async {
      fake.addUser();
      final signedIn =
          (await auth.signIn(email: 'dev@example.com', password: 'devpassword')
                  as LibreChatSignedIn)
              .session;
      await auth.signOut(signedIn);
      check(fake.refreshTokens).isEmpty();
      check(fake.requests.last.bearer).equals(signedIn.accessToken);
    });
  });

  group('probe', () {
    test('reads the sign-in methods of a LibreChat server', () async {
      fake.startupConfig = {
        ...fake.startupConfig,
        'appTitle': 'Team Chat',
        'socialLoginEnabled': true,
        'socialLogins': ['google', 'openid', 'github'],
        'openidLoginEnabled': true,
        'openidLabel': 'Company SSO',
        'googleLoginEnabled': true,
        'githubLoginEnabled': false,
        'ldap': {'enabled': true, 'username': true},
      };
      final result = await probeLibreChatServer(server, adapter: fake);
      final info = (result as LibreChatProbeFound).info;
      check(info.appTitle).equals('Team Chat');
      check(info.ldapEnabled).isTrue();
      check(info.ldapUsesUsername).isTrue();
      check(
        info.ssoProviders.map((provider) => provider.kind),
      ).deepEquals([LibreChatSsoKind.google, LibreChatSsoKind.openid]);
      check(info.ssoProviders.first.supportedInApp).isFalse();
      check(info.ssoProviders.last.label).equals('Company SSO');
      check(info.ssoProviders.last.path).equals('/oauth/openid');
    });

    test('offers no password form while email login is off, LDAP or not',
        () async {
      fake.startupConfig = {
        ...fake.startupConfig,
        'emailLoginEnabled': false,
        'ldap': {'enabled': true},
      };
      final result = await probeLibreChatServer(server, adapter: fake);
      final info = (result as LibreChatProbeFound).info;
      check(info.ldapEnabled).isTrue();
      check(info.passwordSignInEnabled).isFalse();
    });

    test('offers no single sign-on while social login is off', () async {
      fake.startupConfig = {
        ...fake.startupConfig,
        'socialLoginEnabled': false,
        'openidLoginEnabled': true,
      };
      final result = await probeLibreChatServer(server, adapter: fake);
      check((result as LibreChatProbeFound).info.ssoProviders).isEmpty();
    });

    test('a busy or failing server is unreachable, not something else',
        () async {
      for (final status in [429, 502, 503]) {
        fake.on(
          'GET',
          '/api/config',
          (request, match) =>
              FakeLibreChatResponse.text('busy', statusCode: status),
        );
        final result = await probeLibreChatServer(server, adapter: fake);
        check(result).isA<LibreChatProbeUnreachable>();
      }
    });

    test('tells Open WebUI apart', () async {
      fake.on(
        'GET',
        '/api/config',
        (request, match) => FakeLibreChatResponse.json({
          'status': true,
          'name': 'Open WebUI',
          'version': '0.12.3',
          'features': <String, Object>{},
        }),
      );
      final result = await probeLibreChatServer(server, adapter: fake);
      check(result).isA<LibreChatProbeNotLibreChat>().has(
        (it) => it.looksLikeOpenWebUi,
        'looksLikeOpenWebUi',
      ).isTrue();
    });
  });
}
