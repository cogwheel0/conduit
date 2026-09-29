import 'dart:io';

import 'package:conduit_core/features/web_search/services/web_page_fetcher.dart';
import 'package:test/test.dart';

void main() {
  // The device can reach the user's LAN. A public-looking hostname that
  // resolves to a private address (DNS rebinding, split-horizon DNS) must be
  // refused where the socket is opened, not just by a URL check.
  group('connect-time address vetting', () {
    late HttpServer server;
    var requests = 0;

    setUp(() async {
      requests = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        requests++;
        request.response
          ..write('<html><body>internal</body></html>')
          ..close();
      });
    });

    tearDown(() => server.close(force: true));

    final cases = <String, List<InternetAddress>>{
      'loopback': [InternetAddress.loopbackIPv4],
      'mixed public and private answers': [
        InternetAddress('93.184.215.14'),
        InternetAddress.loopbackIPv4,
      ],
      'IPv4-mapped IPv6 loopback': [InternetAddress('::ffff:127.0.0.1')],
    };

    for (final MapEntry(key: name, value: addresses) in cases.entries) {
      test('refuses a hostname resolving to $name', () async {
        final fetcher = WebPageFetcher(lookup: (_) async => addresses);

        await expectLater(
          fetcher.fetch(Uri.parse('http://public.example:${server.port}/')),
          throwsA(
            isA<WebFetchException>().having(
              (e) => e.message,
              'message',
              contains('public URL'),
            ),
          ),
        );
        expect(requests, 0);
      });
    }
  });
}
