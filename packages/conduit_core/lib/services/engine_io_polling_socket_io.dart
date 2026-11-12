import 'dart:async';
import 'dart:collection';
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
    required int maxPayload,
    required List<String> handshakePackets,
  }) : _client = client,
       _endpoint = endpoint,
       _headers = headers,
       _cookies = cookies,
       _sid = sid,
       _pollTimeout = pollTimeout,
       _maxPayload = maxPayload {
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

  /// The longest the HTTP client may take to open a connection, and less when
  /// one of the session's requests may take less (see [connect]). A request
  /// that gives up while its connection is still being opened cannot stop that
  /// attempt (dart:io gives no handle to it), so the client's own connection
  /// timeout must end it.
  static const Duration connectTimeout = Duration(seconds: 15);

  /// The most packets one POST carries. python-engineio refuses a payload of
  /// more (`Payload.max_decode_packets`) and still answers it with `OK`, so
  /// the packets of a larger one would be lost without a sign.
  static const int maxPacketsPerPost = 16;

  // The server answers a held GET at the latest with its next ping, every
  // `pingInterval`; give up on one that outlives a ping and its timeout.
  static const Duration _pollMargin = Duration(seconds: 10);
  static const int _defaultPingIntervalMs = 25000;
  static const int _defaultPingTimeoutMs = 20000;
  // Engine.IO's default `maxHttpBufferSize`, for a server that names none.
  static const int _defaultMaxPayload = 1000000;

  final HttpClient _client;
  final Uri _endpoint;
  final Map<String, String> _headers;
  final Map<String, String> _cookies;
  final String _sid;
  final Duration _pollTimeout;
  final int _maxPayload;
  late final StreamController<ws.WebSocketEvent> _events;

  final ListQueue<String> _outbox = ListQueue<String>();
  bool _flushScheduled = false;
  Future<void>? _flushing;
  bool _closed = false;
  bool _failed = false;
  _Exchange? _pollExchange;
  int _requestCount = 0;

  /// The Engine.IO session id the server assigned in the handshake.
  String get sid => _sid;

  /// Opens a polling session at [url], the `ws`/`wss` address socket_io_client
  /// asks for, by performing the Engine.IO handshake over HTTP.
  ///
  /// Lowers [client]'s `connectionTimeout` to the shortest time any of the
  /// session's requests may take, [connectTimeout] at most, when it has a
  /// longer one or none: [timeout] for the handshake, then the session's poll
  /// and send times, which the server's ping values decide.
  ///
  /// Throws [ws.WebSocketException] when the server does not answer with an
  /// Engine.IO open packet, and passes on network and timeout errors.
  static Future<EngineIoPollingSocket> connect(
    Uri url, {
    required HttpClient client,
    Map<String, String>? headers,
    Duration timeout = handshakeTimeout,
  }) async {
    _limitConnectionTimeout(client, [connectTimeout, timeout]);
    final endpoint = url.replace(
      scheme: switch (url.scheme) {
        'wss' => 'https',
        'ws' => 'http',
        final other => other,
      },
    );
    final requestHeaders = Map<String, String>.of(headers ?? const {});
    final cookies = <String, String>{};
    final reply = await _Exchange.start(
      client,
      'GET',
      _stamped(endpoint, 0),
      headers: _withCookies(requestHeaders, cookies),
      timeout: timeout,
    ).result;
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
    final pingInterval = _positive(
      handshake['pingInterval'],
      _defaultPingIntervalMs,
    );
    final pingTimeout = _positive(
      handshake['pingTimeout'],
      _defaultPingTimeoutMs,
    );
    final pollTimeout =
        Duration(milliseconds: pingInterval + pingTimeout) + _pollMargin;
    _limitConnectionTimeout(client, [pollTimeout, sendTimeout]);
    return EngineIoPollingSocket._(
      client: client,
      endpoint: endpoint,
      headers: requestHeaders,
      cookies: cookies,
      sid: sid,
      pollTimeout: pollTimeout,
      maxPayload: _positive(handshake['maxPayload'], _defaultMaxPayload),
      handshakePackets: packets,
    );
  }

  // A request cannot stop its connection attempt, so the client's own limit
  // must be no longer than any request's. The client may be shared, so it is
  // only ever lowered.
  static void _limitConnectionTimeout(
    HttpClient client,
    List<Duration> limits,
  ) {
    final shortest = limits.reduce((a, b) => a < b ? a : b);
    final current = client.connectionTimeout;
    if (current == null || current > shortest) {
      client.connectionTimeout = shortest;
    }
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
  /// Completes once those packets were sent, or could not be.
  ///
  /// Unlike a WebSocket's, closing an already-closed session does nothing:
  /// socket_io_client closes its transport without awaiting the result, so
  /// an error here would go unhandled.
  @override
  Future<void> close([int? code, String? reason]) async {
    if (_closed) return;
    _closed = true;
    _pollExchange?.cancel();
    unawaited(_events.close());
    _outbox.add('1');
    while (!_failed && (_outbox.isNotEmpty || _flushing != null)) {
      await _flush();
    }
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
  /// server expects. Returns the flush already running, if any. Never throws:
  /// a failed POST ends the session.
  Future<void> _flush() => _flushing ??= _drainOutbox().whenComplete(() {
    _flushing = null;
    // Packets queued as the last POST finished have no flush of their own.
    if (_outbox.isNotEmpty && !_failed) unawaited(_flush());
  });

  Future<void> _drainOutbox() async {
    try {
      while (_outbox.isNotEmpty && !_failed) {
        final reply = await _Exchange.start(
          _client,
          'POST',
          _sessionUri(),
          headers: _withCookies(_headers, _cookies),
          body: _takeBatch().join(_recordSeparator),
          timeout: sendTimeout,
        ).result;
        _keepCookies(reply, _cookies);
        // A 200 from anything but the Engine.IO server, such as a proxy's
        // page, did not deliver the packets. python-engineio answers `OK`,
        // other servers `ok`.
        if (reply.status != HttpStatus.ok ||
            reply.body.trim().toLowerCase() != 'ok') {
          _fail('Engine.IO polling send answered HTTP ${reply.status}');
        }
      }
    } catch (error) {
      _fail('Engine.IO polling send failed: ${error.runtimeType}');
    }
  }

  /// Takes the next packets for one POST, in order: at most
  /// [maxPacketsPerPost], and no more bytes than the server's `maxPayload`.
  /// A single packet over that limit still goes, alone, for the server to
  /// refuse, as it would refuse that message on a WebSocket.
  List<String> _takeBatch() {
    final batch = <String>[];
    var bytes = 0;
    while (_outbox.isNotEmpty && batch.length < maxPacketsPerPost) {
      final size =
          utf8.encode(_outbox.first).length + (batch.isEmpty ? 0 : 1);
      if (batch.isNotEmpty && bytes + size > _maxPayload) break;
      batch.add(_outbox.removeFirst());
      bytes += size;
    }
    return batch;
  }

  void _startPolling() {
    unawaited(_poll());
  }

  Future<void> _poll() async {
    while (!_closed) {
      final exchange = _pollExchange = _Exchange.start(
        _client,
        'GET',
        _sessionUri(),
        headers: _withCookies(_headers, _cookies),
        timeout: _pollTimeout,
      );
      final _Reply reply;
      try {
        reply = await exchange.result;
      } catch (error) {
        // [close] cancels the held poll; that is no failure of the session,
        // whose last packets may still be on their way.
        if (!_closed) _fail('Engine.IO polling failed: ${error.runtimeType}');
        return;
      } finally {
        if (identical(_pollExchange, exchange)) _pollExchange = null;
      }
      if (_closed) return;
      _keepCookies(reply, _cookies);
      if (reply.status != HttpStatus.ok) {
        _fail('Engine.IO polling answered HTTP ${reply.status}');
        return;
      }
      final packets = _split(reply.body);
      // A server holds a poll until it has a packet, at the latest its next
      // ping; python-engineio answers one with nothing only for a session it
      // has closed. Polling again at once would spin on whatever answers so.
      if (packets.isEmpty) {
        _fail('Engine.IO polling answered with no packets');
        return;
      }
      for (final packet in packets) {
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
    _pollExchange?.cancel();
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

  static int _positive(Object? value, int fallback) =>
      value is num && value > 0 ? value.toInt() : fallback;

  // Polling sends a session over many requests, which a load balancer keeps
  // on one server by cookie, as a browser would. A cookie the server set
  // during this session replaces a configured one of the same name; other
  // configured cookies are kept as they are.
  static Map<String, String> _withCookies(
    Map<String, String> headers,
    Map<String, String> cookies,
  ) {
    if (cookies.isEmpty) return headers;
    final merged = Map<String, String>.of(headers);
    final configured = merged.keys.where((k) => k.toLowerCase() == 'cookie');
    final key = configured.isEmpty ? 'cookie' : configured.first;
    merged[key] = [
      for (final part in (merged[key] ?? '').split(';'))
        if (part.trim().isNotEmpty &&
            !cookies.containsKey(part.split('=').first.trim()))
          part.trim(),
      for (final cookie in cookies.entries) '${cookie.key}=${cookie.value}',
    ].join('; ');
    return merged;
  }

  static void _keepCookies(_Reply reply, Map<String, String> cookies) {
    for (final cookie in reply.cookies) {
      cookies[cookie.name] = cookie.value;
    }
  }
}

/// One HTTP request whose wait can be ended at any point, before its response
/// and while the body is still arriving. Aborting a request alone does not
/// release a response whose headers have come and whose body stalls.
final class _Exchange {
  _Exchange._(Duration timeout) {
    _timer = Timer(
      timeout,
      () => cancel(
        TimeoutException('Engine.IO polling request timed out', timeout),
      ),
    );
  }

  static _Exchange start(
    HttpClient client,
    String method,
    Uri uri, {
    required Map<String, String> headers,
    String? body,
    required Duration timeout,
  }) {
    final exchange = _Exchange._(timeout);
    unawaited(exchange._run(client, method, uri, headers, body));
    return exchange;
  }

  final Completer<_Reply> _result = Completer<_Reply>();
  late final Timer _timer;
  HttpClientRequest? _request;
  StreamSubscription<List<int>>? _body;
  bool _cancelled = false;

  Future<_Reply> get result => _result.future;

  Future<void> _run(
    HttpClient client,
    String method,
    Uri uri,
    Map<String, String> headers,
    String? body,
  ) async {
    try {
      final request = await client.openUrl(method, uri);
      if (_cancelled) {
        request.abort();
        return;
      }
      _request = request;
      // A redirect would carry the server's custom headers (an API key, a
      // proxy's access token) to wherever it points, which dart:io allows
      // across origins. It is answered as the failure it is instead, and the
      // socket reconnects later as for any other.
      request
        ..followRedirects = false
        ..maxRedirects = 0;
      headers.forEach(request.headers.set);
      if (body != null) {
        final bytes = utf8.encode(body);
        request.headers.contentType = ContentType(
          'text',
          'plain',
          charset: 'UTF-8',
        );
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close();
      final received = BytesBuilder(copy: false);
      _body = response.listen(
        received.add,
        onError: (Object error, StackTrace stackTrace) =>
            _settle(error: error, stackTrace: stackTrace),
        onDone: () => _settle(
          reply: _Reply(
            response.statusCode,
            utf8.decode(received.takeBytes(), allowMalformed: true),
            _cookiesOf(response),
          ),
        ),
        cancelOnError: true,
      );
      if (_cancelled) unawaited(_body!.cancel());
    } catch (error, stackTrace) {
      _settle(error: error, stackTrace: stackTrace);
    }
  }

  /// Ends the request and releases its connection; [result] fails with
  /// [reason] unless it has already completed.
  void cancel([Object? reason]) {
    if (_cancelled) return;
    _cancelled = true;
    _request?.abort();
    final body = _body;
    if (body != null) unawaited(body.cancel());
    _settle(
      error: reason ?? StateError('Engine.IO polling request cancelled'),
      stackTrace: StackTrace.current,
    );
  }

  void _settle({_Reply? reply, Object? error, StackTrace? stackTrace}) {
    _timer.cancel();
    if (_result.isCompleted) return;
    if (error != null) {
      _result.completeError(error, stackTrace);
    } else {
      _result.complete(reply);
    }
  }

  static List<Cookie> _cookiesOf(HttpClientResponse response) {
    try {
      return response.cookies;
    } catch (_) {
      return const <Cookie>[];
    }
  }
}

final class _Reply {
  const _Reply(this.status, this.body, this.cookies);

  final int status;
  final String body;
  final List<Cookie> cookies;
}
