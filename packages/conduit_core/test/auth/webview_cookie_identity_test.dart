import 'package:checks/checks.dart';
import 'package:conduit_core/auth/webview_cookie_identity.dart';
import 'package:test/test.dart';

void main() {
  test('identity defaults the path and domain', () {
    check(webViewCookieIdentity(name: 'token'))
        .equals(webViewCookieIdentity(name: 'token', path: '/', domain: ''));
    check(webViewCookieIdentity(name: 'token', domain: 'a.example'))
        .not((it) => it.equals(webViewCookieIdentity(name: 'token')));
  });

  test('exact-host cleanup preserves shared parent-domain cookies', () {
    check(webViewCookieBelongsToExactHost(null, 'hermes.example.com')).isTrue();
    check(
      webViewCookieBelongsToExactHost(
        'Hermes.Example.com ',
        'hermes.example.com',
      ),
    ).isTrue();
    check(
      webViewCookieBelongsToExactHost(
        '.hermes.example.com',
        'hermes.example.com',
      ),
    ).isTrue();
    check(webViewCookieBelongsToExactHost('.example.com', 'hermes.example.com'))
        .isFalse();
  });

  group('Android cookie expiry', () {
    test('a __Host- cookie is expired Secure, host-only, at /', () {
      // hermes-src/hermes_cli/dashboard_auth/cookies.py: __Host- on HTTPS.
      // A Domain attribute or a missing Secure makes Chromium refuse the
      // deletion, and sign-out fails with the cookie still set.
      check(
        androidWebViewCookieExpiries(
          url: Uri.parse('https://hermes.example/'),
          name: '__Host-hermes_session_at',
          path: '/',
          domain: 'hermes.example',
        ),
      ).deepEquals([(path: '/', domain: null, secure: true)]);
    });

    test('a __Secure- cookie behind a proxy prefix is tried at the prefix', () {
      check(
        androidWebViewCookieExpiries(
          url: Uri.parse('https://gateway.example/hermes/'),
          name: '__Secure-hermes_session_rt',
          path: '/',
          domain: 'gateway.example',
        ),
      ).deepEquals([
        (path: '/', domain: null, secure: true),
        (path: '/', domain: 'gateway.example', secure: true),
        (path: '/hermes', domain: null, secure: true),
        (path: '/hermes', domain: 'gateway.example', secure: true),
        (path: '/hermes/', domain: null, secure: true),
        (path: '/hermes/', domain: 'gateway.example', secure: true),
      ]);
    });

    test('a cookie stored with a trailing-slash path is expired at it', () {
      // Replacement needs the exact path: `/hermes/` is not `/hermes`.
      final writes = androidWebViewCookieExpiries(
        url: Uri.parse('https://gateway.example/hermes/'),
        name: '__Secure-hermes_session_rt',
        path: '/hermes/',
      );

      check(writes.map((w) => w.path))
          .containsEqualInOrder(['/hermes', '/hermes/', '/']);
      check(writes.every((w) => w.secure)).isTrue();
    });

    test('a __Host- cookie is never expired at another path', () {
      final writes = androidWebViewCookieExpiries(
        url: Uri.parse('https://gateway.example/hermes/'),
        name: '__Host-hermes_session_at',
        path: '/hermes/',
      );

      check(writes.map((w) => w.path)).deepEquals(['/']);
    });

    test('a bare cookie over HTTP is not marked Secure', () {
      check(
        androidWebViewCookieExpiries(
          url: Uri.parse('http://10.0.2.2:18160'),
          name: 'hermes_session_at',
        ),
      ).deepEquals([(path: '/', domain: null, secure: false)]);
    });
  });
}
