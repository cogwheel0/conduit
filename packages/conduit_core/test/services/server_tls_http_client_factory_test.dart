import 'dart:io';
import 'dart:isolate';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/services/hermes_http_transport.dart';
import 'package:conduit_core/services/server_tls_http_client_factory.dart';
import 'package:conduit_core/services/user_trusted_certificates.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:test/test.dart';

void main() {
  group('ServerTlsHttpClientFactory', () {
    test('requires custom HttpClient for self-signed or mTLS servers', () {
      check(ServerTlsHttpClientFactory.requiresCustomHttpClient(_server()))
          .isFalse();
      check(
        ServerTlsHttpClientFactory.requiresCustomHttpClient(
          _server(allowSelfSignedCertificates: true),
        ),
      ).isTrue();
      check(
        ServerTlsHttpClientFactory.requiresCustomHttpClient(
          _server(
            mtlsCertificateChainPem: _invalidCertificatePem,
            mtlsPrivateKeyPem: _invalidPrivateKeyPem,
          ),
        ),
      ).isTrue();
    });

    test('does not require custom HttpClient for partial mTLS input', () {
      check(
        ServerTlsHttpClientFactory.requiresCustomHttpClient(
          _server(mtlsCertificateChainPem: _invalidCertificatePem),
        ),
      ).isFalse();
      check(
        ServerTlsHttpClientFactory.requiresCustomHttpClient(
          _server(mtlsPrivateKeyPem: _invalidPrivateKeyPem),
        ),
      ).isFalse();
    });

    test('creates HttpClient for self-signed certificate trust', () {
      final client = ServerTlsHttpClientFactory.createHttpClient(
        _server(allowSelfSignedCertificates: true),
      );

      addTearDown(() => client.close(force: true));
      check(client).isA<HttpClient>();
    });

    test('configures Dio with the server-scoped mTLS client factory', () {
      final dio = Dio();
      final config = _server(
        mtlsCertificateChainPem: _invalidCertificatePem,
        mtlsPrivateKeyPem: _invalidPrivateKeyPem,
      );

      ServerTlsHttpClientFactory.configureDio(dio, config);

      final adapter = dio.httpClientAdapter;
      check(adapter).isA<IOHttpClientAdapter>();
      final ioAdapter = adapter as IOHttpClientAdapter;
      check(ioAdapter.createHttpClient).isNotNull();
      check(() => ioAdapter.createHttpClient!()).throws<StateError>();
    });

    test('configures a standard Dio client with a stable User-Agent', () {
      final dio = Dio();

      ServerTlsHttpClientFactory.configureDio(
        dio,
        _server(),
        userAgent: 'Conduit/test',
      );

      final adapter = dio.httpClientAdapter as IOHttpClientAdapter;
      final client = adapter.createHttpClient!();
      addTearDown(() => client.close(force: true));
      check(client.userAgent).equals('Conduit/test');
    });
  });

  group('app-scoped Tailscale', () {
    tearDown(() => ServerTlsHttpClientFactory.tailnetConnect = null);

    test('older saved servers keep using their original network', () {
      final json = _server().toJson()..remove('useTailscale');
      final direct = ServerConfig.fromJson(json);
      check(direct.useTailscale).isFalse();
      check(ServerTlsHttpClientFactory.requiresCustomHttpClient(direct))
          .isFalse();
      final private = direct.copyWith(useTailscale: true);
      check(ServerConfig.fromJson(private.toJson()).useTailscale).isTrue();
    });

    test(
      'both backend clients route HTTP and WebSockets to the named peer',
      () async {
        final peer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => peer.close(force: true));
        final url = 'http://orchard.test:${peer.port}';
        peer.listen((request) async {
          if (WebSocketTransformer.isUpgradeRequest(request)) {
            final socket = await WebSocketTransformer.upgrade(request);
            socket.listen(socket.add);
          } else {
            request.response.write('orchard');
            await request.response.close();
          }
        });
        final routes = <Uri>[];
        ServerTlsHttpClientFactory.tailnetConnect = (uri, context, trust) {
          routes.add(uri);
          return Socket.startConnect(InternetAddress.loopbackIPv4, peer.port);
        };
        final webui = _server().copyWith(url: url, useTailscale: true);
        final hermes = HermesConfig(baseUrl: url, useTailscale: true);
        final clients = [Dio(), Dio()];
        ServerTlsHttpClientFactory.configureDio(clients.first, webui);
        configureHermesTransport(clients.last, hermes);
        for (final client in clients) {
          addTearDown(() => client.close(force: true));
          check((await client.get<String>(url)).data).equals('orchard');
        }
        for (final client in [
          ServerTlsHttpClientFactory.createHttpClient(webui),
          hermesTlsHttpClient(hermes)!,
        ]) {
          addTearDown(() => client.close(force: true));
          final socket = await WebSocket.connect(
            'ws://orchard.test:${peer.port}/events',
            customClient: client,
          );
          socket.add('blue kite');
          check(await socket.first).equals('blue kite');
          await socket.close();
        }
        check(routes.length).equals(4);
        check(routes.every((uri) => uri.host == 'orchard.test')).isTrue();
      },
    );

    test(
      'an unavailable route and off-origin redirect never use a direct socket',
      () async {
        final peer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => peer.close(force: true));
        var hits = 0;
        peer.listen((request) async {
          hits++;
          await request.response.redirect(
            Uri.parse('http://localhost:${peer.port}/next'),
          );
        });
        final direct = Uri.parse('http://127.0.0.1:${peer.port}');
        final config = _server().copyWith(
          url: direct.toString(),
          useTailscale: true,
        );
        final client = ServerTlsHttpClientFactory.createHttpClient(config);
        addTearDown(() => client.close(force: true));
        Future<void> get() async {
          final req = await client.getUrl(direct);
          await (await req.close()).drain<void>();
        }

        await check(get()).throws<SocketException>();
        check(hits).equals(0);
        ServerTlsHttpClientFactory.tailnetConnect = (uri, context, trust) =>
            Socket.startConnect(InternetAddress.loopbackIPv4, uri.port);
        await check(get()).throws<SocketException>();
        check(hits).equals(1);
      },
    );
  });

  group('a certificate authority the user installed', () {
    late Directory certificates;
    late HttpServer server;

    setUpAll(() async {
      // Fresh throwaway identities; no certificate or private key is
      // committed.
      certificates = await Directory.systemTemp.createTemp('user-ca-');
      final dir = certificates.path;
      // Apple's TLS policy refuses a server certificate without serverAuth.
      File('$dir/server.ext').writeAsStringSync(
        'subjectAltName=IP:127.0.0.1\nbasicConstraints=CA:FALSE\n'
        'extendedKeyUsage=serverAuth\n',
      );
      for (final command in [
        'req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt '
            '-subj /CN=synthetic-ca -days 1 '
            '-addext basicConstraints=critical,CA:TRUE '
            '-addext keyUsage=critical,keyCertSign,cRLSign',
        'req -newkey rsa:2048 -nodes -keyout server.key -out server.csr '
            '-subj /CN=127.0.0.1',
        'x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial '
            '-out server.crt -days 1 -extfile server.ext',
        'req -x509 -newkey rsa:2048 -nodes -keyout client.key '
            '-out client.crt -subj /CN=synthetic-client -days 1',
      ]) {
        final ProcessResult result;
        try {
          result = await Process.run(
            'openssl',
            command.split(' '),
            workingDirectory: dir,
          );
        } on ProcessException {
          fail('OpenSSL is required for the TLS trust tests.');
        }
        check(
          result.exitCode,
          because: 'OpenSSL must generate the test identities',
        ).equals(0);
      }

      server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        SecurityContext()
          ..useCertificateChain('$dir/server.crt')
          ..usePrivateKey('$dir/server.key'),
      );
      server.listen((request) => request.response.close(), onError: (_) {});
    });

    tearDownAll(() async {
      await server.close(force: true);
      await certificates.delete(recursive: true);
    });

    test('is trusted by plain and mTLS clients once the host installs it, '
        'skipping a certificate that does not parse', () async {
      final outcome = await _installUserCaInIsolate(
        certificates.path,
        server.port,
      );

      check(outcome.before).deepEquals([false, false]);
      check(outcome.installed).equals(1);
      check(outcome.after).deepEquals([true, true]);
    });
  });
}

/// Runs in its own isolate: the default security context belongs to the
/// isolate, so the CA trusted there goes away with it.
Future<({List<bool> before, int installed, List<bool> after})>
_installUserCaInIsolate(String dir, int port) => Isolate.run(() async {
  final url = Uri.parse('https://127.0.0.1:$port/');
  final mutualTls = ServerConfig(
    id: 'synthetic',
    name: 'Synthetic mTLS server',
    url: url.toString(),
    mtlsCertificateChainPem: File('$dir/client.crt').readAsStringSync(),
    mtlsPrivateKeyPem: File('$dir/client.key').readAsStringSync(),
  );
  Future<List<bool>> reachable() async => [
    for (final client in [
      HttpClient(),
      ServerTlsHttpClientFactory.createHttpClient(mutualTls),
    ])
      await _reaches(client, url),
  ];

  final before = await reachable();
  final installed = UserTrustedCertificates.install([
    'not a certificate',
    File('$dir/ca.crt').readAsStringSync(),
  ]);
  final after = await reachable();
  return (before: before, installed: installed, after: after);
});

Future<bool> _reaches(HttpClient client, Uri url) async {
  try {
    final response = await (await client.getUrl(url)).close();
    await response.drain<void>();
    return response.statusCode == HttpStatus.ok;
  } on HandshakeException {
    return false;
  } finally {
    client.close(force: true);
  }
}

ServerConfig _server({
  bool allowSelfSignedCertificates = false,
  String? mtlsCertificateChainPem,
  String? mtlsPrivateKeyPem,
}) {
  return ServerConfig(
    id: 'server',
    name: 'Server',
    url: 'https://example.test',
    allowSelfSignedCertificates: allowSelfSignedCertificates,
    mtlsCertificateChainPem: mtlsCertificateChainPem,
    mtlsPrivateKeyPem: mtlsPrivateKeyPem,
  );
}

const _invalidCertificatePem = '''
-----BEGIN CERTIFICATE-----
invalid
-----END CERTIFICATE-----
''';

const _invalidPrivateKeyPem = '''
-----BEGIN PRIVATE KEY-----
invalid
-----END PRIVATE KEY-----
''';
