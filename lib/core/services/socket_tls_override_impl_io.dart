import 'dart:io' show HttpClient, WebSocket;
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:web_socket/io_web_socket.dart' show IOWebSocket;
import 'package:web_socket/web_socket.dart' as ws;

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

  final connector = _CustomTlsWebSocketConnector(serverConfig);
  builder
    ..enableForceNew()
    ..setTransports(const ['websocket'])
    ..setWebSocketConnector(connector.connect);
  return io.io(base, builder.build());
}

Uri? _tryParseUri(String url) {
  try {
    final parsed = Uri.parse(url);
    if (parsed.hasScheme) return parsed;
  } catch (_) {}
  return null;
}

class _CustomTlsWebSocketConnector {
  _CustomTlsWebSocketConnector(ServerConfig serverConfig)
    : _httpClient = ServerTlsHttpClientFactory.createHttpClient(serverConfig);

  final HttpClient _httpClient;

  // socket_io_client's connector contract returns package:web_socket sockets.
  // Keep the custom dart:io HttpClient so self-signed TLS policy is preserved;
  // callers force WebSocket-only because HTTP polling cannot use this connector.
  Future<ws.WebSocket> connect(
    Uri uri, {
    Iterable<String>? protocols,
    Map<String, String>? headers,
  }) async {
    final socket = await WebSocket.connect(
      uri.toString(),
      protocols: protocols,
      headers: headers,
      customClient: _httpClient,
    );
    return IOWebSocket.fromWebSocket(socket);
  }
}
