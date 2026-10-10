import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Opens a WebSocket to [uri] that never follows a redirect, so the upgrade
/// request and its credentials only ever reach the host that was asked.
///
/// [httpClient] carries the connection's trust policy and client
/// certificate. The socket answers pings every [pingInterval] once open.
WebSocketChannel connectNoRedirectWebSocket(
  Uri uri,
  Map<String, String> headers, {
  HttpClient? httpClient,
  Duration connectTimeout = const Duration(seconds: 15),
  Duration pingInterval = const Duration(seconds: 20),
}) {
  final client = _NoRedirectHttpClient(httpClient ?? HttpClient());
  final socket = WebSocket.connect(
    uri.toString(),
    headers: headers,
    customClient: client,
  ).whenComplete(client.close);
  return IOWebSocketChannel(
    socket
        .timeout(connectTimeout)
        .then((value) => value..pingInterval = pingInterval),
  );
}

final class _NoRedirectHttpClient implements HttpClient {
  _NoRedirectHttpClient(this._delegate);

  final HttpClient _delegate;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final request = await _delegate.openUrl(method, url);
    request.followRedirects = false;
    return request;
  }

  @override
  void close({bool force = false}) => _delegate.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
