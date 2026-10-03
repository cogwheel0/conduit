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
}
