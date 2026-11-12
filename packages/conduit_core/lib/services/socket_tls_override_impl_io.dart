import 'dart:io' show HttpClient, WebSocket;

import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:web_socket/io_web_socket.dart' show IOWebSocket;
import 'package:web_socket/web_socket.dart' as ws;

import 'package:conduit_core/models/server_config.dart';

import '../network/conduit_user_agent.dart';
import '../network/no_redirect_web_socket.dart';
import 'engine_io_polling_socket_io.dart';
import 'server_tls_http_client_factory.dart';

/// socket_io_client's WebSocket transport cannot pause for an upgrade, and on
/// native platforms that transport also carries polling (through
/// [EngineIoPollingSocket]), so a session that starts on polling stays there.
const bool socketPollingCanUpgrade = false;

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

  // Both transports go through this connector, so polling keeps the custom
  // TLS client as well.
  final connector = _CustomTlsWebSocketConnector(serverConfig);
  builder
    ..enableForceNew()
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
  _ScopedWebSocketConnector(this._httpClient)
    : _upgradeClient = noRedirectWebSocketClient(_httpClient);

  final HttpClient _httpClient;

  // The WebSocket handshake never follows a redirect, as browsers do not
  // either; dart:io would otherwise carry the custom headers to another
  // origin. Polling requests refuse redirects themselves.
  final HttpClient _upgradeClient;

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
    // socket_io_client opens its polling transport here too, as a WebSocket
    // to the polling address, which a polling-only server accepts and then
    // drops without a handshake. Poll over HTTP instead.
    if (uri.queryParameters['transport'] == 'polling') {
      return EngineIoPollingSocket.connect(
        uri,
        client: _httpClient,
        headers: forwardedHeaders,
      );
    }
    final socket = await WebSocket.connect(
      uri.toString(),
      protocols: protocols,
      headers: forwardedHeaders,
      customClient: _upgradeClient,
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
