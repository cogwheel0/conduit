import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/browser_sign_in_config.dart';
import 'package:conduit_core/models/browser_sign_in_session.dart';
import 'package:test/test.dart';

void main() {
  group('BrowserSignInConfig', () {
    test('round-trips through JSON', () {
      for (final config in const [
        BrowserSignInConfig(provider: 'oidc', clientId: 'conduit'),
        BrowserSignInConfig(
          provider: 'microsoft',
          clientId: '00000000-1111',
          issuer: 'https://login.example.com/tenant/v2.0',
        ),
      ]) {
        check(BrowserSignInConfig.tryFromJson(jsonDecode(jsonEncode(config))))
            .equals(config);
      }
    });

    test('reads anything else as none', () {
      for (final json in <Object?>[
        null,
        'oidc',
        <String, Object?>{},
        <String, Object?>{'provider': 'oidc'},
        <String, Object?>{'provider': 'oidc', 'clientId': '  '},
        <String, Object?>{'provider': 'OIDC', 'clientId': 'x'},
        <String, Object?>{'provider': '../oidc', 'clientId': 'x'},
        <String, Object?>{'provider': 'oidc', 'clientId': 'x', 'issuer': ''},
        <String, Object?>{'provider': 'oidc', 'clientId': 'x', 'issuer': 1},
      ]) {
        check(because: '$json', BrowserSignInConfig.tryFromJson(json)).isNull();
      }
    });

    test('never shows its client id', () {
      const config = BrowserSignInConfig(
        provider: 'oidc',
        clientId: 'secret-looking-id',
      );

      check('$config').not((it) => it.contains('secret-looking-id'));
    });
  });

  test('an issuer typed as its discovery URL is the same issuer', () {
    for (final typed in [
      'https://id.example.com/realms/main',
      'https://id.example.com/realms/main/',
      ' https://id.example.com/realms/main/.well-known/openid-configuration ',
      'https://ID.Example.com/realms/main',
      'HTTPS://id.example.com:443/realms/main/',
    ]) {
      check(
        because: typed,
        normalizeBrowserSignInIssuer(typed),
      ).equals('https://id.example.com/realms/main');
    }
  });

  test('an issuer on another port or path is another issuer', () {
    check(
      normalizeBrowserSignInIssuer('https://id.example.com:8443/realms/main'),
    ).equals('https://id.example.com:8443/realms/main');
    check(
      normalizeBrowserSignInIssuer('https://id.example.com/realms/Main'),
    ).equals('https://id.example.com/realms/Main');
  });

  group('BrowserSignInSession', () {
    const session = BrowserSignInSession(
      serverId: 'server-1',
      provider: 'oidc',
      clientId: 'conduit',
      issuer: 'https://id.example.com/realms/main',
      tokenEndpoint: 'https://id.example.com/realms/main/token',
      revocationEndpoint: 'https://id.example.com/realms/main/revoke',
      refreshToken: 'refresh-secret',
      scope: 'openid email profile offline_access',
      owuiUserId: 'user-1',
    );

    test('round-trips through its encoding', () {
      check(BrowserSignInSession.tryDecode(session.encode())).equals(session);
      const minimal = BrowserSignInSession(
        serverId: 'server-1',
        provider: 'google',
        clientId: 'conduit',
        issuer: 'https://accounts.google.com',
        tokenEndpoint: 'https://oauth2.googleapis.com/token',
        refreshToken: 'refresh',
        owuiUserId: 'user-1',
      );
      check(BrowserSignInSession.tryDecode(minimal.encode())).equals(minimal);
      final named = session.copyWith(refreshToken: 'named');
      final withSubject = BrowserSignInSession.tryDecode(
        jsonEncode({...named.toJson(), 'subject': 'idp-user'}),
      );
      check(withSubject).isNotNull()
        ..has((s) => s.subject, 'subject').equals('idp-user')
        ..has((s) => s.copyWith(scope: 'openid').subject, 'kept').equals(
          'idp-user',
        );
      check(
        BrowserSignInSession.tryDecode(withSubject!.encode()),
      ).equals(withSubject);
    });

    test('saved before it named the provider\'s user, still reads', () {
      final saved = session.toJson()..remove('subject');
      check(
        BrowserSignInSession.tryDecode(jsonEncode(saved)),
      ).isNotNull().has((s) => s.subject, 'subject').isNull();
    });

    test('reads another version, or anything broken, as none', () {
      final json = session.toJson();
      for (final broken in <String?>[
        null,
        '',
        'not json',
        '[]',
        jsonEncode({...json, 'version': 2}),
        jsonEncode({...json}..remove('version')),
        jsonEncode({...json}..remove('refreshToken')),
        jsonEncode({...json, 'owuiUserId': ''}),
        jsonEncode({...json, 'provider': 'Nope!'}),
        jsonEncode({...json, 'revocationEndpoint': 3}),
        jsonEncode({...json, 'subject': 3}),
      ]) {
        check(
          because: '$broken',
          BrowserSignInSession.tryDecode(broken),
        ).isNull();
      }
    });

    test('never shows its refresh token', () {
      check('$session').not((it) => it.contains('refresh-secret'));
    });

    test('a rotated refresh token keeps the rest', () {
      final rotated = session.copyWith(refreshToken: 'rotated');

      check(rotated.refreshToken).equals('rotated');
      check(rotated.copyWith(refreshToken: 'refresh-secret')).equals(session);
    });

    group('shares a grant', () {
      BrowserSignInSession of({
        String? subject,
        String serverId = 'server-1',
        String owuiUserId = 'user-1',
        String clientId = 'conduit',
        String issuer = 'https://id.example.com/realms/main',
      }) => BrowserSignInSession(
        serverId: serverId,
        provider: 'oidc',
        clientId: clientId,
        issuer: issuer,
        tokenEndpoint: '$issuer/token',
        refreshToken: 'refresh-$serverId-$owuiUserId',
        owuiUserId: owuiUserId,
        subject: subject,
      );

      test('with the same provider user of the same client', () {
        check(
          of(subject: 'ada').sharesGrantWith(
            of(subject: 'ada', serverId: 'server-2', owuiUserId: 'user-9'),
          ),
        ).isTrue();
        // The issuer put another way is the same provider.
        check(
          of(subject: 'ada').sharesGrantWith(
            of(
              subject: 'ada',
              issuer: 'https://ID.example.com:443/realms/main/',
            ),
          ),
        ).isTrue();
      });

      test('by the Open WebUI user on the server, when a provider user is '
          'not known', () {
        check(of().sharesGrantWith(of(subject: 'ada'))).isTrue();
        check(of().sharesGrantWith(of(owuiUserId: 'user-2'))).isFalse();
        check(of().sharesGrantWith(of(serverId: 'server-2'))).isFalse();
      });

      test('not with another provider user, client or provider', () {
        check(
          of(subject: 'ada').sharesGrantWith(of(subject: 'grace')),
        ).isFalse();
        check(
          of(subject: 'ada').sharesGrantWith(
            of(subject: 'ada', clientId: 'other'),
          ),
        ).isFalse();
        check(
          of(subject: 'ada').sharesGrantWith(
            of(subject: 'ada', issuer: 'https://other.example.com'),
          ),
        ).isFalse();
      });
    });

    group('matches the settings it was issued under', () {
      test('found by discovery', () {
        check(
          session.matches(
            serverId: 'server-1',
            config: const BrowserSignInConfig(
              provider: 'oidc',
              clientId: 'conduit',
            ),
          ),
        ).isTrue();
      });

      test('with the issuer typed in, in either form', () {
        for (final issuer in [
          'https://id.example.com/realms/main/',
          'https://id.example.com/realms/main/.well-known/openid-configuration',
          'https://ID.EXAMPLE.COM:443/realms/main',
        ]) {
          check(
            because: issuer,
            session.matches(
              serverId: 'server-1',
              config: BrowserSignInConfig(
                provider: 'oidc',
                clientId: 'conduit',
                issuer: issuer,
              ),
            ),
          ).isTrue();
        }
      });

      test('and no others', () {
        for (final (serverId, config) in [
          ('server-1', null),
          (
            'server-2',
            const BrowserSignInConfig(provider: 'oidc', clientId: 'conduit'),
          ),
          (
            'server-1',
            const BrowserSignInConfig(provider: 'oidc', clientId: 'other'),
          ),
          (
            'server-1',
            const BrowserSignInConfig(provider: 'google', clientId: 'conduit'),
          ),
          (
            'server-1',
            const BrowserSignInConfig(
              provider: 'oidc',
              clientId: 'conduit',
              issuer: 'https://id.example.com/realms/other',
            ),
          ),
        ]) {
          check(
            because: '$serverId $config',
            session.matches(serverId: serverId, config: config),
          ).isFalse();
        }
      });
    });
  });
}
