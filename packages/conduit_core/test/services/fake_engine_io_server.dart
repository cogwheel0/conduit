import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// How [FakeEngineIoServer] answers a WebSocket upgrade.
enum FakeWebSocketUpgrade {
  /// Refuses it, as a server that allows only polling should.
  refuse,

  /// Accepts it and hangs up before any packet, as python-engineio does when a
  /// polling address arrives with an `Upgrade` header (issue #848).
  acceptThenDrop,

  /// Accepts it and sends the Engine.IO handshake, but never answers the
  /// client's Socket.IO CONNECT.
  handshakeWithoutConnect,
}

/// One HTTP request the fake server received.
final class FakeEngineIoRequest {
  FakeEngineIoRequest(HttpRequest request)
    : method = request.method,
      uri = request.uri,
      upgrade = request.headers.value(HttpHeaders.upgradeHeader),
      cookie = request.headers.value(HttpHeaders.cookieHeader),
      authorization = request.headers.value(HttpHeaders.authorizationHeader),
      userAgent = request.headers.value(HttpHeaders.userAgentHeader);

  final String method;
  final Uri uri;
  final String? upgrade;
  final String? cookie;
  final String? authorization;
  final String? userAgent;

  String? get sid => uri.queryParameters['sid'];
  String? get transport => uri.queryParameters['transport'];
}

/// A local Engine.IO v4 server on `/ws/socket.io/` that, like Open WebUI with
/// `ENABLE_WEBSOCKET_SUPPORT=false`, serves HTTP long-polling only, with a
/// minimal Socket.IO layer on top for the default namespace.
final class FakeEngineIoServer {
  FakeEngineIoServer._(
    this._server, {
    required this.webSocketUpgrade,
    required this.allowPolling,
    required this.answerSocketIoConnect,
    required this.handshakeCookies,
    required this.pingIntervalMs,
  }) {
    _server.listen(_handle);
  }

  static Future<FakeEngineIoServer> start({
    FakeWebSocketUpgrade webSocketUpgrade = FakeWebSocketUpgrade.refuse,
    bool allowPolling = true,
    bool answerSocketIoConnect = true,
    List<Cookie> handshakeCookies = const [],
    int pingIntervalMs = 25000,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return FakeEngineIoServer._(
      server,
      webSocketUpgrade: webSocketUpgrade,
      allowPolling: allowPolling,
      answerSocketIoConnect: answerSocketIoConnect,
      handshakeCookies: handshakeCookies,
      pingIntervalMs: pingIntervalMs,
    );
  }

  static const String recordSeparator = '\x1e';

  final HttpServer _server;
  final FakeWebSocketUpgrade webSocketUpgrade;

  /// Whether polling is served at all; a server without it refuses the
  /// handshake.
  final bool allowPolling;
  final bool answerSocketIoConnect;
  final List<Cookie> handshakeCookies;
  final int pingIntervalMs;

  /// Every request, in the order it arrived.
  final List<FakeEngineIoRequest> requests = [];

  /// The body of every POST, as sent.
  final List<String> postBodies = [];

  /// Every packet the client posted, in order.
  final List<String> received = [];

  /// Status for the next session poll, instead of the session's packets.
  int? failNextPollWith;

  final List<String> _outgoing = [];
  final _receivedController = StreamController<String>.broadcast();
  Completer<void>? _outgoingReady;
  int _sessions = 0;
  String? _sid;
  bool _sessionClosed = false;
  final List<WebSocket> _webSockets = [];

  String get url => 'http://${_server.address.address}:${_server.port}';

  /// The Engine.IO session id of the current polling session.
  String? get sid => _sid;

  /// The Socket.IO session id this server hands the client on CONNECT.
  String get socketIoSid => 'socket-$_sessions';

  /// Requests sent with an `Upgrade` header.
  Iterable<FakeEngineIoRequest> get upgradeRequests =>
      requests.where((request) => request.upgrade != null);

  /// Queues [packet] for the client's next poll.
  void push(String packet) {
    _outgoing.add(packet);
    _wakePoll();
  }

  void _wakePoll() {
    final ready = _outgoingReady;
    _outgoingReady = null;
    ready?.complete();
  }

  /// Completes with the first posted packet, from now on, that [matches].
  Future<String> nextReceived(bool Function(String packet) matches) =>
      _receivedController.stream.firstWhere(matches);

  Future<void> close() async {
    _sessionClosed = true;
    _wakePoll();
    for (final socket in _webSockets) {
      unawaited(socket.close());
    }
    await _receivedController.close();
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    requests.add(FakeEngineIoRequest(request));
    if (!request.uri.path.startsWith('/ws/socket.io')) {
      return _reply(request, HttpStatus.notFound, 'not found');
    }
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      return _handleUpgrade(request);
    }
    final sid = request.uri.queryParameters['sid'];
    if (sid == null) {
      if (!allowPolling ||
          request.method != 'GET' ||
          request.uri.queryParameters['transport'] != 'polling') {
        return _reply(request, HttpStatus.badRequest, 'bad handshake');
      }
      _sessions += 1;
      _sid = 'eio-$_sessions';
      _sessionClosed = false;
      _outgoing.clear();
      request.response.cookies.addAll(handshakeCookies);
      return _reply(request, HttpStatus.ok, _openPacket(_sid!));
    }
    if (sid != _sid || _sessionClosed) {
      return _reply(request, HttpStatus.badRequest, 'Invalid session');
    }
    if (request.method == 'POST') {
      final body = await utf8.decoder.bind(request).join();
      postBodies.add(body);
      for (final packet in body.split(recordSeparator)) {
        _receive(packet);
      }
      return _reply(request, HttpStatus.ok, 'ok');
    }
    final failure = failNextPollWith;
    if (failure != null) {
      failNextPollWith = null;
      return _reply(request, failure, 'refused');
    }
    while (_outgoing.isEmpty && !_sessionClosed) {
      await (_outgoingReady ??= Completer<void>()).future;
    }
    if (_sessionClosed && _outgoing.isEmpty) {
      return _reply(request, HttpStatus.badRequest, 'Session is closed');
    }
    final payload = _outgoing.join(recordSeparator);
    _outgoing.clear();
    return _reply(request, HttpStatus.ok, payload);
  }

  void _receive(String packet) {
    received.add(packet);
    if (!_receivedController.isClosed) _receivedController.add(packet);
    if (packet == '1') {
      _sessionClosed = true;
      _wakePoll();
      return;
    }
    // A Socket.IO CONNECT to the default namespace, with or without auth.
    if (answerSocketIoConnect && (packet == '40' || packet.startsWith('40{'))) {
      push('40{"sid":"$socketIoSid"}');
    }
  }

  Future<void> _handleUpgrade(HttpRequest request) async {
    switch (webSocketUpgrade) {
      case FakeWebSocketUpgrade.refuse:
        return _reply(request, HttpStatus.badRequest, 'Transport not allowed');
      case FakeWebSocketUpgrade.acceptThenDrop:
        final socket = await WebSocketTransformer.upgrade(request);
        await socket.close();
      case FakeWebSocketUpgrade.handshakeWithoutConnect:
        final socket = await WebSocketTransformer.upgrade(request);
        _webSockets.add(socket);
        socket.add(_openPacket('eio-ws'));
        socket.listen((_) {}, onError: (_) {});
    }
  }

  String _openPacket(String sid) =>
      '0${jsonEncode({'sid': sid, 'upgrades': <String>[], 'pingInterval': pingIntervalMs, 'pingTimeout': 20000, 'maxPayload': 1000000})}';

  Future<void> _reply(HttpRequest request, int status, String body) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType('text', 'plain', charset: 'UTF-8')
      ..write(body);
    try {
      await request.response.close();
    } catch (_) {
      // The client aborted its request.
    }
  }
}
