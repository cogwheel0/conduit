import 'dart:io' show HttpClient, WebSocket;
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../models/server_config.dart';
import 'server_tls_http_client_factory.dart';

io.Socket createSocketWithOptionalBadCertOverride(
  String base,
  io.OptionBuilder builder,
  ServerConfig serverConfig,
) {
  if (!ServerTlsHttpClientFactory.requiresCustomHttpClient(serverConfig)) {
    return io.io(base, builder.build());
  }

  final target = _tryParseUri(base);
  if (target == null || !(target.scheme == 'https' || target.scheme == 'wss')) {
    return io.io(base, builder.build());
  }

  final adapter = _ServerTlsHttpClientAdapter(serverConfig);
  builder
    ..enableForceNew()
    ..setHttpClientAdapter(adapter)
    ..setTransportOptions({
      'polling': {'httpClientAdapter': adapter},
      'websocket': {'httpClientAdapter': adapter},
    });
  return io.io(base, builder.build());
}

Uri? _tryParseUri(String url) {
  try {
    final parsed = Uri.parse(url);
    if (parsed.hasScheme) return parsed;
  } catch (_) {}
  return null;
}

class _ServerTlsHttpClientAdapter implements io.HttpClientAdapter {
  _ServerTlsHttpClientAdapter(ServerConfig serverConfig)
    : _httpClient = ServerTlsHttpClientFactory.createHttpClient(serverConfig);

  final HttpClient _httpClient;

  @override
  Future<WebSocket> connect(String uri, {Map<String, dynamic>? headers}) {
    return WebSocket.connect(uri, headers: headers, customClient: _httpClient);
  }
}
