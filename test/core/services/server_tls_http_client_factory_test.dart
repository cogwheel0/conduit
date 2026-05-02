import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/services/server_tls_http_client_factory.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ServerTlsHttpClientFactory', () {
    test('requires custom HttpClient for self-signed or mTLS servers', () {
      check(
        ServerTlsHttpClientFactory.requiresCustomHttpClient(_server()),
      ).isFalse();
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
  });
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
