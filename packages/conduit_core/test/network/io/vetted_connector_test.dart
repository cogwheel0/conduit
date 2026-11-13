import 'dart:io';

import 'package:conduit_core/network/io/vetted_connector.dart';
import 'package:test/test.dart';

void main() {
  group('isLanOrPublicHostAddress', () {
    const allowed = <String>[
      '93.184.215.14', // public
      '10.0.0.5',
      '172.16.4.2',
      '172.31.255.254',
      '192.168.1.20',
      '100.64.0.1', // carrier-grade NAT, as a tailnet uses
      '2606:4700::6810:84e5', // public IPv6
      'fd12:3456:789a::1', // unique local (a LAN)
      '::ffff:192.168.1.20', // IPv4-mapped LAN
    ];
    const refused = <String>[
      '127.0.0.1',
      '127.200.1.1',
      '0.0.0.0',
      '0.1.2.3',
      '169.254.169.254', // cloud metadata
      '169.254.1.1',
      '224.0.0.251',
      '239.255.255.250',
      '::1',
      '::',
      'fe80::1',
      'febf::1',
      'ff02::fb',
      '::ffff:127.0.0.1',
      '::ffff:169.254.169.254',
      '::127.0.0.1', // IPv4-compatible
      '64:ff9b::7f00:1', // NAT64 of 127.0.0.1
      '2002:7f00:1::1', // 6to4 of 127.0.0.1
    ];
    for (final a in allowed) {
      test('allows $a', () {
        expect(isLanOrPublicHostAddress(InternetAddress(a)), isTrue);
      });
    }
    for (final a in refused) {
      test('refuses $a', () {
        expect(isLanOrPublicHostAddress(InternetAddress(a)), isFalse);
      });
    }
  });

  group('VettedConnector', () {
    late HttpServer server;
    var requests = 0;

    setUp(() async {
      requests = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        requests++;
        request.response
          ..write('internal')
          ..close();
      });
    });

    tearDown(() => server.close(force: true));

    test('a name resolving to a refused address never connects', () async {
      final connector = VettedConnector(
        allowed: isLanOrPublicHostAddress,
        lookup: (_) async => [InternetAddress.loopbackIPv4],
      );
      final client = HttpClient()
        ..findProxy = ((_) => 'DIRECT')
        ..connectionFactory = (uri, _, _) => connector.connect(uri);
      addTearDown(client.close);
      await expectLater(
        client.getUrl(Uri.parse('http://lan.example:${server.port}/')),
        throwsA(isA<RefusedAddressException>()),
      );
      expect(requests, 0);
    });

    test('connects to the vetted address itself', () async {
      final looked = <String>[];
      final connector = VettedConnector(
        allowed: (_) => true,
        lookup: (host) async {
          looked.add(host);
          return [InternetAddress.loopbackIPv4];
        },
      );
      final client = HttpClient()
        ..findProxy = ((_) => 'DIRECT')
        ..connectionFactory = (uri, _, _) => connector.connect(uri);
      addTearDown(client.close);
      final request = await client.getUrl(
        Uri.parse('http://site.example:${server.port}/'),
      );
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 200);
      expect(requests, 1);
      expect(looked, ['site.example']);
    });

    test('no address at all is a socket error, not a refusal', () async {
      final connector = VettedConnector(
        allowed: (_) => true,
        lookup: (_) async => <InternetAddress>[],
      );
      await expectLater(
        connector.vettedAddresses('nowhere.example'),
        throwsA(isA<SocketException>()),
      );
    });
  });
}
