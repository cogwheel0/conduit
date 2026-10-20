import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:test/test.dart';

/// Characterization tests for the public-health redirect address classifier.
///
/// These pin the behaviour that exists today so the pending move of
/// `isPublicHealthRedirectAddress`, `requestUsesServerConnectivityOrigin` and
/// their private helpers into `packages/conduit_core/lib/src/network/io/` can
/// be proven to be a verbatim move. Nothing here asserts what the guard
/// *should* do; where the observed behaviour is surprising it is pinned and
/// annotated with `LOOKS WRONG`.
///
/// Cases already pinned by `api_service_proxy_diagnostics_test.dart`
/// ("public health redirect address classifier fails closed", "discovered RFC
/// 6052 prefixes cannot disguise private IPv4", "RFC 7050 absence preserves
/// ordinary global IPv6") are deliberately not repeated.
void main() {
  tearDown(ConnectivityService.debugResetTrafficSignals);

  group('requestUsesServerConnectivityOrigin', () {
    test('a null server origin never matches', () {
      check(
        requestUsesServerConnectivityOrigin(
          Uri.parse('http://example.com/health'),
          null,
        ),
      ).isFalse();
    });

    test('both sides need a scheme and a non-empty host', () {
      final origin = Uri.parse('http://example.com/');
      // Scheme-relative and path-only references carry no scheme.
      check(
        requestUsesServerConnectivityOrigin(
          Uri.parse('//example.com/health'),
          origin,
        ),
        because: 'scheme-relative request',
      ).isFalse();
      check(
        requestUsesServerConnectivityOrigin(Uri.parse('/health'), origin),
        because: 'path-only request',
      ).isFalse();
      check(
        requestUsesServerConnectivityOrigin(
          origin,
          Uri.parse('//example.com/'),
        ),
        because: 'scheme-relative server origin',
      ).isFalse();
      // `mailto:` parses with a scheme but no authority, so the host is empty.
      check(
        requestUsesServerConnectivityOrigin(
          Uri.parse('mailto:nobody@example.com'),
          origin,
        ),
        because: 'request with an empty host',
      ).isFalse();
      check(
        requestUsesServerConnectivityOrigin(
          origin,
          Uri(scheme: 'http', host: ''),
        ),
        because: 'server origin with an empty host',
      ).isFalse();
      // Two empty hosts are still not "the same origin".
      check(
        requestUsesServerConnectivityOrigin(
          Uri(scheme: 'http', host: ''),
          Uri(scheme: 'http', host: ''),
        ),
        because: 'two empty hosts',
      ).isFalse();
      // Two scheme-relative references with the same authority are rejected
      // by the `hasScheme` guards, before their (equal, empty) schemes could
      // compare equal to each other.
      check(
        requestUsesServerConnectivityOrigin(
          Uri.parse('//example.com/health'),
          Uri.parse('//example.com/'),
        ),
        because: 'two scheme-relative URIs sharing an authority',
      ).isFalse();
    });

    test('only scheme, host and port participate in the comparison', () {
      final origin = Uri.parse('https://chat.example.com:8443/base/');
      for (final request in <String>[
        'https://chat.example.com:8443/base/',
        'https://chat.example.com:8443/api/v1/models?q=1#frag',
        'https://chat.example.com:8443',
        // Userinfo is ignored, so credentials in the URL do not change the
        // origin decision. `_followPublicHealthRedirect` rejects userinfo
        // separately before it ever consults this predicate.
        'https://alice:secret@chat.example.com:8443/base/',
        // Dart normalizes scheme and host case during parsing, so a shouty
        // redirect target still matches.
        'HTTPS://CHAT.EXAMPLE.COM:8443/base/',
      ]) {
        check(
          requestUsesServerConnectivityOrigin(Uri.parse(request), origin),
          because: request,
        ).isTrue();
      }
      for (final request in <String>[
        'http://chat.example.com:8443/base/',
        'https://other.example.com:8443/base/',
        'https://chat.example.com:8444/base/',
        'https://chat.example.com/base/',
        'https://chat.example.com.:8443/base/',
      ]) {
        check(
          requestUsesServerConnectivityOrigin(Uri.parse(request), origin),
          because: request,
        ).isFalse();
      }
    });

    test('default ports compare equal to their explicit spelling', () {
      check(
        requestUsesServerConnectivityOrigin(
          Uri.parse('http://example.com/health'),
          Uri.parse('http://example.com:80/'),
        ),
        because: 'implicit vs explicit port 80',
      ).isTrue();
      check(
        requestUsesServerConnectivityOrigin(
          Uri.parse('https://example.com:443/health'),
          Uri.parse('https://example.com/'),
        ),
        because: 'implicit vs explicit port 443',
      ).isTrue();
      // Equal ports are not enough; the scheme still has to agree.
      check(
        requestUsesServerConnectivityOrigin(
          Uri.parse('http://example.com:443/health'),
          Uri.parse('https://example.com/'),
        ),
        because: 'http on 443 vs https',
      ).isFalse();
    });

    test('hosts are compared as text, not as resolved identities', () {
      // LOOKS WRONG: Dart does not canonicalize IPv6 literals inside a URI
      // authority, and this predicate only string-compares `Uri.host`. Two
      // spellings of the same address are therefore treated as different
      // origins. The health path fails closed on that (an off-origin redirect
      // must then pass the public-address classifier), but the connectivity
      // and auth-token call sites silently stop recognizing the server.
      check(
        requestUsesServerConnectivityOrigin(
          Uri.parse('http://[0:0:0:0:0:0:0:1]:8080/health'),
          Uri.parse('http://[::1]:8080/'),
        ),
        because: 'expanded vs compressed IPv6 literal',
      ).isFalse();
      // Same idea for the root-anchored FQDN spelling of a registered name.
      check(
        requestUsesServerConnectivityOrigin(
          Uri.parse('http://example.com./health'),
          Uri.parse('http://example.com/'),
        ),
        because: 'trailing-dot FQDN',
      ).isFalse();
      // Percent-encoding in a registered name *is* decoded by Uri, so it
      // matches.
      check(
        requestUsesServerConnectivityOrigin(
          Uri.parse('http://EXAM%50LE.com/health'),
          Uri.parse('http://example.com/'),
        ),
        because: 'percent-encoded registered name',
      ).isTrue();
    });

    test('the scheme is not restricted to http and https', () {
      // Callers gate the scheme themselves; this predicate happily reports a
      // match for any scheme, including ones where `Uri.port` defaults to 0.
      check(
        requestUsesServerConnectivityOrigin(
          Uri.parse('ftp://example.com/health'),
          Uri.parse('ftp://example.com/'),
        ),
        because: 'matching non-http scheme',
      ).isTrue();
      check(
        requestUsesServerConnectivityOrigin(
          Uri.parse('conduit://example.com/health'),
          Uri.parse('conduit://example.com:0/'),
        ),
        because: 'unknown scheme defaults to port 0',
      ).isTrue();
    });
  });

  group('isPublicHealthRedirectAddress IPv4', () {
    test('every non-globally-reachable IPv4 range is rejected', () {
      _pinClassification(<_Case>[
        // 0.0.0.0/8 "this network".
        _case('0/8 lower', InternetAddress('0.0.0.0'), isPublic: false),
        _case('0/8 upper', InternetAddress('0.255.255.255'), isPublic: false),
        // 10.0.0.0/8.
        _case('10/8 lower', InternetAddress('10.0.0.0'), isPublic: false),
        _case('10/8 upper', InternetAddress('10.255.255.255'), isPublic: false),
        // 100.64.0.0/10 CGNAT.
        _case('cgnat lower', InternetAddress('100.64.0.0'), isPublic: false),
        _case(
          'cgnat upper',
          InternetAddress('100.127.255.255'),
          isPublic: false,
        ),
        // 127.0.0.0/8 loopback.
        _case('loopback lower', InternetAddress('127.0.0.0'), isPublic: false),
        _case(
          'loopback upper',
          InternetAddress('127.255.255.255'),
          isPublic: false,
        ),
        // 169.254.0.0/16 link-local, including the cloud metadata address.
        _case(
          'link-local lower',
          InternetAddress('169.254.0.0'),
          isPublic: false,
        ),
        _case(
          'cloud metadata',
          InternetAddress('169.254.169.254'),
          isPublic: false,
        ),
        _case(
          'link-local upper',
          InternetAddress('169.254.255.255'),
          isPublic: false,
        ),
        // 172.16.0.0/12.
        _case(
          '172.16/12 lower',
          InternetAddress('172.16.0.0'),
          isPublic: false,
        ),
        _case(
          '172.16/12 upper',
          InternetAddress('172.31.255.255'),
          isPublic: false,
        ),
        // 192.0.0.0/24 IETF protocol assignments, which also holds the two
        // RFC 7050 NAT64 discovery markers.
        _case(
          '192.0.0/24 lower',
          InternetAddress('192.0.0.0'),
          isPublic: false,
        ),
        _case(
          'nat64 marker a',
          InternetAddress('192.0.0.170'),
          isPublic: false,
        ),
        _case(
          'nat64 marker b',
          InternetAddress('192.0.0.171'),
          isPublic: false,
        ),
        _case(
          '192.0.0/24 upper',
          InternetAddress('192.0.0.255'),
          isPublic: false,
        ),
        // 192.0.2.0/24 TEST-NET-1.
        _case('test-net-1', InternetAddress('192.0.2.255'), isPublic: false),
        // 192.88.99.0/24 deprecated 6to4 relay anycast.
        _case('6to4 relay', InternetAddress('192.88.99.1'), isPublic: false),
        // 192.168.0.0/16.
        _case(
          '192.168/16 lower',
          InternetAddress('192.168.0.0'),
          isPublic: false,
        ),
        _case(
          '192.168/16 upper',
          InternetAddress('192.168.255.255'),
          isPublic: false,
        ),
        // 198.18.0.0/15 benchmarking.
        _case(
          'benchmark lower',
          InternetAddress('198.18.0.0'),
          isPublic: false,
        ),
        _case(
          'benchmark upper',
          InternetAddress('198.19.255.255'),
          isPublic: false,
        ),
        // 198.51.100.0/24 TEST-NET-2 and 203.0.113.0/24 TEST-NET-3.
        _case('test-net-2', InternetAddress('198.51.100.255'), isPublic: false),
        _case('test-net-3', InternetAddress('203.0.113.255'), isPublic: false),
        // 224.0.0.0/4 multicast, 240.0.0.0/4 reserved, broadcast.
        _case('multicast lower', InternetAddress('224.0.0.0'), isPublic: false),
        _case(
          'multicast upper',
          InternetAddress('239.255.255.255'),
          isPublic: false,
        ),
        _case('reserved 240/4', InternetAddress('240.0.0.0'), isPublic: false),
        _case('reserved 250/8', InternetAddress('250.1.2.3'), isPublic: false),
        _case('broadcast', InternetAddress('255.255.255.255'), isPublic: false),
      ]);
    });

    test('addresses immediately outside each reserved range stay public', () {
      _pinClassification(<_Case>[
        _case('below 10/8', InternetAddress('9.255.255.255'), isPublic: true),
        _case('above 10/8', InternetAddress('11.0.0.0'), isPublic: true),
        _case('below cgnat', InternetAddress('100.63.255.255'), isPublic: true),
        _case('above cgnat', InternetAddress('100.128.0.0'), isPublic: true),
        _case(
          'below loopback',
          InternetAddress('126.255.255.255'),
          isPublic: true,
        ),
        _case('above loopback', InternetAddress('128.0.0.0'), isPublic: true),
        _case(
          'below link-local',
          InternetAddress('169.253.255.255'),
          isPublic: true,
        ),
        _case(
          'above link-local',
          InternetAddress('169.255.0.0'),
          isPublic: true,
        ),
        _case(
          'below 172.16/12',
          InternetAddress('172.15.255.255'),
          isPublic: true,
        ),
        _case('above 172.16/12', InternetAddress('172.32.0.0'), isPublic: true),
        // Only the exact /24s inside 192.0.0.0/16 are carved out.
        _case('192.0.1/24', InternetAddress('192.0.1.1'), isPublic: true),
        _case('192.0.3/24', InternetAddress('192.0.3.1'), isPublic: true),
        _case('192.1/16', InternetAddress('192.1.0.1'), isPublic: true),
        _case('192.88.98/24', InternetAddress('192.88.98.1'), isPublic: true),
        _case('192.88.100/24', InternetAddress('192.88.100.1'), isPublic: true),
        _case(
          'below 192.168/16',
          InternetAddress('192.167.255.255'),
          isPublic: true,
        ),
        _case(
          'above 192.168/16',
          InternetAddress('192.169.0.0'),
          isPublic: true,
        ),
        _case(
          'below benchmarking',
          InternetAddress('198.17.255.255'),
          isPublic: true,
        ),
        _case(
          'above benchmarking',
          InternetAddress('198.20.0.0'),
          isPublic: true,
        ),
        _case('198.51.99/24', InternetAddress('198.51.99.1'), isPublic: true),
        _case('198.51.101/24', InternetAddress('198.51.101.1'), isPublic: true),
        _case('203.0.112/24', InternetAddress('203.0.112.1'), isPublic: true),
        _case('203.0.114/24', InternetAddress('203.0.114.1'), isPublic: true),
        _case('203.1/16', InternetAddress('203.1.0.1'), isPublic: true),
        _case(
          'below multicast',
          InternetAddress('223.255.255.255'),
          isPublic: true,
        ),
        // AS112 and AMT delegations are listed as special-purpose but
        // globally reachable, and the classifier lets them through.
        _case('as112-v4', InternetAddress('192.31.196.1'), isPublic: true),
        _case('amt', InternetAddress('192.52.193.1'), isPublic: true),
        _case('as112 direct', InternetAddress('192.175.48.1'), isPublic: true),
      ]);
    });
  });

  group('isPublicHealthRedirectAddress IPv4 inside IPv6', () {
    test('IPv4-mapped IPv6 inherits the IPv4 classification', () {
      _pinClassification(<_Case>[
        _case(
          'mapped unspecified',
          InternetAddress('::ffff:0.0.0.0'),
          isPublic: false,
        ),
        _case(
          'mapped cloud metadata',
          InternetAddress('::ffff:169.254.169.254'),
          isPublic: false,
        ),
        _case(
          'mapped test-net-1',
          InternetAddress('::ffff:192.0.2.1'),
          isPublic: false,
        ),
        _case(
          'mapped nat64 marker',
          InternetAddress('::ffff:192.0.0.170'),
          isPublic: false,
        ),
        _case(
          'mapped test-net-3',
          InternetAddress('::ffff:203.0.113.1'),
          isPublic: false,
        ),
        _case(
          'mapped reserved',
          InternetAddress('::ffff:240.0.0.1'),
          isPublic: false,
        ),
        _case(
          'mapped broadcast',
          InternetAddress('::ffff:255.255.255.255'),
          isPublic: false,
        ),
        // Mapped public IPv4 is explicitly allowed, so the mapped branch is
        // not a blanket rejection.
        _case(
          'mapped public',
          InternetAddress('::ffff:1.1.1.1'),
          isPublic: true,
        ),
        _case(
          'mapped public dns',
          InternetAddress('::ffff:8.8.8.8'),
          isPublic: true,
        ),
      ]);
    });

    test('IPv4-compatible and IPv4-translated IPv6 fail closed', () {
      _pinClassification(<_Case>[
        // ::a.b.c.d (deprecated IPv4-compatible) never reaches the IPv4
        // classifier; it is rejected by the 2000::/3 gate instead.
        _case(
          'compatible loopback',
          InternetAddress('::127.0.0.1'),
          isPublic: false,
        ),
        _case(
          'compatible metadata',
          InternetAddress('::169.254.169.254'),
          isPublic: false,
        ),
        // Even a genuinely public IPv4 in compatible form is rejected.
        _case(
          'compatible public',
          InternetAddress('::1.1.1.1'),
          isPublic: false,
        ),
        // ::ffff:0:a.b.c.d is the RFC 6052 "IPv4-translated" form. bytes[8]
        // is 0xff, so it misses the mapped pattern and is rejected.
        _case(
          'translated loopback',
          InternetAddress('::ffff:0:127.0.0.1'),
          isPublic: false,
        ),
        _case(
          'translated public',
          InternetAddress('::ffff:0:1.1.1.1'),
          isPublic: false,
        ),
      ]);
    });
  });

  group('isPublicHealthRedirectAddress native IPv6', () {
    test('only 2000::/3 minus the special-purpose carve-outs is public', () {
      _pinClassification(<_Case>[
        // Below 2000::/3.
        _case(
          'discard-only 100::/64',
          InternetAddress('100::1'),
          isPublic: false,
        ),
        _case('1000::/4', InternetAddress('1000::1'), isPublic: false),
        _case('0100::/8', InternetAddress('100::'), isPublic: false),
        // Above 2000::/3.
        _case('4000::/3', InternetAddress('4000::1'), isPublic: false),
        _case('8000::/1', InternetAddress('8000::1'), isPublic: false),
        _case('ULA fc00::', InternetAddress('fc00::'), isPublic: false),
        _case('ULA fd00::', InternetAddress('fd00::1'), isPublic: false),
        _case('ULA upper', InternetAddress('fdff:ffff::1'), isPublic: false),
        _case('link-local lower', InternetAddress('fe80::'), isPublic: false),
        _case('link-local upper', InternetAddress('febf::1'), isPublic: false),
        _case('site-local fec0::', InternetAddress('fec0::1'), isPublic: false),
        _case('multicast ff00::', InternetAddress('ff00::1'), isPublic: false),
        _case('multicast ff05::', InternetAddress('ff05::2'), isPublic: false),
        _case('multicast ffff::', InternetAddress('ffff::1'), isPublic: false),
        // Carve-outs nested inside global unicast.
        _case('teredo 2001::', InternetAddress('2001::1'), isPublic: false),
        _case(
          '2001:0000::/23 upper',
          InternetAddress('2001:1ff:ffff::1'),
          isPublic: false,
        ),
        _case(
          'benchmarking 2001:2::',
          InternetAddress('2001:2::1'),
          isPublic: false,
        ),
        _case(
          'orchid 2001:10::',
          InternetAddress('2001:10::1'),
          isPublic: false,
        ),
        _case(
          'orchidv2 2001:20::',
          InternetAddress('2001:20::1'),
          isPublic: false,
        ),
        _case(
          'documentation 2001:db8:: upper',
          InternetAddress('2001:db8:ffff:ffff:ffff:ffff:ffff:ffff'),
          isPublic: false,
        ),
        _case('6to4 2002::', InternetAddress('2002::1'), isPublic: false),
        _case(
          '6to4 upper',
          InternetAddress('2002:ffff:ffff::1'),
          isPublic: false,
        ),
        _case(
          'documentation 3fff::/20 lower',
          InternetAddress('3fff::1'),
          isPublic: false,
        ),
        _case(
          'documentation 3fff::/20 upper',
          InternetAddress('3fff:fff:ffff::1'),
          isPublic: false,
        ),
      ]);
    });

    test('global unicast just outside each carve-out stays public', () {
      _pinClassification(<_Case>[
        _case(
          '2000::/3 lower bound',
          InternetAddress('2000::'),
          isPublic: true,
        ),
        _case(
          '3fff:1000:: above the doc block',
          InternetAddress('3fff:1000::1'),
          isPublic: true,
        ),
        _case(
          '3ffe:: (returned 6bone space)',
          InternetAddress('3ffe::1'),
          isPublic: true,
        ),
        _case(
          '2001:200:: above the /23',
          InternetAddress('2001:200::1'),
          isPublic: true,
        ),
        _case(
          '2001:db9:: beside the doc block',
          InternetAddress('2001:db9::1'),
          isPublic: true,
        ),
        _case(
          '2001:dc8:: beside the doc block',
          InternetAddress('2001:dc8::1'),
          isPublic: true,
        ),
        _case(
          '2003:: beside 2002::/16',
          InternetAddress('2003::1'),
          isPublic: true,
        ),
        _case('2400::', InternetAddress('2400::1'), isPublic: true),
        _case(
          '2a00::',
          InternetAddress('2a00:1450:4001:80f::200e'),
          isPublic: true,
        ),
        _case(
          '3fff upper bound of /3',
          InternetAddress('3fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff'),
          isPublic: true,
        ),
      ]);
    });
  });

  group('isPublicHealthRedirectAddress well-known NAT64', () {
    test('64:ff9b::/96 is classified by its embedded IPv4', () {
      _pinClassification(<_Case>[
        _case(
          'nat64 unspecified',
          InternetAddress('64:ff9b::0.0.0.0'),
          isPublic: false,
        ),
        _case(
          'nat64 loopback',
          InternetAddress('64:ff9b::127.0.0.1'),
          isPublic: false,
        ),
        _case(
          'nat64 rfc1918',
          InternetAddress('64:ff9b::10.0.0.1'),
          isPublic: false,
        ),
        _case(
          'nat64 192.168',
          InternetAddress('64:ff9b::192.168.1.1'),
          isPublic: false,
        ),
        _case(
          'nat64 cloud metadata',
          InternetAddress('64:ff9b::169.254.169.254'),
          isPublic: false,
        ),
        _case(
          'nat64 cgnat',
          InternetAddress('64:ff9b::100.64.0.1'),
          isPublic: false,
        ),
        _case(
          'nat64 broadcast',
          InternetAddress('64:ff9b::255.255.255.255'),
          isPublic: false,
        ),
        _case(
          'nat64 public',
          InternetAddress('64:ff9b::1.1.1.1'),
          isPublic: true,
        ),
        _case(
          'nat64 public dns',
          InternetAddress('64:ff9b::8.8.8.8'),
          isPublic: true,
        ),
      ]);
    });

    test('near-miss NAT64 prefixes fall through to the 2000::/3 gate', () {
      _pinClassification(<_Case>[
        // RFC 8215's local-use NAT64 prefix 64:ff9b:1::/48 is not the
        // well-known prefix, and 0x00 fails the global-unicast gate.
        _case(
          'rfc 8215 local-use nat64',
          InternetAddress('64:ff9b:1::127.0.0.1'),
          isPublic: false,
        ),
        _case(
          'rfc 8215 local-use nat64 with public v4',
          InternetAddress('64:ff9b:1::1.1.1.1'),
          isPublic: false,
        ),
        // Nonzero bytes anywhere in the 96-bit prefix break the match.
        _case(
          'nonzero prefix tail',
          _ipv6(<int>[
            0x00, 0x64, 0xff, 0x9b, 0x00, 0x00, 0x00, 0x00, //
            0x00, 0x01, 0x00, 0x00, 1, 1, 1, 1,
          ]),
          isPublic: false,
        ),
        _case(
          'wrong well-known prefix',
          InternetAddress('64:ff9c::1.1.1.1'),
          isPublic: false,
        ),
      ]);
    });
  });

  test('non-IP address families are rejected outright', () {
    // Unix domain sockets carry a path, not 4 or 16 address bytes, and the
    // classifier rejects any type that is neither IPv4 nor 16-byte IPv6.
    final unixAddress = InternetAddress(
      '/tmp/conduit-health.sock',
      type: InternetAddressType.unix,
    );
    check(unixAddress.type).equals(InternetAddressType.unix);
    check(isPublicHealthRedirectAddress(unixAddress)).isFalse();
  });

  group('RFC 7050 ipv4only.arpa discovery', () {
    test('missing or poisoned discovery answers fail closed', () {
      // No answers at all.
      check(
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
          InternetAddress('2606:4700:4700::1111'),
          const <InternetAddress>[],
        ),
        because: 'empty answers, global IPv6 target',
      ).isFalse();
      // LOOKS WRONG: the seam refuses even a plain public IPv4 target when
      // discovery yields nothing, although an IPv4 target never needs a
      // Pref64 to be classified. Production hides this because
      // `_requiresNat64PrefixDiscovery` skips discovery entirely for IPv4,
      // IPv4-mapped and well-known-NAT64 answers, so the null-prefix path is
      // never reached for them.
      check(
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
          InternetAddress('1.1.1.1'),
          const <InternetAddress>[],
        ),
        because: 'empty answers, public IPv4 target',
      ).isFalse();

      // An A record that is not one of the two RFC 7050 markers means the
      // answer set was tampered with.
      check(
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
          InternetAddress('2606:4700:4700::1111'),
          <InternetAddress>[InternetAddress('8.8.8.8')],
        ),
        because: 'non-marker A record',
      ).isFalse();
      check(
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
          InternetAddress('2606:4700:4700::1111'),
          <InternetAddress>[
            InternetAddress('192.0.0.170'),
            InternetAddress('192.0.0.172'),
          ],
        ),
        because: 'one good and one bad A record',
      ).isFalse();

      // ipv4only.arpa has no native AAAA records, so an IPv6 answer that does
      // not embed a marker at a supported prefix length is rejected.
      check(
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
          InternetAddress('2606:4700:4700::1111'),
          <InternetAddress>[
            InternetAddress('192.0.0.170'),
            InternetAddress('2606:4700:4700::1111'),
          ],
        ),
        because: 'AAAA answer without an embedded marker',
      ).isFalse();
      // A marker embedded at an unsupported prefix length (/80 here) is not
      // recognized either.
      final unsupportedLength = _ipv6(<int>[
        0x2a, 0x00, 0x14, 0x50, 0x40, 0x01, 0x08, 0x0f, //
        0x00, 0x00, 192, 0, 0, 170, 0x00, 0x00,
      ]);
      check(
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
          InternetAddress('2606:4700:4700::1111'),
          <InternetAddress>[unsupportedLength],
        ),
        because: 'marker embedded at an unsupported /80 prefix',
      ).isFalse();
      // A Unix answer is neither IPv4 nor IPv6, so discovery aborts.
      check(
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
          InternetAddress('2606:4700:4700::1111'),
          <InternetAddress>[
            InternetAddress('192.0.0.170'),
            InternetAddress('/tmp/x.sock', type: InternetAddressType.unix),
          ],
        ),
        because: 'non-IP answer',
      ).isFalse();
    });

    test('a discovered prefix rejects every reserved embedded IPv4', () {
      final discovery = _rfc6052(96, const <int>[192, 0, 0, 170]);
      for (final embedded in const <List<int>>[
        <int>[0, 0, 0, 0],
        <int>[10, 0, 0, 1],
        <int>[100, 64, 0, 1],
        <int>[127, 0, 0, 1],
        <int>[169, 254, 169, 254],
        <int>[172, 16, 0, 1],
        <int>[192, 0, 0, 170],
        <int>[192, 0, 2, 1],
        <int>[192, 88, 99, 1],
        <int>[192, 168, 0, 1],
        <int>[198, 18, 0, 1],
        <int>[198, 51, 100, 1],
        <int>[203, 0, 113, 1],
        <int>[224, 0, 0, 1],
        <int>[240, 0, 0, 1],
        <int>[255, 255, 255, 255],
      ]) {
        check(
          isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
            _rfc6052(96, embedded),
            <InternetAddress>[discovery],
          ),
          because: 'embedded ${embedded.join('.')}',
        ).isFalse();
      }
      for (final embedded in const <List<int>>[
        <int>[1, 1, 1, 1],
        <int>[8, 8, 8, 8],
        <int>[93, 184, 216, 34],
      ]) {
        check(
          isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
            _rfc6052(96, embedded),
            <InternetAddress>[discovery],
          ),
          because: 'embedded ${embedded.join('.')}',
        ).isTrue();
      }
    });

    test('addresses inside a discovered prefix must be RFC 6052 shaped', () {
      for (final prefixLength in const <int>[32, 40, 48, 56, 64]) {
        final discovery = _rfc6052(prefixLength, const <int>[192, 0, 0, 170]);
        // A nonzero u octet is not a valid RFC 6052 layout, so the address
        // fails closed even though it is otherwise ordinary global unicast.
        check(
          isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
            _rfc6052(prefixLength, const <int>[1, 1, 1, 1], uOctet: 0x01),
            <InternetAddress>[discovery],
          ),
          because: 'nonzero u octet at /$prefixLength with public IPv4',
        ).isFalse();
        // Nonzero reserved suffix bits are rejected the same way.
        check(
          isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
            _rfc6052(prefixLength, const <int>[1, 1, 1, 1], suffixTaint: 0x01),
            <InternetAddress>[discovery],
          ),
          because: 'nonzero suffix at /$prefixLength with public IPv4',
        ).isFalse();
        check(
          isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
            _rfc6052(prefixLength, const <int>[
              127,
              0,
              0,
              1,
            ], suffixTaint: 0x01),
            <InternetAddress>[discovery],
          ),
          because: 'nonzero suffix at /$prefixLength with private IPv4',
        ).isFalse();
      }
    });

    test('a discovered short prefix also fails closed on unrelated hosts', () {
      // The /32 Pref64 2a00:1450::/32 makes every 2a00:1450::/32 address
      // "inside" the translation prefix. A legitimate native host there is
      // not RFC 6052 shaped, so it is rejected. This is collateral damage of
      // failing closed, not a security hole.
      final discovery = _rfc6052(32, const <int>[192, 0, 0, 170]);
      check(
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
          InternetAddress('2a00:1450:4001:80f::200e'),
          <InternetAddress>[discovery],
        ),
        because: 'native host inside the discovered /32',
      ).isFalse();
      // A host outside the discovered prefix is untouched by it.
      check(
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
          InternetAddress('2606:4700:4700::1111'),
          <InternetAddress>[discovery],
        ),
        because: 'native host outside the discovered /32',
      ).isTrue();
    });

    test(
      'a /96 discovered prefix keeps byte 8 as prefix, not as a u octet',
      () {
        // RFC 6052 places the whole IPv4 in the last 32 bits for a /96, so the
        // u octet check is skipped and a nonzero byte 8 is simply part of the
        // prefix that has to match.
        const seed = <int>[
          0x2a, 0x00, 0x14, 0x50, 0x40, 0x01, 0x08, 0x0f, //
          0x42, 0x00, 0x00, 0x00,
        ];
        final discovery = _ipv6(<int>[...seed, 192, 0, 0, 170]);
        check(
          isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
            _ipv6(<int>[...seed, 127, 0, 0, 1]),
            <InternetAddress>[discovery],
          ),
          because: 'private IPv4 inside the discovered /96',
        ).isFalse();
        check(
          isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
            _ipv6(<int>[...seed, 1, 1, 1, 1]),
            <InternetAddress>[discovery],
          ),
          because: 'public IPv4 inside the discovered /96',
        ).isTrue();
        // The same /96 with byte 8 cleared is a different prefix, so it is not
        // constrained at all and passes on native classification alone.
        final clearedByte8 = <int>[...seed]..[8] = 0x00;
        check(
          isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
            _ipv6(<int>[...clearedByte8, 127, 0, 0, 1]),
            <InternetAddress>[discovery],
          ),
          because: 'private IPv4 under a prefix that was not discovered',
        ).isTrue();
      },
    );

    test('every discovered prefix is enforced, and duplicates collapse', () {
      const seedA = <int>[
        0x2a, 0x00, 0x14, 0x50, 0x40, 0x01, 0x08, 0x0f, //
        0x00, 0x00, 0x00, 0x00,
      ];
      const seedB = <int>[
        0x26, 0x20, 0x00, 0x4f, 0x80, 0x00, 0x00, 0x00, //
        0x00, 0x00, 0x00, 0x00,
      ];
      final answers = <InternetAddress>[
        InternetAddress('192.0.0.170'),
        InternetAddress('192.0.0.171'),
        _ipv6(<int>[...seedA, 192, 0, 0, 170]),
        // Same prefix discovered twice through both markers; the prefix map
        // keys on length plus bytes, so this collapses to one entry.
        _ipv6(<int>[...seedA, 192, 0, 0, 171]),
        _ipv6(<int>[...seedB, 192, 0, 0, 170]),
      ];
      check(
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
          _ipv6(<int>[...seedA, 127, 0, 0, 1]),
          answers,
        ),
        because: 'private IPv4 under the first discovered prefix',
      ).isFalse();
      check(
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
          _ipv6(<int>[...seedB, 169, 254, 169, 254]),
          answers,
        ),
        because: 'metadata address under the second discovered prefix',
      ).isFalse();
      check(
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
          _ipv6(<int>[...seedA, 1, 1, 1, 1]),
          answers,
        ),
        because: 'public IPv4 under the first discovered prefix',
      ).isTrue();
      check(
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
          InternetAddress('2606:4700:4700::1111'),
          answers,
        ),
        because: 'unrelated global IPv6',
      ).isTrue();
    });

    test('the well-known prefix stays enforced when it is also discovered', () {
      final discovery = InternetAddress('64:ff9b::192.0.0.170');
      check(
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
          InternetAddress('64:ff9b::127.0.0.1'),
          <InternetAddress>[discovery],
        ),
      ).isFalse();
      check(
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
          InternetAddress('64:ff9b::1.1.1.1'),
          <InternetAddress>[discovery],
        ),
      ).isTrue();
    });

    test('a Pref64 that discovery never reported is not enforced', () {
      // LOOKS WRONG: this is the residual SSRF gap. When ipv4only.arpa answers
      // with A records only (the "no NAT64 here" signal), an address that is
      // really a NAT64 translation of 127.0.0.1 behind an undiscovered Pref64
      // is indistinguishable from an ordinary global IPv6 host and is allowed
      // through. The source comment above the 2000::/3 gate acknowledges that
      // network-specific Pref64 values cannot be inferred from an address
      // alone, but the practical effect is that an attacker who can also
      // shape ipv4only.arpa answers can reach the private network.
      const undiscoveredSeed = <int>[
        0x2a, 0x00, 0x14, 0x50, 0x40, 0x01, 0x08, 0x0f, //
        0x00, 0x00, 0x00, 0x00,
      ];
      check(
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
          _ipv6(<int>[...undiscoveredSeed, 127, 0, 0, 1]),
          <InternetAddress>[
            InternetAddress('192.0.0.170'),
            InternetAddress('192.0.0.171'),
          ],
        ),
        because: 'loopback behind an undiscovered Pref64',
      ).isTrue();
      check(
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
          _ipv6(<int>[...undiscoveredSeed, 169, 254, 169, 254]),
          <InternetAddress>[InternetAddress('192.0.0.170')],
        ),
        because: 'cloud metadata behind an undiscovered Pref64',
      ).isTrue();
    });

    test('IPv4 answers are never constrained by a discovered prefix', () {
      final discovery = _rfc6052(96, const <int>[192, 0, 0, 170]);
      check(
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
          InternetAddress('1.1.1.1'),
          <InternetAddress>[discovery],
        ),
        because: 'public IPv4 target',
      ).isTrue();
      check(
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
          InternetAddress('127.0.0.1'),
          <InternetAddress>[discovery],
        ),
        because: 'loopback IPv4 target',
      ).isFalse();
      check(
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
          InternetAddress('::ffff:169.254.169.254'),
          <InternetAddress>[discovery],
        ),
        because: 'IPv4-mapped metadata target',
      ).isFalse();
    });
  });

  for (final scenario in _discoveryTriggers) {
    test('off-origin health redirect to ${scenario.label} '
        '${scenario.discovers ? 'resolves' : 'skips'} ipv4only.arpa', () async {
      // The off-origin target is served by a second loopback server that the
      // pinned connector dials directly, so the whole redirect walk runs and
      // the only thing that varies is whether Pref64 discovery was needed.
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      target.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write('{"status":true}');
        await request.response.close();
      });
      final redirect = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      redirect.listen((request) async {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(
            HttpHeaders.locationHeader,
            'http://health-target.invalid/ready',
          );
        await request.response.close();
      });
      final resolvedHosts = <String>[];
      final dialled = <String>[];
      final workerManager = WorkerManager();
      final api = ApiService(
        serverConfig: ServerConfig(
          id: 'nat64-discovery-trigger',
          name: 'NAT64 discovery trigger',
          url: 'http://${redirect.address.address}:${redirect.port}',
        ),
        workerManager: workerManager,
        publicHealthAddressResolver: (host) async {
          resolvedHosts.add(host);
          if (host == 'ipv4only.arpa') {
            return <InternetAddress>[
              InternetAddress('192.0.0.170'),
              InternetAddress('192.0.0.171'),
            ];
          }
          return <InternetAddress>[scenario.address];
        },
        publicHealthSocketConnector: (address, port) {
          dialled.add('${address.address}:$port');
          return Socket.startConnect(target.address, target.port);
        },
      );

      try {
        check(await api.checkHealth()).isTrue();
        check(resolvedHosts).deepEquals(<String>[
          'health-target.invalid',
          if (scenario.discovers) 'ipv4only.arpa',
        ]);
        // Every scenario address classifies as public, so the transport is
        // always reached and is always pinned to the prevalidated address.
        check(dialled).deepEquals(<String>['${scenario.address.address}:80']);
      } finally {
        api.dispose();
        workerManager.dispose();
        await redirect.close(force: true);
        await target.close(force: true);
      }
    });
  }
}

typedef _Case = ({String label, InternetAddress address, bool isPublic});

_Case _case(String label, InternetAddress address, {required bool isPublic}) =>
    (label: label, address: address, isPublic: isPublic);

void _pinClassification(List<_Case> cases) {
  for (final entry in cases) {
    check(
      isPublicHealthRedirectAddress(entry.address),
      because: '${entry.label} <${entry.address.address}>',
    ).equals(entry.isPublic);
  }
}

InternetAddress _ipv6(List<int> bytes) {
  if (bytes.length != 16) {
    throw ArgumentError.value(bytes, 'bytes', 'expected 16 IPv6 bytes');
  }
  return InternetAddress.fromRawAddress(Uint8List.fromList(bytes));
}

/// A test Pref64 seed. Its first bytes stay inside 2000::/3 and clear of every
/// carve-out, so an address built from it passes native IPv6 classification
/// and the RFC 6052 layers are what the assertions actually exercise.
const _pref64Seed = <int>[
  0x2a, 0x00, 0x14, 0x50, 0x40, 0x01, 0x08, 0x0f, //
  0x00, 0x00, 0x00, 0x00,
];

/// Builds the RFC 6052 section 2.2 encoding of [ipv4] under the [prefixLength]
/// prefix taken from [_pref64Seed], optionally corrupting the u octet or the
/// reserved suffix bits.
InternetAddress _rfc6052(
  int prefixLength,
  List<int> ipv4, {
  int uOctet = 0,
  int suffixTaint = 0,
}) {
  final raw = List<int>.filled(16, 0);
  raw.setRange(0, prefixLength ~/ 8, _pref64Seed);
  switch (prefixLength) {
    case 32:
      raw.setRange(4, 8, ipv4);
    case 40:
      raw.setRange(5, 8, ipv4.take(3));
      raw[9] = ipv4[3];
    case 48:
      raw.setRange(6, 8, ipv4.take(2));
      raw.setRange(9, 11, ipv4.skip(2));
    case 56:
      raw[7] = ipv4[0];
      raw.setRange(9, 12, ipv4.skip(1));
    case 64:
      raw.setRange(9, 13, ipv4);
    case 96:
      if (uOctet != 0 || suffixTaint != 0) {
        throw ArgumentError('a /96 has no u octet and no suffix bits');
      }
      raw.setRange(12, 16, ipv4);
    default:
      throw ArgumentError.value(prefixLength, 'prefixLength');
  }
  if (prefixLength != 96) {
    raw[8] = uOctet;
    if (suffixTaint != 0) raw[15] = suffixTaint;
  }
  return _ipv6(raw);
}

final _discoveryTriggers =
    <({String label, InternetAddress address, bool discovers})>[
      (
        label: 'a public IPv4',
        address: InternetAddress('1.1.1.1'),
        discovers: false,
      ),
      (
        label: 'an IPv4-mapped public address',
        address: InternetAddress('::ffff:1.1.1.1'),
        discovers: false,
      ),
      (
        label: 'a well-known NAT64 address',
        address: InternetAddress('64:ff9b::1.1.1.1'),
        discovers: false,
      ),
      (
        label: 'an ordinary global IPv6 address',
        address: InternetAddress('2606:4700:4700::1111'),
        discovers: true,
      ),
    ];
