import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../core/utils/debug_logger.dart';
import 'hermes_json_guard.dart';

const int kMaxHermesDesktopFrameBytes = 4 * 1024 * 1024;
const int kMaxHermesDesktopFrameCharacters = 2 * 1024 * 1024;

typedef HermesDesktopChannelFactory = WebSocketChannel Function(
  Uri uri,
  Map<String, String> headers,
);

final class HermesDesktopRpcException implements Exception {
  const HermesDesktopRpcException(
    this.message, {
    this.code,
    this.timedOut = false,
    this.disconnected = false,
  });

  final String message;
  final int? code;
  final bool timedOut;
  final bool disconnected;
  bool get deliveryAmbiguous => timedOut || disconnected;

  @override
  String toString() => message;
}

final class HermesDesktopEvent {
  const HermesDesktopEvent({
    required this.type,
    required this.payload,
    this.sessionId,
  });

  final String type;
  final Map<String, dynamic> payload;
  final String? sessionId;
}

final class HermesDesktopEventBuffer {
  HermesDesktopEventBuffer({
    this.maximumPerSession = 4096,
    this.maximumSessions = 64,
    this.maximumTotalEvents = 4096,
  }) : assert(maximumPerSession > 0),
       assert(maximumSessions > 0),
       assert(maximumTotalEvents > 0);

  final int maximumPerSession;
  final int maximumSessions;
  final int maximumTotalEvents;
  final LinkedHashMap<String, Queue<HermesDesktopEvent>> _pending =
      LinkedHashMap();
  final Set<String> _active = {};
  int _totalEvents = 0;

  bool add(HermesDesktopEvent event) {
    final sessionId = event.sessionId;
    if (sessionId == null || sessionId.isEmpty || _active.contains(sessionId)) {
      return false;
    }
    if (!_pending.containsKey(sessionId) &&
        _pending.length >= maximumSessions) {
      _removeQueue(_pending.keys.first);
    }
    final queue = _pending.putIfAbsent(sessionId, Queue.new);
    final wasEmpty = queue.isEmpty;
    queue.addLast(event);
    _totalEvents++;
    while (queue.length > maximumPerSession) {
      queue.removeFirst();
      _totalEvents--;
    }
    while (_totalEvents > maximumTotalEvents && _pending.isNotEmpty) {
      final oldest = _pending.entries.first;
      oldest.value.removeFirst();
      _totalEvents--;
      if (oldest.value.isEmpty) _pending.remove(oldest.key);
    }
    return wasEmpty;
  }

  List<HermesDesktopEvent> activate(String sessionId) {
    _active.add(sessionId);
    return _removeQueue(sessionId)?.toList(growable: false) ?? const [];
  }

  void deactivate(String sessionId) => _active.remove(sessionId);

  bool hasPending(String sessionId) => _pending[sessionId]?.isNotEmpty == true;

  List<HermesDesktopEvent> pending(String sessionId) =>
      _pending[sessionId]?.toList(growable: false) ?? const [];

  List<HermesDesktopEvent> take(String sessionId) =>
      _removeQueue(sessionId)?.toList(growable: false) ?? const [];

  void discard(String sessionId) => _removeQueue(sessionId);

  Queue<HermesDesktopEvent>? _removeQueue(String sessionId) {
    final removed = _pending.remove(sessionId);
    _totalEvents -= removed?.length ?? 0;
    return removed;
  }

  void clear() {
    _pending.clear();
    _active.clear();
    _totalEvents = 0;
  }
}

/// Bounded JSON-RPC client for Hermes Desktop's `/api/ws` gateway.
final class HermesDesktopRpcClient {
  HermesDesktopRpcClient({
    HermesDesktopChannelFactory? channelFactory,
    this.requestTimeout = const Duration(seconds: 60),
  }) : _channelFactory = channelFactory ?? _connectChannel;

  final HermesDesktopChannelFactory _channelFactory;
  final Duration requestTimeout;
  final _events = StreamController<HermesDesktopEvent>.broadcast();
  final _disconnects = StreamController<void>.broadcast();
  final Map<String, _PendingRpc> _pending = {};
  Map<String, dynamic> _defaultParams = const {};

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  int _socketGeneration = 0;
  int _requestId = 0;
  bool _ready = false;

  Stream<HermesDesktopEvent> get events => _events.stream;
  Stream<void> get disconnects => _disconnects.stream;
  bool get isReady => _ready;
  int get socketGeneration => _socketGeneration;

  /// Connection-wide params merged into every request as a *fallback*.
  /// Callers that pass the same key win (Bot Mode scopes single calls to
  /// another profile without rebuilding the connection).
  void setDefaultParams(Map<String, dynamic> value) {
    _defaultParams = Map.unmodifiable(value);
  }

  static WebSocketChannel _connectChannel(
    Uri uri,
    Map<String, String> headers,
  ) {
    final client = _NoRedirectHttpClient(HttpClient());
    final socket = WebSocket.connect(
      uri.toString(),
      headers: headers,
      customClient: client,
    ).whenComplete(client.close);
    return IOWebSocketChannel(
      socket
          .timeout(const Duration(seconds: 15))
          .then((value) => value..pingInterval = const Duration(seconds: 20)),
    );
  }

  Future<void> connect(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    await disconnect();
    final generation = ++_socketGeneration;
    final channel = _channelFactory(uri, headers);
    _channel = channel;
    _ready = false;
    final ready = Completer<void>();

    _subscription = channel.stream.listen(
      (raw) => _handleFrame(raw, channel, generation, ready),
      onError: (Object error, StackTrace stackTrace) {
        if (!_owns(channel, generation)) return;
        if (!ready.isCompleted) ready.completeError(error, stackTrace);
        _handleDisconnect(channel, generation);
      },
      onDone: () {
        if (!_owns(channel, generation)) return;
        if (!ready.isCompleted) {
          ready.completeError(
            const HermesDesktopRpcException(
              'Hermes closed the gateway before it became ready.',
            ),
          );
        }
        _handleDisconnect(channel, generation);
      },
      cancelOnError: false,
    );

    try {
      await Future.wait<void>([channel.ready, ready.future])
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      if (_owns(channel, generation)) await disconnect();
      rethrow;
    }
  }

  Future<T> request<T>(
    String method, {
    Map<String, dynamic> params = const {},
    Duration? timeout,
  }) {
    final channel = _channel;
    if (!_ready || channel == null) {
      return Future<T>.error(
        const HermesDesktopRpcException('Hermes gateway is not connected.'),
      );
    }
    final id = 'mobile-${++_requestId}';
    final completer = Completer<Object?>();
    final timer = Timer(timeout ?? requestTimeout, () {
      final pending = _pending.remove(id);
      pending?.completer.completeError(
        HermesDesktopRpcException(
          'Hermes request timed out: $method',
          timedOut: true,
        ),
      );
    });
    _pending[id] = _PendingRpc(completer, timer);
    try {
      channel.sink.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': {..._defaultParams, ...params},
        }),
      );
    } catch (error, stackTrace) {
      _pending.remove(id)?.timer.cancel();
      completer.completeError(error, stackTrace);
    }
    return completer.future.then((value) => value as T);
  }

  void _handleFrame(
    Object? raw,
    WebSocketChannel channel,
    int generation,
    Completer<void> ready,
  ) {
    if (!_owns(channel, generation)) return;
    try {
      final String source;
      if (raw is String) {
        source = raw;
      } else if (raw is List<int>) {
        if (raw.length > kMaxHermesDesktopFrameBytes) {
          throw const FormatException('Hermes gateway frame is too large.');
        }
        source = utf8.decode(raw);
      } else {
        return;
      }
      if (source.length > kMaxHermesDesktopFrameCharacters ||
          (source.length * 3 > kMaxHermesDesktopFrameBytes &&
              utf8.encode(source).length > kMaxHermesDesktopFrameBytes)) {
        throw const FormatException('Hermes gateway frame is too large.');
      }
      validateHermesJsonSource(source);
      final decoded = jsonDecode(source);
      if (decoded is! Map) return;
      final frame = Map<String, dynamic>.from(decoded);
      final id = frame['id']?.toString();
      if (id != null &&
          (frame.containsKey('result') || frame['error'] is Map)) {
        final pending = _pending.remove(id);
        if (pending == null) return;
        pending.timer.cancel();
        final error = frame['error'];
        if (error is Map) {
          pending.completer.completeError(
            HermesDesktopRpcException(
              error['message']?.toString() ?? 'Hermes RPC failed.',
              code: error['code'] is int ? error['code'] as int : null,
            ),
          );
        } else {
          pending.completer.complete(frame['result']);
        }
        return;
      }

      if (frame['method'] == 'event' && frame['params'] is Map) {
        final params = Map<String, dynamic>.from(frame['params'] as Map);
        final type = params['type']?.toString();
        if (type == null || type.isEmpty) return;
        final rawPayload = params['payload'];
        final payload = rawPayload is Map
            ? Map<String, dynamic>.from(rawPayload)
            : <String, dynamic>{};
        if (type == 'gateway.ready') {
          _ready = true;
          if (!ready.isCompleted) ready.complete();
        }
        _events.add(
          HermesDesktopEvent(
            type: type,
            payload: payload,
            sessionId: params['session_id']?.toString(),
          ),
        );
        return;
      }

      // Desktop-only host requests must never reach mobile platform features.
      if (frame['method'] is String && frame['id'] != null) {
        channel.sink.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'error': {
              'code': -32601,
              'message': 'Method not supported on mobile',
            },
          }),
        );
      }
    } catch (error) {
      DebugLogger.warning(
        'invalid-frame-dropped',
        scope: 'hermes/desktop/ws',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
  }

  bool _owns(WebSocketChannel channel, int generation) =>
      identical(_channel, channel) && generation == _socketGeneration;

  void _handleDisconnect(WebSocketChannel channel, int generation) {
    if (!_owns(channel, generation)) return;
    _ready = false;
    _channel = null;
    _rejectPending('Hermes gateway disconnected.');
    _disconnects.add(null);
  }

  void _rejectPending(String message) {
    for (final pending in _pending.values) {
      pending.timer.cancel();
      pending.completer.completeError(
        HermesDesktopRpcException(message, disconnected: true),
      );
    }
    _pending.clear();
  }

  Future<void> disconnect() async {
    _socketGeneration++;
    _ready = false;
    final subscription = _subscription;
    final channel = _channel;
    _subscription = null;
    _channel = null;
    _rejectPending('Hermes gateway disconnected.');
    await subscription?.cancel();
    await channel?.sink.close();
  }

  Future<void> close() async {
    await disconnect();
    await _events.close();
    await _disconnects.close();
  }
}

final class _PendingRpc {
  const _PendingRpc(this.completer, this.timer);

  final Completer<Object?> completer;
  final Timer timer;
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
