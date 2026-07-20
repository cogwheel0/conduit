import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/network/conduit_user_agent.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/connectivity_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

const _headerSecret = 'proxy-custom-header-secret';
const _redirectSecret = 'proxy-reflected-location-secret';
const _healthProxySecret = 'health-proxy-header-secret';
const _healthCookieSecret = 'health-proxy-cookie-secret';

void main() {
  tearDown(ConnectivityService.debugResetTrafficSignals);

  test(
    'health check preserves the Conduit User-Agent across redirects',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final receivedUserAgents = <String?>[];
      server.listen((request) async {
        receivedUserAgents.add(
          request.headers.value(HttpHeaders.userAgentHeader),
        );
        if (request.uri.path == '/health') {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set(HttpHeaders.locationHeader, '/ready');
          await request.response.close();
          return;
        }
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write('{"status":true}');
        await request.response.close();
      });

      final workerManager = WorkerManager();
      final api = ApiService(
        serverConfig: ServerConfig(
          id: 'health-user-agent',
          name: 'Health User-Agent',
          url: 'http://${server.address.address}:${server.port}',
        ),
        workerManager: workerManager,
      );

      try {
        check(await api.checkHealth()).isTrue();
        check(
          receivedUserAgents,
        ).deepEquals([ConduitUserAgent.value, ConduitUserAgent.value]);
      } finally {
        api.dispose();
        workerManager.dispose();
        await server.close(force: true);
      }
    },
  );

  test('health check does not wait for or buffer a response body', () async {
    final releaseBody = Completer<void>();
    final bodyStarted = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write('{"status":');
      await request.response.flush();
      if (!bodyStarted.isCompleted) bodyStarted.complete();
      await releaseBody.future;
      try {
        request.response.write('true}');
        await request.response.close();
      } catch (_) {
        // The streamed health probe intentionally cancels the unused body.
      }
    });

    final workerManager = WorkerManager();
    final api = ApiService(
      serverConfig: ServerConfig(
        id: 'streamed-health-body',
        name: 'Streamed health body',
        url: 'http://${server.address.address}:${server.port}',
      ),
      workerManager: workerManager,
    );

    try {
      final health = api.checkHealth();
      await bodyStarted.future.timeout(const Duration(seconds: 2));
      check(await health.timeout(const Duration(seconds: 1))).isTrue();
    } finally {
      if (!releaseBody.isCompleted) releaseBody.complete();
      api.dispose();
      workerManager.dispose();
      await server.close(force: true);
    }
  });

  test('one deadline bounds the complete public redirect chain', () async {
    final stalledLookupStarted = Completer<void>();
    final stalledLookup = Completer<List<InternetAddress>>();
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((request) async {
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(
          HttpHeaders.locationHeader,
          'http://second-health.invalid:${target.port}/two',
        );
      await request.response.close();
    });
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    source.listen((request) async {
      // Spend a meaningful share of the deadline on the initial request. The
      // redirect DNS lookup must receive only the remaining budget instead of
      // starting a fresh timeout for the second hop.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(
          HttpHeaders.locationHeader,
          'http://first-health.invalid:${target.port}/one',
        );
      await request.response.close();
    });

    var resolverCalls = 0;
    final workerManager = WorkerManager();
    final api = ApiService(
      serverConfig: ServerConfig(
        id: 'bounded-health-chain',
        name: 'Bounded health chain',
        url: 'http://${source.address.address}:${source.port}',
      ),
      workerManager: workerManager,
      publicHealthRequestTimeout: const Duration(milliseconds: 500),
      publicHealthAddressResolver: (host) {
        resolverCalls++;
        if (host == 'first-health.invalid') {
          return Future.value(<InternetAddress>[InternetAddress('8.8.8.8')]);
        }
        if (!stalledLookupStarted.isCompleted) {
          stalledLookupStarted.complete();
        }
        return stalledLookup.future;
      },
      publicHealthSocketConnector: (_, port) {
        return Socket.startConnect(InternetAddress.loopbackIPv4, port);
      },
    );

    final elapsed = Stopwatch()..start();
    try {
      final result = await api.checkHealth().timeout(
        const Duration(seconds: 2),
      );
      elapsed.stop();
      check(result).isFalse();
      await stalledLookupStarted.future.timeout(const Duration(seconds: 1));
      check(resolverCalls).equals(2);
      // A fresh 500 ms budget for the stalled second-hop lookup would take at
      // least ~800 ms after the deliberate 300 ms first hop. Keep enough host
      // scheduling slack for the correct single-deadline path (~500 ms) while
      // still distinguishing a per-hop timeout reset.
      check(elapsed.elapsed).isLessThan(const Duration(milliseconds: 700));
    } finally {
      api.dispose();
      workerManager.dispose();
      await source.close(force: true);
      await target.close(force: true);
    }
  });

  test(
    'health redirect pins its validated address without a second DNS lookup',
    () async {
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final targetHeaders =
          Completer<
            ({String? host, String? userAgent, String? proxyCredential})
          >();
      target.listen((request) async {
        if (!targetHeaders.isCompleted) {
          targetHeaders.complete((
            host: request.headers.value(HttpHeaders.hostHeader),
            userAgent: request.headers.value(HttpHeaders.userAgentHeader),
            proxyCredential: request.headers.value('x-proxy-credential'),
          ));
        }
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write('{"status":true}');
        await request.response.close();
      });

      final redirect = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sourceProxyCredential = Completer<String?>();
      redirect.listen((request) async {
        if (!sourceProxyCredential.isCompleted) {
          sourceProxyCredential.complete(
            request.headers.value('x-proxy-credential'),
          );
        }
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(
            HttpHeaders.locationHeader,
            'http://health-target.invalid:${target.port}/ready',
          );
        await request.response.close();
      });

      var resolverCalls = 0;
      final connectedAddresses = <String>[];
      final workerManager = WorkerManager();
      final api = ApiService(
        serverConfig: ServerConfig(
          id: 'cross-origin-user-agent',
          name: 'Cross-origin User-Agent',
          url: 'http://${redirect.address.address}:${redirect.port}',
          customHeaders: const {'x-proxy-credential': _healthProxySecret},
        ),
        workerManager: workerManager,
        // The production resolver must return only public addresses. This
        // deterministic seam lets the test exercise the accepted branch while
        // the local HTTP fixture remains reachable on loopback.
        publicHealthAddressResolver: (_) async {
          resolverCalls++;
          // A second policy lookup would simulate a DNS rebind to loopback.
          return <InternetAddress>[
            resolverCalls == 1
                ? InternetAddress('8.8.8.8')
                : InternetAddress.loopbackIPv4,
          ];
        },
        publicHealthSocketConnector: (address, port) {
          connectedAddresses.add(address.address);
          // Preserve a globally-routable policy result while routing this
          // deterministic fixture to its local test server.
          return Socket.startConnect(InternetAddress.loopbackIPv4, port);
        },
      );

      try {
        check(await api.checkHealth()).isTrue();
        check(await sourceProxyCredential.future).equals(_healthProxySecret);
        final received = await targetHeaders.future.timeout(
          const Duration(seconds: 5),
        );
        check(resolverCalls).equals(1);
        check(connectedAddresses).deepEquals(['8.8.8.8']);
        check(received.host).equals('health-target.invalid:${target.port}');
        check(received.userAgent).equals(ConduitUserAgent.value);
        check(received.proxyCredential).isNull();
      } finally {
        api.dispose();
        workerManager.dispose();
        await redirect.close(force: true);
        await target.close(force: true);
      }
    },
  );

  test(
    'health redirect falls back across the prevalidated address set',
    () async {
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
            'http://health-target.invalid:${target.port}/ready',
          );
        await request.response.close();
      });

      final attemptedAddresses = <String>[];
      final workerManager = WorkerManager();
      final api = ApiService(
        serverConfig: ServerConfig(
          id: 'health-address-fallback',
          name: 'Health address fallback',
          url: 'http://${redirect.address.address}:${redirect.port}',
        ),
        workerManager: workerManager,
        publicHealthAddressResolver: (_) async => <InternetAddress>[
          InternetAddress('8.8.8.8'),
          InternetAddress('1.1.1.1'),
        ],
        publicHealthSocketConnector: (address, port) {
          attemptedAddresses.add(address.address);
          if (address.address == '8.8.8.8') {
            return Future<ConnectionTask<Socket>>.error(
              const SocketException('injected first-address failure'),
            );
          }
          return Socket.startConnect(InternetAddress.loopbackIPv4, port);
        },
      );

      try {
        check(await api.checkHealth()).isTrue();
        check(attemptedAddresses).deepEquals(['8.8.8.8', '1.1.1.1']);
      } finally {
        api.dispose();
        workerManager.dispose();
        await redirect.close(force: true);
        await target.close(force: true);
      }
    },
  );

  test(
    'timed-out HTTPS upgrade destroys a socket that completes late',
    () async {
      final rawServer = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final rawPeer = Completer<Socket>();
      rawServer.listen((socket) {
        if (!rawPeer.isCompleted) rawPeer.complete(socket);
      });
      final lateServer = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final latePeer = Completer<Socket>();
      final latePeerClosed = Completer<void>();
      lateServer.listen((socket) {
        if (!latePeer.isCompleted) latePeer.complete(socket);
        socket.listen(
          (_) {},
          onDone: () {
            if (!latePeerClosed.isCompleted) latePeerClosed.complete();
          },
        );
      });
      final lateClient = await Socket.connect(
        InternetAddress.loopbackIPv4,
        lateServer.port,
      );
      await latePeer.future;

      final redirect = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      redirect.listen((request) async {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(
            HttpHeaders.locationHeader,
            'https://health-target.invalid:${rawServer.port}/ready',
          );
        await request.response.close();
      });
      final upgradeStarted = Completer<String>();
      final upgradeResult = Completer<Socket>();
      final workerManager = WorkerManager();
      final api = ApiService(
        serverConfig: ServerConfig(
          id: 'late-health-tls',
          name: 'Late health TLS',
          url: 'http://${redirect.address.address}:${redirect.port}',
        ),
        workerManager: workerManager,
        publicHealthAddressResolver: (_) async => <InternetAddress>[
          InternetAddress('8.8.8.8'),
        ],
        publicHealthSocketConnector: (_, _) {
          return Socket.startConnect(
            InternetAddress.loopbackIPv4,
            rawServer.port,
          );
        },
        publicHealthSocketUpgrader: (socket, host) {
          if (!upgradeStarted.isCompleted) upgradeStarted.complete(host);
          return upgradeResult.future;
        },
        publicHealthPinnedConnectTimeout: const Duration(milliseconds: 80),
      );

      try {
        final health = api.checkHealth();
        check(
          await upgradeStarted.future.timeout(const Duration(seconds: 2)),
        ).equals('health-target.invalid');
        await rawPeer.future.timeout(const Duration(seconds: 2));
        check(await health.timeout(const Duration(seconds: 2))).isFalse();

        upgradeResult.complete(lateClient);
        await latePeerClosed.future.timeout(const Duration(seconds: 2));
      } finally {
        if (!upgradeResult.isCompleted) upgradeResult.complete(lateClient);
        api.dispose();
        workerManager.dispose();
        if (rawPeer.isCompleted) {
          (await rawPeer.future).destroy();
        }
        (await latePeer.future).destroy();
        await redirect.close(force: true);
        await rawServer.close();
        await lateServer.close();
      }
    },
  );

  test('health check rejects an off-origin loopback redirect', () async {
    var targetRequests = 0;
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((request) async {
      targetRequests++;
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
    });
    final redirect = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    redirect.listen((request) async {
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(
          HttpHeaders.locationHeader,
          'http://${target.address.address}:${target.port}/ready',
        );
      await request.response.close();
    });
    final workerManager = WorkerManager();
    final api = ApiService(
      serverConfig: ServerConfig(
        id: 'private-health-redirect',
        name: 'Private health redirect',
        url: 'http://${redirect.address.address}:${redirect.port}',
      ),
      workerManager: workerManager,
    );

    try {
      check(await api.checkHealth()).isFalse();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      check(targetRequests).equals(0);
    } finally {
      api.dispose();
      workerManager.dispose();
      await redirect.close(force: true);
      await target.close(force: true);
    }
  });

  test(
    'health check rejects hostnames resolving to private addresses',
    () async {
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
      final workerManager = WorkerManager();
      final api = ApiService(
        serverConfig: ServerConfig(
          id: 'private-dns-health-redirect',
          name: 'Private DNS health redirect',
          url: 'http://${redirect.address.address}:${redirect.port}',
        ),
        workerManager: workerManager,
        publicHealthAddressResolver: (host) async {
          resolvedHosts.add(host);
          return <InternetAddress>[InternetAddress.loopbackIPv4];
        },
      );

      try {
        check(await api.checkHealth()).isFalse();
        check(resolvedHosts).deepEquals(['health-target.invalid']);
      } finally {
        api.dispose();
        workerManager.dispose();
        await redirect.close(force: true);
      }
    },
  );

  test('public health redirect address classifier fails closed', () {
    for (final address in <String>[
      '0.0.0.0',
      '10.0.0.1',
      '100.64.0.1',
      '127.0.0.1',
      '169.254.1.1',
      '172.16.0.1',
      '192.168.0.1',
      '192.0.2.1',
      '198.18.0.1',
      '198.51.100.1',
      '203.0.113.1',
      '240.0.0.1',
      '255.255.255.255',
      '224.0.0.1',
      '::',
      '::1',
      '::ffff:127.0.0.1',
      '::ffff:10.0.0.1',
      '::ffff:100.64.0.1',
      '::ffff:169.254.1.1',
      '::ffff:172.16.0.1',
      '::ffff:192.168.0.1',
      '::ffff:198.18.0.1',
      '::ffff:224.0.0.1',
      'fc00::1',
      'fe80::1',
      'ff02::1',
      '2001:db8::1',
    ]) {
      check(
        isPublicHealthRedirectAddress(InternetAddress(address)),
        because: address,
      ).isFalse();
    }
    for (final address in <String>[
      '1.1.1.1',
      '8.8.8.8',
      '2606:4700:4700::1',
      '2606:4700:4700::808:808',
    ]) {
      check(
        isPublicHealthRedirectAddress(InternetAddress(address)),
        because: address,
      ).isTrue();
    }
  });

  test('off-origin health resolves Pref64 before opening a socket', () async {
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
    var socketAttempts = 0;
    final workerManager = WorkerManager();
    final api = ApiService(
      serverConfig: ServerConfig(
        id: 'nat64-private-health-redirect',
        name: 'NAT64 private health redirect',
        url: 'http://${redirect.address.address}:${redirect.port}',
      ),
      workerManager: workerManager,
      publicHealthAddressResolver: (host) async {
        resolvedHosts.add(host);
        return <InternetAddress>[
          if (host == 'ipv4only.arpa')
            _synthesizedNat64Address(
              prefixLength: 96,
              ipv4: const <int>[192, 0, 0, 170],
            )
          else
            _synthesizedNat64Address(
              prefixLength: 96,
              ipv4: const <int>[127, 0, 0, 1],
            ),
        ];
      },
      publicHealthSocketConnector: (_, _) {
        socketAttempts++;
        throw StateError('unsafe socket should not be opened');
      },
    );

    try {
      check(await api.checkHealth()).isFalse();
      check(
        resolvedHosts,
      ).deepEquals(['health-target.invalid', 'ipv4only.arpa']);
      check(socketAttempts).equals(0);
    } finally {
      api.dispose();
      workerManager.dispose();
      await redirect.close(force: true);
    }
  });

  test('discovered RFC 6052 prefixes cannot disguise private IPv4', () {
    for (final prefixLength in <int>[32, 40, 48, 56, 64, 96]) {
      final discovery = _synthesizedNat64Address(
        prefixLength: prefixLength,
        ipv4: const <int>[192, 0, 0, 170],
      );
      final privateTarget = _synthesizedNat64Address(
        prefixLength: prefixLength,
        ipv4: const <int>[127, 0, 0, 1],
      );
      final publicTarget = _synthesizedNat64Address(
        prefixLength: prefixLength,
        ipv4: const <int>[1, 1, 1, 1],
      );

      check(
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
          privateTarget,
          <InternetAddress>[discovery],
        ),
        because: 'private RFC 6052 /$prefixLength target',
      ).isFalse();
      check(
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
          publicTarget,
          <InternetAddress>[discovery],
        ),
        because: 'public RFC 6052 /$prefixLength target',
      ).isTrue();
    }
  });

  test('RFC 7050 absence preserves ordinary global IPv6', () {
    check(
      isPublicHealthRedirectAddressWithNat64DiscoveryForTest(
        InternetAddress('2606:4700:4700::1'),
        <InternetAddress>[
          InternetAddress('192.0.0.170'),
          InternetAddress('192.0.0.171'),
        ],
      ),
    ).isTrue();
  });

  test('proxy health-check diagnostics never log redirect credentials', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestSeen = Completer<void>();
    server.listen((request) async {
      check(request.uri.path).equals('/health');
      check(request.headers.value('x-proxy-credential')).equals(_headerSecret);
      check(
        request.headers.value(HttpHeaders.authorizationHeader),
      ).equals('Bearer health-session-token');
      check(request.headers.value(HttpHeaders.cookieHeader)).isNull();
      check(
        request.headers.value(HttpHeaders.userAgentHeader),
      ).equals(ConduitUserAgent.value);
      if (!requestSeen.isCompleted) requestSeen.complete();
      request.response
        ..statusCode = HttpStatus.temporaryRedirect
        ..headers.set(
          HttpHeaders.locationHeader,
          'https://example.test/login?credential=$_redirectSecret&reflected=$_headerSecret',
        );
      await request.response.close();
    });

    final workerManager = WorkerManager();
    final api = ApiService(
      serverConfig: ServerConfig(
        id: 'proxy-diagnostics',
        name: 'Proxy diagnostics',
        url: 'http://${server.address.address}:${server.port}',
        customHeaders: const {
          'x-proxy-credential': _headerSecret,
          'Cookie': _healthCookieSecret,
          'uSeR-aGeNt': 'spoofed-agent',
        },
      ),
      workerManager: workerManager,
      authToken: 'health-session-token',
      suppressCookieCustomHeader: true,
    );

    final previousDebugPrint = debugPrint;
    final output = StringBuffer();
    debugPrint = (message, {wrapWidth}) {
      if (message != null) output.writeln(message);
    };

    try {
      final result = await api.checkHealthWithProxyDetection();
      check(result).equals(HealthCheckResult.proxyAuthRequired);
      await requestSeen.future;
    } finally {
      debugPrint = previousDebugPrint;
      api.dispose();
      workerManager.dispose();
      await server.close(force: true);
    }

    final logs = output.toString();
    check(logs).contains('proxy-auth-redirect-detected');
    check(logs).contains('statusCode=307');
    check(logs).not((value) => value.contains(_headerSecret));
    check(logs).not((value) => value.contains(_healthCookieSecret));
    check(logs).not((value) => value.contains(_redirectSecret));
  });

  for (final statusCode in <int>[
    HttpStatus.movedPermanently,
    HttpStatus.seeOther,
  ]) {
    test('proxy detection recognizes HTTP $statusCode redirects', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response
          ..statusCode = statusCode
          ..headers.set(HttpHeaders.locationHeader, '/proxy/login');
        await request.response.close();
      });
      final workerManager = WorkerManager();
      final api = ApiService(
        serverConfig: ServerConfig(
          id: 'proxy-redirect-$statusCode',
          name: 'Proxy redirect $statusCode',
          url: 'http://${server.address.address}:${server.port}',
        ),
        workerManager: workerManager,
      );

      try {
        check(
          await api.checkHealthWithProxyDetection(),
        ).equals(HealthCheckResult.proxyAuthRequired);
      } finally {
        api.dispose();
        workerManager.dispose();
        await server.close(force: true);
      }
    });
  }

  test('proxy detection does not wait for an HTML response body', () async {
    final releaseBody = Completer<void>();
    final bodyStarted = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write('<!doctype html>');
      await request.response.flush();
      if (!bodyStarted.isCompleted) bodyStarted.complete();
      await releaseBody.future;
      try {
        request.response.write('<body>proxy login</body>');
        await request.response.close();
      } catch (_) {
        // The probe has already classified and cancelled the streamed body.
      }
    });
    final workerManager = WorkerManager();
    final api = ApiService(
      serverConfig: ServerConfig(
        id: 'streamed-proxy-body',
        name: 'Streamed proxy body',
        url: 'http://${server.address.address}:${server.port}',
      ),
      workerManager: workerManager,
    );

    try {
      final health = api.checkHealthWithProxyDetection();
      await bodyStarted.future.timeout(const Duration(seconds: 2));
      check(
        await health.timeout(const Duration(seconds: 1)),
      ).equals(HealthCheckResult.proxyAuthRequired);
    } finally {
      if (!releaseBody.isCompleted) releaseBody.complete();
      api.dispose();
      workerManager.dispose();
      await server.close(force: true);
    }
  });

  test(
    'connection-page health checks can retain the transport exception',
    () async {
      final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final rejectedConnections = reserved.listen((socket) => socket.destroy());
      final unavailableUrl =
          'http://${reserved.address.address}:${reserved.port}';
      final workerManager = WorkerManager();
      final api = ApiService(
        serverConfig: ServerConfig(
          id: 'unavailable-transport',
          name: 'Unavailable transport',
          url: unavailableUrl,
        ),
        workerManager: workerManager,
      );
      addTearDown(() async {
        api.dispose();
        workerManager.dispose();
        await rejectedConnections.cancel();
        await reserved.close();
      });

      Object? caught;
      try {
        await api.checkHealthWithProxyDetection(throwOnConnectionError: true);
      } catch (error) {
        caught = error;
      }

      check(caught).isA<DioException>();
    },
  );

  test(
    'absolute off-origin requests cannot mutate server health signals',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final originAuthorization = Completer<String?>();
      origin.listen((request) async {
        if (!originAuthorization.isCompleted) {
          originAuthorization.complete(
            request.headers.value(HttpHeaders.authorizationHeader),
          );
        }
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('image', 'png')
          ..add([1, 2, 3]);
        await request.response.close();
      });
      final external = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final externalAuthorization = Completer<String?>();
      external.listen((request) async {
        if (!externalAuthorization.isCompleted) {
          externalAuthorization.complete(
            request.headers.value(HttpHeaders.authorizationHeader),
          );
        }
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('image', 'png')
          ..add([4, 5, 6]);
        await request.response.close();
      });
      final originUri = Uri.parse(
        'http://${origin.address.address}:${origin.port}',
      );
      final externalUri = Uri.parse(
        'http://${external.address.address}:${external.port}/avatar.png',
      );
      final workerManager = WorkerManager();
      final api = ApiService(
        serverConfig: ServerConfig(
          id: 'connectivity-origin',
          name: 'Connectivity origin',
          url: originUri.toString(),
        ),
        workerManager: workerManager,
        authToken: 'connectivity-test-token',
      );
      try {
        ConnectivityService.debugResetTrafficSignals();
        try {
          check(
            await api.fetchImageBytes(externalUri.toString()),
          ).deepEquals([4, 5, 6]);
        } catch (error) {
          throw StateError('external request failed: $error');
        }
        check(await externalAuthorization.future).isNull();
        check(
          ConnectivityService.debugHasRecentSuccessfulTraffic(originUri),
        ).isFalse();
        check(
          ConnectivityService.debugHasRecentSuccessfulTraffic(externalUri),
        ).isFalse();

        check(
          requestUsesServerConnectivityOrigin(externalUri, originUri),
        ).isFalse();

        try {
          await api.fetchImageBytes(originUri.resolve('/same.png').toString());
        } catch (error) {
          throw StateError('same-origin request failed: $error');
        }
        check(
          await originAuthorization.future,
        ).equals('Bearer connectivity-test-token');
        check(
          ConnectivityService.debugHasRecentSuccessfulTraffic(originUri),
        ).isTrue();
      } finally {
        api.dispose();
        workerManager.dispose();
        await external.close(force: true);
        await origin.close(force: true);
      }
    },
  );
}

InternetAddress _synthesizedNat64Address({
  required int prefixLength,
  required List<int> ipv4,
}) {
  final raw = <int>[
    0x26,
    0x06,
    0x47,
    0x00,
    0x12,
    0x34,
    0x56,
    0x78,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
  ];
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
      raw.setRange(12, 16, ipv4);
    default:
      throw ArgumentError.value(prefixLength, 'prefixLength');
  }
  return InternetAddress.fromRawAddress(Uint8List.fromList(raw));
}
