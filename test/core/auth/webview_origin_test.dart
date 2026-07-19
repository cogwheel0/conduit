import 'package:conduit/core/auth/webview_origin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('webViewUrlHasExactServerOrigin', () {
    test('normalizes host case and implicit default HTTPS port', () {
      expect(
        webViewUrlHasExactServerOrigin(
          'https://OPENWEBUI.example:443/oauth/callback',
          'https://openwebui.example/auth',
        ),
        isTrue,
      );
    });

    test('rejects a same-host scheme downgrade', () {
      expect(
        webViewUrlHasExactServerOrigin(
          'http://openwebui.example/auth',
          'https://openwebui.example',
        ),
        isFalse,
      );
    });

    test('rejects a same-host alternate port', () {
      expect(
        webViewUrlHasExactServerOrigin(
          'https://openwebui.example:8443/auth',
          'https://openwebui.example',
        ),
        isFalse,
      );
    });

    test('rejects unsupported and hostless URLs', () {
      expect(
        webViewUrlHasExactServerOrigin(
          'javascript:alert(1)',
          'https://openwebui.example',
        ),
        isFalse,
      );
      expect(
        webViewUrlHasExactServerOrigin('/auth', 'https://openwebui.example'),
        isFalse,
      );
    });
  });

  group('webViewUrlHasTrustedServerOrigin', () {
    test('accepts the exact configured origin', () {
      expect(
        webViewUrlHasTrustedServerOrigin(
          'https://openwebui.example/oauth/callback',
          'https://openwebui.example',
        ),
        isTrue,
      );
    });

    test('accepts a default-port https upgrade of an http server', () {
      expect(
        webViewUrlHasTrustedServerOrigin(
          'https://openwebui.example/oauth/callback',
          'http://openwebui.example',
        ),
        isTrue,
      );
      expect(
        webViewUrlHasTrustedServerOrigin(
          'https://openwebui.example:443/auth',
          'http://openwebui.example:80',
        ),
        isTrue,
      );
    });

    test('rejects scheme downgrades and host changes on upgrade', () {
      expect(
        webViewUrlHasTrustedServerOrigin(
          'http://openwebui.example/auth',
          'https://openwebui.example',
        ),
        isFalse,
      );
      expect(
        webViewUrlHasTrustedServerOrigin(
          'https://evil.example/auth',
          'http://openwebui.example',
        ),
        isFalse,
      );
      expect(
        webViewUrlHasTrustedServerOrigin(
          'https://sub.openwebui.example/auth',
          'http://openwebui.example',
        ),
        isFalse,
      );
    });

    test('rejects nonstandard-port remaps on upgrade', () {
      expect(
        webViewUrlHasTrustedServerOrigin(
          'https://openwebui.example:8443/auth',
          'http://openwebui.example',
        ),
        isFalse,
      );
      expect(
        webViewUrlHasTrustedServerOrigin(
          'https://openwebui.example/auth',
          'http://openwebui.example:8080',
        ),
        isFalse,
      );
    });
  });

  test('diagnostic origin omits OAuth query fragment and userinfo', () {
    const secret = 'authorization-code-must-not-log';
    final label = webViewOriginForLog(
      'https://user:password@Chat.Example/oauth/callback?code=$secret#token=$secret',
    );

    expect(label, 'https://chat.example');
    expect(label, isNot(contains(secret)));
    expect(label, isNot(contains('password')));
  });

  test('cookie lookup uses a slash-terminated trusted descendant path', () {
    expect(
      webViewCookieLookupUrl(
        'https://chat.example/openwebui?setup=secret#fragment',
      ),
      'https://chat.example/openwebui/',
    );
    expect(
      webViewCookieLookupUrl('https://chat.example'),
      'https://chat.example/',
    );
  });
}
