import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/terminal/models/computer_models.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/services/computer_service.dart';
import 'package:conduit_core/features/terminal/services/computer_socket_relay.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/server_tls_http_client_factory.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:test/test.dart';

void main() {
  late Directory certificates;
  late HttpServer backend;
  final relays = <ComputerSocketRelay>[];

  setUpAll(() async {
    // Fresh throwaway identities; no certificate or private key is committed.
    certificates = await Directory.systemTemp.createTemp('computer-tls-');
    addTearDown(() => certificates.delete(recursive: true));
    for (final name in ['server', 'client']) {
      late final ProcessResult result;
      try {
        result = await Process.run('openssl', [
          'req',
          '-x509',
          '-newkey',
          'rsa:2048',
          '-nodes',
          '-keyout',
          '${certificates.path}/$name.key',
          '-out',
          '${certificates.path}/$name.crt',
          '-subj',
          '/CN=synthetic-$name',
          '-days',
          '1',
        ]);
      } on ProcessException {
        fail(
          'OpenSSL is required for the Computer TLS tests. Install openssl and rerun this test.',
        );
      }
      expect(
        result.exitCode,
        0,
        reason: 'OpenSSL must generate the test identities',
      );
    }
  });

  Future<void> serve({bool mutualTls = false}) async {
    final context = SecurityContext()
      ..useCertificateChain('${certificates.path}/server.crt')
      ..usePrivateKey('${certificates.path}/server.key');
    if (mutualTls) {
      context.setTrustedCertificates('${certificates.path}/client.crt');
    }
    backend = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
      requestClientCertificate: mutualTls,
    );
    backend.listen((request) async {
      if (mutualTls && request.certificate == null) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      } else if (WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen(socket.add, onError: (_) {});
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"transport":"frames"}');
        await request.response.close();
      }
    }, onError: (_) {});
  }

  ServerConfig config({
    bool trust = true,
    bool identity = false,
    String host = '127.0.0.1',
  }) => ServerConfig(
    id: 'synthetic',
    name: 'Synthetic TLS server',
    url: 'https://$host:${backend.port}',
    allowSelfSignedCertificates: trust,
    mtlsCertificateChainPem: identity
        ? File('${certificates.path}/client.crt').readAsStringSync()
        : null,
    mtlsPrivateKeyPem: identity
        ? File('${certificates.path}/client.key').readAsStringSync()
        : null,
  );

  Future<WebSocket> connect(ComputerConnection connection) async {
    final relay = await ComputerSocketRelay.start(connection);
    relays.add(relay);
    return WebSocket.connect(
      relay.streamUri.toString(),
      headers: {'Origin': ComputerSocketRelay.viewerOrigin},
    );
  }

  tearDown(() async {
    for (final relay in relays) {
      await relay.close();
    }
    relays.clear();
    await backend.close(force: true);
  });

  for (final mutualTls in [false, true]) {
    test(
      'system Computer preserves REST TLS policy in its stream (mTLS: $mutualTls)',
      () async {
        await serve(mutualTls: mutualTls);
        final settings = config(identity: mutualTls);
        final api = ApiService(
          serverConfig: settings,
          authToken: 'synthetic-token',
          workerManager: WorkerManager(),
        );
        addTearDown(() => api.dio.close(force: true));
        final service = ComputerService(
          TerminalService(api),
          TerminalServerInfo(
            kind: TerminalServerKind.system,
            selectionId: 'terminal',
            systemServerId: 'terminal',
            baseUrl: Uri.parse(settings.url),
          ),
          'saved-chat',
        );
        final connection = (await service.open(ComputerSurface.desktop))!;
        expect(
          jsonEncode(connection.toViewerConfig()),
          isNot(contains('CERTIFICATE')),
        );
        expect(
          jsonEncode(connection.toViewerConfig()),
          isNot(contains('PRIVATE KEY')),
        );
        final socket = await connect(connection);
        socket.add('synthetic frame');
        expect(
          await socket.first.timeout(const Duration(seconds: 5)),
          'synthetic frame',
        );
        await socket.close();
      },
    );
  }

  test(
    'self-signed trust is opt-in and remains scoped to the configured host',
    () async {
      await serve();
      for (final settings in [
        config(trust: false),
        config(host: 'localhost'),
      ]) {
        final socket = await connect(
          ComputerConnection(
            surface: ComputerSurface.desktop,
            streamUri: Uri.parse(
              'wss://127.0.0.1:${backend.port}/desktop/stream',
            ),
            createHttpClient: () =>
                ServerTlsHttpClientFactory.createHttpClient(settings),
          ),
        );
        await socket.drain<void>().timeout(const Duration(seconds: 5));
        expect(socket.closeCode, 1011);
      }
    },
  );

  test(
    'a server requiring a client identity rejects a viewer without it',
    () async {
      await serve(mutualTls: true);
      final settings = config();
      final socket = await connect(
        ComputerConnection(
          surface: ComputerSurface.desktop,
          streamUri: Uri.parse(
            'wss://127.0.0.1:${backend.port}/desktop/stream',
          ),
          createHttpClient: () =>
              ServerTlsHttpClientFactory.createHttpClient(settings),
        ),
      );
      await socket.drain<void>().timeout(const Duration(seconds: 5));
      expect(socket.closeCode, 4003);
    },
  );
}
