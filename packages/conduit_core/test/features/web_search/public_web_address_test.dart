import 'dart:io';

import 'package:conduit_core/features/web_search/services/public_web_address.dart';
import 'package:test/test.dart';

void main() {
  // web_fetch connects only to addresses this accepts, so every range a
  // local or carrier network could route internally must be rejected.
  test('only globally routable addresses count as public', () {
    const public = [
      '8.8.8.8',
      '93.184.215.14',
      '2606:4700:4700::1111',
      // NAT64 and 6to4 are only as public as the IPv4 address they carry.
      '64:ff9b::808:808',
      '2002:808:808::1',
    ];
    const internal = [
      '10.0.0.1',
      '127.0.0.1',
      '169.254.169.254',
      '100.64.0.1',
      '192.168.1.1',
      '172.16.0.1',
      '192.0.0.170',
      '192.0.2.1',
      '192.88.99.1',
      '198.18.0.1',
      '198.51.100.1',
      '203.0.113.1',
      '224.0.0.1',
      '240.0.0.1',
      '::',
      '::1',
      'fe80::1',
      'fc00::1',
      'fec0::1',
      'ff02::1',
      '2001:db8::1',
      '2001::1',
      '::ffff:10.0.0.1',
      '64:ff9b::a00:1',
      '64:ff9b::a9fe:a9fe',
      '2002:0a00:0001::1',
    ];
    for (final address in public) {
      expect(
        isPublicInternetAddress(InternetAddress(address)),
        isTrue,
        reason: address,
      );
    }
    for (final address in internal) {
      expect(
        isPublicInternetAddress(InternetAddress(address)),
        isFalse,
        reason: address,
      );
    }
  });
}
