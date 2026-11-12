import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:web_socket/web_socket.dart' as ws;

/// Engine.IO v4 HTTP long-polling, presented to socket_io_client as a
/// `package:web_socket` [ws.WebSocket] that carries one Engine.IO packet per
/// message.
///
/// socket_io_client 3.1 has no polling transport on native platforms: asked
/// for `polling`, it opens a WebSocket to the polling address instead. A server
/// that allows only polling (Open WebUI with `ENABLE_WEBSOCKET_SUPPORT=false`)
/// accepts that upgrade, sends no handshake and drops it, so the client never
/// connects and every reply shows up only once it has finished. The library
/// opens each transport through its WebSocket connector, so for a
/// `transport=polling` address the connector returns this instead: a GET the
/// server holds until it has packets, and a POST for each batch the client
/// writes, both plain HTTP requests through the same client and headers.
///
/// The library's WebSocket transport cannot pause for an upgrade, so a session
/// that starts here stays on polling; callers must not ask it to upgrade.
final class EngineIoPollingSocket implements ws.WebSocket {
  EngineIoPollingSocket._({
    required HttpClient client,
    required Uri endpoint,
    required Map<String, String> headers,
    required Map<String, String> cookies,
    required String sid,
    required Duration pollTimeout,
    required List<String> handshakePackets,
  }) : _client = client,
       _endpoint = endpoint,
       _headers = headers,
       _cookies = cookies,
       _sid = sid,
       _pollTimeout = pollTimeout {
    _events = StreamController<ws.WebSocketEvent>(onListen: _startPolling);
    for (final packet in handshakePackets) {
      if (!_deliver(packet)) break;
    }
  }

  /// Separates packets in an Engine.IO v4 polling payload.
  static const String _recordSeparator = '\x1e';

  /// How long the handshake may take, matching Conduit's Socket.IO timeout.
  static const Duration handshakeTimeout = Duration(seconds: 20);

  /// How long one POST of client packets may take.
  static const Duration sendTimeout = Duration(seconds: 30);

  // The server answers a held GET at the latest with its next ping, every
  // `pingInterval`; give up on one that outlives a ping and its timeout.
  static const Duration _pollMargin = Duration(seconds: 10);
  static const int _defaultPingIntervalMs = 25000;
  static const int _defaultPingTimeoutMs = 20000;

  final HttpClient _client;
  final Uri _endpoint;
  final Map<String, String> _headers;
  final Map<String, String> _cookies;
  final String _sid;
  final Duration _pollTimeout;
  late final StreamController<ws.WebSocketEvent> _events;

  final List<String> _outbox = <String>[];
  bool _flushScheduled = false;
  bool _posting = false;
  bool _closed = false;
  bool _failed = false;
  HttpClientRequest? _pollRequest;
  int _requestCount = 0;

  /// The Engine.IO session id the server assigned in the handshake.
  String get sid => _sid;

  /// Opens a polling session at [url], the `ws`/`wss` address socket_io_client
  /// asks for, by performing the Engine.IO handshake over HTTP.
  ///
  /// Throws [ws.WebSocketException] when the server does not answer with an
  /// Engine.IO open packet, and passes on network and timeout errors.
  static Future<EngineIoPollingSocket> connect(
    Uri url, {
    required HttpClient client,
    Map<String, String>? headers,
    Duration timeout = handshakeTimeout,
  }) async {
    final endpoint = url.replace(
      scheme: switch (url.scheme) {
        'wss' => 'https',
        'ws' => 'http',
        final other => other,
      },
    );
    final requestHeaders = Map<String, String>.of(headers ?? const {});
    final cookies = <String, String>{};
    final reply = await _exchange(
      client,
      'GET',
      _stamped(endpoint, 0),
      headers: _withCookies(requestHeaders, cookies),
      timeout: timeout,
    );
    _keepCookies(reply, cookies);
    if (reply.status != HttpStatus.ok) {
      throw ws.WebSocketException(
        'Engine.IO polling handshake answered HTTP ${reply.status}',
      );
    }
    final packets = _split(reply.body);
    final open = packets.isEmpty ? '' : packets.first;
    Object? handshake;
    if (open.startsWith('0')) {
      try {
        handshake = jsonDecode(open.substring(1));
      } on FormatException {
        handshake = null;
      }
    }
    final sid = handshake is Map ? handshake['sid'] : null;
    if (handshake is! Map || sid is! String || sid.isEmpty) {
      throw ws.WebSocketException(
        'Engine.IO polling handshake had no open packet',
      );
    }
    final pingInterval = _millis(
      handshake['pingInterval'],
      _defaultPingIntervalMs,
    );
    final pingTimeout = _millis(
      handshake['pingTimeout'],
      _defaultPingTimeoutMs,
    );
    return EngineIoPollingSocket._(
      client: client,
      endpoint: endpoint,
      headers: requestHeaders,
      cookies: cookies,
      sid: sid,
      pollTimeout:
          Duration(milliseconds: pingInterval + pingTimeout) + _pollMargin,
      handshakePackets: packets,
    );
  }

  @override
  Stream<ws.WebSocketEvent> get events => _events.stream;

  @override
  String get protocol => '';

  @override
  void sendText(String s) {
    if (_closed) throw ws.WebSocketConnectionClosed();
    _queue(s);
  }

  @override
  void sendBytes(Uint8List b) {
    if (_closed) throw ws.WebSocketConnectionClosed();
    _queue('b${base64Encode(b)}');
  }

  /// Ends the session: stops polling, closes [events], and tells the server,
  /// after anything still being sent, so it need not wait out a ping timeout.
  ///
  /// Unlike a WebSocket's, closing an already-closed session does nothing:
  /// socket_io_client closes its transport without awaiting the result, so
  /// an error here would go unhandled.
  @override
  Future<void> close([int? code, String? reason]) async {
    if (_closed) return;
    _closed = true;
    _pollRequest?.abort();
    unawaited(_events.close());
    _outbox.add('1');
    await _flush();
  }

  void _queue(String packet) {
    _outbox.add(packet);
    if (_flushScheduled) return;
    // Packets written together (an event and its pong, say) go in one POST.
    _flushScheduled = true;
    scheduleMicrotask(() {
      _flushScheduled = false;
      unawaited(_flush());
    });
  }

  /// Posts the queued packets, one request at a time and in order, as the
  /// server expects. Never throws: a failed POST ends the session.
  Future<void> _flush() async {
    if (_posting) return;
    _posting = true;
    try {
      while (_outbox.isNotEmpty && !_failed) {
        final payload = _outbox.join(_recordSeparator);
        _outbox.clear();
        final reply = await _exchange(
          _client,
          'POST',
          _sessionUri(),
          headers: _withCookies(_headers, _cookies),
          body: payload,
          timeout: sendTimeout,
        );
        _keepCookies(reply, _cookies);
        if (reply.status != HttpStatus.ok) {
          _fail('Engine.IO polling send answered HTTP ${reply.status}');
        }
      }
    } catch (error) {
      _fail('Engine.IO polling send failed: ${error.runtimeType}');
    } finally {
      _posting = false;
    }
  }

  void _startPolling() {
    unawaited(_poll());
  }

  Future<void> _poll() async {
    while (!_closed) {
      final _Reply reply;
      try {
        reply = await _exchange(
          _client,
          'GET',
          _sessionUri(),
          headers: _withCookies(_headers, _cookies),
          timeout: _pollTimeout,
          opened: (request) => _pollRequest = request,
        );
      } catch (error) {
        // [close] aborts the held poll; that is no failure of the session,
        // whose last packets may still be on their way.
        if (!_closed) _fail('Engine.IO polling failed: ${error.runtimeType}');
        return;
      } finally {
        _pollRequest = null;
      }
      if (_closed) return;
      _keepCookies(reply, _cookies);
      if (reply.status != HttpStatus.ok) {
        _fail('Engine.IO polling answered HTTP ${reply.status}');
        return;
      }
      for (final packet in _split(reply.body)) {
        if (!_deliver(packet)) return;
      }
    }
  }

  /// Hands one received packet to the library, or ends the session on the
  /// server's close packet. Returns whether the session is still open.
  bool _deliver(String packet) {
    if (_closed) return false;
    if (packet == '1') {
      _end(1000, 'The server closed the Engine.IO session');
      return false;
    }
    if (packet.startsWith('b')) {
      final Uint8List data;
      try {
        data = base64Decode(packet.substring(1));
      } on FormatException {
        _fail('Engine.IO polling received a malformed binary packet');
        return false;
      }
      _events.add(ws.BinaryDataReceived(data));
      return true;
    }
    _events.add(ws.TextDataReceived(packet));
    return true;
  }

  void _fail(String reason) {
    _failed = true;
    _outbox.clear();
    // An abnormal closure, as a WebSocket reports a dropped connection.
    _end(1006, reason);
  }

  /// Ends the session from the server's side: [events] reports why and closes.
  void _end(int code, String reason) {
    if (_closed) return;
    _closed = true;
    _failed = true;
    _outbox.clear();
    _pollRequest?.abort();
    _events.add(ws.CloseReceived(code, reason));
    unawaited(_events.close());
  }

  Uri _sessionUri() => _stamped(
    _endpoint.replace(
      queryParameters: {..._endpoint.queryParameters, 'sid': _sid},
    ),
    ++_requestCount,
  );

  // A unique `t` keeps a caching proxy from answering a poll with an old one,
  // as Engine.IO's own polling clients do.
  static Uri _stamped(Uri uri, int count) => uri.replace(
    queryParameters: {
      ...uri.queryParameters,
      't':
          '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
          '.${count.toRadixString(36)}',
    },
  );

  static List<String> _split(String payload) => [
    for (final packet in payload.split(_recordSeparator))
      if (packet.isNotEmpty) packet,
  ];

  static int _millis(Object? value, int fallback) =>
      value is num && value > 0 ? value.toInt() : fallback;

  // Polling sends a session over many requests, which a load balancer keeps
  // on one server by cookie, as a browser would. Only cookies the server set
  // during this session are added; the configured headers are kept as they are.
  static Map<String, String> _withCookies(
    Map<String, String> headers,
    Map<String, String> cookies,
  ) {
    if (cookies.isEmpty) return headers;
    final jar = cookies.entries.map((c) => '${c.key}=${c.value}').join('; ');
    final merged = Map<String, String>.of(headers);
    final configured = merged.keys.where((k) => k.toLowerCase() == 'cookie');
    final key = configured.isEmpty ? 'cookie' : configured.first;
    final existing = merged[key];
    merged[key] = existing == null || existing.isEmpty
        ? jar
        : '$existing; $jar';
    return merged;
  }

  static void _keepCookies(_Reply reply, Map<String, String> cookies) {
    for (final cookie in reply.cookies) {
      cookies[cookie.name] = cookie.value;
    }
  }

  static Future<_Reply> _exchange(
    HttpClient client,
    String method,
    Uri uri, {
    required Map<String, String> headers,
    String? body,
    required Duration timeout,
    void Function(HttpClientRequest request)? opened,
  }) async {
    HttpClientRequest? request;
    Future<_Reply> run() async {
      final open = request = await client.openUrl(method, uri);
      opened?.call(open);
      headers.forEach(open.headers.set);
      if (body != null) {
        final bytes = utf8.encode(body);
        open.headers.contentType = ContentType(
          'text',
          'plain',
          charset: 'UTF-8',
        );
        open.contentLength = bytes.length;
        open.add(bytes);
      }
      final response = await open.close();
      final text = await response.transform(utf8.decoder).join();
      List<Cookie> cookies;
      try {
        cookies = response.cookies;
      } catch (_) {
        cookies = const <Cookie>[];
      }
      return _Reply(response.statusCode, text, cookies);
    }

    try {
      return await run().timeout(timeout);
    } on TimeoutException {
      request?.abort();
      rethrow;
    }
  }
}

final class _Reply {
  const _Reply(this.status, this.body, this.cookies);

  final int status;
  final String body;
  final List<Cookie> cookies;
}
