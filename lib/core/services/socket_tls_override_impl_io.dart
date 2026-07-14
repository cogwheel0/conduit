import 'dart:io' show HttpClient, WebSocket;
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:web_socket/io_web_socket.dart' show IOWebSocket;
import 'package:web_socket/web_socket.dart' as ws;

import '../models/server_config.dart';
import '../network/conduit_user_agent.dart';
import 'server_tls_http_client_factory.dart';

// Match dart:io WebSocket's shared-client lifecycle while replacing its
// generic runtime identity with the public product identity.
final _defaultWebSocketConnector = _ScopedWebSocketConnector(
  HttpClient()..userAgent = ConduitUserAgent.value,
);

io.Socket createSocketWithOptionalBadCertOverride(
  String base,
  io.OptionBuilder builder,
  ServerConfig serverConfig,
) {
  builder.setWebSocketConnector(_defaultWebSocketConnector.connect);
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

class _ScopedWebSocketConnector {
  _ScopedWebSocketConnector(this._httpClient);

  final HttpClient _httpClient;

  // socket_io_client's connector contract returns package:web_socket sockets.
  Future<ws.WebSocket> connect(
    Uri uri, {
    Iterable<String>? protocols,
    Map<String, String>? headers,
  }) async {
    Map<String, String>? forwardedHeaders;
    if (headers != null) {
      forwardedHeaders = Map<String, String>.from(headers)
        ..removeWhere((name, _) => ConduitUserAgent.isHeaderName(name));
    }
    final socket = await WebSocket.connect(
      uri.toString(),
      protocols: protocols,
      headers: forwardedHeaders,
      customClient: _httpClient,
    );
    return IOWebSocket.fromWebSocket(socket);
  }
}

class _CustomTlsWebSocketConnector extends _ScopedWebSocketConnector {
  _CustomTlsWebSocketConnector(ServerConfig serverConfig)
    : super(
        ServerTlsHttpClientFactory.createHttpClient(serverConfig)
          ..userAgent = ConduitUserAgent.value,
      );
}
