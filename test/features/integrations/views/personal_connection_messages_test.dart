import 'package:conduit/features/integrations/views/personal_connection_messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('personalConnectionPublicEndpoint', () {
    test('keeps scheme, host, port and path of a URL with a host', () {
      expect(
        personalConnectionPublicEndpoint(
          'https://user:secret@tools.example.com:8443/api/v1?key=abc#frag',
        ),
        'https://tools.example.com:8443/api/v1',
      );
      expect(
        personalConnectionPublicEndpoint('  http://localhost:8000/openapi  '),
        'http://localhost:8000/openapi',
      );
    });

    test('a URL without a parsable host never shows its user info', () {
      // Parses with "user" as the scheme and an empty host.
      expect(
        personalConnectionPublicEndpoint('user:token@host.example/path'),
        'host.example/path',
      );
      expect(
        personalConnectionPublicEndpoint('token@host.example'),
        'host.example',
      );
      expect(
        personalConnectionPublicEndpoint('a@b:c@host.example/x@y'),
        'host.example/x@y',
      );
    });

    test('a URL without a parsable host never shows its query or fragment',
        () {
      expect(
        personalConnectionPublicEndpoint('user:token@host/path?api_key=s3cret'),
        'host/path',
      );
      expect(
        personalConnectionPublicEndpoint('host/path#access_token=s3cret'),
        'host/path',
      );
    });

    test('an unparsable URL with a scheme keeps it and drops the user info',
        () {
      // The unclosed IPv6 bracket makes Uri.tryParse fail.
      const broken = 'https://user:token@[::1/path?key=1';
      expect(Uri.tryParse(broken), isNull);
      expect(personalConnectionPublicEndpoint(broken), 'https://[::1/path');
    });
  });
}
