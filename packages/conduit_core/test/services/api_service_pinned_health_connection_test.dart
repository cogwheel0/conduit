// Characterization tests for the pinned raw-socket health-probe connection
// (`_PinnedPublicHealthConnection` and friends in
// `lib/core/services/api_service.dart`).
//
// These tests pin the CURRENT behaviour of that transport ahead of moving it
// verbatim into `packages/conduit_core/lib/src/network/io/`. They assert what
// the code does today, not what it arguably should do; anything that looks
// wrong is marked `LOOKS WRONG:` and pinned as-is.
//
// The pinned connection is private, so it is driven the only way production
// reaches it: `ApiService.checkHealth()` follows an off-origin redirect, which
// installs the pinned `HttpClient.connectionFactory`. The three injectable
// seams (`PublicHealthAddressResolver`, `PublicHealthSocketConnector`,
// `PublicHealthSocketUpgrader`) are faked here, so no real DNS lookup, TCP
// connection or TLS handshake happens: the only real socket in this file is
// the loopback `HttpServer` that serves the initial `/health` redirect, which
// is the sole way to enter the redirect path at all.
//
// `_FakeSocket` speaks just enough HTTP for `dart:io`'s `HttpClient` to drive
// a request over it, which lets every hop after the first be fully synthetic
// and lets the tests count sockets opened against sockets destroyed.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  tearDown(ConnectivityService.debugResetTrafficSignals);

  group('pinned health connection: happy path', () {
    test('an http hop uses the first prevalidated address and never '
        'upgrades', () async {
      final ledger = _SocketLedger();
      final source = await _startRedirectSource(
        'http://health-target.invalid/ready',
      );
      final attempts = <String>[];
      var upgrades = 0;
      final api = _api(
        source: source,
        resolver: (_) async => <InternetAddress>[
          InternetAddress('8.8.8.8'),
          InternetAddress('1.1.1.1'),
          InternetAddress('9.9.9.9'),
        ],
        connector: (address, port) async {
          attempts.add('${address.address}:$port');
          final connect = _FakeConnect('connect-${attempts.length}');
          connect.provide(ledger.open('raw', response: _httpResponse(200)));
          return connect.task;
        },
        upgrader: (socket, host) {
          upgrades++;
          return Future<Socket>.error(StateError('must not upgrade http'));
        },
      );

      check(await api.checkHealth()).isTrue();
      // Strictly serial: the remaining prevalidated addresses are never
      // dialled once the first one connects. There is no happy-eyeballs race.
      check(attempts).deepEquals(['8.8.8.8:80']);
      check(upgrades).equals(0);
      check(ledger.opened).equals(1);
      check(ledger.sockets.single.request).contains('GET /ready HTTP/1.1');
      // The hop's socket belongs to the per-hop Dio client once it is handed
      // over, and that client is force-closed on every exit path.
      await ledger.sockets.single.whenDestroyed.timeout(_settle);
      check(ledger.live).isEmpty();
    });

    test('an https hop upgrades the raw socket and hands over the TLS '
        'socket', () async {
      final ledger = _SocketLedger();
      final source = await _startRedirectSource(
        'https://health-target.invalid:8443/ready',
      );
      final attempts = <String>[];
      final upgradeHosts = <String>[];
      Socket? upgradedFrom;
      late final _FakeSocket raw;
      late final _FakeSocket tls;
      final api = _api(
        source: source,
        resolver: (_) async => <InternetAddress>[InternetAddress('8.8.8.8')],
        connector: (address, port) async {
          attempts.add('${address.address}:$port');
          final connect = _FakeConnect('connect');
          raw = ledger.open('raw');
          connect.provide(raw);
          return connect.task;
        },
        upgrader: (socket, host) async {
          upgradeHosts.add(host);
          upgradedFrom = socket;
          tls = ledger.open('tls', response: _httpResponse(200));
          return tls;
        },
      );

      check(await api.checkHealth()).isTrue();
      // The port comes from the redirect URI, not from the scheme default.
      check(attempts).deepEquals(['8.8.8.8:8443']);
      // The upgrade is handed the bare hostname, without the port.
      check(upgradeHosts).deepEquals(['health-target.invalid']);
      check(identical(upgradedFrom, raw)).isTrue();
      check(tls.request).contains('GET /ready HTTP/1.1');
      check(raw.request).isEmpty();

      await tls.whenDestroyed.timeout(_settle);
      // The raw socket is deliberately not destroyed after a successful
      // upgrade: `SecureSocket.secure` detaches it and the TLS socket owns the
      // underlying connection from then on. `transferSocketOwnership()` drops
      // both references, so nothing in the pinned connection can destroy it.
      check(raw.destroyCount).equals(0);
      check(ledger.opened).equals(2);
    });

    test('an IP-literal redirect target skips DNS and still pins', () async {
      final ledger = _SocketLedger();
      final source = await _startRedirectSource('http://8.8.8.8:8080/ready');
      final resolvedHosts = <String>[];
      final attempts = <String>[];
      final api = _api(
        source: source,
        resolver: (host) async {
          resolvedHosts.add(host);
          return <InternetAddress>[InternetAddress('8.8.8.8')];
        },
        connector: (address, port) async {
          attempts.add('${address.address}:$port');
          final connect = _FakeConnect('connect');
          connect.provide(ledger.open('raw', response: _httpResponse(200)));
          return connect.task;
        },
      );

      check(await api.checkHealth()).isTrue();
      check(resolvedHosts).isEmpty();
      check(attempts).deepEquals(['8.8.8.8:8080']);
      await ledger.sockets.single.whenDestroyed.timeout(_settle);
    });
  });

  group('pinned health connection: address fallback', () {
    test('addresses are tried one at a time until one connects', () async {
      final ledger = _SocketLedger();
      final source = await _startRedirectSource(
        'http://health-target.invalid/ready',
      );
      final attempts = <String>[];
      final firstDialled = Completer<void>();
      final releaseFirst = Completer<void>();
      var secondStartedAfterFirstFailed = false;
      final api = _api(
        source: source,
        resolver: (_) async => <InternetAddress>[
          InternetAddress('8.8.8.8'),
          InternetAddress('1.1.1.1'),
          InternetAddress('9.9.9.9'),
        ],
        connector: (address, port) async {
          attempts.add(address.address);
          switch (address.address) {
            case '8.8.8.8':
              if (!firstDialled.isCompleted) firstDialled.complete();
              await releaseFirst.future;
              // The connector future itself fails.
              throw const SocketException('injected connector failure');
            case '1.1.1.1':
              secondStartedAfterFirstFailed = releaseFirst.isCompleted;
              // The connector succeeds but the socket never arrives.
              final connect = _FakeConnect('connect-2');
              connect.fail(const SocketException('injected connect refusal'));
              return connect.task;
            default:
              final connect = _FakeConnect('connect-3');
              connect.provide(ledger.open('raw', response: _httpResponse(200)));
              return connect.task;
          }
        },
      );

      final health = api.checkHealth();
      await firstDialled.future.timeout(_settle);
      // A parallel dial would already have reached the second address.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      check(attempts).deepEquals(['8.8.8.8']);
      releaseFirst.complete();

      check(await health.timeout(_settle)).isTrue();
      check(attempts).deepEquals(['8.8.8.8', '1.1.1.1', '9.9.9.9']);
      check(secondStartedAfterFirstFailed).isTrue();
      // Only the address that connected ever produced a socket.
      check(ledger.opened).equals(1);
      await ledger.sockets.single.whenDestroyed.timeout(_settle);
    });

    test('every address failing reports unhealthy and leaks nothing', () async {
      final ledger = _SocketLedger();
      final source = await _startRedirectSource(
        'https://health-target.invalid/ready',
      );
      final attempts = <String>[];
      final api = _api(
        source: source,
        resolver: (_) async => <InternetAddress>[
          InternetAddress('8.8.8.8'),
          InternetAddress('1.1.1.1'),
        ],
        connector: (address, port) async {
          attempts.add(address.address);
          final connect = _FakeConnect('connect-${attempts.length}');
          // A socket that arrives from a doomed attempt is still destroyed.
          connect.provide(ledger.open('raw-${attempts.length}'));
          return connect.task;
        },
        // Every address connects, but the (https) upgrade always fails, so
        // the loop exhausts the address list.
        upgrader: (socket, host) =>
            Future<Socket>.error(const HandshakeException('injected')),
      );

      // LOOKS WRONG: every distinct transport failure below - DNS refusal,
      // connect refusal, TLS handshake failure, deadline expiry - collapses
      // into the same bare `false`. `checkHealth` catches DioException,
      // TimeoutException and `catch (_)` alike, so no caller can tell why the
      // probe failed, and the last error the pinned connection recorded is
      // discarded rather than surfaced.
      check(await api.checkHealth()).isFalse();
      check(attempts).deepEquals(['8.8.8.8', '1.1.1.1']);
      check(ledger.opened).equals(2);
      for (final socket in ledger.sockets) {
        await socket.whenDestroyed.timeout(_settle);
      }
      check(ledger.live).isEmpty();
    });

    test('one connect deadline is split across the prevalidated '
        'addresses', () async {
      final ledger = _SocketLedger();
      final source = await _startRedirectSource(
        'http://health-target.invalid/ready',
      );
      final attempts = <String>[];
      final stalled = Completer<ConnectionTask<Socket>>();
      final api = _api(
        source: source,
        resolver: (_) async => <InternetAddress>[
          InternetAddress('8.8.8.8'),
          InternetAddress('1.1.1.1'),
        ],
        connector: (address, port) {
          attempts.add(address.address);
          if (address.address == '8.8.8.8') {
            // Never completes: the first address must be abandoned by its
            // own share of the deadline, not by the whole budget.
            return stalled.future;
          }
          final connect = _FakeConnect('connect-2');
          connect.provide(ledger.open('raw', response: _httpResponse(200)));
          return Future<ConnectionTask<Socket>>.value(connect.task);
        },
        // Two addresses share this budget, so the first attempt is abandoned
        // after ~450ms and the second still has ~450ms to succeed.
        pinnedConnectTimeout: const Duration(milliseconds: 900),
      );

      final elapsed = Stopwatch()..start();
      check(await api.checkHealth().timeout(const Duration(seconds: 5)))
          .isTrue();
      elapsed.stop();
      check(attempts).deepEquals(['8.8.8.8', '1.1.1.1']);
      // Without slicing the stalled address would hold the full 900ms budget
      // and the hop would time out instead of falling back.
      check(elapsed.elapsed).isGreaterThan(const Duration(milliseconds: 300));
      await ledger.sockets.single.whenDestroyed.timeout(_settle);
    });
  });

  group('pinned health connection: cancellation and late results', () {
    test('a connection task that arrives after the hop gave up is '
        'cancelled', () async {
      final ledger = _SocketLedger();
      final source = await _startRedirectSource(
        'http://health-target.invalid/ready',
      );
      final lateConnect = _FakeConnect('late');
      final stalled = Completer<ConnectionTask<Socket>>();
      var dials = 0;
      final api = _api(
        source: source,
        resolver: (_) async => <InternetAddress>[InternetAddress('8.8.8.8')],
        connector: (address, port) {
          dials++;
          return stalled.future;
        },
        pinnedConnectTimeout: const Duration(milliseconds: 150),
      );

      check(await api.checkHealth().timeout(const Duration(seconds: 5)))
          .isFalse();
      check(dials).equals(1);
      check(lateConnect.cancelCount).equals(0);

      // The connect finally lands after the hop is over. The pinned
      // connection must cancel it rather than abandon it.
      stalled.complete(lateConnect.task);
      await lateConnect.whenCancelled.timeout(_settle);
      check(lateConnect.cancelCount).equals(1);
      // It never asks the abandoned task for its socket, so releasing the
      // underlying connection is entirely `ConnectionTask.cancel`'s job.
      check(ledger.opened).equals(0);
    });

    test(
      'a socket delivered after its attempt timed out is destroyed',
      () async {
        final ledger = _SocketLedger();
        final source = await _startRedirectSource(
          'http://health-target.invalid/ready',
        );
        // Models the real race the acceptance flag exists for: the cancel loses
        // and the connect completes anyway.
        final racing = _FakeConnect('racing', failOnCancel: false);
        final api = _api(
          source: source,
          resolver: (_) async => <InternetAddress>[InternetAddress('8.8.8.8')],
          connector: (address, port) async => racing.task,
          pinnedConnectTimeout: const Duration(milliseconds: 150),
        );

        check(await api.checkHealth().timeout(const Duration(seconds: 5)))
            .isFalse();
        check(racing.cancelCount).equals(1);
        check(ledger.opened).equals(0);

        final orphan = ledger.open('orphan');
        racing.provide(orphan);
        await orphan.whenDestroyed.timeout(_settle);
        check(orphan.destroyCount).equals(1);
        check(ledger.live).isEmpty();
      },
    );

    test('a TLS upgrade that completes after the deadline destroys both '
        'sockets', () async {
      final ledger = _SocketLedger();
      final source = await _startRedirectSource(
        'https://health-target.invalid/ready',
      );
      final upgradeStarted = Completer<void>();
      final upgrade = Completer<Socket>();
      late final _FakeSocket raw;
      final api = _api(
        source: source,
        resolver: (_) async => <InternetAddress>[InternetAddress('8.8.8.8')],
        connector: (address, port) async {
          final connect = _FakeConnect('connect');
          raw = ledger.open('raw');
          connect.provide(raw);
          return connect.task;
        },
        upgrader: (socket, host) {
          if (!upgradeStarted.isCompleted) upgradeStarted.complete();
          return upgrade.future;
        },
        pinnedConnectTimeout: const Duration(milliseconds: 150),
      );

      check(await api.checkHealth().timeout(const Duration(seconds: 5)))
          .isFalse();
      await upgradeStarted.future.timeout(_settle);
      // The raw socket is destroyed as soon as the attempt is abandoned, even
      // though `SecureSocket.secure` may already have detached it.
      await raw.whenDestroyed.timeout(_settle);

      final orphan = ledger.open('tls-orphan');
      upgrade.complete(orphan);
      await orphan.whenDestroyed.timeout(_settle);
      check(ledger.opened).equals(2);
      check(ledger.live).isEmpty();
    });

    test('a hop whose response never arrives is bounded by the overall '
        'deadline', () async {
      final ledger = _SocketLedger();
      final source = await _startRedirectSource(
        'http://health-target.invalid/ready',
      );
      final api = _api(
        source: source,
        resolver: (_) async => <InternetAddress>[InternetAddress('8.8.8.8')],
        connector: (address, port) async {
          final connect = _FakeConnect('connect');
          // No canned response: the hop connects but never answers.
          connect.provide(ledger.open('raw'));
          return connect.task;
        },
        requestTimeout: const Duration(milliseconds: 400),
      );

      final elapsed = Stopwatch()..start();
      check(await api.checkHealth().timeout(const Duration(seconds: 5)))
          .isFalse();
      elapsed.stop();
      check(elapsed.elapsed).isLessThan(const Duration(milliseconds: 2000));
      // Force-closing the per-hop client releases the connected socket even
      // though the pinned connection had already handed ownership over.
      await ledger.sockets.single.whenDestroyed.timeout(_settle);
      check(ledger.sockets.single.request).contains('GET /ready HTTP/1.1');
    });
  });

  group('pinned health connection: failures', () {
    test('a failed TLS upgrade destroys the raw socket and reports '
        'unhealthy', () async {
      final ledger = _SocketLedger();
      final source = await _startRedirectSource(
        'https://health-target.invalid/ready',
      );
      var upgrades = 0;
      final attempts = <String>[];
      final api = _api(
        source: source,
        resolver: (_) async => <InternetAddress>[InternetAddress('8.8.8.8')],
        connector: (address, port) async {
          attempts.add('${address.address}:$port');
          final connect = _FakeConnect('connect');
          connect.provide(ledger.open('raw'));
          return connect.task;
        },
        upgrader: (socket, host) async {
          upgrades++;
          throw const HandshakeException('injected handshake failure');
        },
      );

      check(await api.checkHealth()).isFalse();
      // A redirect target without an explicit port dials the scheme default.
      check(attempts).deepEquals(['8.8.8.8:443']);
      check(upgrades).equals(1);
      check(ledger.opened).equals(1);
      await ledger.sockets.single.whenDestroyed.timeout(_settle);
      check(ledger.sockets.single.destroyCount).equals(1);
    });

    test('a global IPv6 answer without Pref64 discovery never opens a '
        'socket', () async {
      final source = await _startRedirectSource(
        'http://health-target.invalid/ready',
      );
      final resolvedHosts = <String>[];
      var dials = 0;
      final api = _api(
        source: source,
        resolver: (host) async {
          resolvedHosts.add(host);
          return <InternetAddress>[
            InternetAddress('8.8.8.8'),
            InternetAddress('2606:4700:4700::1111'),
          ];
        },
        connector: (address, port) async {
          dials++;
          throw StateError('must not dial an unclassified target');
        },
      );

      // A globally routable IPv6 answer forces an `ipv4only.arpa` lookup, and
      // an answer carrying no RFC 7050 marker fails the whole target closed -
      // including the public IPv4 address that came back with it.
      check(await api.checkHealth()).isFalse();
      check(resolvedHosts)
          .deepEquals(['health-target.invalid', 'ipv4only.arpa']);
      check(dials).equals(0);
    });

    test('a resolver failure never opens a socket', () async {
      final source = await _startRedirectSource(
        'http://health-target.invalid/ready',
      );
      var dials = 0;
      final api = _api(
        source: source,
        resolver: (_) async =>
            throw const SocketException('injected DNS failure'),
        connector: (address, port) async {
          dials++;
          throw StateError('must not dial after a DNS failure');
        },
      );

      check(await api.checkHealth()).isFalse();
      check(dials).equals(0);
    });
  });

  group('pinned health connection: redirect chain', () {
    for (final statusCode in <int>[
      HttpStatus.movedPermanently,
      HttpStatus.found,
      HttpStatus.seeOther,
      HttpStatus.temporaryRedirect,
      HttpStatus.permanentRedirect,
    ]) {
      test('a pinned hop follows HTTP $statusCode', () async {
        final ledger = _SocketLedger();
        final source = await _startRedirectSource('http://hop-1.invalid/one');
        final resolvedHosts = <String>[];
        final api = _api(
          source: source,
          resolver: (host) async {
            resolvedHosts.add(host);
            return <InternetAddress>[InternetAddress('8.8.8.8')];
          },
          connector: (address, port) async {
            final connect = _FakeConnect('connect-${ledger.opened + 1}');
            connect.provide(
              ledger.open(
                'hop-${ledger.opened + 1}',
                response: ledger.opened == 0
                    ? _httpResponse(
                        statusCode,
                        location: 'http://hop-2.invalid/two',
                      )
                    : _httpResponse(200),
              ),
            );
            return connect.task;
          },
        );

        check(await api.checkHealth()).isTrue();
        check(resolvedHosts).deepEquals(['hop-1.invalid', 'hop-2.invalid']);
        check(ledger.opened).equals(2);
        for (final socket in ledger.sockets) {
          await socket.whenDestroyed.timeout(_settle);
        }
      });
    }

    test('a 3xx outside the redirect set is not followed', () async {
      final ledger = _SocketLedger();
      final source = await _startRedirectSource('http://hop-1.invalid/one');
      final api = _api(
        source: source,
        resolver: (_) async => <InternetAddress>[InternetAddress('8.8.8.8')],
        connector: (address, port) async {
          final connect = _FakeConnect('connect');
          connect.provide(
            ledger.open(
              'hop',
              // 300 carries a Location but is not in
              // `_publicHealthRedirectStatusCodes`.
              response: _httpResponse(
                HttpStatus.multipleChoices,
                location: 'http://hop-2.invalid/two',
              ),
            ),
          );
          return connect.task;
        },
      );

      check(await api.checkHealth()).isFalse();
      check(ledger.opened).equals(1);
      await ledger.sockets.single.whenDestroyed.timeout(_settle);
    });

    test('a pinned redirect without a Location header stops the '
        'chain', () async {
      final ledger = _SocketLedger();
      final source = await _startRedirectSource('http://hop-1.invalid/one');
      final api = _api(
        source: source,
        resolver: (_) async => <InternetAddress>[InternetAddress('8.8.8.8')],
        connector: (address, port) async {
          final connect = _FakeConnect('connect');
          connect.provide(
            ledger.open('hop', response: _httpResponse(HttpStatus.found)),
          );
          return connect.task;
        },
      );

      check(await api.checkHealth()).isFalse();
      check(ledger.opened).equals(1);
      await ledger.sockets.single.whenDestroyed.timeout(_settle);
    });

    test('five pinned hops are followed and the fifth can succeed', () async {
      final result = await _runPinnedChain(healthyHop: 5);
      check(result.healthy).isTrue();
      check(result.resolvedHosts).deepEquals([
        'hop-1.invalid',
        'hop-2.invalid',
        'hop-3.invalid',
        'hop-4.invalid',
        'hop-5.invalid',
      ]);
      check(result.socketsOpened).equals(5);
      check(result.socketsLive).isEmpty();
    });

    test('a sixth pinned hop is never dialled', () async {
      final result = await _runPinnedChain(healthyHop: 6);
      check(result.healthy).isFalse();
      // `_maximumPublicHealthRedirects` is 5: the sixth target is resolved
      // for policy but never becomes a request.
      check(result.resolvedHosts).deepEquals([
        'hop-1.invalid',
        'hop-2.invalid',
        'hop-3.invalid',
        'hop-4.invalid',
        'hop-5.invalid',
      ]);
      check(result.socketsOpened).equals(5);
      check(result.socketsLive).isEmpty();
    });
  });

  group('TLS handshake classification', () {
    // Complements the four cases already pinned in
    // api_service_chat_completion_test.dart.
    test('a TlsException instance is a handshake failure', () {
      check(
        isTlsHandshakeFailureForTest(
          DioException(
            requestOptions: RequestOptions(path: '/health'),
            error: const TlsException('handshake aborted'),
          ),
        ),
      ).isTrue();
    });

    for (final text in <String>[
      'HandshakeException: something',
      'TlsException: something',
      'alert bad certificate',
    ]) {
      test('the message text "$text" is a handshake failure', () {
        check(
          isTlsHandshakeFailureForTest(
            DioException(
              requestOptions: RequestOptions(path: '/health'),
              error: text,
            ),
          ),
        ).isTrue();
      });
    }

    test('with no error object the DioException message is classified', () {
      check(
        isTlsHandshakeFailureForTest(
          DioException(
            requestOptions: RequestOptions(path: '/health'),
            message: 'CERTIFICATE_VERIFY_FAILED: self signed certificate',
          ),
        ),
      ).isTrue();
      check(
        isTlsHandshakeFailureForTest(
          DioException(requestOptions: RequestOptions(path: '/health')),
        ),
      ).isFalse();
    });

    test('a pinned handshake failure never reaches the classifier', () async {
      // `checkHealth` has no TLS branch at all: a failed pinned upgrade is
      // reported as a plain unhealthy result, unlike
      // `checkHealthWithProxyDetection`, which rethrows handshake failures.
      final source = await _startRedirectSource(
        'https://health-target.invalid/ready',
      );
      final ledger = _SocketLedger();
      final api = _api(
        source: source,
        resolver: (_) async => <InternetAddress>[InternetAddress('8.8.8.8')],
        connector: (address, port) async {
          final connect = _FakeConnect('connect');
          connect.provide(ledger.open('raw'));
          return connect.task;
        },
        upgrader: (socket, host) async => throw const HandshakeException(
          'CERTIFICATE_VERIFY_FAILED: self signed certificate',
        ),
      );

      check(await api.checkHealth()).isFalse();
    });
  });
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Upper bound for "this should already have happened" waits.
const Duration _settle = Duration(seconds: 5);

typedef _ChainResult = ({
  bool healthy,
  List<String> resolvedHosts,
  int socketsOpened,
  List<String> socketsLive,
});

/// Runs a chain of pinned hops where hop `healthyHop` answers 200 and every
/// earlier hop redirects to the next one.
Future<_ChainResult> _runPinnedChain({required int healthyHop}) async {
  final ledger = _SocketLedger();
  final source = await _startRedirectSource('http://hop-1.invalid/one');
  final resolvedHosts = <String>[];
  var hop = 0;
  final api = _api(
    source: source,
    resolver: (host) async {
      resolvedHosts.add(host);
      return <InternetAddress>[InternetAddress('8.8.8.8')];
    },
    connector: (address, port) async {
      hop++;
      final connect = _FakeConnect('connect-$hop');
      connect.provide(
        ledger.open(
          'hop-$hop',
          response: hop == healthyHop
              ? _httpResponse(200)
              : _httpResponse(
                  HttpStatus.found,
                  location: 'http://hop-${hop + 1}.invalid/next',
                ),
        ),
      );
      return connect.task;
    },
  );

  final healthy = await api.checkHealth().timeout(const Duration(seconds: 10));
  for (final socket in ledger.sockets) {
    await socket.whenDestroyed.timeout(_settle);
  }
  return (
    healthy: healthy,
    resolvedHosts: resolvedHosts,
    socketsOpened: ledger.opened,
    socketsLive: ledger.live,
  );
}

String _httpResponse(int status, {String? location}) {
  final buffer = StringBuffer('HTTP/1.1 $status Test\r\n');
  if (location != null) {
    buffer.write('location: $location\r\n');
  }
  buffer.write('content-length: 0\r\n\r\n');
  return buffer.toString();
}

/// A loopback server standing in for the configured Open WebUI origin. Its
/// only job is to answer `/health` with the off-origin redirect that arms the
/// pinned transport.
Future<HttpServer> _startRedirectSource(
  String location, {
  int status = HttpStatus.found,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response
      ..statusCode = status
      ..headers.set(HttpHeaders.locationHeader, location);
    await request.response.close();
  });
  addTearDown(() => server.close(force: true));
  return server;
}

ApiService _api({
  required HttpServer source,
  required PublicHealthAddressResolver resolver,
  required PublicHealthSocketConnector connector,
  PublicHealthSocketUpgrader? upgrader,
  Duration pinnedConnectTimeout = const Duration(seconds: 30),
  Duration requestTimeout = const Duration(seconds: 30),
}) {
  final workerManager = WorkerManager();
  final api = ApiService(
    serverConfig: ServerConfig(
      id: 'pinned-health',
      name: 'Pinned health',
      url: 'http://${source.address.address}:${source.port}',
    ),
    workerManager: workerManager,
    publicHealthAddressResolver: resolver,
    publicHealthSocketConnector: connector,
    publicHealthSocketUpgrader:
        upgrader ??
        (socket, host) =>
            Future<Socket>.error(StateError('unexpected TLS upgrade')),
    publicHealthPinnedConnectTimeout: pinnedConnectTimeout,
    publicHealthRequestTimeout: requestTimeout,
  );
  addTearDown(() {
    api.dispose();
    workerManager.dispose();
  });
  return api;
}

final class _SocketLedger {
  final List<_FakeSocket> sockets = <_FakeSocket>[];

  _FakeSocket open(String label, {String? response}) {
    final socket = _FakeSocket(label, response: response);
    sockets.add(socket);
    return socket;
  }

  int get opened => sockets.length;

  List<String> get live => <String>[
    for (final socket in sockets)
      if (socket.destroyCount == 0) socket.label,
  ];
}

/// A scripted [ConnectionTask] whose socket and cancellation are driven by the
/// test instead of by a real connect.
final class _FakeConnect {
  _FakeConnect(this.label, {this.failOnCancel = true}) {
    task = ConnectionTask.fromSocket<Socket>(_socket.future, _cancel);
    // Keep an error listener attached so a cancelled or refused attempt never
    // becomes an unhandled asynchronous error in the test isolate.
    unawaited(
      _socket.future.then((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  final String label;

  /// `dart:io` documents that cancelling a [ConnectionTask] completes its
  /// socket future with a [SocketException]. Setting this to false models the
  /// race where the connect completes anyway.
  final bool failOnCancel;

  final Completer<Socket> _socket = Completer<Socket>();
  final Completer<void> _cancelled = Completer<void>();
  late final ConnectionTask<Socket> task;
  int cancelCount = 0;

  Future<void> get whenCancelled => _cancelled.future;

  void provide(Socket socket) {
    if (!_socket.isCompleted) _socket.complete(socket);
  }

  void fail(Object error) {
    if (!_socket.isCompleted) _socket.completeError(error, StackTrace.current);
  }

  void _cancel() {
    cancelCount++;
    if (!_cancelled.isCompleted) _cancelled.complete();
    if (failOnCancel) {
      fail(const SocketException('fake connection attempt cancelled'));
    }
  }
}

/// A [Socket] that exists only in memory. It records everything written to it
/// and, once a full request head has been written, replays a canned HTTP
/// response so `dart:io`'s `HttpClient` can complete a real request over it.
final class _FakeSocket extends Stream<Uint8List> implements Socket {
  _FakeSocket(this.label, {this.response});

  final String label;
  final String? response;
  final StreamController<Uint8List> _inbound = StreamController<Uint8List>();
  final BytesBuilder _written = BytesBuilder();
  final Completer<Socket> _done = Completer<Socket>();
  final Completer<void> _destroyed = Completer<void>();
  bool _responded = false;
  int destroyCount = 0;

  String get request => utf8.decode(_written.toBytes(), allowMalformed: true);

  Future<void> get whenDestroyed => _destroyed.future;

  void _maybeRespond() {
    final body = response;
    if (_responded || body == null) return;
    if (!request.contains('\r\n\r\n')) return;
    _responded = true;
    if (_inbound.isClosed) return;
    _inbound.add(Uint8List.fromList(ascii.encode(body)));
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _inbound.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  void add(List<int> data) {
    _written.add(data);
    _maybeRespond();
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<dynamic> close() async {
    if (!_done.isCompleted) _done.complete(this);
    return this;
  }

  @override
  Future<dynamic> get done => _done.future;

  @override
  Encoding encoding = utf8;

  @override
  Future<void> flush() async => _maybeRespond();

  @override
  void write(Object? object) => add(utf8.encode('$object'));

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void writeln([Object? object = '']) => write('$object\n');

  @override
  void destroy() {
    destroyCount++;
    if (!_destroyed.isCompleted) _destroyed.complete();
    if (!_done.isCompleted) _done.complete(this);
    if (!_inbound.isClosed) unawaited(_inbound.close());
  }

  @override
  bool setOption(SocketOption option, bool enabled) => true;

  @override
  Uint8List getRawOption(RawSocketOption option) => Uint8List(0);

  @override
  void setRawOption(RawSocketOption option) {}

  @override
  InternetAddress get address => InternetAddress('8.8.8.8');

  @override
  InternetAddress get remoteAddress => InternetAddress('8.8.8.8');

  @override
  int get port => 54321;

  @override
  int get remotePort => 80;
}
