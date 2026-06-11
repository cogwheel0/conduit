import 'package:checks/checks.dart';
import 'package:conduit/core/network/image_header_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('imageUrlIsServerOrigin', () {
    test('returns true for same host absolute URL', () {
      check(
        imageUrlIsServerOrigin(
          'https://openwebui.example.com',
          'https://openwebui.example.com/static/image.png',
        ),
      ).isTrue();
    });

    test('returns false for same host with different port', () {
      check(
        imageUrlIsServerOrigin(
          'https://openwebui.example.com:443',
          'https://openwebui.example.com:8443/static/image.png',
        ),
      ).isFalse();
    });

    test('returns true for same origin with implicit default port', () {
      check(
        imageUrlIsServerOrigin(
          'https://openwebui.example.com:443',
          'https://openwebui.example.com/static/image.png',
        ),
      ).isTrue();
    });

    test('returns false for same host with different scheme', () {
      check(
        imageUrlIsServerOrigin(
          'https://openwebui.example.com',
          'http://openwebui.example.com/static/image.png',
        ),
      ).isFalse();
    });

    test('returns false for cross-origin absolute URL', () {
      check(
        imageUrlIsServerOrigin(
          'https://openwebui.example.com',
          'https://attacker.example.net/static/image.png',
        ),
      ).isFalse();
    });

    test('returns true for relative path', () {
      check(
        imageUrlIsServerOrigin(
          'https://openwebui.example.com',
          '/static/image.png',
        ),
      ).isTrue();
    });

    test('returns false for null server base URL', () {
      check(imageUrlIsServerOrigin(null, '/static/image.png')).isFalse();
    });

    test('returns false for empty server base URL', () {
      check(imageUrlIsServerOrigin('', '/static/image.png')).isFalse();
    });

    test('returns false for malformed URL', () {
      check(
        imageUrlIsServerOrigin('https://openwebui.example.com', 'http://[::1'),
      ).isFalse();
    });

    test('returns false for absolute non-network URL', () {
      check(
        imageUrlIsServerOrigin(
          'https://openwebui.example.com',
          'data:application/pdf;base64,AA==',
        ),
      ).isFalse();
    });
  });
}
