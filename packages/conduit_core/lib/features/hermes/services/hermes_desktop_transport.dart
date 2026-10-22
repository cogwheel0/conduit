import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/utils/continuity_probe.dart';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:conduit_core/network/no_redirect_web_socket.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_core/features/hermes/services/hermes_json_guard.dart';
import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';

const int kMaxHermesDesktopFrameBytes = 4 * 1024 * 1024;
const int kMaxHermesDesktopFrameCharacters = 2 * 1024 * 1024;

typedef HermesDesktopChannelFactory = WebSocketChannel Function(
  Uri uri,
  Map<String, String> headers, {
  HttpClient? httpClient,
});

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
    this.sequence,
  });

  final String type;
  final Map<String, dynamic> payload;
  final String? sessionId;
  final int? sequence;
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
  }) : _channelFactory = channelFactory ?? connectNoRedirectWebSocket;

  final HermesDesktopChannelFactory _channelFactory;
  final Duration requestTimeout;
  final _events = StreamController<HermesDesktopEvent>.broadcast();
  final _disconnects = StreamController<void>.broadcast();
  final Map<String, _PendingRpc> _pending = {};
  final Map<String, _PendingServerApproval> _serverApprovals = {};
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

  /// The queue's request id and the JSON-RPC response id are distinct. Match
  /// both the owning runtime and queue id before answering on this socket.
  bool respondToServerApproval({
    required String runtimeId,
    required String approvalId,
    required String choice,
  }) {
    final channel = _channel;
    if (!_ready || channel == null) return false;
    final matches = _serverApprovals.entries
        .where(
          (entry) =>
              entry.value.runtimeId == runtimeId &&
              entry.value.approvalId == approvalId,
        )
        .toList(growable: false);
    if (matches.isEmpty) return false;
    if (matches.length != 1 || !matches.single.value.choices.contains(choice)) {
      throw StateError(
        'This choice is not available for the pending approval.',
      );
    }
    final entry = matches.single;
    channel.sink.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': entry.key,
        'result': {'choice': choice},
      }),
    );
    _serverApprovals.remove(entry.key);
    return true;
  }

  /// Resume snapshots replay still-open requests after a socket reconnect.
  /// Only approvals are supported here; desktop host operations stay rejected.
  List<HermesDesktopEvent> restoreServerApprovals(
    Object? snapshots, {
    required String runtimeId,
  }) {
    if (snapshots is! List || !_ready) return const [];
    final restored = <HermesDesktopEvent>[];
    for (final snapshot in snapshots.take(64)) {
      if (snapshot is! Map || snapshot['method'] != 'approval') continue;
      final params = snapshot['params'];
      if (params is! Map || params['session_id'] != runtimeId) continue;
      final event = _acceptServerApproval(
        snapshot['id'],
        Map<String, dynamic>.from(params),
      );
      if (event != null) {
        restored.add(event);
        _events.add(event);
      }
    }
    return restored;
  }

  HermesDesktopEvent? _acceptServerApproval(
    Object? rawId,
    Map<String, dynamic> params,
  ) {
    final id = validateHermesOpaqueIdentifier(rawId);
    final runtimeId = validateHermesOpaqueIdentifier(params['session_id']);
    final approvalId = validateHermesOpaqueIdentifier(params['request_id']);
    if (id == null || runtimeId == null || approvalId == null) {
      throw const FormatException(
        'Invalid Hermes server approval identifiers.',
      );
    }
    final existing = _serverApprovals[id];
    if (existing != null) {
      if (existing.runtimeId != runtimeId ||
          existing.approvalId != approvalId) {
        throw const FormatException('Hermes reused an approval response id.');
      }
      return null;
    }
    if (_serverApprovals.length >= 64) {
      throw const FormatException('Too many pending Hermes approval requests.');
    }
    final rawChoices = params['choices'];
    final choices = rawChoices is List
        ? rawChoices
              .whereType<String>()
              .where(const {'once', 'session', 'always', 'deny'}.contains)
              .take(4)
              .toSet()
        : <String>{'once', 'deny'};
    if (choices.isEmpty) {
      throw const FormatException(
        'Hermes returned no supported approval choices.',
      );
    }
    _serverApprovals[id] = _PendingServerApproval(
      runtimeId,
      approvalId,
      choices,
    );
    return HermesDesktopEvent(
      type: 'approval.request',
      sessionId: runtimeId,
      payload: {...params, 'choices': choices.toList(growable: false)},
    );
  }

  Future<void> connect(
    Uri uri, {
    Map<String, String> headers = const {},
    HttpClient? httpClient,
  }) async {
    await disconnect();
    final generation = ++_socketGeneration;
    final channel = _channelFactory(uri, headers, httpClient: httpClient);
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
    return ContinuityProbe.measure(
      'rpc',
      () => completer.future.then((value) => value as T),
      {'method': method, 'refresh': params['refresh'] == true},
    );
  }

  void _handleFrame(
    Object? raw,
    WebSocketChannel channel,
    int generation,
    Completer<void> ready,
  ) {
    if (!_owns(channel, generation)) return;
    ContinuityProbe.mark('network-received', {
      'size': raw is String
          ? raw.length
          : raw is List
          ? raw.length
          : 0,
    });
    try {
      final String source;
      if (raw is String) {
        source = raw;
      } else if (raw is List<int>) {
        if (raw.length > kMaxHermesDesktopFrameBytes) {
          throw const HermesResponseTooLargeException(
            'Hermes gateway frame is too large.',
          );
        }
        source = utf8.decode(raw);
      } else {
        return;
      }
      if (source.length > kMaxHermesDesktopFrameCharacters ||
          (source.length * 3 > kMaxHermesDesktopFrameBytes &&
              utf8.encode(source).length > kMaxHermesDesktopFrameBytes)) {
        throw const HermesResponseTooLargeException(
          'Hermes gateway frame is too large.',
        );
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
        ContinuityProbe.mark('network-decoded', {'event': type});
        final rawPayload = params['payload'];
        final payload = rawPayload is Map
            ? Map<String, dynamic>.from(rawPayload)
            : <String, dynamic>{};
        if (type == 'gateway.ready') {
          _ready = true;
          // New gateways fail approval requests immediately unless the client
          // advertises its server-request handler. Older gateways may reject
          // this optional handshake; their event/RPC approval flow still works.
          unawaited(
            request<Object?>(
              'client.capabilities',
              params: {'server_requests': true},
            ).then<void>((_) {}, onError: (Object _) {}),
          );
          if (!ready.isCompleted) ready.complete();
        }
        if (type == 'request.cancel') {
          final id = payload['id'];
          final pending = _serverApprovals[id];
          if (pending != null && params['session_id'] == pending.runtimeId) {
            _serverApprovals.remove(id);
            _events.add(
              HermesDesktopEvent(
                type: 'approval.expire',
                sessionId: pending.runtimeId,
                payload: {'request_id': pending.approvalId},
              ),
            );
          }
        }
        _events.add(
          HermesDesktopEvent(
            type: type,
            payload: payload,
            sessionId: params['session_id']?.toString(),
            sequence: params['seq'] is int ? params['seq'] as int : null,
          ),
        );
        return;
      }

      if (frame['method'] == 'approval' && frame['id'] != null) {
        try {
          final params = frame['params'];
          if (params is! Map) throw const FormatException('Invalid approval.');
          final event = _acceptServerApproval(
            frame['id'],
            Map<String, dynamic>.from(params),
          );
          if (event != null) _events.add(event);
        } on FormatException {
          channel.sink.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'error': {
                'code': -32602,
                'message': 'Invalid mobile approval request',
              },
            }),
          );
        }
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
    _serverApprovals.clear();
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
    _serverApprovals.clear();
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

final class _PendingServerApproval {
  const _PendingServerApproval(this.runtimeId, this.approvalId, this.choices);
  final String runtimeId;
  final String approvalId;
  final Set<String> choices;
}

final class _PendingRpc {
  const _PendingRpc(this.completer, this.timer);

  final Completer<Object?> completer;
  final Timer timer;
}
