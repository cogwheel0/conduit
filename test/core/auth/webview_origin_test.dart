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
