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
    required this.pingTimeoutMs,
    required this.maxPayload,
    required this.stallHandshakeBody,
  }) {
    _server.listen(_handle);
  }

  static Future<FakeEngineIoServer> start({
    FakeWebSocketUpgrade webSocketUpgrade = FakeWebSocketUpgrade.refuse,
    bool allowPolling = true,
    bool answerSocketIoConnect = true,
    List<Cookie> handshakeCookies = const [],
    int pingIntervalMs = 25000,
    int pingTimeoutMs = 20000,
    int maxPayload = 1000000,
    bool stallHandshakeBody = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return FakeEngineIoServer._(
      server,
      webSocketUpgrade: webSocketUpgrade,
      allowPolling: allowPolling,
      answerSocketIoConnect: answerSocketIoConnect,
      handshakeCookies: handshakeCookies,
      pingIntervalMs: pingIntervalMs,
      pingTimeoutMs: pingTimeoutMs,
      maxPayload: maxPayload,
      stallHandshakeBody: stallHandshakeBody,
    );
  }

  /// The most packets python-engineio decodes from one POST
  /// (`Payload.max_decode_packets`); it drops a larger payload whole and still
  /// answers `OK`.
  static const int maxDecodePackets = 16;

  static const String recordSeparator = '\x1e';

  final HttpServer _server;
  final FakeWebSocketUpgrade webSocketUpgrade;

  /// Whether polling is served at all; a server without it refuses the
  /// handshake.
  final bool allowPolling;
  final bool answerSocketIoConnect;
  final List<Cookie> handshakeCookies;
  final int pingIntervalMs;
  final int pingTimeoutMs;

  /// The largest POST body in bytes; a larger one is refused with a 400 and
  /// ends the session, as python-engineio's `max_http_buffer_size` does.
  final int maxPayload;

  /// Whether the handshake sends its headers and part of its body, then
  /// nothing more.
  final bool stallHandshakeBody;

  /// Every request, in the order it arrived.
  final List<FakeEngineIoRequest> requests = [];

  /// The body of every POST, as sent.
  final List<String> postBodies = [];

  /// Every packet the client posted, in order.
  final List<String> received = [];

  /// Status for the next session poll, instead of the session's packets.
  int? failNextPollWith;

  /// Whether the next session poll is answered 200 with no packets.
  bool answerNextPollEmpty = false;

  /// What a POST is answered with, read when it arrives; python-engineio
  /// says `OK`.
  String postReplyBody = 'ok';

  /// When set, each POST is answered only once this completes.
  Completer<void>? holdPosts;

  /// When set, every request from now on is redirected there (a 302, or for
  /// a POST the 303 an HTTP client would follow), keeping its path and query.
  Uri? redirectTo;

  /// Completes once the client lets go of a stalled handshake's connection.
  Future<void> get stalledResponseReleased => _stalledReleased.future;
  final _stalledReleased = Completer<void>();
  final List<Socket> _detached = [];

  void _releaseStalled() {
    if (!_stalledReleased.isCompleted) _stalledReleased.complete();
  }

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
    for (final socket in _detached) {
      socket.destroy();
    }
    await _receivedController.close();
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    requests.add(FakeEngineIoRequest(request));
    if (!request.uri.path.startsWith('/ws/socket.io')) {
      return _reply(request, HttpStatus.notFound, 'not found');
    }
    final redirect = redirectTo;
    if (redirect != null) {
      request.response
        ..statusCode = request.method == 'POST'
            ? HttpStatus.seeOther
            : HttpStatus.found
        ..headers.set(
          HttpHeaders.locationHeader,
          redirect.replace(path: request.uri.path, query: request.uri.query),
        );
      await request.response.close();
      return;
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
      if (stallHandshakeBody) {
        final open = _openPacket(_sid!);
        request.response
          ..statusCode = HttpStatus.ok
          ..contentLength = open.length + 100;
        final socket = await request.response.detachSocket();
        _detached.add(socket);
        socket.write(open);
        socket.listen(
          (_) {},
          onDone: _releaseStalled,
          onError: (_) => _releaseStalled(),
        );
        return;
      }
      return _reply(request, HttpStatus.ok, _openPacket(_sid!));
    }
    if (sid != _sid || _sessionClosed) {
      return _reply(request, HttpStatus.badRequest, 'Invalid session');
    }
    if (request.method == 'POST') {
      final answer = postReplyBody;
      final bytes = await request.fold<List<int>>(
        [],
        (all, c) => all..addAll(c),
      );
      if (bytes.length > maxPayload) {
        _sessionClosed = true;
        _wakePoll();
        return _reply(request, HttpStatus.badRequest, 'Bad Request');
      }
      final body = utf8.decode(bytes);
      postBodies.add(body);
      final packets = body.split(recordSeparator);
      if (packets.length <= maxDecodePackets) {
        packets.forEach(_receive);
      }
      await holdPosts?.future;
      return _reply(request, HttpStatus.ok, answer);
    }
    final failure = failNextPollWith;
    if (failure != null) {
      failNextPollWith = null;
      return _reply(request, failure, 'refused');
    }
    if (answerNextPollEmpty) {
      answerNextPollEmpty = false;
      return _reply(request, HttpStatus.ok, '');
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
      '0${jsonEncode({'sid': sid, 'upgrades': <String>[], 'pingInterval': pingIntervalMs, 'pingTimeout': pingTimeoutMs, 'maxPayload': maxPayload})}';

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
