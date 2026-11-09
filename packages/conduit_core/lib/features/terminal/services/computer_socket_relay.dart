import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../models/computer_models.dart';

/// Keeps sign-in proxy cookies out of the platform WebView's cookie store.
/// Only this viewer's fixed stream endpoints are reachable through the relay.
final class ComputerSocketRelay {
  ComputerSocketRelay._(this._server, this._connection, this._secret);

  /// Loopback gives the bundled document a secure context for VNC crypto.
  /// Remote HTML never loads here.
  static const viewerOrigin = 'http://127.0.0.1';
  final HttpServer _server;
  final ComputerConnection _connection;
  final String _secret;
  final _sockets = <WebSocket>{};
  final _clients = <HttpClient>{};
  bool _closed = false;
  int _active = 0;

  /// Binds an ephemeral IPv4 loopback port with a per-viewer secret path.
  static Future<ComputerSocketRelay> start(
    ComputerConnection connection,
  ) async {
    if (!['ws', 'wss'].contains(connection.streamUri.scheme) ||
        !connection.streamUri.path.endsWith('/stream')) {
      throw const FormatException('Invalid Computer stream');
    }
    final random = Random.secure();
    final secret = base64Url.encode(
      List.generate(32, (_) => random.nextInt(256)),
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final relay = ComputerSocketRelay._(server, connection, secret);
    server.listen(relay._accept);
    return relay;
  }

  /// Local endpoint for the viewer; upstream credentials stay in Dart.
  Uri get streamUri => Uri(
    scheme: 'ws',
    host: '127.0.0.1',
    port: _server.port,
    path: '/$_secret/stream',
  );

  Future<void> _accept(HttpRequest request) async {
    final endpoint = request.uri.path.split('/').last;
    final allowed =
        endpoint == 'stream' ||
        (endpoint == 'vnc' && _connection.surface == ComputerSurface.browser) ||
        (endpoint == 'audio' &&
            _connection.surface == ComputerSurface.desktop &&
            _connection.audioAvailable);
    if (_closed ||
        _active >= 3 ||
        !allowed ||
        request.uri.path != '/$_secret/$endpoint' ||
        request.uri.hasQuery ||
        request.headers.value('origin') != viewerOrigin ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    _active++;
    WebSocket? local;
    WebSocket? remote;
    HttpClient? client;
    try {
      local = await WebSocketTransformer.upgrade(request);
      _sockets.add(local);
      client = (_connection.createHttpClient?.call() ?? HttpClient())
        ..connectionTimeout = const Duration(seconds: 15);
      _clients.add(client);
      final uri = _connection.streamUri.replace(
        path: _connection.streamUri.path.replaceFirst(
          RegExp(r'/stream$'),
          '/$endpoint',
        ),
      );
      final cookies = _connection.proxyCookies.entries
          .map((entry) {
            final cookie = Cookie(entry.key, entry.value);
            return '${cookie.name}=${cookie.value}';
          })
          .join('; ');
      remote = await WebSocket.connect(
        uri.toString(),
        customClient: client,
        headers: {
          ..._connection.proxyHeaders,
          if (cookies.isNotEmpty) HttpHeaders.cookieHeader: cookies,
        },
        compression: CompressionOptions.compressionOff,
      ).timeout(const Duration(seconds: 20));
      _sockets.add(remote);
      if (!_closed) {
        await Future.wait([_forward(local, remote), _forward(remote, local)]);
      }
    } catch (error) {
      // Never expose URLs, browser tickets, cookies or upstream error bodies.
      final denied =
          error is WebSocketException &&
          [
            HttpStatus.unauthorized,
            HttpStatus.forbidden,
          ].contains(error.httpStatusCode);
      unawaited(local?.close(denied ? 4003 : 1011));
    } finally {
      unawaited(local?.close());
      unawaited(remote?.close());
      _sockets.remove(local);
      _sockets.remove(remote);
      client?.close(force: true);
      _clients.remove(client);
      _active--;
    }
  }

  Future<void> _forward(WebSocket source, WebSocket target) async {
    try {
      await source.forEach(target.add);
    } catch (_) {
      // Closing either side tears down its peer, including held remote input.
    } finally {
      final code = source.closeCode;
      await target.close(
        code == 1008 || (code != null && code >= 4000) ? code : 1000,
      );
    }
  }

  /// Releases this viewer’s listener, sockets and pending native connections.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final socket in _sockets.toList()) {
      unawaited(socket.close());
    }
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    await _server.close(force: true);
  }
}
