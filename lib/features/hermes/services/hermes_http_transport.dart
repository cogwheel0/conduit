import 'dart:io';

import 'package:dio/dio.dart';

import '../../../core/models/server_config.dart';
import '../../../core/services/server_tls_http_client_factory.dart';
import '../models/hermes_config.dart';

/// Applies the Hermes server's custom headers and TLS trust to a Dio client.
///
/// Hermes reuses the same user-facing controls as Open WebUI and direct
/// connections: user-supplied request headers plus an opt-in trust for an
/// unverified certificate, scoped to the configured host.
void configureHermesTransport(Dio dio, HermesConfig config) {
  dio.options.headers.addAll(config.accessHeaders);
  ServerTlsHttpClientFactory.configureDio(dio, _serverConfig(config));
}

/// The same TLS trust for the Desktop Gateway's WebSocket, which cannot go
/// through Dio. Returns null when the default trust store is sufficient.
HttpClient? hermesTlsHttpClient(HermesConfig config) {
  final server = _serverConfig(config);
  if (!ServerTlsHttpClientFactory.requiresCustomHttpClient(server)) return null;
  return ServerTlsHttpClientFactory.createHttpClient(server);
}

ServerConfig _serverConfig(HermesConfig config) => ServerConfig(
  id: 'hermes',
  name: 'Hermes',
  url: config.baseUrl,
  allowSelfSignedCertificates: config.allowSelfSignedCertificates,
);
