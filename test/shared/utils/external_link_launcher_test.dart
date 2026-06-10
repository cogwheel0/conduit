import 'package:conduit/shared/utils/external_link_launcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseAllowedExternalLink', () {
    test('allows https URLs', () {
      final uri = parseAllowedExternalLink('https://example.com/page');

      expect(uri, isNotNull);
      expect(uri!.scheme, 'https');
    });

    test('allows http URLs with local network hosts and ports', () {
      final uri = parseAllowedExternalLink('http://192.168.1.10:3000/x');

      expect(uri, isNotNull);
      expect(uri!.scheme, 'http');
    });

    test('allows mailto URLs', () {
      final uri = parseAllowedExternalLink('mailto:user@example.com');

      expect(uri, isNotNull);
      expect(uri!.scheme, 'mailto');
    });

    test('matches allowed schemes case-insensitively', () {
      final uri = parseAllowedExternalLink('HTTPS://EXAMPLE.COM');

      expect(uri, isNotNull);
      expect(uri!.scheme.toLowerCase(), 'https');
    });

    test('trims whitespace around URLs', () {
      final uri = parseAllowedExternalLink('  https://example.com  ');

      expect(uri, isNotNull);
      expect(uri!.toString(), 'https://example.com');
    });

    test('blocks tel URLs', () {
      expect(parseAllowedExternalLink('tel:+19005551234'), isNull);
    });

    test('blocks sms URLs', () {
      expect(parseAllowedExternalLink('sms:+19005551234'), isNull);
    });

    test('blocks javascript URLs', () {
      expect(parseAllowedExternalLink('javascript:alert(1)'), isNull);
    });

    test('blocks file URLs', () {
      expect(parseAllowedExternalLink('file:///etc/passwd'), isNull);
    });

    test('blocks Android intent URLs', () {
      expect(
        parseAllowedExternalLink('intent://scan/#Intent;scheme=zxing;end'),
        isNull,
      );
    });

    test('blocks empty URLs', () {
      expect(parseAllowedExternalLink(''), isNull);
    });

    test('blocks whitespace-only URLs', () {
      expect(parseAllowedExternalLink('   '), isNull);
    });

    test('blocks malformed URLs', () {
      expect(parseAllowedExternalLink('not a url ::'), isNull);
    });

    test('blocks bare hosts without a scheme', () {
      expect(parseAllowedExternalLink('example.com'), isNull);
    });
  });
}
